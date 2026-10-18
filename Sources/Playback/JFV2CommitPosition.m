#import "JFV2CommitPosition.h"
#import <objc/message.h>
#include <math.h>
#include <string.h>
#include <limits.h>

// Bound the possible unreported startup progress; reject stale/incorrect
// native timing rather than seeking the Mac soundtrack far into a movie.
static const long long kMaxUnreportedTicks=30000000LL; // 3 s

long long JFV2CommitPositionTicks(id player, long long reportedTicks, long long durationTicks) {
    if (reportedTicks<0 || durationTicks<=0 || reportedTicks>=durationTicks) return reportedTicks;
    if (![NSThread isMainThread] || !player ||
        ![NSStringFromClass([player class]) isEqualToString:@"LTAVPlayer"])
        return reportedTicks;
    SEL selector=NSSelectorFromString(@"elapsedTime");
    if (![player respondsToSelector:selector]) return reportedTicks;
    NSMethodSignature *signature=[player methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments!=2 ||
        strcmp(signature.methodReturnType,@encode(double))) return reportedTicks;
    @try {
        double seconds=((double(*)(id,SEL))objc_msgSend)(player,selector);
        if (!isfinite(seconds) || seconds<0.0 ||
            seconds>(double)durationTicks/10000000.0) return reportedTicks;
        double ticksDouble=seconds*10000000.0;
        if (!isfinite(ticksDouble) || ticksDouble>(double)LLONG_MAX) return reportedTicks;
        long long sampled=(long long)(ticksDouble+0.5);
        // A late or backward sample must not rewind the Mac timeline.
        if (sampled<reportedTicks || sampled-reportedTicks>kMaxUnreportedTicks ||
            sampled>=durationTicks) return reportedTicks;
        return sampled;
    } @catch (NSException *error) {
        return reportedTicks;
    }
}

BOOL JFV2RefreshWatchdogFromPlayer(id player,long long *lastTicks,
                                    NSTimeInterval *lastProgress,
                                    NSTimeInterval now,long long durationTicks) {
    if (!lastTicks || !lastProgress || !isfinite(now) || now<0.0 ||
        !isfinite(*lastProgress) || *lastProgress<0.0 ||
        now<*lastProgress || *lastTicks<0 || durationTicks<=0) return NO;
    long long candidate=JFV2CommitPositionTicks(player,*lastTicks,durationTicks);
    // A static/sluggish elapsedTime must not masquerade as a running video.
    // 50ms ignores timer jitter and tiny residual position fluctuations.
    if (candidate<=*lastTicks || candidate-*lastTicks<500000LL) return NO;
    *lastTicks=candidate;
    *lastProgress=now;
    return YES;
}

BOOL JFV2VideoSnapshot(id player,long long durationTicks,
                       long long *currentTicks,double *rate) {
    if (!currentTicks || !rate || durationTicks<=0 ||
        ![NSThread isMainThread] || !player ||
        ![NSStringFromClass([player class]) isEqualToString:@"LTAVPlayer"]) return NO;
    for (NSString *name in @[@"elapsedTime",@"rate"]) {
        SEL method=NSSelectorFromString(name);
        if (![player respondsToSelector:method]) return NO;
        NSMethodSignature *sig=[player methodSignatureForSelector:method];
        if (!sig || sig.numberOfArguments!=2 ||
            strcmp(sig.methodReturnType,@encode(double))) return NO;
    }
    @try {
        double pos=((double(*)(id,SEL))objc_msgSend)(player,NSSelectorFromString(@"elapsedTime"));
        double speed=((double(*)(id,SEL))objc_msgSend)(player,NSSelectorFromString(@"rate"));
        if (!isfinite(pos) || !isfinite(speed) || pos<0 ||
            pos>(double)durationTicks/10000000.0 ||
            fabs(speed)>128.0 || pos*10000000.0>(double)LLONG_MAX) return NO;
        *currentTicks=(long long)(pos*10000000.0+0.5);
        *rate=speed;
        return YES;
    } @catch (NSException *error) {return NO;}
}
