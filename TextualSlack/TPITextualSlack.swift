//
//  TPITextualSlack.swift
//  TextualSlack
//
//  Created by Andrew Wason on 4/26/18.
//  Copyright © 2018 Andrew Wason. All rights reserved.
//

import os.log
import Cocoa
import SlackKit

class TPITextualSlack: NSObject, THOPluginProtocol {
    @IBOutlet var preferencesPane: NSView!
    let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "plugin")
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

        slackKit.notificationForEvent(.fileShared) { [weak self] (event, clientConnection) in
            DispatchQueue.main.async {
                self?.didRecieveSlackMessage(event: event, clientConnection: clientConnection)
            }
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
        if let slackBots = TPCPreferencesUserDefaults.shared().array(forKey: "Slack Extension -> SlackBots") as? [[String : String]] {
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
        #if DEBUG
        if let log = self?.log {
            os_log("Event %@", log: log, type: .debug, String(reflecting: event))
        }
        #endif
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
        if let ts = message.ts, let tv = Double(ts) {
            receivedAt = Date(timeIntervalSince1970: tv)
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
                }
                if let imageURL = attachment.imageURL {
                    mutableText.append(" " + imageURL)
                }
            }
        }

        if let file = message.file {
            if let title = file.title {
                mutableText.append(" " + title)
            }
            if let thumb360 = file.thumb360 {
                mutableText.append(" " + thumb360)
            }
            if let permalink = file.permalink {
                mutableText.append(" File link: " + permalink)
            }
        }

        let userName = client.users[slackUser]?.name ?? "unknown"
        ircClient.print(mutableText, by: userName, in: ircChannel, as: .privateMessageType, command: TVCLogLineDefaultCommandValue, receivedAt: receivedAt, isEncrypted: false, referenceMessage: nil) { (context) in
            // Don't mark messages this user sent on the slack side as unread
            if !ircClient.stringIsNickname(userName) {
                ircClient.setUnreadStateFor(ircChannel)
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
        if let input = input as? NSAttributedString {
            inputText = input.string
        }
        else if let input = input as? String {
            inputText = input
        }
        else {
            inputText = ""
        }
        webAPI.sendMessage(channel: channelID, text: inputText, username: ircClient.userNickname, asUser: false, parse: WebAPI.ParseMode.full, linkNames: true, attachments: nil, unfurlLinks: false, unfurlMedia: false, iconURL: nil, iconEmoji: nil, success: nil) { (error) in
            self.logMessage(clientConnection: clientConnection) { (ircClient) in
                return "Error sending message: \(error)"
            }
        }

        return input
    }

    func ensureIRCChannel(ircClient: IRCClient, slackTeamID: String?, slackChannelID: String, slackChannelName: String) -> IRCChannel {
        var topic = "https://slack.com/app_redirect?channel=\(slackChannelID)"
        if let slackTeamID = slackTeamID {
            topic += "&team=\(slackTeamID)"
        }
        let ircChannelName = "#" + slackChannelName
        if let ircChannel = ircClient.findChannel(ircChannelName) {
            ircChannel.topic = topic
            ircChannels[ircChannel] = slackChannelID
            ircChannel.activate()
            return ircChannel
        }
        else {
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
