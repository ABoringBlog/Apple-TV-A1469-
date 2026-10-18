#import <Foundation/Foundation.h>
// Only an explicitly supplied app-owned player. Never obtains a global player.
@interface JFV2LocalAudioGate : NSObject
- (BOOL)mutePlayer:(id)player;
- (void)restore;
@end
