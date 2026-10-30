#import "JFATV3PlaybackBackend.h"
#import "JFAppAudioLink.h"
#import "JFMediaGateway.h"
#import "JFPlaybackTrace.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <math.h>
#include <limits.h>

static char jfAssetRequestKey;

static BOOL JFATV3Signature(id target, SEL selector, const char *result, NSArray *arguments) {
    if (!target || ![target respondsToSelector:selector]) return NO;
    NSMethodSignature *signature=[target methodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType,result) || signature.numberOfArguments!=arguments.count+2) return NO;
    for (NSUInteger i=0;i<arguments.count;i++)
        if (strcmp([signature getArgumentTypeAtIndex:i+2],[arguments[i] UTF8String])) return NO;
    return YES;
}
static id JFATV3Object(id target, NSString *name) {
    SEL selector=NSSelectorFromString(name);
    if (!JFATV3Signature(target,selector,@encode(id),@[])) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(target,selector);
}
static BOOL JFATV3InstanceSignature(Class cls, NSString *name, const char *result, NSArray *arguments) {
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));
    if (!method) return NO;
    NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!signature || strcmp(signature.methodReturnType,result) || signature.numberOfArguments!=arguments.count+2) return NO;
    for (NSUInteger i=0;i<arguments.count;i++)
        if (strcmp([signature getArgumentTypeAtIndex:i+2],[arguments[i] UTF8String])) return NO;
    return YES;
}
static BOOL JFATV3BoolMethod(Class cls, NSString *name) {
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));
    return method && !strcmp(method_getTypeEncoding(method),"c8@0:4");
}
static BOOL JFATV3ObjectMethod(Class cls, NSString *name) {
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));
    return method && !strcmp(method_getTypeEncoding(method),"@8@0:4");
}
static NSURLRequest *JFAssetRequest(id self) { return objc_getAssociatedObject(self,&jfAssetRequestKey); }
static id JFAssetPlaybackMetadata(id self, SEL cmd) {
    NSMutableDictionary *headers=[NSMutableDictionary dictionary];
    // Explicit allowlist: never forward Host, cookies, framing or hop-by-hop fields.
    for (NSString *name in @[@"Authorization",@"Accept",@"Accept-Language",@"User-Agent"]) {
        NSString *value=[JFAssetRequest(self) valueForHTTPHeaderField:name];
        if (value.length && [value rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location==NSNotFound)
            headers[name]=value;
    }
    // 12H1006 LTAVPlayer merges this dictionary into AVURLAssetHTTPHeaderFieldsKey.
    // The gateway means the native loader sees only loopback plus a non-secret marker.
    return @{@"BRMediaAssetMetadataHTTPHeaders":[NSDictionary dictionaryWithDictionary:headers],
             @"kBRMediaAssetReferenceRestrictions":@5};
}
static id JFAssetURL(id self, SEL cmd) { return [[JFAssetRequest(self) URL] absoluteString]; }
static id JFAssetID(id self, SEL cmd) {
    NSString *value=[[[JFAssetRequest(self) URL] absoluteString] copy];
    return [value autorelease];
}
static id JFAssetTitle(id self, SEL cmd) {
    NSString *title=[[[JFAssetRequest(self) URL] lastPathComponent] stringByRemovingPercentEncoding];
    return title.length ? title : @"Jellyfin";
}
static id JFAssetMediaType(id self, SEL cmd) {
    Class mediaType=objc_getClass("BRMediaType");
    SEL selector=NSSelectorFromString(@"streamingVideo");
    if (!mediaType || ![mediaType respondsToSelector:selector]) return nil;
    NSMethodSignature *signature=[mediaType methodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType,@encode(id)) || signature.numberOfArguments!=2) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(mediaType,selector);
}
static BOOL JFAssetTrue(id self, SEL cmd) { return YES; }
static long JFAssetDuration(id self, SEL cmd) { return 0; }

