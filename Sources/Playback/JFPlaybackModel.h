#import <Foundation/Foundation.h>
// Pure, conservative planning. All hardware capabilities remain PROVISIONAL.
BOOL JFMediaID(id value);
BOOL JFTicks(id value);
NSDictionary *JFProvisionalDeviceProfile(void);
NSDictionary *JFPlaybackBody(long long startTicks, NSInteger subtitleIndex);
// Server video negotiation may use a compatible AAC transport audio track,
// independently of the user's selected audio track for the Mac Bridge.
NSInteger JFVideoTransportAACIndex(NSDictionary *info, NSString *sourceID);
NSDictionary *JFPlaybackPlan(NSDictionary *info, NSString *itemID, long long startTicks, NSError **error);
NSDictionary *JFPlaybackPlanForSource(NSDictionary *info, NSString *itemID, long long startTicks, NSString *sourceID, NSError **error);
NSDictionary *JFPlaybackPlanForSourceAndAudio(NSDictionary *info, NSString *itemID, long long startTicks, NSString *sourceID, NSInteger requestedAudio, NSError **error);
NSDictionary *JFPlaybackReport(NSDictionary *plan, long long ticks, BOOL paused);
