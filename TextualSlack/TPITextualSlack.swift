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

    func pluginLoadedIntoMemory() {
        DispatchQueue.main.sync {
            _ = Bundle(for: type(of: self)).loadNibNamed("TextualSlack", owner: self, topLevelObjects: nil)
        }

        if let serverMenu = masterController().menuController?.mainMenuServerMenuItem?.menu {
            let menuItem = NSMenuItem(title: "Connect to Slack", target: self, action: #selector(menuItemClicked(sender:)))
            serverMenu.addItem(NSMenuItem.separator())
            serverMenu.addItem(menuItem)
        }

        //XXX listen for and log .error and .hello ?
        slackKit.notificationForEvent(.message) { [weak self] (event, clientConnection) in
            DispatchQueue.main.async {
                self?.didRecieveSlackMessage(event: event, clientConnection: clientConnection)
            }
        }

        if TPCPreferencesUserDefaults.shared().bool(forKey: "Slack Extension -> Autoconnect") {
            connectToSlack()
        }
    }

    func menuItemClicked(sender: NSMenuItem) {
        connectToSlack()
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
                    slackKit.addRTMBotWithAPIToken(token, options: RTMOptions(reconnect: true))
                    slackKit.addWebAPIAccessWithToken(token)

                    if let clientConnection = slackKit.clients[token], let channels = clientConnection.client?.channels {
                        for (_, channel) in channels {
                            if let channelName = channel.name {
                                ircClient.findChannelOrCreate(channelName, isPrivateMessage: true)
                                //XXX populate with recent messages
                                //XXX need to track slack channel ID and associate with irc channel
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
            let channelName = client.channels[slackChannelID]?.name,
            let slackUser = message.user,
            let text = message.text,
            let token = clientConnection?.rtm?.token,
            let ircClient = ircClients[token] else {
            return
        }
        let ircChannel = ircClient.findChannelOrCreate(channelName, isPrivateMessage: true)
        let receivedAt: Date
        if let ts = message.ts, let tv = Double(ts) {
            receivedAt = Date(timeIntervalSince1970: tv / 1000.0)
        }
        else {
            receivedAt = Date()
        }
        ircClient.print(text, by: client.users[slackUser]?.name, in: ircChannel, as: TVCLogLineType.privateMessageType, command: TVCLogLineDefaultCommandValue, receivedAt: receivedAt, isEncrypted: false, referenceMessage: nil) { (context) in
            ircClient.setUnreadStateFor(ircChannel!)
        }
    }

    func interceptUserInput(_ input: Any, command: IRCPrivateCommand) -> Any? {
        guard let token = masterController().mainWindow.selectedClient?.uniqueIdentifier, let ircClient = ircClients[token] else {
            return input
        }

        if let slackClient = self.slackKit.clients[token]?.client,
           let selectedChannel = masterController().mainWindow.selectedChannel,
           //XXX name may not be unique, need to create all channels up front and maintain structs pairing irc/slack channels
           let channelID = slackClient.channels.filter({ $0.value.name == selectedChannel.name }).first?.value.id {

            let inputText: String
            if input is NSAttributedString {
                inputText = (input as! NSAttributedString).string
            }
            else {
                inputText = input as! String
            }
            //XXX on failure, print error to irc server console
            self.slackKit.webAPI?.sendMessage(channel: channelID, text: inputText, username: ircClient.userNickname, asUser: false, parse: WebAPI.ParseMode.full, linkNames: true, attachments: nil, unfurlLinks: false, unfurlMedia: false, iconURL: nil, iconEmoji: nil, success: nil, failure: nil)
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
