//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "TextualApplication.h"

// It is an abomination to use private APIs.
// Textual/Classes/Headers/Private/IRCChannelUserPrivate.h
@interface IRCChannelUser ()
- (instancetype)initWithUser:(IRCUser *)user;
@end
