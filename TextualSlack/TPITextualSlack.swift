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
    func pluginLoadedIntoMemory() {
        let bot = SlackKit()
        bot.addRTMBotWithAPIToken("XXX")
        bot.notificationForEvent(.message) { (event, _) in
            guard let message = event.message, let text = message.text else {
                return
            }
            print(text)
        }
    }
}
