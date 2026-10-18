#import "JFLocalSubtitleOverlay.h"
#import "JFPlaybackTrace.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <string.h>
// Do not assume a BRController is a UIView. Probe object ABI before retrieving a layer.
static id JFLayerObject(id target, NSString *selector) {
    if (!target) return nil;
    SEL sel=NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig=[target methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments!=2 || strcmp(sig.methodReturnType,@encode(id))) return nil;
    @try { return ((id(*)(id,SEL))objc_msgSend)(target,sel); }
    @catch (NSException *exception) { return nil; }
}
static CALayer *JFUsableLayer(id target) {
    CALayer *layer=[target isKindOfClass:[CALayer class]] ? target : JFLayerObject(target,@"layer");
    return [layer isKindOfClass:[CALayer class]] &&
           layer.bounds.size.width>=100 && layer.bounds.size.height>=100 ? layer : nil;
}
// UIKit's UIWindowLayer uses top-to-bottom on the ATV; a bare Core
// Animation layer uses bottom-to-top. Keep the two cases explicit.
static BOOL JFSubtitleTopOrigin(CALayer *root) {
    NSString *name=NSStringFromClass([root class]);
    return [name hasPrefix:@"UIWindow"] || [name hasPrefix:@"UIView"];
}
static CGRect JFSubtitleBottomFrame(CGRect bounds, CGFloat fontSize, NSString *text, BOOL topOrigin) {
    // The visible glyphs are top aligned inside CATextLayer. A fixed tall box
    // makes one-line captions appear much higher than two-line captions.
    NSUInteger lines=1;
    for (NSUInteger i=0;i<text.length;i++) if ([text characterAtIndex:i]=='\n') lines++;
    lines=MIN(lines,4U);
    CGFloat inset=MAX(24.0,MIN(52.0,bounds.size.height*0.04));
    CGFloat height=MIN(bounds.size.height*0.28,
                       MAX(fontSize*1.48,fontSize*1.28*(CGFloat)lines+8.0));
    CGFloat y=topOrigin ? CGRectGetMaxY(bounds)-inset-height : CGRectGetMinY(bounds)+inset;
    return CGRectMake(CGRectGetMinX(bounds)+bounds.size.width*0.08,
                      y,bounds.size.width*0.84,height);
}
static CALayer *JFRootLayer(id controller) {
    // BackRow's BRMediaPlayerController on 12H1006 is not a UIView and can
    // lack -view/-layer. First inspect its known presentation containers.
    CALayer *layer=JFUsableLayer(controller);
    if (layer) return layer;
    for (NSString *key in @[@"view",@"rootControl",@"control",@"contentView",@"contentControl",
                             @"containerView",@"playerView",@"overlayView"]) {
        id value=JFLayerObject(controller,key);
        layer=JFUsableLayer(value);
        if (layer) return layer;
    }
    // Prefer the player's own presentation window. It is removed with native
    // playback, so the subtitle cannot remain over Jellyfin's detail menu.
    // The app's keyWindow persists across playback and caused ghost captions.
    Class managerClass=objc_getClass("BRMediaPlayerManager");
    id manager=JFLayerObject((id)managerClass,@"sharedInstance");
    id presentedWindow=JFLayerObject(manager,@"presentationWindow");
    layer=JFUsableLayer(presentedWindow);
    if (layer) {
        JFPlaybackTrace([NSString stringWithFormat:@"LOCAL_SRT_LAYER_PLAYER_WINDOW class=%@",NSStringFromClass([presentedWindow class])]);
        return layer;
    }
    // Legacy AppleTV.app also hosts UIKit windows. On firmware lacking an
    // accessible presentationWindow, keep the previously verified fallback.
    // Use only runtime-validated object getters, never assume private ivars.
    Class application=objc_getClass("UIApplication");
    id app=JFLayerObject((id)application,@"sharedApplication");
    id key=JFLayerObject(app,@"keyWindow");
    layer=JFUsableLayer(key);
    if (layer) {
        JFPlaybackTrace([NSString stringWithFormat:@"LOCAL_SRT_LAYER_WINDOW kind=key class=%@",NSStringFromClass([key class])]);
        return layer;
    }
    id windows=JFLayerObject(app,@"windows");
    if ([windows isKindOfClass:[NSArray class]]) {
        for (id window in [(NSArray *)windows reverseObjectEnumerator]) {
            layer=JFUsableLayer(window);
            if (layer) {
                JFPlaybackTrace([NSString stringWithFormat:@"LOCAL_SRT_LAYER_WINDOW kind=last class=%@",NSStringFromClass([window class])]);
                return layer;
            }
        }
    }
    JFPlaybackTrace([NSString stringWithFormat:@"LOCAL_SRT_LAYER_MISSING controller=%@ view=%@ key=%@ windows=%lu",
                     controller ? NSStringFromClass([controller class]) : @"nil",
                     NSStringFromClass([JFLayerObject(controller,@"view") class]) ?: @"nil",
                     key ? NSStringFromClass([key class]) : @"nil",
                     [windows isKindOfClass:[NSArray class]] ? (unsigned long)[windows count] : 0UL]);
    return nil;
}
@implementation JFLocalSubtitleOverlay
- (BOOL)attachToPlayerController:(id)controller {
    if (![NSThread isMainThread]) return NO;
    [self detach];
    CALayer *root=JFRootLayer(controller);
    CGRect bounds=root ? root.bounds : CGRectZero;
    if (!root || bounds.size.width<100 || bounds.size.height<100) return NO;
    JFPlaybackTrace([NSString stringWithFormat:@"LOCAL_SRT_LAYER_ROOT class=%@ width=%ld height=%ld",
                     NSStringFromClass([root class]),(long)bounds.size.width,(long)bounds.size.height]);
    CATextLayer *layer=[[CATextLayer alloc] init];
    layer.alignmentMode=kCAAlignmentCenter;
    layer.wrapped=YES;
    layer.contentsScale=1.0f;
    layer.fontSize=MAX(22.0,MIN(38.0,bounds.size.height*0.052));
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGFloat whiteComponents[]={1.0,1.0,1.0,1.0};
    CGFloat blackComponents[]={0.0,0.0,0.0,1.0};
    CGColorRef white=CGColorCreate(space,whiteComponents);
    CGColorRef black=CGColorCreate(space,blackComponents);
    layer.foregroundColor=white;
    layer.shadowColor=black;
    CGColorRelease(white);CGColorRelease(black);CGColorSpaceRelease(space);
    layer.shadowRadius=3.0f; layer.shadowOpacity=0.95f;
    layer.shadowOffset=CGSizeMake(1.0f,2.0f);
    _topOrigin=JFSubtitleTopOrigin(root);
    layer.frame=JFSubtitleBottomFrame(bounds,layer.fontSize,@"",_topOrigin);
    JFPlaybackTrace([NSString stringWithFormat:@"LOCAL_SRT_BOTTOM_LAYOUT topOrigin=%d y=%ld height=%ld insetPct=4",
                     _topOrigin,(long)layer.frame.origin.y,(long)layer.frame.size.height]);
    layer.hidden=YES;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [root addSublayer:layer];
    [CATransaction commit];
    _layer=layer; // held by our +1 and by superlayer
    return YES;
}
- (BOOL)attached { return _layer!=nil; }
- (void)showText:(NSString *)text {
    if (![NSThread isMainThread] || !_layer) return;
    NSString *next=[text isKindOfClass:[NSString class]] ? text : @"";
    if ([_visible isEqualToString:next] || (!_visible && !next.length)) return;
    [_visible release];_visible=[next copy];
    CATextLayer *layer=(CATextLayer *)_layer;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    layer.string=next;
    if (next.length && layer.superlayer)
        layer.frame=JFSubtitleBottomFrame(layer.superlayer.bounds,layer.fontSize,next,_topOrigin);
    layer.hidden=next.length==0;
    [CATransaction commit];
}
- (void)detach {
    if (![NSThread isMainThread]) return;
    [(CALayer *)_layer removeFromSuperlayer];
    [_layer release]; _layer=nil;
    [_visible release]; _visible=nil;
}
- (void)dealloc { [self detach];[super dealloc]; }
@end
