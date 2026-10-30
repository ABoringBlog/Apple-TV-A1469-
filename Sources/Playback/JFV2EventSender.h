#import <Foundation/Foundation.h>
@interface JFV2EventSender : NSObject
// Explicit independent 32-byte pairing key; does NOT accept Jellyfin tokens.
@property(copy) void (^termination)(BOOL confirmedStopped);
// Main queue: signed silent-prepare receipt. Caller must mute then send commit.
@property(copy) void (^started)(void);
@property(copy) void (^committed)(void); // Confirmed signed Mac commit, audio running
- (id)initWithKey:(NSData *)key;
- (void)event:(NSString *)kind plan:(NSDictionary *)plan ticks:(long long)ticks;
- (BOOL)preparedAccepted; // Verified Mac prepare receipt seen for this session.
// Re-issue Start only after a signed cache-miss response; never while pending.
- (BOOL)cacheMissRetryAllowed;
- (void)invalidate;
@end

// Background-only signed Mac audio preflight; returns NO on cancellation/unavailability.
BOOL JFV2WaitForAudioCache(NSString *item, NSString *source, NSInteger track);
