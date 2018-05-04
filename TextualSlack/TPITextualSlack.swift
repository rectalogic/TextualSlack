//
//  TPITextualSlack.swift
//  TextualSlack
//
//  Created by Andrew Wason on 4/26/18.
//  Copyright © 2018 Andrew Wason. All rights reserved.
//

import Cocoa
import SlackKit

class TPITextualSlack: NSObject, THOPluginProtocol {
    @IBOutlet var preferencesPane: NSView!
    let slackKit = SlackKit()
    // Map slackbot token to IRCClient
    var ircClients = [String : IRCClient]()
    // Map IRCChannel to slack channelID
    var ircChannels = [IRCChannel : String]()
    let userRegex = try! NSRegularExpression(pattern: "<@(U\\w+)>")

    func pluginLoadedIntoMemory() {
        DispatchQueue.main.sync {
            _ = Bundle(for: type(of: self)).loadNibNamed("TextualSlack", owner: self, topLevelObjects: nil)
        }

        if let serverMenu = masterController().menuController?.mainMenuServerMenuItem?.submenu {
            let menuItem = NSMenuItem(title: "Connect to Slack", target: self, action: #selector(menuItemClicked(sender:)))
            serverMenu.addItem(NSMenuItem.separator())
            serverMenu.addItem(menuItem)
        }

        slackKit.notificationForEvent(.message) { [weak self] (event, clientConnection) in
            DispatchQueue.main.async {
                self?.didRecieveSlackMessage(event: event, clientConnection: clientConnection)
            }
        }
        slackKit.notificationForEvent(.hello) { [weak self] (event, clientConnection) in
            DispatchQueue.main.async {
                self?.logMessage(clientConnection: clientConnection) { (ircClient) in
                    return "Connected to \(ircClient.config.connectionName)"
                }
            }
        }
        slackKit.notificationForEvent(.error) { [weak self] (event, clientConnection) in
            DispatchQueue.main.async {
                self?.logMessage(clientConnection: clientConnection) { (ircClient) in
                    return "Error: \(event)"
                }
            }
        }

        if TPCPreferencesUserDefaults.shared().bool(forKey: "Slack Extension -> Autoconnect") {
            DispatchQueue.main.async {
                self.connectToSlack()
            }
        }
    }

    func menuItemClicked(sender: NSMenuItem) {
        connectToSlack()
    }

    func logMessage(clientConnection: ClientConnection?, message: (_ ircClient: IRCClient) -> String) {
        if let token = clientConnection?.rtm?.token, let ircClient = ircClients[token] {
            ircClient.print(message(ircClient), by: nil, in: nil, as: .noticeType, command: TVCLogLineDefaultCommandValue)
        }
    }

    func connectToSlack() {
        if let slackBots = TPCPreferencesUserDefaults.shared().array(forKey: "Slack Extension -> SlackBots") as! [[String : String]]? {
            for slackBot in slackBots {
                if let token = slackBot["botToken"] {
                    let ircClient: IRCClient
                    if let client = masterController().world.findClient(withId: token) {
                        ircClient = client
                    }
                    else {
                        let config = IRCClientConfigMutable(dictionary: ["uniqueIdentifier": token])
                        config.connectionName = slackBot["name"] ?? "Slack"
                        config.autoConnect = false
                        config.autoReconnect = false
                        config.sidebarItemExpanded = true
                        config.serverList = [IRCServer(dictionary: ["serverAddress": "textual.slack.example"])]
                        ircClient = masterController().world.createClient(with: config)
                    }
                    ircClients[token] = ircClient
                    if slackKit.clients[token]?.rtm == nil {
                        slackKit.addRTMBotWithAPIToken(token, options: RTMOptions(reconnect: true))
                    }
                    if slackKit.clients[token]?.webAPI == nil {
                        slackKit.addWebAPIAccessWithToken(token)
                    }

                    if let clientConnection = slackKit.clients[token], let webAPI = clientConnection.webAPI {
                        webAPI.channelsList(excludeArchived: true, excludeMembers: true, success: { (channels) in
                            if let channels = channels {
                                DispatchQueue.main.async {
                                    for channel in channels {
                                        if let channelID = channel["id"] as? String, let channelName = channel["name"] as? String, let isMember = channel["is_member"] as? Bool {
                                            if isMember {
                                                _ = self.ensureIRCChannel(ircClient: ircClient, slackTeamID: clientConnection.client?.team?.id, slackChannelID: channelID, slackChannelName: channelName)
                                                //XXX populate with recent messages ?
                                            }
                                        }
                                    }
                                }
                            }
                        }) { (error) in
                            DispatchQueue.main.async {
                                self.logMessage(clientConnection: clientConnection) { (ircClient) in
                                    return "Error fetching channels: \(error)"
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func didRecieveSlackMessage(event: Event, clientConnection: ClientConnection?) {
        guard let message = event.message,
            let client = clientConnection?.client,
            let slackChannelID = message.channel,
            let slackChannelName = client.channels[slackChannelID]?.name,
            let slackUser = message.user,
            let text = message.text,
            let token = clientConnection?.rtm?.token,
            let ircClient = ircClients[token] else {
            return
        }
        let ircChannel = ensureIRCChannel(ircClient: ircClient, slackTeamID: client.team?.id, slackChannelID: slackChannelID, slackChannelName: slackChannelName)
        let receivedAt: Date
        //XXX seems wrong, slack time 3:04pm is shown as 10:40 in irc
        if let ts = message.ts, let tv = Double(ts) {
            receivedAt = Date(timeIntervalSince1970: tv / 1000.0)
        }
        else {
            receivedAt = Date()
        }

        // Replace slack <@Uxxxx> user references with usernames
        // https://stackoverflow.com/questions/6222115/how-do-you-use-nsregularexpressions-replacementstringforresultinstringoffset
        var mutableText = text
        var offset = 0
        for result in userRegex.matches(in: text, options: [], range: NSRange(location: 0, length: text.count)) {
            var resultRange = result.range
            resultRange.location += offset
            let userID = userRegex.replacementString(for: result, in: mutableText, offset: offset, template: "$1")
            if let userName = client.users[userID]?.name, let range = Range<String.Index>(resultRange, in: mutableText) {
                mutableText.replaceSubrange(range, with: userName)
                offset += userName.count - resultRange.length
            }
        }

        if let attachments = message.attachments {
            for attachment in attachments {
                if let title = attachment.title {
                    mutableText.append(" " + title)
                    mutableText.append(" ")
                }
                if let imageURL = attachment.imageURL {
                    mutableText.append(" " + imageURL)
                }
            }
        }

        let userName = client.users[slackUser]?.name ?? "unknown"
        ircClient.print(mutableText, by: userName, in: ircChannel, as: .privateMessageType, command: TVCLogLineDefaultCommandValue, receivedAt: receivedAt, isEncrypted: false, referenceMessage: nil) { (context) in
            // Don't mark messages this user sent on the slack side as unread
            if !ircClient.stringIsNickname(userName) {
                ircClient.setUnreadStateFor(ircChannel!)
            }
        }
    }

    func interceptUserInput(_ input: Any, command: IRCPrivateCommand) -> Any? {
        guard let token = masterController().mainWindow.selectedClient?.uniqueIdentifier,
            let ircClient = ircClients[token],
            let selectedChannel = masterController().mainWindow.selectedChannel,
            let channelID = ircChannels[selectedChannel],
            let clientConnection = slackKit.clients[token],
            let webAPI = self.slackKit.webAPI else {
            return input
        }

        let inputText: String
        if input is NSAttributedString {
            inputText = (input as! NSAttributedString).string
        }
        else {
            inputText = input as! String
        }
        webAPI.sendMessage(channel: channelID, text: inputText, username: ircClient.userNickname, asUser: false, parse: WebAPI.ParseMode.full, linkNames: true, attachments: nil, unfurlLinks: false, unfurlMedia: false, iconURL: nil, iconEmoji: nil, success: nil) { (error) in
            self.logMessage(clientConnection: clientConnection) { (ircClient) in
                return "Error sending message: \(error)"
            }
        }

        return input
    }

    func ensureIRCChannel(ircClient: IRCClient, slackTeamID: String?, slackChannelID: String, slackChannelName: String) -> IRCChannel? {
        let ircChannelName = "#" + slackChannelName
        if let ircChannel = ircClient.findChannel(ircChannelName) {
            ircChannels[ircChannel] = slackChannelID
            ircChannel.activate()
            return ircChannel
        }
        else {
            var topic = "https://slack.com/app_redirect?channel=\(slackChannelID)"
            if let slackTeamID = slackTeamID {
                topic += "&team=\(slackTeamID)"
            }
            let config = IRCChannelConfig(dictionary: [
                "channelName": ircChannelName,
                // See TVCLogController.inlineMediaEnabledForView comment - global preferences changes meaning of ignoreInlineMedia
                "ignoreInlineMedia": TPCPreferences.showInlineMedia() ? false : true,
                "defaultTopic": topic,
            ])
            let ircChannel = masterController().world.createChannel(with: config, on: ircClient)
            ircChannel.topic = topic
            ircChannels[ircChannel] = slackChannelID
            ircChannel.activate()
            return ircChannel
        }
    }

    var pluginPreferencesPaneView: NSView {
        get {
            return preferencesPane
        }
    }

    var pluginPreferencesPaneMenuItemName: String {
        get {
            return "Textual Slack"
        }
    }
}
