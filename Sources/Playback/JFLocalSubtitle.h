#import <Foundation/Foundation.h>
// SRT-only, bounded text cue format. All timestamps are Jellyfin ticks (100 ns).
// Parsing is done off the main playback thread; the returned NSArray is immutable.
NSArray *JFLocalSubtitleParse(NSData *data, NSError **error);
NSString *JFLocalSubtitleAtTicks(NSArray *cues, long long ticks);
