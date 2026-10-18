#import <Foundation/Foundation.h>
// Subtitle metadata/selection policy: local SRT or offline-preprocess-required.
NSArray *JFSubtitleTracks(NSArray *streams, NSError **error);
NSArray *JFSubtitleTracksForSources(NSArray *sources, NSError **error);
NSDictionary *JFSubtitleSelection(NSArray *tracks, NSInteger index, BOOL preserveStyling, NSError **error);
NSString *JFSubtitleTrackLabel(NSDictionary *track);
NSString *JFSubtitleText(NSData *data, NSError **error);