static Class JFATV3AssetClass(void) {
    Class existing=objc_getClass("JFJellyfinMediaAsset");
    if (existing) return existing;
    Class base=objc_getClass("BRBaseMediaAsset");
    if (!base) return Nil;
    Class cls=objc_allocateClassPair(base,"JFJellyfinMediaAsset",0);
    if (!cls) return Nil;
    struct { const char *name; IMP imp; } methods[]={
        {"mediaURL",(IMP)JFAssetURL},{"assetID",(IMP)JFAssetID},{"title",(IMP)JFAssetTitle},{"mediaType",(IMP)JFAssetMediaType},
        {"playbackMetadata",(IMP)JFAssetPlaybackMetadata},
        {"isValid",(IMP)JFAssetTrue},{"playable",(IMP)JFAssetTrue},{"hasVideoContent",(IMP)JFAssetTrue},{"isScrubbable",(IMP)JFAssetTrue},
        {"duration",(IMP)JFAssetDuration}
    };
    for (NSUInteger i=0;i<sizeof(methods)/sizeof(methods[0]);i++) {
        SEL selector=sel_registerName(methods[i].name);
        Method source=class_getInstanceMethod(base,selector);
        if (!source || !class_addMethod(cls,selector,methods[i].imp,method_getTypeEncoding(source))) {
            objc_disposeClassPair(cls); return Nil;
        }
    }
    objc_registerClassPair(cls);
    return cls;
}

static NSError *JFATV3Error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"JFATV3Playback" code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"ATV3 playback unavailable"}];
}
static NSString *JFATV3SafeErrorDomain(NSError *error) {
    NSString *domain=[error.domain isKindOfClass:[NSString class]] ? error.domain : nil;
    if (!domain.length || domain.length>64) return @"other";
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    return [domain rangeOfCharacterFromSet:[allowed invertedSet]].location==NSNotFound ? domain : @"other";
}
static NSError *JFATV3NotificationError(NSNotification *notification) {
    for (id value in notification.userInfo.allValues)
        if ([value isKindOfClass:[NSError class]]) return value;
    return nil;
}

@interface JFATV3PlaybackBackend ()
- (void)installObservers;
- (void)removeObservers;
- (void)nativeNotification:(NSNotification *)notification;
- (void)sampleProgress;
- (BOOL)detectNativePresentationExit;
- (void)checkNativeRate;
- (long long)currentTicks;
- (void)emit:(NSString *)event ticks:(long long)ticks;
- (void)failCurrentAtTicks:(long long)ticks;
@end

@implementation JFATV3PlaybackBackend

+ (BOOL)runtimeCompatible {
    Class base=objc_getClass("BRBaseMediaAsset"), manager=objc_getClass("BRMediaPlayerManager");
    Class player=objc_getClass("BRMediaPlayer"), controller=objc_getClass("BRMediaPlayerController"), mediaType=objc_getClass("BRMediaType");
    if (!base || !manager || !player || !controller || !mediaType) return NO;
    if (!JFATV3Signature(mediaType,NSSelectorFromString(@"streamingVideo"),@encode(id),@[])) return NO;
    Protocol *assetProtocol=objc_getProtocol("BRMediaAsset");
    if (!assetProtocol || !class_conformsToProtocol(base,assetProtocol)) return NO;
    if (!JFATV3ObjectMethod(base,@"mediaURL") || !JFATV3ObjectMethod(base,@"assetID") ||
        !JFATV3ObjectMethod(base,@"title") || !JFATV3ObjectMethod(base,@"mediaType") ||
        !JFATV3ObjectMethod(base,@"playbackMetadata") ||
        !JFATV3BoolMethod(base,@"isValid") || !JFATV3BoolMethod(base,@"playable") ||
        !JFATV3BoolMethod(base,@"hasVideoContent") || !JFATV3BoolMethod(base,@"isScrubbable")) return NO;
    Method duration=class_getInstanceMethod(base,NSSelectorFromString(@"duration"));
    if (!duration || strcmp(method_getTypeEncoding(duration),"l8@0:4")) return NO;
    if (!JFATV3Signature(manager,NSSelectorFromString(@"sharedInstance"),@encode(id),@[])) return NO;
    id shared=JFATV3Object(manager,@"sharedInstance");
    if (!shared || !JFATV3Signature(shared,NSSelectorFromString(@"playerForMediaAsset:error:"),@encode(id),@[@"@",@"^@"]) ||
        !JFATV3Signature(shared,NSSelectorFromString(@"presentPlayer:options:"),@encode(void),@[@"@",@"@"]) ||
        !JFATV3Signature(shared,NSSelectorFromString(@"endPresentation"),@encode(void),@[])) return NO;
    if (!JFATV3Signature(controller,NSSelectorFromString(@"controllerForPlayer:"),@encode(id),@[@"@"])) return NO;
    Method controllerInit=class_getInstanceMethod(controller,NSSelectorFromString(@"initWithPlayer:"));
    if (!controllerInit || strcmp(method_getTypeEncoding(controllerInit),"@12@0:4@8")) return NO;
    if (!JFATV3InstanceSignature(player,@"cueMediaWithError:",@encode(BOOL),@[@"^@"]) ||
        !JFATV3InstanceSignature(player,@"setState:error:",@encode(BOOL),@[@"i",@"^@"]) ||
        !JFATV3InstanceSignature(player,@"elapsedTime",@encode(double),@[]) ||
        !JFATV3InstanceSignature(player,@"rate",@encode(double),@[]) ||
        !JFATV3InstanceSignature(player,@"setElapsedTime:",@encode(void),@[@"d"])) return NO;
    return JFATV3AssetClass()!=Nil;
}

