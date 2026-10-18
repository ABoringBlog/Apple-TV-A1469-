#import "JFPlaybackController.h"
#import "JFAppAudioLink.h"
#import "JFATV3PlaybackBackend.h"
#import "JFV2EventSender.h"
#import "JFPlaybackModel.h"
#import "JFPlaybackTrace.h"
#import "JFLocalSubtitle.h"
#import "JFLocalSubtitleOverlay.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#import "API/JFClient.h"
#import "API/JFWorker.h"
// Only actual movie playback, not library browsing/setup/paused, inhibits screen idle.
static void JFPlaybackIdleSet(BOOL active){
    static BOOL held=NO;
    static NSInteger original=0;
    static NSInteger sleepOriginal=0;
    if(held==active)return;
    Class facade=objc_getClass("ATVSettingsFacade");
    SEL get=NSSelectorFromString(@"screenSaverTimeout"),set=NSSelectorFromString(@"setScreenSaverTimeout:");
    id settings=(facade && [facade respondsToSelector:NSSelectorFromString(@"singleton")]) ?
        ((id(*)(id,SEL))objc_msgSend)(facade,NSSelectorFromString(@"singleton")) : nil;
    if(settings && [settings respondsToSelector:get] && [settings respondsToSelector:set]){
        if(active)original=((NSInteger(*)(id,SEL))objc_msgSend)(settings,get);
        ((void(*)(id,SEL,int))objc_msgSend)(settings,set,active?-1:(int)original);
        SEL flush=NSSelectorFromString(@"flushDiskChanges");
        if([settings respondsToSelector:flush])((void(*)(id,SEL))objc_msgSend)(settings,flush);
    }
    SEL sleepGet=NSSelectorFromString(@"sleepTimeout"),sleepSet=NSSelectorFromString(@"setSleepTimeout:");
    if(settings && [settings respondsToSelector:sleepGet] && [settings respondsToSelector:sleepSet]){
        if(active)sleepOriginal=((NSInteger(*)(id,SEL))objc_msgSend)(settings,sleepGet);
        ((void(*)(id,SEL,int))objc_msgSend)(settings,sleepSet,active?-1:(int)sleepOriginal);
    }
    Class appClass=objc_getClass("UIApplication");
    if(appClass && [appClass respondsToSelector:NSSelectorFromString(@"sharedApplication")]){
        id app=((id(*)(id,SEL))objc_msgSend)(appClass,NSSelectorFromString(@"sharedApplication"));
        SEL idle=NSSelectorFromString(@"setIdleTimerDisabled:");
        if([app respondsToSelector:idle])((void(*)(id,SEL,BOOL))objc_msgSend)(app,idle,active);
    }
    held=active;
}
NSString * const JFPlaybackChanged=@"JFPlaybackChanged";
@interface JFPlaybackDelivery : NSObject { @public JFPlaybackController *owner; } @end
@implementation JFPlaybackDelivery @end
static NSString *Kind(NSError *error) {
    if ([error.domain isEqual:@"Jellyfin"] && (error.code==401 || error.code==1004)) return @"authentication";
    if (error.code==NSURLErrorTimedOut) return @"timeout";
    if ([error.domain isEqual:NSURLErrorDomain]) return @"transport";
    return @"playback";
}
static NSInteger JFPlaybackTraceCode(NSError **error) { return error && *error ? (*error).code : 0; }
static NSString *JFPlaybackTraceKind(NSError **error) { return Kind(error && *error ? *error : nil); }
@interface JFPlaybackController ()
- (void)backendEvent:(NSString *)event ticks:(long long)ticks generation:(NSUInteger)generation;
- (void)report:(NSString *)event;
- (void)fail:(NSString *)kind;
- (void)beginLocalSubtitles;
- (void)attachLocalSubtitleOverlayIfNeeded;
- (void)updateLocalSubtitles;
- (void)clearLocalSubtitles;
@end
@implementation JFPlaybackController
@synthesize currentState=_state,errorKind=_errorKind,positionTicks=_position,progressCallback=_progress,failureCallback=_failure;
- (id)initWithClient:(JFClient *)client worker:(JFWorker *)worker backend:(id<JFPlaybackBackend>)backend {
    if ((self=[super init])) {
        if (![NSThread isMainThread] || !client || !worker || !backend) { [self release]; return nil; }
        _client=[client retain]; _worker=[worker retain]; _backend=[backend retain];
        _delivery=[JFPlaybackDelivery new]; _delivery->owner=self;
        _state=[@"idle" copy]; _errorKind=[@"none" copy]; _subtitleIndex=-1;
        _subtitleOverlay=[[JFLocalSubtitleOverlay alloc] init];
    } return self;
}
- (BOOL)active { return [_state isEqual:@"setup"] || [_state isEqual:@"playing"] || [_state isEqual:@"paused"]; }
- (void)state:(NSString *)state {
    [_state release]; _state=[state copy];
    JFPlaybackIdleSet([_state isEqual:@"playing"]);
    // Retain across observers which may close/release the UI and this controller.
    [self retain]; [[NSNotificationCenter defaultCenter] postNotificationName:JFPlaybackChanged object:self]; [self release];
}
- (BOOL)playItem:(NSString *)item startTicks:(long long)ticks {
    return [self playItem:item startTicks:ticks mediaSourceID:nil audioIndex:-1 subtitleIndex:-1];
}
- (BOOL)playItem:(NSString *)item startTicks:(long long)ticks mediaSourceID:(NSString *)source audioIndex:(NSInteger)audioIndex {
    return [self playItem:item startTicks:ticks mediaSourceID:source audioIndex:audioIndex subtitleIndex:-1];
}
- (BOOL)playItem:(NSString *)item startTicks:(long long)ticks mediaSourceID:(NSString *)source audioIndex:(NSInteger)audioIndex subtitleIndex:(NSInteger)subtitleIndex {
    BOOL boundSource=source!=nil, hasAudio=audioIndex>=0, hasSubtitle=subtitleIndex>=0;
    if (![NSThread isMainThread] || _closed || [self active] || !JFMediaID(item) || !JFTicks(@(ticks)) ||
        audioIndex < -1 || audioIndex>10000 || subtitleIndex < -1 || subtitleIndex>10000 ||
        (boundSource && !JFMediaID(source)) || (!boundSource && (hasAudio || hasSubtitle))) return NO;
    [self clearLocalSubtitles];
    [_subtitleItemID release];_subtitleItemID=[item copy];
    [_subtitleSourceID release];_subtitleSourceID=[source copy];
    _subtitleIndex=subtitleIndex;
    [self retain]; _generation++; _position=ticks; _reportedStart=NO; _reportBusy=NO; _lastReported=ticks;
    [_plan release]; _plan=nil; [_macAudioRequest release]; _macAudioRequest=nil; _lastMacAudioSync=ticks; [_errorKind release]; _errorKind=[@"none" copy];
    NSUInteger generation=_generation; JFClient *client=_client; JFPlaybackDelivery *delivery=_delivery;
    NSString *identifier=[[item copy] autorelease];
    NSString *selectedSource=[[source copy] autorelease];
    [_setupTask release];
    _setupTask=[[_worker perform:^id(NSError **error) {
        NSTimeInterval setupStarted=[NSProcessInfo processInfo].systemUptime;
        // Local SRT is independent of video negotiation: do not force burn-in.
        // Negotiate video against the server's default AAC transport audio.
        // An explicit AC3 user choice would otherwise force HLS transcoding
        // even though the Mac already has that exact track cached as AAC.
        // The chosen original audio index is separately validated and bound
        // to the Mac Bridge below; never replace it with the default track.
        NSDictionary *info=[client playbackInfo:identifier startTicks:ticks mediaSourceID:selectedSource audioIndex:-1 subtitleIndex:-1 error:error];
        NSUInteger playbackInfoMillis=(NSUInteger)MAX(0,([NSProcessInfo processInfo].systemUptime-setupStarted)*1000.0);
        JFPlaybackTrace([NSString stringWithFormat:@"SETUP_PLAYBACKINFO_TIME ms=%lu",(unsigned long)playbackInfoMillis]);
        if (!info || JFWorkCancelled()) {
            if (!JFWorkCancelled()) JFPlaybackTrace([NSString stringWithFormat:@"SETUP_PLAYBACKINFO ok=0 kind=%@ code=%ld",JFPlaybackTraceKind(error),(long)JFPlaybackTraceCode(error)]);
            return nil;
        }
        JFPlaybackTrace(@"SETUP_PLAYBACKINFO ok=1");
        // A source may default to AC3 even though it contains AAC (e.g. Blueberry
        // Nights). The first PlaybackInfo then says AudioCodecNotSupported.
        // Retry the VIDEO negotiation using an explicit AAC track, while the
        // chosen original index remains bound separately to the Mac Bridge.
        if (selectedSource) {
            NSDictionary *media=nil;
            for (id entry in info[@"MediaSources"])
                if ([entry isKindOfClass:[NSDictionary class]] && [entry[@"Id"] isEqual:selectedSource]) {media=entry;break;}
            NSString *reason=[media[@"TranscodingUrl"] isKindOfClass:[NSString class]] ? media[@"TranscodingUrl"] : @"";
            if (media && ![media[@"SupportsDirectPlay"] boolValue] &&
                [reason containsString:@"AudioCodecNotSupported"]) {
                NSInteger videoAudio=JFVideoTransportAACIndex(info,selectedSource);
                if (videoAudio>=0 && videoAudio!=audioIndex) {
                    NSDictionary *alternate=[client playbackInfo:identifier startTicks:ticks mediaSourceID:selectedSource audioIndex:videoAudio subtitleIndex:-1 error:error];
                    if (JFWorkCancelled()) return nil;
                    if (alternate) {
                        info=alternate;
                        JFPlaybackTrace(@"SETUP_VIDEO_AUDIO_NEGOTIATED_AAC");
                    }
                }
            }
        }
        NSDictionary *plan=JFPlaybackPlanForSourceAndAudio(info,identifier,ticks,selectedSource,audioIndex,error);
        if (!plan) {
            JFPlaybackTrace([NSString stringWithFormat:@"SETUP_PLAN ok=0 kind=%@ code=%ld",JFPlaybackTraceKind(error),(long)JFPlaybackTraceCode(error)]);
            return nil;
        }
        if (selectedSource) {
            NSMutableDictionary *bound=[[plan mutableCopy] autorelease];
            if (hasAudio) bound[@"audioStreamIndex"]=@(audioIndex);
            // Do not append a subtitle index to the video transport.
            plan=bound;
        }
        NSString *method=[plan[@"method"] isKindOfClass:[NSString class]] ? plan[@"method"] : @"none";
        JFPlaybackTrace([NSString stringWithFormat:@"SETUP_PLAN ok=1 method=%@ videoCopy=%d videoRejectMask=%lu videos=%lu audios=%lu audioBound=%d subtitleBound=%d",
            method,[plan[@"allowVideoCopy"] boolValue],(unsigned long)[plan[@"videoRejectMask"] unsignedIntegerValue],
            (unsigned long)[plan[@"videoCount"] unsignedIntegerValue],(unsigned long)[plan[@"audioCount"] unsignedIntegerValue],hasAudio,hasSubtitle]);
        NSDictionary *source=[plan[@"source"] isKindOfClass:[NSDictionary class]] ? plan[@"source"] : nil;
        NSDictionary *firstVideo=nil;
        for (NSDictionary *stream in [source[@"MediaStreams"] isKindOfClass:[NSArray class]] ? source[@"MediaStreams"] : @[])
            if ([stream[@"Type"] isEqual:@"Video"]) { firstVideo=stream; break; }
        if (firstVideo) JFPlaybackTrace([NSString stringWithFormat:@"SETUP_VIDEO width=%ld height=%ld bit=%ld fps_x100=%ld level=%ld sdr=%d h264=%d",
            (long)[firstVideo[@"Width"] integerValue],(long)[firstVideo[@"Height"] integerValue],(long)[firstVideo[@"BitDepth"] integerValue],
            (long)llround([firstVideo[@"RealFrameRate"] doubleValue]*100.0),(long)[firstVideo[@"Level"] integerValue],
            [firstVideo[@"VideoRange"] isEqual:@"SDR"],[firstVideo[@"Codec"] isEqual:@"h264"]]);
        NSURLRequest *request=[client playbackRequest:plan error:error];
        if (!request) JFPlaybackTrace([NSString stringWithFormat:@"SETUP_REQUEST ok=0 kind=%@ code=%ld",JFPlaybackTraceKind(error),(long)JFPlaybackTraceCode(error)]);
        else JFPlaybackTrace([NSString stringWithFormat:@"SETUP_REQUEST ok=1 method=%@",method]);
        // The background setup worker waits until Mac has a signed, verified
        // complete soundtrack. Never present the native video on a cache miss.
        NSNumber *audioTrack=plan[@"audioStreamIndex"];
        if (request && [audioTrack isKindOfClass:[NSNumber class]]) {
            JFPlaybackTrace(@"AUDIO_CACHE_GATE_BEGIN_BEFORE_VIDEO");
            if (!JFV2WaitForAudioCache(plan[@"itemID"],plan[@"sourceID"],[audioTrack integerValue])) {
                if (!JFWorkCancelled() && error)
                    *error=[NSError errorWithDomain:@"ATV3AudioCache" code:202 userInfo:nil];
                JFPlaybackTrace(@"AUDIO_CACHE_GATE_NOT_READY_VIDEO_NOT_STARTED");
                return nil;
            }
        }
        return JFWorkCancelled() ? nil : (request ? @{@"plan":plan,@"request":request} : nil);
    } completion:^(id result, NSError *error) {
        JFPlaybackController *owner=delivery->owner;
        if (!owner || owner->_closed || owner->_generation!=generation || ![owner->_state isEqual:@"setup"]) return;
        [owner retain];
        if (!result) [owner fail:Kind(error)];
        else {
            owner->_plan=[result[@"plan"] copy];
            [owner->_macAudioRequest release]; owner->_macAudioRequest=[result[@"request"] copy];
            JFBackendEvent callback=^(NSString *event,long long position) {
                JFPlaybackController *target=delivery->owner;
                if (target && [NSThread isMainThread]) { [target retain]; [target backendEvent:event ticks:position generation:generation]; [target release]; }
            };
            if ([owner->_backend isKindOfClass:[JFATV3PlaybackBackend class]])
                [(JFATV3PlaybackBackend *)owner->_backend startRequest:result[@"request"]
                    positionTicks:ticks audioPlan:owner->_plan event:callback];
            else [owner->_backend startRequest:result[@"request"] positionTicks:ticks event:callback];
        }
        [owner release];
    }] retain];
    [self state:@"setup"]; [self release]; return YES;
}
- (void)clearLocalSubtitles {
    [_subtitleTask cancel];[_subtitleTask release];_subtitleTask=nil;
    _subtitleGeneration++;
    _subtitleAttachAttempts=0;
    [_subtitleCues release];_subtitleCues=nil;
    [_subtitleOverlay showText:nil];
    [_subtitleOverlay detach];
}
- (void)attachLocalSubtitleOverlayIfNeeded {
    if (![NSThread isMainThread] || ![self active] || _subtitleIndex<0 ||
        [_subtitleOverlay attached] || _subtitleAttachAttempts>=12) return;
    ++_subtitleAttachAttempts;
    id playerController=nil;
    SEL getter=NSSelectorFromString(@"preparedPlayerController");
    if ([_backend respondsToSelector:getter]) {
        NSMethodSignature *sig=[(id)_backend methodSignatureForSelector:getter];
        if (sig && sig.numberOfArguments==2 && !strcmp(sig.methodReturnType,@encode(id)))
            playerController=((id(*)(id,SEL))objc_msgSend)(_backend,getter);
    }
    if ([_subtitleOverlay attachToPlayerController:playerController]) {
        JFPlaybackTrace([NSString stringWithFormat:@"LOCAL_SRT_OVERLAY_ATTACHED attempt=%lu",
                         (unsigned long)_subtitleAttachAttempts]);
    } else if (_subtitleAttachAttempts==1 || _subtitleAttachAttempts==12) {
        JFPlaybackTrace([NSString stringWithFormat:@"LOCAL_SRT_OVERLAY_UNAVAILABLE attempt=%lu",
                         (unsigned long)_subtitleAttachAttempts]);
    }
}
- (void)updateLocalSubtitles {
    if (![NSThread isMainThread] || ![self active]) return;
    // Retry only during existing player progress notifications, never on a timer.
    // The native presentation hierarchy may be created *after* started.
    [self attachLocalSubtitleOverlayIfNeeded];
    if (!_subtitleCues.count || ![_subtitleOverlay attached]) return;
    [_subtitleOverlay showText:JFLocalSubtitleAtTicks(_subtitleCues,_position)];
}
- (void)beginLocalSubtitles {
    if (![NSThread isMainThread] || (![_state isEqual:@"playing"] && ![_state isEqual:@"paused"])) return;
    [_subtitleTask cancel];[_subtitleTask release];_subtitleTask=nil;
    _subtitleGeneration++;
    [_subtitleCues release];_subtitleCues=nil;
    [_subtitleOverlay showText:nil];
    _subtitleAttachAttempts=0;
    if (_subtitleIndex<0 || !JFMediaID(_subtitleItemID) || !JFMediaID(_subtitleSourceID)) {
        [_subtitleOverlay detach];return;
    }
    // Download/parse and compositor attachment must be independent. Previously
    // failure to obtain a layer at startup prevented SRT downloads entirely.
    [self attachLocalSubtitleOverlayIfNeeded];
    NSString *item=[_subtitleItemID copy],*source=[_subtitleSourceID copy];
    NSInteger index=_subtitleIndex;
    NSUInteger generation=_subtitleGeneration;
    JFClient *client=_client; JFPlaybackDelivery *delivery=_delivery;
    _subtitleTask=[[_worker perform:^id(NSError **error) {
        if (JFWorkCancelled()) return nil;
        // Decode SRT only once; never build two complete cue arrays on the A5.
        NSArray *cues=[client localSubtitleCues:item mediaSource:source index:index error:error];
        return JFWorkCancelled() ? nil : cues;
    } completion:^(id result,NSError *error) {
        JFPlaybackController *owner=delivery->owner;
        if (!owner || owner->_closed || generation!=owner->_subtitleGeneration || ![owner active]) return;
        [owner retain];
        [owner->_subtitleCues release];
        owner->_subtitleCues=[result isKindOfClass:[NSArray class]] ? [result copy] : nil;
        JFPlaybackTrace([NSString stringWithFormat:@"LOCAL_SRT_RESULT ok=%d cues=%lu",
                         owner->_subtitleCues.count>0,(unsigned long)owner->_subtitleCues.count]);
        [owner updateLocalSubtitles];
        [owner release];
    }] retain];
    [item release];[source release];
}
- (BOOL)selectLocalSubtitleForItem:(NSString *)item mediaSourceID:(NSString *)source index:(NSInteger)index {
    if (![NSThread isMainThread] || _closed || ![self active] || index< -1 || index>10000 ||
        ![_plan[@"itemID"] isEqual:item] || ![_plan[@"sourceID"] isEqual:source]) return NO;
    [_subtitleItemID release];_subtitleItemID=[item copy];
    [_subtitleSourceID release];_subtitleSourceID=[source copy];
    _subtitleIndex=index;
    [self beginLocalSubtitles]; // Does not stop/reopen video.
    return YES;
}
- (void)report:(NSString *)event {
    if (!_plan || ([event isEqual:@"Stopped"] && !_reportedStart)) return;
    JFPlaybackTrace([NSString stringWithFormat:@"PLAYBACK_REPORT event=%@ ticks=%lld",event,_position]);
    NSDictionary *body=JFPlaybackReport(_plan,_position,[_state isEqual:@"paused"]);
    if (!body) return;
    if ([event isEqual:@"Playing"]) _reportedStart=YES;
    BOOL progress=[event isEqual:@"Progress"];
    if (progress) { _reportBusy=YES; _lastReported=_position; }
    JFClient *client=_client; JFPlaybackDelivery *delivery=_delivery; NSUInteger generation=_generation;
    // Serial queue preserves start/progress/stop ordering. No retry of ambiguous POSTs.
    [_worker perform:^id(NSError **error) { return @([client reportPlayback:event body:body error:error]); }
        completion:^(id result,NSError *error) {
            JFPlaybackController *owner=delivery->owner;
            if (!owner || owner->_closed || owner->_generation!=generation) return;
            [owner retain];
            if (progress) owner->_reportBusy=NO;
            BOOL ok=[result boolValue];
            JFPlaybackTrace([NSString stringWithFormat:@"PLAYBACK_REPORT_RESULT event=%@ ok=%d kind=%@",event,ok,ok ? @"none" : Kind(error)]);
            if (!ok) [owner fail:Kind(error)];
            [owner release];
        }];
}
- (void)backendEvent:(NSString *)event ticks:(long long)ticks generation:(NSUInteger)generation {
    if (_closed || _generation!=generation || ![self active]) return;
    if ([event isEqual:@"failure"]) { [self fail:@"playback"]; return; }
    if ([event isEqual:@"started"]) {
        if (![_state isEqual:@"setup"] || !_plan) return;
        if (ticks>0 && JFTicks(@(ticks)) && ticks<=[_plan[@"durationTicks"] longLongValue]) _position=ticks;
        [self report:@"Playing"]; [self state:@"playing"];
        _lastMacAudioSync=_position;
        if ([_backend respondsToSelector:NSSelectorFromString(@"preparedPlayer")]) {
            id player=((id(*)(id,SEL))objc_msgSend)(_backend,NSSelectorFromString(@"preparedPlayer"));
            if (![JFAppAudioLink isBoundPlayer:player])
                [JFAppAudioLink bindPlayer:player plan:_plan];
        }
        [JFAppAudioLink event:@"start" plan:_plan request:_macAudioRequest ticks:_position paused:NO];
        [self beginLocalSubtitles];
        return;
    }
    if ([_state isEqual:@"setup"]) return;
    if ([event isEqual:@"paused"]) {
        if (![_state isEqual:@"playing"]) return;
        if (JFTicks(@(ticks)) && ticks<=[_plan[@"durationTicks"] longLongValue]) _position=ticks;
        [self state:@"paused"];
        [self updateLocalSubtitles];
        [JFAppAudioLink event:@"pause" plan:_plan request:_macAudioRequest ticks:_position paused:YES];
        if (!_closed && [_state isEqual:@"paused"]) [self report:@"Progress"];
        return;
    }
    if ([event isEqual:@"resumed"]) {
        if (![_state isEqual:@"paused"]) return;
        if (JFTicks(@(ticks)) && ticks<=[_plan[@"durationTicks"] longLongValue]) _position=ticks;
        [self state:@"playing"];
        [self updateLocalSubtitles];
        [JFAppAudioLink event:@"resume" plan:_plan request:_macAudioRequest ticks:_position paused:NO];
        if (!_closed && [_state isEqual:@"playing"]) [self report:@"Progress"];
        return;
    }
    if ([event isEqual:@"ended"]) {
        // Native end notification is authoritative: natural completion is the full duration.
        _position=[_plan[@"durationTicks"] longLongValue];
        [self stop]; return;
    }
    if ([event isEqual:@"popped"]) {
        if (JFTicks(@(ticks)) && ticks<=[_plan[@"durationTicks"] longLongValue]) _position=ticks;
        [self stop]; return;
    }
    if (![event isEqual:@"progress"] || !JFTicks(@(ticks)) || ticks>[_plan[@"durationTicks"] longLongValue] || [_state isEqual:@"paused"]) return;
    BOOL movedBackward=ticks<_position;
    _position=ticks;
    [self updateLocalSubtitles];
    if (movedBackward || ticks<_lastMacAudioSync || ticks-_lastMacAudioSync>=50000000LL) {
        _lastMacAudioSync=ticks;
        [JFAppAudioLink event:@"sync" plan:_plan request:_macAudioRequest ticks:ticks paused:NO];
    }
    if (!_reportBusy && (movedBackward || ticks<_lastReported || ticks-_lastReported>=100000000LL)) [self report:@"Progress"];
    void (^callback)(long long)=[_progress copy];
    if (callback) callback(ticks);
    [callback release];
}
- (NSString *)currentMediaSourceID {
    if (![NSThread isMainThread] || _closed || ![self active]) return nil;
    id identifier = _plan[@"sourceID"];
    return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}
