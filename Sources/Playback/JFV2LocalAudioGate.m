#import "JFV2LocalAudioGate.h"
#import <objc/message.h>
#include <string.h>
@interface JFV2LocalAudioGate () { id _player; BOOL _original; } @end
@implementation JFV2LocalAudioGate
- (BOOL)mutePlayer:(id)player {
    if (![NSThread isMainThread] || _player || !player)return NO;
    SEL get=NSSelectorFromString(@"muted"),set=NSSelectorFromString(@"setMuted:");
    NSMethodSignature *g=[player methodSignatureForSelector:get],*s=[player methodSignatureForSelector:set];
    if (!g || !s || g.numberOfArguments!=2 || s.numberOfArguments!=3 ||
        strcmp(g.methodReturnType,@encode(BOOL)) || strcmp(s.methodReturnType,@encode(void)) ||
        strcmp([s getArgumentTypeAtIndex:2],@encode(BOOL)))return NO;
    @try {
        _original=((BOOL(*)(id,SEL))objc_msgSend)(player,get);
        _player=[player retain];((void(*)(id,SEL,BOOL))objc_msgSend)(player,set,YES);
        if (!((BOOL(*)(id,SEL))objc_msgSend)(player,get)) {[self restore];return NO;}
        return YES;
    } @catch(NSException *exception) {[self restore];return NO;}
}
- (void)restore {
    if (!_player)return;
    @try {((void(*)(id,SEL,BOOL))objc_msgSend)(_player,NSSelectorFromString(@"setMuted:"),_original);}
    @catch(NSException *exception) {} // Original instance may have failed; never change global volume.
    [_player release];_player=nil;
}
- (void)dealloc {[self restore];[super dealloc];}
@end