- (id)initWithHostController:(id)controller {
    if ((self=[super init])) _hostController=[controller retain];
    return self;
}
- (BOOL)prepared { return _asset && _player && _playerController && _preparedRequest; }
- (id)preparedAsset { return _asset; }
- (id)preparedPlayer { return _player; }
- (id)preparedPlayerController { return _playerController; }

- (BOOL)prepareRequest:(NSURLRequest *)request positionTicks:(long long)ticks error:(NSError **)error {
    if (error) *error=nil;
    [self discardPreparedPlayback];
    if (![NSThread isMainThread]) {
        if (error) *error=JFATV3Error(3001,@"Playback preparation must run on main thread"); return NO;
    }
    if (![[self class] runtimeCompatible]) {
        if (error) *error=JFATV3Error(3002,@"12H1006 player ABI unavailable"); return NO;
    }
    if (![request isKindOfClass:[NSURLRequest class]] || ticks<0) {
        if (error) *error=JFATV3Error(3003,@"Invalid playback request"); return NO;
    }
    NSURL *url=request.URL;
    if (!url || ![@[@"http",@"https"] containsObject:url.scheme.lowercaseString] || url.user || url.password || url.fragment) {
        if (error) *error=JFATV3Error(3003,@"Unsafe playback URL"); return NO;
    }
    NSString *authorization=[request valueForHTTPHeaderField:@"Authorization"];
    if (!authorization.length) {
        if (error) *error=JFATV3Error(3004,@"Authenticated playback request required"); return NO;
    }
    Class assetClass=JFATV3AssetClass();
    id asset=[[assetClass alloc] init];
    if (!asset) {
        if (error) *error=JFATV3Error(3005,@"Could not create media asset"); return NO;
    }
    objc_setAssociatedObject(asset,&jfAssetRequestKey,request,OBJC_ASSOCIATION_COPY_NONATOMIC);
    id manager=JFATV3Object(objc_getClass("BRMediaPlayerManager"),@"sharedInstance");
    NSError *playerError=nil;
    id player=nil, controller=nil;
    @try {
        player=((id(*)(id,SEL,id,NSError **))objc_msgSend)(manager,NSSelectorFromString(@"playerForMediaAsset:error:"),asset,&playerError);
        if (player)
            controller=((id(*)(id,SEL,id))objc_msgSend)(objc_getClass("BRMediaPlayerController"),NSSelectorFromString(@"controllerForPlayer:"),player);
    } @catch (NSException *exception) {
        [asset release];
        if (error) *error=[NSError errorWithDomain:@"JFATV3Playback" code:3008 userInfo:@{
            NSLocalizedDescriptionKey:@"Native player rejected media asset",
            @"JFExceptionName":exception.name ?: @"",
            @"JFExceptionReason":exception.reason ?: @""
        }];
        return NO;
    }
    if (!player) {
        [asset release];
        if (error) *error=playerError ?: JFATV3Error(3006,@"Could not create native player");
        return NO;
    }
    if (!controller) {
        [asset release];
        if (error) *error=JFATV3Error(3007,@"Could not create native player controller");
        return NO;
    }
    _preparedRequest=[request copy];
    _asset=[asset retain]; _player=[player retain]; _playerController=[controller retain];
    _positionTicks=ticks; _lastTicks=ticks;
    [asset release];
    return YES;
}

