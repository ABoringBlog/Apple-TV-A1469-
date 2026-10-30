#import "JFAppAudioLink.h"
#import "JFPlaybackTrace.h"
#import "JFV2EventSender.h"
#import "JFV2LocalAudioGate.h"
#import "JFV2CommitPosition.h"
#import <dispatch/dispatch.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>
// V2 ONLY overlay. Does not inspect old V1 config or forward upstream request.
// Inert without independently provisioned private V2 pairing configuration.
// A rare multi-second A5 main-thread stall can outlast Mac's 5-second
// authenticated playback watchdog. Preemptively PAUSE (never resume/seek)
// the exact signed session from a minimal background dispatch timer.
// A later verified native playhead sample is still mandatory for resume.
BOOL JFV2BackgroundHoldDue(NSTimeInterval now, NSTimeInterval lastMain, BOOL armed, BOOL alreadySent) {
    return armed && !alreadySent && isfinite(now) && isfinite(lastMain) &&
           lastMain>0 && now-lastMain>=2.0;
}
@interface JFV2MainThreadFence : NSObject {
@public JFV2EventSender *sender;NSDictionary *plan;NSTimeInterval lastMain;
BOOL armed;BOOL pauseSent;BOOL closed;
}
@end
@implementation JFV2MainThreadFence
- (void)dealloc { [sender release];[plan release];[super dealloc]; }
@end
@interface JFV2AppSession : NSObject {
@public JFV2EventSender *sender;JFV2LocalAudioGate *gate;NSTimer *timer;
NSDictionary *plan;id localPlayer;long long ticks;BOOL paused;BOOL committing;BOOL ending;BOOL startupPending;BOOL startupPassed;void (^startupReady)(void);void (^startupFailure)(void);BOOL startSent;BOOL transportHold;BOOL startupVideoJoinPending;NSTimeInterval progress;NSTimeInterval startAt;NSTimeInterval startSentAt;NSTimeInterval lastCacheRetry;NSTimeInterval holdStarted;NSTimeInterval candidateAt;long long candidateTicks;
JFV2MainThreadFence *safetyFence;dispatch_source_t safetyTimer;
}
- (void)tick:(NSTimer *)timer;
- (void)beginTransportHold:(NSTimeInterval)now reason:(NSString *)reason;
- (void)startBackgroundHoldFence;
- (void)stopBackgroundHoldFence;
@end
@implementation JFV2AppSession
- (void)startBackgroundHoldFence {
    if (![NSThread isMainThread] || safetyFence || safetyTimer || !committing || ending || !plan || !sender) return;
    JFV2MainThreadFence *f=[JFV2MainThreadFence new];
    f->sender=[sender retain];f->plan=[plan copy];
    f->lastMain=[NSProcessInfo processInfo].systemUptime;
    f->armed=!paused && !transportHold;
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0));
    if (!source) {[f release];return;}
    safetyFence=f;safetyTimer=source;
    dispatch_source_set_timer(source,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(400*NSEC_PER_MSEC)),
                              (uint64_t)(400*NSEC_PER_MSEC),(uint64_t)(80*NSEC_PER_MSEC));
    // Handler captures only the fence, never the owning session/player.
    // Avoids retaining the video scene or touching any UIKit/BackRow object.
    dispatch_source_set_event_handler(source,^{
        @synchronized(f) {
            if (f->closed || !JFV2BackgroundHoldDue([NSProcessInfo processInfo].systemUptime,
                    f->lastMain,f->armed,f->pauseSent)) return;
            f->pauseSent=YES;f->armed=NO;
            JFPlaybackTrace(@"V2_BACKGROUND_STALL_SIGNED_PAUSE");
            // PAUSE has no position field: never invent or extrapolate video time.
            [f->sender event:@"pause" plan:f->plan ticks:0];
        }
    });
    dispatch_resume(source);
}
- (void)stopBackgroundHoldFence {
    if (safetyFence) @synchronized(safetyFence) {safetyFence->closed=YES;safetyFence->armed=NO;}
    if (safetyTimer) {dispatch_source_cancel(safetyTimer);dispatch_release(safetyTimer);safetyTimer=NULL;}
    [safetyFence release];safetyFence=nil;
}
- (void)beginTransportHold:(NSTimeInterval)now reason:(NSString *)reason {
    if (transportHold || !committing || ending) return;
    transportHold=YES;holdStarted=now;candidateAt=0;candidateTicks=-1;
    if (safetyFence) @synchronized(safetyFence) {safetyFence->armed=NO;}
    JFPlaybackTrace([NSString stringWithFormat:@"V2_TRANSPORT_HOLD reason=%@",reason]);
    // Mac must STOP advancing soundtrack while native video seeks/buffers.
    if (!paused) [sender event:@"pause" plan:plan ticks:ticks];
}
- (void)tick:(NSTimer *)unused {
    if (ending || !plan || ![NSThread isMainThread]) return;
    NSTimeInterval now=[NSProcessInfo processInfo].systemUptime;
    BOOL backgroundHeld=NO;
    if (safetyFence) @synchronized(safetyFence) {
        safetyFence->lastMain=now;
        backgroundHeld=safetyFence->pauseSent && !transportHold;
        safetyFence->armed=!paused && committing && !transportHold && !backgroundHeld;
    }
    if (backgroundHeld) {
        // Mac already received the one signed pause. Do NOT send a duplicate.
        transportHold=YES;holdStarted=now;candidateAt=0;candidateTicks=-1;
        JFPlaybackTrace(@"V2_TRANSPORT_HOLD reason=background-stall");
    }
    // Keep native video stopped while Mac prepares AND confirms commit.
    if (startupPending && committing) {
        if (now-startSentAt>20.0) {
            JFPlaybackTrace(@"V2_HELD_START_COMMIT_TIMEOUT");
            ending=YES;[sender invalidate];[timer invalidate];
        }
        return;
    }
    if (!startSent) {
        if (paused) return;
        long long before=ticks;
        BOOL advanced=JFV2RefreshWatchdogFromPlayer(localPlayer,&ticks,&progress,
                           now,[plan[@"durationTicks"] longLongValue]);
        if (advanced) {
            startSent=YES;startSentAt=now;lastCacheRetry=now;
            JFPlaybackTrace([NSString stringWithFormat:
                @"V2_DEFERRED_START video_advanced=%lld ticks=%lld",ticks-before,ticks]);
            [sender event:@"start" plan:plan ticks:ticks];
        } else if (now-startAt>20.0) {
            JFPlaybackTrace(@"V2_DEFERRED_START_TIMEOUT_NATIVE_NOT_MOVING");
            ending=YES;[sender invalidate];[timer invalidate];
        }
        return;
    }
    if (!committing) {
        // An Archived audio track may take time to copy/convert on the NAS.
        // Until authenticated prepare arrives, keep native audio untouched.
        if (now-startSentAt>(startupPending?20.0:240.0)) {
            JFPlaybackTrace(@"V2_PREPARE_PENDING_TIMEOUT");
            ending=YES;[sender invalidate];[timer invalidate];
        } else if (now-lastCacheRetry>=1.8 && [sender cacheMissRetryAllowed]) {
            // Never enqueue another Start while the original signed Start is
            // pending: a 1.8s timer previously raced with a 1.81s receipt,
            // caused a duplicate Start and invalidated the subsequent Commit.
            JFPlaybackTrace(@"V2_CACHE_MISS_SIGNED_RETRY");
            long long position=0;double rate=0;
            if (JFV2VideoSnapshot(localPlayer,[plan[@"durationTicks"] longLongValue],
                                  &position,&rate) && position>=0) ticks=position;
            lastCacheRetry=now;
            [sender event:@"start" plan:plan ticks:ticks];
        }
        return;
    }
    long long position=0;double rate=0;
    BOOL snapshot=JFV2VideoSnapshot(localPlayer,[plan[@"durationTicks"] longLongValue],
                                   &position,&rate);
    if (!snapshot) {
        // Never submit a fabricated video timestamp to resynchronize audio.
        JFPlaybackTrace(@"V2_TRANSPORT_SNAPSHOT_INVALID");
        [self beginTransportHold:now reason:@"invalid-snapshot"];
    } else if (rate>1.08 || rate<-.05) {
        [self beginTransportHold:now reason:@"native-trickplay"];
    } else if (paused || fabs(rate)<.05) {
        // User pause or native buffering. A paused soundtrack must still get
        // signed heartbeats, otherwise Mac closes it after five seconds.
        [self beginTransportHold:now reason:@"native-paused-or-buffering"];
    } else if (!transportHold) {
        long long before=ticks;
        // Never mistake a skipped/fast-forward video jump for natural 1x
        // progress; it must go through hold then rejoin.
        if (position<ticks || position-ticks>30000000LL) {
            [self beginTransportHold:now reason:@"position-discontinuity"];
        } else if (position-ticks>=500000LL) {
            ticks=position;progress=now;
            JFPlaybackTrace([NSString stringWithFormat:
                @"V2_NATIVE_PROGRESS from=%lld to=%lld",before,ticks]);
        } else if (!paused && now-progress>2.5) {
            [self beginTransportHold:now reason:@"native-stall"];
        }
    }
    if (transportHold) {
        // Explicit user pause is unbounded and still heartbeats; only a
        // non-paused video that never recovers eventually fails closed.
        if (!paused && now-holdStarted>60.0) {
            JFPlaybackTrace(@"V2_TRANSPORT_HOLD_TIMEOUT");
            [sender invalidate];[timer invalidate];return;
        }
        if (!paused && snapshot && rate>=.92 && rate<=1.08) {
            NSTimeInterval age=now-candidateAt;
            double advanced=(double)(position-candidateTicks)/10000000.0;
            // Startup additionally demands ~0.9 s of monotonic native video
            // progress. The first Mac audio sample must not precede buffering.
            double neededAge=startupVideoJoinPending ? 0.75 : 0.45;
            double neededAdvance=startupVideoJoinPending ? 0.55 : 0.30;
            if (candidateAt>0 && age>=neededAge && age<=2.5 &&
                advanced>=neededAdvance && advanced<=2.5*age) {
                // Confirmed REAL native position advances at normal rate.
                // Seek MAC first while paused; only then resume soundtrack.
                ticks=position;progress=now;
                transportHold=NO;candidateAt=0;
                startupVideoJoinPending=NO;
                if (safetyFence) @synchronized(safetyFence) {
                    safetyFence->pauseSent=NO;safetyFence->lastMain=now;
                    safetyFence->armed=!paused;
                }
                JFPlaybackTrace([NSString stringWithFormat:
                    @"V2_TRANSPORT_REJOIN native_ticks=%lld",ticks]);
                [sender event:@"seek" plan:plan ticks:ticks];
                [sender event:@"resume" plan:plan ticks:ticks];
            } else if (candidateAt<=0 || age>2.5 || position<candidateTicks ||
                       (age>0.20 && advanced>2.5*age)) {
                // Keep the first credible sample across the timer intervals;
                // resetting it on EVERY tick could prevent a longer gate.
                candidateAt=now;candidateTicks=position;
            }
        } else {candidateAt=0;candidateTicks=-1;}
        // Heartbeat while Mac audio is PAUSED (never an automatic seek).
        [sender event:@"sync" plan:plan ticks:ticks];
        return;
    }
    [sender event:@"sync" plan:plan ticks:ticks]; // pause heartbeat too
}
- (void)dealloc {[self stopBackgroundHoldFence];[startupReady release];[startupFailure release];[timer invalidate];[timer release];[sender release];[gate restore];[gate release];[localPlayer release];[plan release];[super dealloc];}
@end
static JFV2AppSession *current=nil;
@implementation JFAppAudioLink
+ (void)bindPlayer:(id)player plan:(NSDictionary *)plan {
    JFPlaybackTrace([NSString stringWithFormat:@"V2_BIND_ENTER main=%d occupied=%d player=%@",(int)[NSThread isMainThread],(int)(current!=nil),NSStringFromClass([player class]) ?: @"nil"]);
    if (![plan[@"audioStreamIndex"] isKindOfClass:[NSNumber class]] ||
        [plan[@"audioStreamIndex"] integerValue]<0 || [plan[@"audioStreamIndex"] integerValue]>10000) {JFPlaybackTrace(@"V2_BIND_REJECT audio_track");return;}
    if (![NSThread isMainThread] || current || ![NSStringFromClass([player class]) isEqual:@"LTAVPlayer"]) {JFPlaybackTrace(@"V2_BIND_REJECT main_or_occupied_or_class");return;}
    NSString *path=@"/var/mobile/Library/Preferences/org.atv3.jellyfin-audio-v2.plist";
    struct stat s;if (lstat(path.fileSystemRepresentation,&s) || !S_ISREG(s.st_mode) || (s.st_mode&077) || s.st_nlink!=1 || (s.st_uid!=getuid() && s.st_uid!=0)) {JFPlaybackTrace(@"V2_BIND_REJECT config_path_owner_or_mode");return;}
    NSDictionary *config=[NSDictionary dictionaryWithContentsOfFile:path];
    NSData *key=config[@"PairKey"];
    if (![config[@"Enabled"] boolValue] || ![key isKindOfClass:[NSData class]] || key.length!=32 || [config[@"Version"] intValue]!=2) {JFPlaybackTrace(@"V2_BIND_REJECT config_disabled_or_invalid");return;}
    JFV2AppSession *session=[JFV2AppSession new];session->gate=[JFV2LocalAudioGate new];
    session->localPlayer=[player retain];
    session->sender=[[JFV2EventSender alloc] initWithKey:key];
    if (!session->sender) {JFPlaybackTrace(@"V2_BIND_REJECT sender_init");[session release];return;}
    // Keep ATV instance audio untouched until Mac verifies the start receipt.
    // This prevents silence when Mac is offline or the cache is unavailable.
    session->sender.started=^{
        JFPlaybackTrace(@"V2_PREPARE_RECEIPT_OK");
        if (current!=session || session->ending || ![NSThread isMainThread])return;
        if (![session->gate mutePlayer:session->localPlayer]) {
            JFPlaybackTrace(@"V2_GATE_MUTE_FAILED");
            session->ending=YES;[session->sender invalidate];return;
        }
        // The last progress event can be up to ~1 second old while the
        // two-phase handshake completes. Sample the SAME LTAVPlayer instance
        // on the main thread after mute, just before committing Mac playback.
        // Invalid or implausible samples fall back to the last reported ticks.
        long long actualTicks=JFV2CommitPositionTicks(session->localPlayer,session->ticks,
                                                       [session->plan[@"durationTicks"] longLongValue]);
        JFPlaybackTrace([NSString stringWithFormat:@"V2_COMMIT_POSITION reported_ticks=%lld actual_ticks=%lld paused=%d",
                          session->ticks,actualTicks,(int)session->paused]);
        JFPlaybackTrace(@"V2_GATE_MUTED_COMMIT_SENT");
        session->committing=YES;
        session->ticks=actualTicks;
        session->progress=[NSProcessInfo processInfo].systemUptime;
        // Mac MUST NOT begin audio before ATV has decoded its first advancing
        // video frames. A signed paused commit arms the exact audio track.
        [session->sender event:@"commit" plan:@{@"paused":@(session->startupPending || session->paused)} ticks:actualTicks];
    };
    session->sender.committed=^{
        if (current!=session || session->ending || ![NSThread isMainThread]) return;
        if (!session->startupPending) return;
        session->startupPending=NO;
        session->startupPassed=YES;
        // This initial hold is local (Mac already committed in PAUSED state).
        // Release native video now, but only seek+resume Mac after sampled
        // LTAVPlayer rate and playhead both demonstrate real 1x progress.
        session->transportHold=YES;
        session->startupVideoJoinPending=YES;
        session->holdStarted=[NSProcessInfo processInfo].systemUptime;
        session->candidateAt=0;session->candidateTicks=-1;
        JFPlaybackTrace(@"V2_INITIAL_VIDEO_BUFFER_HOLD");
        [session startBackgroundHoldFence];
        JFPlaybackTrace(@"V2_HELD_AUDIO_COMMITTED_VIDEO_RELEASE");
        void (^callback)(void)=[session->startupReady copy];
        if (callback)callback();
        [callback release];
    };
    session->sender.termination=^(BOOL confirmedStopped) {
        // Never restore local audio while an unacknowledged Mac session may
        // still run: wait beyond 5s watchdog + bounded outstanding HTTP request.
        JFPlaybackTrace([NSString stringWithFormat:@"V2_TERMINATION confirmed=%d",(int)confirmedStopped]);
        BOOL bootFailed=session->startupPending && !session->startupPassed;
        session->ending=YES;[session->timer invalidate];
        [session stopBackgroundHoldFence];
        if (bootFailed) {
            JFPlaybackTrace(@"V2_HELD_START_FAILED_NO_VIDEO");
            void (^callback)(void)=[session->startupFailure copy];
            if (callback)callback();
            [callback release];
        }
        // The Mac never opened audio if its signed prepare wasn't accepted.
        // Release immediately in that case so a quick replay can recover.
        BOOL everPrepared=[session->sender preparedAccepted];
        NSTimeInterval releaseDelay=(!everPrepared || confirmedStopped)?0:10.0;
        JFPlaybackTrace([NSString stringWithFormat:@"V2_TERMINATION_RELEASE early=%d prepared=%d",(int)(releaseDelay==0),(int)everPrepared]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(releaseDelay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if (current==session) {current=nil;[session->gate restore];session->sender.started=nil;session->sender.committed=nil;session->sender.termination=nil;[session release];}
        });
    };
    current=session;
    JFPlaybackTrace(@"V2_BIND_OK");
}
+ (BOOL)isBoundPlayer:(id)player {
    return [NSThread isMainThread] && current && !current->ending &&
           current->localPlayer==player;
}
+ (BOOL)startHeldPlayer:(id)player plan:(NSDictionary *)plan
                 ticks:(long long)ticks ready:(void (^)(void))ready
                failure:(void (^)(void))failure {
    if (![NSThread isMainThread] || !ready || !failure ||
        ![plan[@"itemID"] isKindOfClass:[NSString class]] ||
        ![plan[@"sourceID"] isKindOfClass:[NSString class]] ||
        ![plan[@"audioStreamIndex"] isKindOfClass:[NSNumber class]]) return NO;
    [self bindPlayer:player plan:plan];
    if (![self isBoundPlayer:player])return NO;
    JFV2AppSession *s=current;
    [s->plan release];s->plan=[plan copy];
    s->startupPending=YES; s->startupPassed=NO;
    s->startupReady=[ready copy];s->startupFailure=[failure copy];
    s->ticks=ticks;s->paused=NO;
    s->progress=[NSProcessInfo processInfo].systemUptime;
    s->startAt=s->progress;
    s->startSent=YES;s->startSentAt=s->progress;s->lastCacheRetry=s->progress;
    s->timer=[[NSTimer scheduledTimerWithTimeInterval:0.30 target:s
                selector:@selector(tick:) userInfo:nil repeats:YES] retain];
    JFPlaybackTrace(@"V2_HELD_START_REQUEST_BEFORE_VIDEO");
    [s->sender event:@"start" plan:s->plan ticks:ticks];
    return YES;
}
+ (void)event:(NSString *)event plan:(NSDictionary *)p request:(NSURLRequest *)unused ticks:(long long)t paused:(BOOL)isPaused {
    if (![NSThread isMainThread] || !current) {if ([event isEqual:@"start"]) JFPlaybackTrace(@"V2_EVENT_START_WITHOUT_BIND");return;}
    JFV2AppSession *s=current;
    if (s->ending)return;
    if (s->safetyFence) @synchronized(s->safetyFence) {
        s->safetyFence->lastMain=[NSProcessInfo processInfo].systemUptime;
        if ([event isEqual:@"pause"] || [event isEqual:@"seek"] ||
            [event isEqual:@"stop"]) s->safetyFence->armed=NO;
    }
    if ([event isEqual:@"start"]) {
        JFPlaybackTrace(@"V2_EVENT_START_BOUND");
        if (s->plan)return;
        [s->plan release];s->plan=[p copy];s->ticks=t;s->paused=NO;s->progress=[NSProcessInfo processInfo].systemUptime;s->startAt=s->progress;
        s->timer=[[NSTimer scheduledTimerWithTimeInterval:1.0 target:s selector:@selector(tick:) userInfo:nil repeats:YES] retain];
    }
    if (!s->plan)return;
    BOOL pauseAlreadyDelivered=[event isEqual:@"pause"] && s->transportHold;
    if ([@[@"start",@"seek",@"sync",@"pause",@"resume"] containsObject:event]) {
        s->paused=isPaused;
        // During trick play the backend's reported tick can jump well ahead of
        // the REAL LTAVPlayer playhead. Do not overwrite verified video ticks.
        if (!s->transportHold && [event isEqual:@"start"]) {
            s->ticks=t;s->progress=[NSProcessInfo processInfo].systemUptime;
        }
        if ([event isEqual:@"seek"] && s->committing) {
            [s beginTransportHold:[NSProcessInfo processInfo].systemUptime reason:@"explicit-seek"];
        }
        if ([event isEqual:@"pause"] && s->committing && !s->transportHold) {
            // A native pause event already sends exactly one pause command;
            // do not duplicate it in the timer's next paused-rate sample.
            s->transportHold=YES;
            s->holdStarted=[NSProcessInfo processInfo].systemUptime;
            s->candidateAt=0;s->candidateTicks=-1;
            JFPlaybackTrace(@"V2_TRANSPORT_HOLD reason=user-pause");
        }
        if ([event isEqual:@"sync"] || [event isEqual:@"pause"] || [event isEqual:@"resume"])
            JFPlaybackTrace([NSString stringWithFormat:@"V2_APP_PROGRESS event=%@ ticks=%lld",event,t]);
    }
    if ([event isEqual:@"stop"]) {
        JFPlaybackTrace(@"V2_APP_STOP_CALLED");
        s->ending=YES;[s->timer invalidate];
        [s stopBackgroundHoldFence];
        [s->sender invalidate];return;
    }
    // Initial start is deliberately scheduled by the native progress sampler.
    // Never open Mac audio on the provisional backend "started" notification.
    if ([event isEqual:@"start"] || !s->committing)return;
    // Explicit seeks and native trick play are reconciled from verified native
    // playhead samples on the next timer ticks, never speculative UI targets.
    if ([event isEqual:@"seek"] || [event isEqual:@"sync"] ||
        ([event isEqual:@"resume"] && s->transportHold) ||
        pauseAlreadyDelivered) return;
    [s->sender event:event plan:s->plan ticks:t];
}
@end
