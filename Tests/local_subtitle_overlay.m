#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "Playback/JFLocalSubtitleOverlay.h"
#include <stdio.h>
#include <math.h>
@interface UIWindowLayer : CALayer @end
@implementation UIWindowLayer @end
// A Mac-only stand-in for the ATV3's UIKit application window. It makes sure
// attachment succeeds even when BRMediaPlayerController exposes no CALayer.
@interface UIApplication : NSObject {
    CALayer *_testRoot;
}
+ (UIApplication *)sharedApplication;
- (id)keyWindow;
- (CALayer *)layer;
@end
@implementation UIApplication
+ (UIApplication *)sharedApplication {
    static UIApplication *app=nil;
    if (!app) app=[UIApplication new];
    return app;
}
- (id)init {
    if ((self=[super init])) {
        _testRoot=[[UIWindowLayer alloc] init];
        _testRoot.frame=CGRectMake(0,0,1280,720);
    }
    return self;
}
- (id)keyWindow { return self; }
- (CALayer *)layer { return _testRoot; }
- (void)dealloc { [_testRoot release]; [super dealloc]; }
@end
// The actual video has its own transient presentation window. Prefer it over
// the persistent app window, which caused the detail-page subtitle ghost.
@interface BRMediaPlayerManager : NSObject {
    CALayer *_playerLayer;
}
+ (id)sharedInstance;
- (id)presentationWindow;
- (void)setTestPresentation:(BOOL)enabled;
- (CALayer *)layer;
@end
@implementation BRMediaPlayerManager
+ (id)sharedInstance {
    static id manager=nil;
    if (!manager) manager=[[self alloc] init];
    return manager;
}
- (void)setTestPresentation:(BOOL)enabled {
    [_playerLayer release];_playerLayer=nil;
    if (enabled) {
        _playerLayer=[[UIWindowLayer alloc] init];
        _playerLayer.frame=CGRectMake(0,0,1280,720);
    }
}
- (id)presentationWindow { return _playerLayer; }
- (CALayer *)layer { return _playerLayer; }
- (void)dealloc { [_playerLayer release];[super dealloc]; }
@end
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
int main(void) { @autoreleasepool {
    int checks=0;
    CALayer *root=[CALayer layer];
    root.frame=CGRectMake(0,0,1280,720);
    JFLocalSubtitleOverlay *overlay=[JFLocalSubtitleOverlay new];
    CHECK([overlay attachToPlayerController:root]);
    CHECK([overlay attached]);
    CHECK(root.sublayers.count==1);
    CATextLayer *text=(CATextLayer *)[root.sublayers objectAtIndex:0];
    CHECK(text.hidden);
    [overlay showText:@"中文字幕\nEnglish subtitles"];
    CHECK(!text.hidden);
    CHECK([[text string] isEqual:@"中文字幕\nEnglish subtitles"]);
    CHECK(text.frame.origin.y>0 && text.frame.origin.y<root.bounds.size.height*0.10); // Core Animation bottom origin
    for (NSUInteger i=0;i<4000;i++) {
        [overlay showText:i%2 ? @"中文\nEnglish" : @"English\n中文"];
        CHECK(root.sublayers.count==1);
    }
    [overlay showText:nil]; CHECK(text.hidden);
    [overlay detach]; CHECK(root.sublayers.count==0);
    CHECK(![overlay attached]);
    // The native controller has no view/layer, so the test falls back to the
    // frontmost UIKit window instead of dropping selected subtitles.
    NSObject *nativeController=[NSObject new];
    CHECK([overlay attachToPlayerController:nativeController]);
    CHECK([overlay attached]);
    CALayer *windowLayer=[[UIApplication sharedApplication] layer];
    CHECK(windowLayer.sublayers.count==1);
    [overlay showText:@"字幕"]; CHECK(windowLayer.sublayers.count==1);
    CATextLayer *windowText=(CATextLayer *)windowLayer.sublayers[0];
    CGRect single=windowText.frame;
    CHECK(single.origin.y>windowLayer.bounds.size.height*0.83); // UIKit top origin, near bottom
    CHECK(fabs(CGRectGetMaxY(single)-(windowLayer.bounds.size.height*0.96))<1.0);
    [overlay showText:@"中文字幕\nEnglish subtitles"];
    CGRect doubleLine=windowText.frame;
    CHECK(doubleLine.origin.y<single.origin.y); // taller cues rise, bottom stays aligned
    CHECK(fabs(CGRectGetMaxY(doubleLine)-CGRectGetMaxY(single))<1.0);
    [overlay showText:@"One\nTwo\nThree"];
    CHECK(windowText.frame.origin.y<doubleLine.origin.y);
    CHECK(fabs(CGRectGetMaxY(windowText.frame)-CGRectGetMaxY(single))<1.0);
    [overlay detach]; CHECK(windowLayer.sublayers.count==0);
    BRMediaPlayerManager *manager=[BRMediaPlayerManager sharedInstance];
    [manager setTestPresentation:YES];
    CALayer *videoRoot=[manager presentationWindow];
    CHECK([overlay attachToPlayerController:nativeController]);
    CHECK(videoRoot.sublayers.count==1);
    CHECK(windowLayer.sublayers.count==0); // No permanent UIKit-window subtitles.
    [overlay showText:@"中文字幕"];
    CHECK(videoRoot.sublayers.count==1 && windowLayer.sublayers.count==0);
    [overlay detach];
    CHECK(videoRoot.sublayers.count==0 && windowLayer.sublayers.count==0);
    [manager setTestPresentation:NO];
    [nativeController release];
    [overlay release];
    printf("PASS: %d subtitle overlay reuse/teardown assertions\n",checks);
    return 0;
} }
