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
    // Map slack user token to IRCClient
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
                if let slackClient = clientConnection?.client, let ircChannels = self?.ircChannels {
                    for (ircChannel, slackChannelID) in ircChannels {
                        if let slackChannel = slackClient.channels[slackChannelID], let ircClient = ircChannel.associatedClient {
                            self?.ensureIRCChannelMembers(ircClient: ircClient, ircChannel: ircChannel, slackClient: slackClient, slackChannel: slackChannel)
                        }
                    }
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
        if let slackTokens = TPCPreferencesUserDefaults.shared().array(forKey: "Slack Extension -> Tokens") as? [[String : String]] {
            for slackToken in slackTokens {
                if let token = slackToken["token"] {
                    let ircClient: IRCClient
                    if let client = masterController().world.findClient(withId: token) {
                        ircClient = client
                    }
                    else {
                        let config = IRCClientConfigMutable(dictionary: ["uniqueIdentifier": token])
                        config.connectionName = slackToken["name"] ?? "Slack"
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
            let slackChannel = client.channels[slackChannelID],
            let slackChannelName = slackChannel.name,
            let slackUser = message.user ?? message.botID,
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
            if let userName = client.users[userID]?.name ?? client.bots[userID]?.name, let range = Range<String.Index>(resultRange, in: mutableText) {
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

        let userName = client.users[slackUser]?.name ?? client.bots[slackUser]?.name ?? "unknown"
        ircClient.print(mutableText, by: userName, in: ircChannel, as: .privateMessageType, command: TVCLogLineDefaultCommandValue, receivedAt: receivedAt, isEncrypted: false, referenceMessage: nil) { (context) in
            // Don't mark messages this user sent on the slack side as unread
            if !ircClient.nicknameIsMyself(userName) {
                ircClient.setUnreadStateFor(ircChannel)
            }
        }

        ensureIRCChannelMembers(ircClient: ircClient, ircChannel: ircChannel, slackClient: client, slackChannel: slackChannel)
    }

    func interceptUserInput(_ input: Any, command: IRCPrivateCommand) -> Any? {
        guard let token = masterController().mainWindow.selectedClient?.uniqueIdentifier,
            let ircClient = ircClients[token],
            let selectedChannel = masterController().mainWindow.selectedChannel,
            let channelID = ircChannels[selectedChannel],
            let clientConnection = slackKit.clients[token],
            let webAPI = clientConnection.webAPI else {
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
        webAPI.sendMessage(channel: channelID, text: inputText, username: ircClient.userNickname, asUser: true, parse: WebAPI.ParseMode.full, linkNames: true, attachments: nil, unfurlLinks: true, unfurlMedia: true, iconURL: nil, iconEmoji: nil, success: nil) { (error) in
            self.logMessage(clientConnection: clientConnection) { (ircClient) in
                return "Error sending message: \(error)"
            }
        }

        return ""
    }

    func ensureIRCChannelMembers(ircClient: IRCClient, ircChannel: IRCChannel, slackClient: Client, slackChannel: Channel) {
        guard let slackChannelMemberIDs = slackChannel.members else {
            return
        }
        let ircChannelNicknames = Set(ircChannel.memberList.map { $0.user.nickname })
        let slackChannelMemberMap = Dictionary<String, User>(uniqueKeysWithValues: slackChannelMemberIDs.flatMap {
            guard let user = slackClient.users[$0], let username = user.name else {
                return nil
            }
            return (username, user)
        })
        let slackUsernames = Set(slackChannelMemberMap.keys)
        // Add users to IRC that are in slack channel and not in IRC
        for username in slackUsernames.subtracting(ircChannelNicknames) {
            let ircUser: IRCUser
            if let existingIRCUser = ircClient.findUser(username) {
                ircUser = existingIRCUser
            }
            else {
                let newIRCUser = IRCUserMutable(nickname: username, on: ircClient)
                newIRCUser.username = username
                if let slackUser = slackChannelMemberMap[username] {
                    newIRCUser.realName = slackUser.profile?.realName
                }
                ircUser = newIRCUser
            }

            // This uses a private API
            ircChannel.addMember(IRCChannelUser(user: ircUser))
        }
        // Remove users from IRC that are not in slack channel
        for username in ircChannelNicknames.subtracting(slackUsernames) {
            ircChannel.removeMember(withNickname: username)
        }
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
            if !ircChannel.isActive {
                ircChannel.activate()
            }
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

    @IBAction func launchSlackTokenWebsite(sender: Any) {
        if let url = URL(string: "https://api.slack.com/custom-integrations/legacy-tokens") {
            NSWorkspace.shared().open(url)
        }
    }
}
