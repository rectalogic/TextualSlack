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

class SlackChannelInfo {
    typealias MarkReadFunc = (_ channel: String, _ timestamp: String, _ success: ((String) -> Void)?, _ failure: WebAPI.FailureClosure?) -> ()
    let channelID: String
    let markRead: MarkReadFunc
    var lastMessageTS: String?
    var lastMarkTS: String?

    init(channelID: String, markRead: @escaping MarkReadFunc) {
        self.channelID = channelID
        self.markRead = markRead
    }

    var needsMark: Bool {
        return lastMessageTS != nil && lastMessageTS != lastMarkTS
    }
}

class TPITextualSlack: NSObject, THOPluginProtocol {
    @IBOutlet var preferencesPane: NSView!
    let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "plugin")
    let slackKit = SlackKit()
    // Map slack user token to IRCClient
    var ircClients = [String : IRCClient]()
    // Map IRCChannel to slack channelID
    var ircChannels = [IRCChannel : SlackChannelInfo]()
    let messageRegex = try! NSRegularExpression(pattern: "<@(U\\w+)>|:([\\w\\-\\+]+):")
    var selectionChangeObserver: NSObjectProtocol?
    var didBecomeMainObserver: NSObjectProtocol?

    lazy var emojiMap: Dictionary<String, String>? = { [unowned self] in
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: "emoji", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                let json =  try JSONSerialization.jsonObject(with: data)
                return json as? Dictionary<String, String>
            } catch let error {
                os_log("Error loading emoji %@", log: self.log, type: .error, String(reflecting: error))
            }
        }
        return nil
    }()

    func pluginLoadedIntoMemory() {
        DispatchQueue.main.sync {
            _ = Bundle(for: type(of: self)).loadNibNamed("TextualSlack", owner: self, topLevelObjects: nil)
        }

        let center = NotificationCenter.default
        selectionChangeObserver = center.addObserver(forName: NSOutlineView.selectionDidChangeNotification, object: masterController().mainWindow.serverList, queue: OperationQueue.main) { (notification) in
            self.ensureChannelsMarked()
        }
        didBecomeMainObserver = center.addObserver(forName: NSWindow.didBecomeMainNotification, object: masterController().mainWindow, queue: OperationQueue.main) { (notification) in
            self.ensureChannelsMarked()
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
                    for (ircChannel, slackChannelInfo) in ircChannels {
                        if let slackChannel = slackClient.channels[slackChannelInfo.channelID], let ircClient = ircChannel.associatedClient {
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

    func pluginWillBeUnloadedFromMemory() {
        let center = NotificationCenter.default
        if let o = self.selectionChangeObserver {
            center.removeObserver(o)
        }
        if let o = self.didBecomeMainObserver {
            center.removeObserver(o)
        }
    }

    @objc func menuItemClicked(sender: NSMenuItem) {
        connectToSlack()
    }

    func logMessage(clientConnection: ClientConnection?, message: (_ ircClient: IRCClient) -> String) {
        if let token = clientConnection?.rtm?.token, let ircClient = ircClients[token] {
            ircClient.print(message(ircClient), by: nil, in: nil, as: .notice, command: TVCLogLineDefaultCommandValue)
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
                    if let rtm = slackKit.clients[token]?.rtm {
                        rtm.connect()
                    }
                    else {
                        slackKit.addRTMBotWithAPIToken(token, options: RTMOptions(reconnect: true))
                    }
                    if slackKit.clients[token]?.webAPI == nil {
                        slackKit.addWebAPIAccessWithToken(token)
                    }

                    if let clientConnection = slackKit.clients[token], let webAPI = clientConnection.webAPI, let slackClient = clientConnection.client {
                        webAPI.channelsList(excludeArchived: true, excludeMembers: true, success: { (channels) in
                            if let channels = channels {
                                DispatchQueue.main.async {
                                    for channel in channels {
                                        if let channelID = channel["id"] as? String, let slackChannel = slackClient.channels[channelID] {
                                            if slackChannel.isMember ?? false {
                                                _ = self.ensureIRCChannel(ircClient: ircClient, webAPI: webAPI, slackTeamID: clientConnection.client?.team?.id, slackChannel: slackChannel)
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
            os_log("Event %@", log: log, type: .debug, String(reflecting: event))
        #endif
        guard
            let client = clientConnection?.client,
            let slackChannelID = event.nestedMessage?.channel ?? event.message?.channel,
            let slackChannel = client.channels[slackChannelID],
            let slackUser = (event.nestedMessage?.user ?? event.message?.user) ?? (event.nestedMessage?.botID ?? event.message?.botID),
            let text = event.nestedMessage?.text ?? event.message?.text,
            let token = clientConnection?.rtm?.token,
            let webAPI = clientConnection?.webAPI,
            let ircClient = ircClients[token],
            let ircChannel = ensureIRCChannel(ircClient: ircClient, webAPI: webAPI, slackTeamID: client.team?.id, slackChannel: slackChannel) else {
            return
        }

        let receivedAt: Date
        if let ts = event.nestedMessage?.ts ?? event.message?.ts, let tv = Double(ts) {
            receivedAt = Date(timeIntervalSince1970: tv)
        }
        else {
            receivedAt = Date()
        }

        // Replace slack <@Uxxxx> user references with usernames, and emoji :xxxx: with unicode emoji
        // https://stackoverflow.com/questions/6222115/how-do-you-use-nsregularexpressions-replacementstringforresultinstringoffset
        var mutableText = text
        if event.edited?.ts != nil {
            mutableText = "(edited) \(mutableText)"
        }
        var offset = 0
        for result in messageRegex.matches(in: text, options: [], range: NSRange(location: 0, length: text.count)) {
            let replacementValue: String?
            var resultRange = result.range
            resultRange.location += offset
            // Emoji match
            if result.range(at: 2).location != NSNotFound {
                let emoji = messageRegex.replacementString(for: result, in: mutableText, offset: offset, template: "$2")
                replacementValue = emojiMap?[emoji]
            }
            // Username match
            else {
                let userID = messageRegex.replacementString(for: result, in: mutableText, offset: offset, template: "$1")
                replacementValue = client.users[userID]?.name ?? client.bots[userID]?.name
            }
            if let replacementValue = replacementValue, let range = Range<String.Index>(resultRange, in: mutableText) {
                mutableText.replaceSubrange(range, with: replacementValue)
                // Something is wrong with replacementString offset, it seems to be counting utf16 instead of characters so count utf16 here
                // NSString.length is defined as "the number of UTF-16 code units", so replacementString must be defined in terms of utf16 too
                offset += (replacementValue.utf16.count - resultRange.length)
            }
        }

        if let attachments = event.nestedMessage?.attachments ?? event.message?.attachments {
            for attachment in attachments {
                if let fallback = attachment.fallback {
                    mutableText.append(" " + fallback)
                }
                if let attachmentText = attachment.text {
                    mutableText.append(" " + attachmentText)
                }
                if let imageURL = attachment.imageURL {
                    mutableText.append(" " + imageURL)
                }
            }
        }

        if let files = event.nestedMessage?.files ?? event.message?.files {
            for file in files {
                if let title = file.title {
                    mutableText.append(" " + title)
                }
                if let urlPrivate = file.urlPrivate {
                    mutableText.append(" File link: " + urlPrivate)
                }
            }
        }

        // Make our IRC nickname match our slack username
        if let slackUsername = client.authenticatedUser?.name {
            if slackUsername != ircClient.userNickname {
                ircClient.changeNickname(slackUsername)
            }
        }

        let userName = client.users[slackUser]?.name ?? client.bots[slackUser]?.name ?? "unknown"
        ircClient.print(mutableText, by: userName, in: ircChannel, as: .privateMessage, command: TVCLogLineDefaultCommandValue, receivedAt: receivedAt, isEncrypted: false, referenceMessage: nil) { (context) in
            if let ts = event.nestedMessage?.ts ?? event.message?.ts, let slackChannelInfo = self.ircChannels[ircChannel] {
                slackChannelInfo.lastMessageTS = ts
            }
            // Don't mark our own messages as unread
            if !ircClient.nicknameIsMyself(userName) {
                // Slack @here and our nickname should highlight
                let isHighlight = context.isHighlight || mutableText.contains("<!here>")
                if ircClient.notifyText(isHighlight ? .highlight : .channelMessage, lineType: .privateMessage, target: ircChannel, nickname: userName, text: mutableText) {
                    if isHighlight {
                        ircClient.setHighlightStateFor(ircChannel)
                    }
                    ircClient.setUnreadStateFor(ircChannel, isHighlight: isHighlight)
                }
            }
        }

        ensureIRCChannelMembers(ircClient: ircClient, ircChannel: ircChannel, slackClient: client, slackChannel: slackChannel)
    }

    func interceptUserInput(_ input: Any, command: IRCRemoteCommand) -> Any? {
        guard
            let token = masterController().mainWindow.selectedClient?.uniqueIdentifier,
            let selectedChannel = masterController().mainWindow.selectedChannel,
            let slackChannelInfo = ircChannels[selectedChannel],
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
        webAPI.sendMessage(channel: slackChannelInfo.channelID, text: inputText, username: nil, asUser: true, parse: WebAPI.ParseMode.full, linkNames: true, attachments: nil, unfurlLinks: true, unfurlMedia: true, iconURL: nil, iconEmoji: nil, success: nil) { (error) in
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
        let slackChannelMemberMap = Dictionary<String, User>(uniqueKeysWithValues: slackChannelMemberIDs.compactMap {
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

    func ensureIRCChannel(ircClient: IRCClient, webAPI: WebAPI, slackTeamID: String?, slackChannel: Channel) -> IRCChannel? {
        guard
            let slackChannelID = slackChannel.id,
            let slackChannelName = slackChannel.name else {
                return nil
        }
        let markRead: SlackChannelInfo.MarkReadFunc =
            (slackChannel.isIM ?? false)
            ? webAPI.markIM
            : ((slackChannel.isMPIM ?? false) ? webAPI.markMPIM : webAPI.markChannel)
        var topic = "https://slack.com/app_redirect?channel=\(slackChannelID)"
        if let slackTeamID = slackTeamID {
            topic += "&team=\(slackTeamID)"
        }
        let ircChannelName = "#" + slackChannelName
        if let ircChannel = ircClient.findChannel(ircChannelName) {
            ircChannel.topic = topic
            if !ircChannels.keys.contains { $0 === ircChannel } {
                ircChannels[ircChannel] = SlackChannelInfo(channelID: slackChannelID, markRead: markRead)
            }
            if !ircChannel.isActive {
                ircChannel.activate()
            }
            return ircChannel
        }
        else {
            let config = IRCChannelConfig(dictionary: [
                "channelName": ircChannelName,
                // 7.0.10 changes inline media preference names, see comments in IRCChannelConfig.populateDictionaryValues
                "inlineMediaEnabled": true,
                "inlineMediaDisabled": false,
                "defaultTopic": topic,
            ])
            let ircChannel = masterController().world.createChannel(with: config, on: ircClient)
            ircChannel.topic = topic
            ircChannels[ircChannel] = SlackChannelInfo(channelID: slackChannelID, markRead: markRead)
            ircChannel.activate()
            return ircChannel
        }
    }

    func ensureChannelsMarked() {
        for (ircChannel, slackChannelInfo) in ircChannels {
            if slackChannelInfo.needsMark && !ircChannel.isUnread {
                if let ircClient = ircChannel.associatedClient, let clientConnection = slackKit.clients[ircClient.uniqueIdentifier], let ts = slackChannelInfo.lastMessageTS {
                    slackChannelInfo.markRead(slackChannelInfo.channelID, ts, { (ts) in
                        slackChannelInfo.lastMarkTS = slackChannelInfo.lastMessageTS
                    }) { (error) in
                        self.logMessage(clientConnection: clientConnection) { (ircClient) in
                            return "Error marking channel \(ircChannel.name): \(error)"
                        }
                    }
                }
            }
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
            NSWorkspace.shared.open(url)
        }
    }
}
