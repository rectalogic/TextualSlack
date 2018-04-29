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
        if let botToken = TPCPreferencesUserDefaults.shared().string(forKey: "Slack Extension -> Bot Token") {
            slackBot.addRTMBotWithAPIToken(botToken, options: RTMOptions(reconnect: true))
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
