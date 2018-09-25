//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "Textual.h"

// It is an abomination to use private APIs.
// Textual/Classes/Headers/Private/IRCChannelUserPrivate.h
// Textual/Classes/IRC/IRCClient.m
@interface IRCChannelUser ()
- (instancetype)initWithUser:(IRCUser *)user;
@end

@interface IRCClient ()
- (BOOL)notifyText:(TXNotificationType)eventType lineType:(TVCLogLineType)lineType target:(IRCChannel *)target nickname:(NSString *)nickname text:(NSString *)text;
@end