- (void)installObservers {
    NSNotificationCenter *center=[NSNotificationCenter defaultCenter];
    for (NSString *name in @[@"BRMPStateChanged",@"BRMediaPlayerPlaybackError",
                              @"BRMediaPlayerPlaylistAssetPlayedToEndTime",@"BRMediaPlayerControllerWasPopped"])
        [center addObserver:self selector:@selector(nativeNotification:) name:name object:nil];
}
- (void)removeObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (long long)currentTicks {
    if (!_player) return _lastTicks;
    @try {
        double seconds=((double(*)(id,SEL))objc_msgSend)(_player,NSSelectorFromString(@"elapsedTime"));
        if (!isfinite(seconds) || seconds<0.0 || seconds>(double)LLONG_MAX/10000000.0) return _lastTicks;
        return (long long)(seconds*10000000.0+0.5);
    } @catch (NSException *exception) {
        return _lastTicks;
    }
}
- (void)emit:(NSString *)event ticks:(long long)ticks {
    JFBackendEvent callback=[_event copy];
    if (callback) callback(event,ticks);
    [callback release];
}
- (BOOL)detectNativePresentationExit {
    // 12H1006 may briefly publish a nil/different _presentedPlayer while its
    // native presentation changes state. A single mismatch must NOT stop the film.
    // Actual BRMediaPlayerControllerWasPopped notifications still stop immediately.
    if (!_presented || !_started || _stopping || !_player) return NO;
    id manager=JFATV3Object(objc_getClass("BRMediaPlayerManager"),@"sharedInstance");
    if (!manager || !JFATV3Signature(manager,NSSelectorFromString(@"_presentedPlayer"),@encode(id),@[])) return NO;
    id current=JFATV3Object(manager,@"_presentedPlayer");
    if (current==_player) {
        if (_nativeExitSuspectSince>0)
            JFPlaybackTrace(@"NATIVE_PRESENTATION_RECOVERED");
        _nativeExitSuspectSince=0;
        _verifiedNativePresentation=YES;
        return NO;
    }
    if (!_verifiedNativePresentation) return NO; // Initial async presentation.
    NSTimeInterval now=[NSProcessInfo processInfo].systemUptime;
    if (_nativeExitSuspectSince<=0 || now<_nativeExitSuspectSince) {
        _nativeExitSuspectSince=now;
        JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_PRESENTATION_SUSPECT kind=%@",
            current ? @"other" : @"nil"]);
    } else if (now-_nativeExitSuspectSince>=1.20) {
        long long ticks=[self currentTicks];
        if (ticks>0) _lastTicks=ticks;
        JFPlaybackTrace([NSString stringWithFormat:
            @"NATIVE_PRESENTATION_GONE confirmed=1 elapsed_ms=%lu ticks=%lld",
            (unsigned long)MAX(0,(now-_nativeExitSuspectSince)*1000.0),_lastTicks]);
        _presented=NO; _started=NO; _nativePaused=NO;
        _verifiedNativePresentation=NO; _nativeExitSuspectSince=0;
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
        [self emit:@"popped" ticks:_lastTicks];
        return YES;
    }
    // Skip rate/progress sampling while uncertain; schedule exactly one
    // bounded recheck. Never call endPresentation in this uncertain state.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sampleProgress) object:nil];
    [self performSelector:@selector(sampleProgress) withObject:nil afterDelay:0.35];
    return YES;
}
- (void)sampleProgress {
    if (!_started || _stopping || !_player) return;
    if ([self detectNativePresentationExit]) return;
    long long ticks=[self currentTicks];
    NSTimeInterval now=[NSProcessInfo processInfo].systemUptime;
    if (ticks==0 && _lastTicks>10000000LL) {
        if (!_zeroPositionActive) {
            _zeroPositionActive=YES; _zeroPositionSince=now;
            JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_STALL begin retained=%lld",_lastTicks]);
        }
    } else {
        if (_zeroPositionActive) {
            NSUInteger stallMillis=(NSUInteger)MAX(0,(now-_zeroPositionSince)*1000.0);
            JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_STALL end ms=%lu sampled=%lld",(unsigned long)stallMillis,ticks]);
            _zeroPositionActive=NO;
        }
        if (ticks<_lastTicks) JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_POSITION_BACKWARD from=%lld to=%lld",_lastTicks,ticks]);
        _lastTicks=ticks;
        const long long readyDelta=2000000LL; // 0.2 s of real timeline advance.
        long long startDelta=ticks>=_startBaselineTicks ? ticks-_startBaselineTicks : _startBaselineTicks-ticks;
        if (_startProgressPending && startDelta>=readyDelta) {
            NSUInteger ms=(NSUInteger)MAX(0,(now-_startRequestedAt)*1000.0);
            JFPlaybackTrace([NSString stringWithFormat:@"PLAY_PROGRESS_READY ms=%lu ticks=%lld",(unsigned long)ms,ticks]);
            _startProgressPending=NO;
        }
        long long resumeDelta=ticks>=_resumeBaselineTicks ? ticks-_resumeBaselineTicks : _resumeBaselineTicks-ticks;
        if (_resumeProgressPending && resumeDelta>=readyDelta) {
            NSUInteger ms=(NSUInteger)MAX(0,(now-_resumeRequestedAt)*1000.0);
            JFPlaybackTrace([NSString stringWithFormat:@"RESUME_PROGRESS_READY ms=%lu ticks=%lld",(unsigned long)ms,ticks]);
            _resumeProgressPending=NO;
        }
        long long seekDelta=ticks>=_seekBaselineTicks ? ticks-_seekBaselineTicks : _seekBaselineTicks-ticks;
        if (_seekProgressPending && seekDelta>=readyDelta) {
            NSUInteger ms=(NSUInteger)MAX(0,(now-_seekRequestedAt)*1000.0);
            JFPlaybackTrace([NSString stringWithFormat:@"SEEK_PROGRESS_READY ms=%lu target=%lld ticks=%lld",(unsigned long)ms,_seekBaselineTicks,ticks]);
            _seekProgressPending=NO;
        }
        [self emit:@"progress" ticks:ticks];
    }
    if (_started && !_stopping)
        [self performSelector:@selector(sampleProgress) withObject:nil afterDelay:1.0];
}
- (void)checkNativeRate {
    if (!_started || _stopping || !_player || [NSProcessInfo processInfo].systemUptime<_ignoreNativeRateUntil) return;
    if ([self detectNativePresentationExit]) return;
    @try {
        double rate=((double(*)(id,SEL))objc_msgSend)(_player,NSSelectorFromString(@"rate"));
        long long sampled=[self currentTicks];
        long long ticks=_lastTicks;
        if (!(sampled==0 && _lastTicks>10000000LL)) {
            if (sampled<_lastTicks) JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_POSITION_BACKWARD from=%lld to=%lld",_lastTicks,sampled]);
            _lastTicks=sampled; ticks=sampled;
        } else JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_POSITION_IGNORE sampled=0 retained=%lld",_lastTicks]);
        BOOL paused=fabs(rate)<0.01;
        NSString *transport=rate<-0.01 ? @"rewind" : rate>1.01 ? @"fast-forward" : paused ? @"paused" : @"playing";
        JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_RATE state=%@ ticks=%lld",transport,ticks]);
        if (paused && !_nativePaused) {
            _nativePaused=YES; [self emit:@"paused" ticks:ticks];
        } else if (!paused && _nativePaused) {
            _nativePaused=NO; [self emit:@"resumed" ticks:ticks];
        }
    } @catch (NSException *exception) {
        [self failCurrentAtTicks:_lastTicks];
    }
}
- (void)nativeNotification:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(nativeNotification:) withObject:notification waitUntilDone:NO];
        return;
    }
    if (_stopping || !_player) return;
    NSString *name=notification.name;
    id object=notification.object;
    BOOL ours=!object || object==_player || object==_playerController || object==_asset;
    if (!ours) return;
    if ([name isEqual:@"BRMPStateChanged"]) {
        if (_started) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkNativeRate) object:nil];
            [self performSelector:@selector(checkNativeRate) withObject:nil afterDelay:0.25];
        }
        return;
    }
    if ([name isEqual:@"BRMediaPlayerPlaylistAssetPlayedToEndTime"]) {
        long long sampled=[self currentTicks];
        if (!(sampled==0 && _lastTicks>10000000LL)) _lastTicks=sampled;
        else JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_POSITION_IGNORE sampled=0 retained=%lld",_lastTicks]);
        _started=NO; _nativePaused=NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
        JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_NOTIFICATION natural-end ticks=%lld",_lastTicks]);
        [self emit:@"ended" ticks:_lastTicks];
        return;
    }
    if ([name isEqual:@"BRMediaPlayerControllerWasPopped"]) {
        long long sampled=[self currentTicks];
        if (!(sampled==0 && _lastTicks>10000000LL)) _lastTicks=sampled;
        else JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_POSITION_IGNORE sampled=0 retained=%lld",_lastTicks]);
        _presented=NO; _started=NO; _nativePaused=NO; _nativeExitSuspectSince=0;
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
        JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_NOTIFICATION popped ticks=%lld",_lastTicks]);
        [self emit:@"popped" ticks:_lastTicks];
        return;
    }
    if ([name isEqual:@"BRMediaPlayerPlaybackError"]) {
        NSError *nativeError=JFATV3NotificationError(notification);
        JFPlaybackTrace(nativeError ?
            [NSString stringWithFormat:@"NATIVE_NOTIFICATION playback-error hasError=1 domain=%@ code=%ld",JFATV3SafeErrorDomain(nativeError),(long)nativeError.code] :
            @"NATIVE_NOTIFICATION playback-error hasError=0");
        _started=NO; _nativePaused=NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
        [self emit:@"failure" ticks:_lastTicks];
    }
}
- (void)failAudioCurrentAtTicks:(long long)ticks {
    JFBackendEvent callback=[_event copy];
    [self stop];
    if (callback) callback(@"audio-failure",ticks);
    [callback release];
}
- (void)failCurrentAtTicks:(long long)ticks {
    JFBackendEvent callback=[_event copy];
    [self stop];
    if (callback) callback(@"failure",ticks);
    [callback release];
}

