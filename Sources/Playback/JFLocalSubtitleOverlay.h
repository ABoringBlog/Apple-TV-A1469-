#import <Foundation/Foundation.h>
// Main-thread only. Runtime-gated native CA overlay. No timers or video frame callbacks.
@interface JFLocalSubtitleOverlay : NSObject {
    id _layer;
    NSString *_visible;
    BOOL _topOrigin;
}
- (BOOL)attachToPlayerController:(id)controller;
- (BOOL)attached;
- (void)showText:(NSString *)text;
- (void)detach;
@end
