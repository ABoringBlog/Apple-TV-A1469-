#import <Foundation/Foundation.h>

// Read an actual app-owned native player's elapsedTime immediately before
// two-phase audio commit. Never adjust global audio or playback rate.
long long JFV2CommitPositionTicks(id player, long long reportedTicks, long long durationTicks);


// True only when the native video position really advanced. A one-second
// NSTimer may observe progress well before an optimized backend emits its
// first coarse 10s progress callback. No proof of native advancement => no
// watchdog renewal. Caller must execute on main thread.
BOOL JFV2RefreshWatchdogFromPlayer(id player,long long *lastTicks,
                                    NSTimeInterval *lastProgress,
                                    NSTimeInterval now,long long durationTicks);

// Read the actual bound LTAVPlayer playhead and rate with strict Objective-C
// ABI validation. Unlike commit sampling, this permits legitimate jumps during
// remote trick play; only diagnostics/hold recovery may use the unbounded jump.
BOOL JFV2VideoSnapshot(id player,long long durationTicks,
                       long long *currentTicks,double *rate);