- (void)startRequest:(NSURLRequest *)request positionTicks:(long long)ticks event:(JFBackendEvent)event {
    [self startRequest:request positionTicks:ticks audioPlan:nil event:event];
}
- (void)startRequest:(NSURLRequest *)request positionTicks:(long long)ticks
          audioPlan:(NSDictionary *)audioPlan event:(JFBackendEvent)event {
    if (![NSThread isMainThread] || !event) {
        JFPlaybackTrace(@"BACKEND_START rejected");
        if (event) event(@"failure",ticks);
        return;
    }
    [self stop];
    _startRequestedAt=[NSProcessInfo processInfo].systemUptime;
    _startBaselineTicks=ticks;
    _startProgressPending=YES; _resumeProgressPending=NO; _seekProgressPending=NO;
    JFPlaybackTrace([NSString stringWithFormat:@"PLAY_REQUEST ticks=%lld",ticks]);
    JFMediaGateway *gateway=[[JFMediaGateway alloc] initWithRequest:request];
    NSError *error=nil;
    if (!gateway || ![gateway start:&error]) {
        JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_START ok=0 code=%ld",(long)error.code]);
        [gateway release];
        event(@"failure",ticks);
        return;
    }
    JFPlaybackTrace(@"GATEWAY_START ok=1");
    NSURLRequest *local=gateway.localRequest;
    if (!local || ![self prepareRequest:local positionTicks:ticks error:&error]) {
        JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_PREPARE ok=0 code=%ld",(long)error.code]);
        [gateway stop]; [gateway release];
        event(@"failure",ticks);
        return;
    }
    JFPlaybackTrace(@"NATIVE_PREPARE ok=1");
    _gateway=gateway;
    [_event release]; _event=[event copy];
    _lastTicks=ticks; _nativePaused=NO;
    [self installObservers];
    @try {
        NSTimeInterval cueStarted=[NSProcessInfo processInfo].systemUptime;
        BOOL cued=((BOOL(*)(id,SEL,NSError **))objc_msgSend)(_player,NSSelectorFromString(@"cueMediaWithError:"),&error);
        NSUInteger cueMillis=(NSUInteger)MAX(0,([NSProcessInfo processInfo].systemUptime-cueStarted)*1000.0);
        JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_CUE ok=%d code=%ld",cued,(long)error.code]);
        JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_CUE_TIME ms=%lu",(unsigned long)cueMillis]);
        if (!cued) { [self failCurrentAtTicks:ticks]; return; }
        if (ticks>0) {
            double seconds=(double)ticks/10000000.0;
            ((void(*)(id,SEL,double))objc_msgSend)(_player,NSSelectorFromString(@"setElapsedTime:"),seconds);
        }
        id manager=JFATV3Object(objc_getClass("BRMediaPlayerManager"),@"sharedInstance");
        JFPlaybackTrace(@"NATIVE_PRESENT begin");
        ((void(*)(id,SEL,id,id))objc_msgSend)(manager,NSSelectorFromString(@"presentPlayer:options:"),_player,nil);
        _presented=YES;
        _verifiedNativePresentation=NO; _nativeExitSuspectSince=0;
        // This getter is firmware-verified. Observe the current player before
        // it can be dismissed so exit cleanup doesn't depend on WasPopped.
        [self detectNativePresentationExit];
        JFPlaybackTrace(@"NATIVE_PRESENT ok=1");
        if (audioPlan && [audioPlan[@"audioStreamIndex"] isKindOfClass:[NSNumber class]]) {
            // Explicitly park native playback, even if the presentation layer
            // would otherwise start rendering on this firmware.
            NSError *parkError=nil;
            BOOL parked=((BOOL(*)(id,SEL,int,NSError **))objc_msgSend)(_player,
                NSSelectorFromString(@"setState:error:"),1,&parkError);
            JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_HELD_PARK ok=%d code=%ld",parked,(long)parkError.code]);
            if (!parked) { [self failCurrentAtTicks:ticks];return; }
            // Native player is cued and presented but NOT started. Mac must
            // complete signed start + signed commit before video can move.
            __block JFATV3PlaybackBackend *target=self;
            BOOL bound=[JFAppAudioLink startHeldPlayer:_player plan:audioPlan ticks:ticks ready:^{
                if (!target->_gateway || !target->_player || target->_stopping || target->_started)return;
                JFPlaybackTrace(@"NATIVE_VIDEO_RELEASE_AFTER_MAC_COMMIT");
                [target finishHeldNativeStartAtTicks:ticks];
            } failure:^{
                if (!target->_gateway || target->_stopping || target->_started)return;
                JFPlaybackTrace(@"NATIVE_HELD_AUDIO_SETUP_FAILED");
                [target failAudioCurrentAtTicks:ticks];
            }];
            if (!bound) {JFPlaybackTrace(@"NATIVE_HELD_AUDIO_BIND_FAILED");[self failAudioCurrentAtTicks:ticks];}
            return;
        }
        [self finishHeldNativeStartAtTicks:ticks];
    } @catch (NSException *exception) {
        JFPlaybackTrace(@"BACKEND_EXCEPTION stage=start");
        [self failCurrentAtTicks:ticks];
    }
}
- (void)finishHeldNativeStartAtTicks:(long long)ticks {
    if (![NSThread isMainThread] || !_player || !_gateway || _stopping || _started)return;
    @try {
        _ignoreNativeRateUntil=[NSProcessInfo processInfo].systemUptime+1.0;
        NSError *error=nil;
        BOOL playing=((BOOL(*)(id,SEL,int,NSError **))objc_msgSend)(_player,NSSelectorFromString(@"setState:error:"),3,&error);
        JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_PLAY ok=%d code=%ld",playing,(long)error.code]);
        if (!playing) { [self failCurrentAtTicks:ticks]; return; }
        _started=YES;
        JFPlaybackTrace(@"BACKEND_STARTED");
        [self emit:@"started" ticks:ticks];
        if (_started && !_stopping)
            [self performSelector:@selector(sampleProgress) withObject:nil afterDelay:1.0];
    } @catch (NSException *exception) {
        JFPlaybackTrace(@"BACKEND_EXCEPTION stage=start");
        [self failCurrentAtTicks:ticks];
    }
}
- (void)pause {
    if (![NSThread isMainThread] || !_started || _stopping || !_player) return;
    @try {
        _ignoreNativeRateUntil=[NSProcessInfo processInfo].systemUptime+1.0;
        NSError *error=nil;
        BOOL ok=((BOOL(*)(id,SEL,int,NSError **))objc_msgSend)(_player,NSSelectorFromString(@"setState:error:"),1,&error);
        if (!ok) { [self failCurrentAtTicks:_lastTicks]; return; }
        _nativePaused=YES;
        long long ticks=[self currentTicks];
        if (!(ticks==0 && _lastTicks>10000000LL)) {
            if (ticks<_lastTicks) JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_POSITION_BACKWARD from=%lld to=%lld",_lastTicks,ticks]);
            _lastTicks=ticks;
        } else JFPlaybackTrace([NSString stringWithFormat:@"NATIVE_POSITION_IGNORE sampled=0 retained=%lld",_lastTicks]);
    } @catch (NSException *exception) { [self failCurrentAtTicks:_lastTicks]; }
}
- (void)resume {
    if (![NSThread isMainThread] || !_started || _stopping || !_player) return;
    @try {
        _ignoreNativeRateUntil=[NSProcessInfo processInfo].systemUptime+1.0;
        NSError *error=nil;
        long long baseline=[self currentTicks];
        _resumeRequestedAt=[NSProcessInfo processInfo].systemUptime;
        _resumeBaselineTicks=baseline;
        _resumeProgressPending=YES;
        JFPlaybackTrace([NSString stringWithFormat:@"RESUME_REQUEST ticks=%lld",baseline]);
        BOOL ok=((BOOL(*)(id,SEL,int,NSError **))objc_msgSend)(_player,NSSelectorFromString(@"setState:error:"),3,&error);
        if (!ok) { _resumeProgressPending=NO; [self failCurrentAtTicks:_lastTicks]; return; }
        _nativePaused=NO;
    } @catch (NSException *exception) { [self failCurrentAtTicks:_lastTicks]; }
}
- (void)seek:(long long)ticks event:(JFBackendEvent)event {
    if (![NSThread isMainThread] || !_started || _stopping || !_player || ticks<0) {
        if (event) event(@"failure",ticks);
        return;
    }
    [_event release]; _event=[event copy];
    @try {
        double seconds=(double)ticks/10000000.0;
        _seekRequestedAt=[NSProcessInfo processInfo].systemUptime;
        _seekBaselineTicks=ticks;
        _seekProgressPending=!_nativePaused;
        JFPlaybackTrace([NSString stringWithFormat:@"SEEK_REQUEST target=%lld paused=%d",ticks,_nativePaused]);
        ((void(*)(id,SEL,double))objc_msgSend)(_player,NSSelectorFromString(@"setElapsedTime:"),seconds);
        _lastTicks=ticks; _positionTicks=ticks;
    } @catch (NSException *exception) {
        [self failCurrentAtTicks:ticks];
    }
}
- (void)stop {
    if (_stopping) return;
    _stopping=YES;
    _started=NO; _nativePaused=NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self removeObservers];
    @try {
        if (_player)
            ((BOOL(*)(id,SEL,int,NSError **))objc_msgSend)(_player,NSSelectorFromString(@"setState:error:"),0,NULL);
        if (_presented) {
            id manager=JFATV3Object(objc_getClass("BRMediaPlayerManager"),@"sharedInstance");
            if (manager) ((void(*)(id,SEL))objc_msgSend)(manager,NSSelectorFromString(@"endPresentation"));
        }
    } @catch (NSException *exception) {}
    _presented=NO; _verifiedNativePresentation=NO; _nativeExitSuspectSince=0;
    _startProgressPending=_resumeProgressPending=_seekProgressPending=NO;
    _zeroPositionActive=NO; _zeroPositionSince=0;
    [self discardPreparedPlayback];
    _stopping=NO;
}
- (void)discardPreparedPlayback {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self removeObservers];
    [_gateway stop]; [_gateway release]; _gateway=nil;
    [_preparedRequest release]; _preparedRequest=nil;
    [_asset release]; _asset=nil;
    [_player release]; _player=nil;
    [_playerController release]; _playerController=nil;
    [_event release]; _event=nil;
    _positionTicks=0; _lastTicks=0; _presented=NO; _started=NO; _nativePaused=NO; _verifiedNativePresentation=NO; _nativeExitSuspectSince=0;
    _ignoreNativeRateUntil=0;
}
- (void)dealloc {
    [self stop];
    [_hostController release];
    [super dealloc];
}
@end
