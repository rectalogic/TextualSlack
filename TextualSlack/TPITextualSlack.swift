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
    lazy var slackIRCClient: IRCClient = {
        let config = IRCClientConfigMutable()
        config.connectionName = "Slack"
        config.serverList = [IRCServer(dictionary: ["serverAddress": "textual.slack.example"])]
        return masterController().world.createClient(with: config)
    }()

    func pluginLoadedIntoMemory() {
        let bot = SlackKit()
        bot.addRTMBotWithAPIToken("XXX")
        bot.notificationForEvent(.message) { [weak self] (event, client) in
            guard let message = event.message else {
                return
            }
            DispatchQueue.main.async {
                self?.didRecieveSlackMessage(message: message)
            }
        }
    }

    func didRecieveSlackMessage(message: Message) {
        guard let slackChannel = message.channel, let slackUser = message.username, let text = message.text else {
            return
        }
        print(text)
        let ircChannel = self.slackIRCClient.findChannelOrCreate(slackChannel, isPrivateMessage: true)
        self.slackIRCClient.print(text, by: slackUser, in: ircChannel, as: TVCLogLineType.privateMessageType, command: TVCLogLineDefaultCommandValue)
    }
}