- (long long)resumeTicksForItem:(NSString *)item {
    if (![NSThread isMainThread] || _closed || !JFMediaID(item) || ![_plan[@"itemID"] isEqual:item]) return 0;
    long long duration=[_plan[@"durationTicks"] longLongValue];
    return _position>0 && duration>0 && _position<duration ? _position : 0;
}
- (BOOL)pause {
    if (![NSThread isMainThread] || _closed || ![_state isEqual:@"playing"]) return NO;
    [self retain]; [_backend pause];
    if (!_closed && [_state isEqual:@"playing"]) { [self state:@"paused"]; if (!_closed && [_state isEqual:@"paused"]) [self report:@"Progress"]; }
    [self release]; return YES;
}
- (BOOL)resume {
    if (![NSThread isMainThread] || _closed || ![_state isEqual:@"paused"]) return NO;
    [self retain]; [_backend resume];
    if (!_closed && [_state isEqual:@"paused"]) { [self state:@"playing"]; if (!_closed && [_state isEqual:@"playing"]) [self report:@"Progress"]; }
    [self release]; return YES;
}
- (BOOL)seekBySeconds:(NSInteger)seconds {
    if (![NSThread isMainThread] || _closed || seconds==0 || seconds < -600 || seconds > 600 ||
        (![_state isEqual:@"playing"] && ![_state isEqual:@"paused"])) return NO;
    long long duration=[_plan[@"durationTicks"] longLongValue];
    if (duration<=10000000LL) return NO;
    long long target=_position+(long long)seconds*10000000LL;
    if (target<0) target=0;
    if (target>=duration) target=duration-10000000LL;
    if (target==_position) return NO;
    return [self seek:target];
}
- (BOOL)seek:(long long)ticks {
    if (![NSThread isMainThread] || _closed || (![_state isEqual:@"playing"] && ![_state isEqual:@"paused"]) || !JFTicks(@(ticks)) || ticks>[_plan[@"durationTicks"] longLongValue]) return NO;
    [self retain]; _position=ticks; _generation++; _reportBusy=NO;
    [self updateLocalSubtitles];
    NSUInteger generation=_generation; JFPlaybackDelivery *delivery=_delivery;
    [_backend seek:ticks event:^(NSString *event, long long position) {
        JFPlaybackController *target=delivery->owner;
        if (target && [NSThread isMainThread]) { [target retain]; [target backendEvent:event ticks:position generation:generation]; [target release]; }
    }];
    if (!_closed && [self active]) {
        [JFAppAudioLink event:@"seek" plan:_plan request:_macAudioRequest ticks:ticks paused:[_state isEqual:@"paused"]];
        [self report:@"Progress"];
    }
    [self release]; return YES;
}
- (BOOL)stop {
    if (![NSThread isMainThread] || _closed || ![self active]) return NO;
    [self retain]; [_setupTask cancel]; _generation++; // Reject synchronous/late backend callbacks before stop.
    [self clearLocalSubtitles];
    [JFAppAudioLink event:@"stop" plan:_plan request:_macAudioRequest ticks:_position paused:NO];
    [self report:@"Stopped"]; _reportedStart=NO;
    [_backend stop]; [self state:@"stopped"]; [self release]; return YES;
}
- (void)fail:(NSString *)kind {
    if (_closed) return;
    [self retain]; [_setupTask cancel]; _generation++;
    [self clearLocalSubtitles];
    [JFAppAudioLink event:@"stop" plan:_plan request:_macAudioRequest ticks:_position paused:NO];
    // A 401 invalidates the client; do not send another authenticated request.
    if (![kind isEqual:@"authentication"]) [self report:@"Stopped"];
    _reportedStart=NO; [_backend stop]; [_errorKind release]; _errorKind=[kind copy];
    [self state:@"failed"];
    void (^callback)(NSString *)=[_failure copy];
    if (!_closed && callback) callback(kind);
    [callback release]; [self release];
}
- (void)invalidateSession { if ([NSThread isMainThread] && !_closed) { [self stop]; _generation++; } }
- (void)close {
    if (![NSThread isMainThread] || _closed) return;
    // No notification on close: host removes observations before releasing ownership.
    [_setupTask cancel]; _generation++;
    [self clearLocalSubtitles];
    [JFAppAudioLink event:@"stop" plan:_plan request:_macAudioRequest ticks:_position paused:NO];
    [self report:@"Stopped"]; _reportedStart=NO;
    _closed=YES; if (_delivery) _delivery->owner=nil; [_backend stop];
    JFPlaybackIdleSet(NO);
    [_state release]; _state=[@"closed" copy];
    self.progressCallback=nil; self.failureCallback=nil;
}
- (void)dealloc {
    [self close];
    [_subtitleTask release];[_subtitleCues release];[_subtitleOverlay release];
    [_subtitleItemID release];[_subtitleSourceID release];
    [_setupTask release]; [_delivery release]; [_client release]; [_worker release]; [_backend release]; [_plan release]; [_macAudioRequest release]; [_state release]; [_errorKind release]; [super dealloc];
}
@end
@implementation JFMockPlaybackBackend
@synthesize starts=_starts,stops=_stops;
- (void)startRequest:(NSURLRequest *)request positionTicks:(long long)ticks event:(JFBackendEvent)event { [_event release]; _event=[event copy]; _starts++; }
- (void)pause {}
- (void)resume {}
- (void)seek:(long long)ticks event:(JFBackendEvent)event { [_event release]; _event=[event copy]; }
- (void)stop { _stops++; [_event release]; _event=nil; }
- (void)emit:(NSString *)event ticks:(long long)ticks { JFBackendEvent callback=[_event copy]; if (callback) callback(event,ticks); [callback release]; }
- (JFBackendEvent)capturedEvent { return [[_event copy] autorelease]; }
- (void)dealloc { [_event release]; [super dealloc]; }
@end
