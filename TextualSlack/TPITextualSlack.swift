//
//  TPITextualSlack.swift
//  TextualSlack
//
//  Created by Andrew Wason on 4/26/18.
//  Copyright © 2018 Andrew Wason. All rights reserved.
//

import Cocoa
import SlackKit

let serverAddress = "textual.slack.example"

class TPITextualSlack: NSObject, THOPluginProtocol {
    @IBOutlet var preferencesPane: NSView!

    lazy var slackIRCClient: IRCClient = {
        for client in masterController().world.clientList {
            if client.config.serverList.first?.serverAddress == serverAddress {
                return client
            }
        }
        let config = IRCClientConfigMutable()
        config.connectionName = "Slack"
        config.serverList = [IRCServer(dictionary: ["serverAddress": serverAddress])]
        return masterController().world.createClient(with: config)
    }()
    let slackBot = SlackKit()

    func pluginLoadedIntoMemory() {
        DispatchQueue.main.sync {
            _ = Bundle(for: type(of: self)).loadNibNamed("TextualSlack", owner: self, topLevelObjects: nil)
        }
        //XXX support multiple bots, each with "autoconnect" bool and username override
        //XXX NSTableView bound to NSArrayController on user defaults https://stackoverflow.com/questions/28820337/nstableview-bound-to-nsarraycontroller-doesnt-save-changes
        if let botToken = TPCPreferencesUserDefaults.shared().string(forKey: "Slack Extension -> Bot Token") {
            slackBot.addRTMBotWithAPIToken(botToken, options: RTMOptions(reconnect: true))
            slackBot.addWebAPIAccessWithToken(botToken)
            slackBot.notificationForEvent(.message) { [weak self] (event, clientConnection) in
                guard let message = event.message, let client = clientConnection?.client else {
                    return
                }
                DispatchQueue.main.async {
                    self?.didRecieveSlackMessage(message: message, client: client)
                }
            }
        }
    }

    func didRecieveSlackMessage(message: Message, client: Client) {
        guard let slackChannel = message.channel, let slackUser = message.user, let text = message.text else {
            return
        }
        let ircChannel = self.slackIRCClient.findChannelOrCreate((client.channels[slackChannel]?.name)!, isPrivateMessage: true)
        let receivedAt: Date
        if let ts = message.ts, let tv = Double(ts) {
            receivedAt = Date(timeIntervalSince1970: tv / 1000.0)
        }
        else {
            receivedAt = Date()
        }
        self.slackIRCClient.print(text, by: client.users[slackUser]?.name, in: ircChannel, as: TVCLogLineType.privateMessageType, command: TVCLogLineDefaultCommandValue, receivedAt: receivedAt, isEncrypted: false, referenceMessage: nil) { (context) in
            self.slackIRCClient.setUnreadStateFor(ircChannel!)
        }
    }

    func interceptUserInput(_ input: Any, command: IRCPrivateCommand) -> Any? {
        if masterController().mainWindow.selectedClient != self.slackIRCClient {
            return input
        }
        if let token = self.slackBot.rtm?.token,
           let client = self.slackBot.clients[token]?.client,
           let selectedChannel = masterController().mainWindow.selectedChannel,
           //XXX name may not be unique, need to create all channels up front and maintain structs pairing irc/slack channels
           let channelID = client.channels.filter({ $0.value.name == selectedChannel.name }).first?.value.id {

            let inputText: String
            if input is NSAttributedString {
                inputText = (input as! NSAttributedString).string
            }
            else {
                inputText = input as! String
            }
            //XXX on failure, print error to irc server console
            self.slackBot.webAPI?.sendMessage(channel: channelID, text: inputText, username: self.slackIRCClient.userNickname, asUser: false, parse: WebAPI.ParseMode.full, linkNames: true, attachments: nil, unfurlLinks: false, unfurlMedia: false, iconURL: nil, iconEmoji: nil, success: nil, failure: nil)
        }
        return input //XXX nil asserts
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
