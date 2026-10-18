#import "JFATV3PlaybackProbe.h"
#import "JFATV3PlaybackBackend.h"
#import "JFMediaGateway.h"
#import "JFPlaybackController.h"
#import "API/JFClient.h"
#import "API/JFWorker.h"
#import "API/JFServerURL.h"
#import <objc/message.h>
static void JFATV3ScheduleNetworkProbeIfEnabled(void);
static void JFATV3SchedulePresentationProbeIfEnabled(void);
static void JFATV3ScheduleRealPlaybackProbeIfEnabled(void);
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
static NSString * const JFProbeEnable=@"/tmp/Jellyfin-ATV3.playbackprobe-enable";
static NSString * const JFProbeLog=@"/tmp/Jellyfin-ATV3.playbackprobe";
static void JFProbeWrite(NSString *line) {
    NSData *data=[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    int fd=open([JFProbeLog fileSystemRepresentation],O_WRONLY|O_CREAT|O_APPEND,0600);
    if (fd>=0) { write(fd,data.bytes,data.length); close(fd); }
}
@interface JFATV3PlaybackProbeRunner : NSObject
+ (void)run;
@end
@implementation JFATV3PlaybackProbeRunner
+ (void)run {
    if (![[NSFileManager defaultManager] fileExistsAtPath:JFProbeEnable]) return;
    [[NSFileManager defaultManager] removeItemAtPath:JFProbeEnable error:NULL];
    unlink([JFProbeLog fileSystemRepresentation]);
    @autoreleasepool {
        BOOL main=[NSThread isMainThread];
        BOOL compatible=[JFATV3PlaybackBackend runtimeCompatible];
        Class ltav=NSClassFromString(@"LTAVPlayer"), mediaTypeClass=NSClassFromString(@"BRMediaType");
        id contentTypes=nil, streamingType=nil; BOOL handlesStreaming=NO, listed=NO;
        SEL typesSelector=NSSelectorFromString(@"contentTypes");
        NSMethodSignature *typesSignature=[ltav methodSignatureForSelector:typesSelector];
        if (typesSignature && !strcmp(typesSignature.methodReturnType,@encode(id)) && typesSignature.numberOfArguments==2)
            contentTypes=((id(*)(id,SEL))objc_msgSend)(ltav,typesSelector);
        SEL streamingSelector=NSSelectorFromString(@"streamingVideo");
        NSMethodSignature *streamingSignature=[mediaTypeClass methodSignatureForSelector:streamingSelector];
        if (streamingSignature && !strcmp(streamingSignature.methodReturnType,@encode(id)) && streamingSignature.numberOfArguments==2)
            streamingType=((id(*)(id,SEL))objc_msgSend)(mediaTypeClass,streamingSelector);
        listed=[contentTypes respondsToSelector:@selector(containsObject:)] && streamingType && [contentTypes containsObject:streamingType];
        SEL handlesSelector=NSSelectorFromString(@"handlesVideoForType:");
        NSMethodSignature *handlesSignature=[ltav methodSignatureForSelector:handlesSelector];
        if (handlesSignature && !strcmp(handlesSignature.methodReturnType,@encode(BOOL)) && handlesSignature.numberOfArguments==3 && !strcmp([handlesSignature getArgumentTypeAtIndex:2],@encode(id)) && streamingType)
            handlesStreaming=((BOOL(*)(id,SEL,id))objc_msgSend)(ltav,handlesSelector,streamingType);
        JFProbeWrite([NSString stringWithFormat:@"PROBE_BEGIN main=%d compatible=%d",main,compatible]);
        JFProbeWrite([NSString stringWithFormat:@"PROBE_LTAV streamingType=%@ listed=%d handlesStreaming=%d",streamingType ?: @"",listed,handlesStreaming]);
        if (!main || !compatible) { JFProbeWrite(@"PROBE_END prepared=0"); return; }
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1/jellyfin-probe.mp4"]];
        [request setValue:@"MediaBrowser Client=\"Jellyfin ATV3 Probe\"" forHTTPHeaderField:@"Authorization"];
        JFATV3PlaybackBackend *backend=[[[JFATV3PlaybackBackend alloc] initWithHostController:nil] autorelease];
        NSError *error=nil; BOOL prepared=[backend prepareRequest:request positionTicks:0 error:&error];
        id asset=backend.preparedAsset, player=backend.preparedPlayer, controller=backend.preparedPlayerController;
        JFProbeWrite([NSString stringWithFormat:@"PROBE_PREPARE prepared=%d asset=%d player=%d controller=%d errorDomain=%@ errorCode=%ld exceptionName=%@ exceptionReason=%@",prepared,asset!=nil,player!=nil,controller!=nil,error.domain ?: @"",(long)error.code,error.userInfo[@"JFExceptionName"] ?: @"",error.userInfo[@"JFExceptionReason"] ?: @""]);
        NSString *url=nil;
        if (asset && [asset respondsToSelector:NSSelectorFromString(@"mediaURL")]) {
            id raw=[asset performSelector:NSSelectorFromString(@"mediaURL")];
            if ([raw isKindOfClass:[NSString class]]) url=raw;
            else if ([raw isKindOfClass:[NSURL class]]) url=[raw absoluteString];
        }
        JFProbeWrite([NSString stringWithFormat:@"PROBE_ASSET loopback=%d tokenInURL=%d stringURL=%d",[url hasPrefix:@"http://127.0.0.1/"],[url.lowercaseString containsString:@"token"],[url isKindOfClass:[NSString class]]]);
        [backend discardPreparedPlayback];
        JFProbeWrite([NSString stringWithFormat:@"PROBE_END preparedAfterDiscard=%d",backend.prepared]);
    }
}
@end
void JFATV3SchedulePlaybackProbeIfEnabled(void) {
    JFATV3ScheduleRealPlaybackProbeIfEnabled();
    JFATV3SchedulePresentationProbeIfEnabled();
    JFATV3ScheduleNetworkProbeIfEnabled();
    if (![[NSFileManager defaultManager] fileExistsAtPath:JFProbeEnable]) return;
    [JFATV3PlaybackProbeRunner performSelector:@selector(run) withObject:nil afterDelay:1.0];
}

// Separate, one-shot presentation experiment; only synthetic fixture credentials.
@interface JFATV3PresentationProbe : NSObject {
    JFATV3PlaybackBackend *_backend;
    JFMediaGateway *_gateway;
    NSUInteger _samples;
}
- (void)begin;
- (void)sample;
- (void)finish;
@end
static void JFPresentationWrite(NSString *line) {
    NSData *data=[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    int fd=open("/tmp/Jellyfin-ATV3.presentationprobe",O_WRONLY|O_CREAT|O_APPEND,0600);
    if (fd>=0) { write(fd,data.bytes,data.length); close(fd); }
}
@implementation JFATV3PresentationProbe
- (void)notification:(NSNotification *)note {
    if (note.object!=_backend.preparedPlayer && note.object!=_backend.preparedPlayerController && note.object!=_backend.preparedAsset) return;
    // Names are from our fixed observer allowlist; never serialize userInfo.
    JFPresentationWrite([@"PRESENT_EVENT " stringByAppendingString:note.name]);
}
- (void)begin {
    @try {
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:18780/plain/master.m3u8"]];
        [request setValue:@"Bearer JF-PROBE-ONLY-12H1006" forHTTPHeaderField:@"Authorization"];
        _gateway=[[JFMediaGateway alloc] initWithRequest:request];
        _backend=[[JFATV3PlaybackBackend alloc] initWithHostController:nil];
        if (![_gateway start:NULL] || ![_backend prepareRequest:_gateway.localRequest positionTicks:0 error:NULL]) { [self finish]; return; }
        for (NSString *name in @[@"BRMPStateChanged",@"BRMediaPlayerPlaybackError",@"BRMediaPlayerPlaylistAssetPlayedToEndTime",@"BRMediaPlayerControllerWasPopped",@"BRMediaAssetStalledDuringPlaybackNotification"])
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notification:) name:name object:nil];
        id manager=[NSClassFromString(@"BRMediaPlayerManager") performSelector:NSSelectorFromString(@"sharedInstance")];
        BOOL cued=((BOOL(*)(id,SEL,NSError **))objc_msgSend)(_backend.preparedPlayer,NSSelectorFromString(@"cueMediaWithError:"),NULL);
        JFPresentationWrite([NSString stringWithFormat:@"PRESENT_CUE ok=%d",cued]);
        if (!cued) { [self finish]; return; }
        ((void(*)(id,SEL,id,id))objc_msgSend)(manager,NSSelectorFromString(@"presentPlayer:options:"),_backend.preparedPlayer,nil);
        BOOL playing=((BOOL(*)(id,SEL,int,NSError **))objc_msgSend)(_backend.preparedPlayer,NSSelectorFromString(@"setState:error:"),3,NULL);
        JFPresentationWrite([NSString stringWithFormat:@"PRESENT_PLAY ok=%d",playing]);
        [self performSelector:@selector(sample) withObject:nil afterDelay:1];
    } @catch (NSException *exception) { JFPresentationWrite(@"PRESENT_EXCEPTION"); [self finish]; }
}
- (void)sample {
    @try {
        double elapsed=((double(*)(id,SEL))objc_msgSend)(_backend.preparedPlayer,NSSelectorFromString(@"elapsedTime"));
        JFPresentationWrite([NSString stringWithFormat:@"PRESENT_SAMPLE n=%lu elapsed=%.3f",(unsigned long)++_samples,elapsed]);
    } @catch (NSException *exception) { JFPresentationWrite(@"PRESENT_SAMPLE_EXCEPTION"); [self finish]; return; }
    if (_samples>=25) [self finish];
    else [self performSelector:@selector(sample) withObject:nil afterDelay:1];
}
- (void)finish {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    @try {
        id manager=[NSClassFromString(@"BRMediaPlayerManager") performSelector:NSSelectorFromString(@"sharedInstance")];
        if (_backend.preparedPlayer) ((BOOL(*)(id,SEL,int,NSError **))objc_msgSend)(_backend.preparedPlayer,NSSelectorFromString(@"setState:error:"),0,NULL);
        if ([manager respondsToSelector:NSSelectorFromString(@"endPresentation")]) [manager performSelector:NSSelectorFromString(@"endPresentation")];
    } @catch (NSException *exception) { JFPresentationWrite(@"PRESENT_STOP_EXCEPTION"); }
    [_backend discardPreparedPlayback]; [_backend release]; _backend=nil;
    [_gateway stop]; [_gateway release]; _gateway=nil;
    JFPresentationWrite(@"PRESENT_END"); [self release];
}
@end
static void JFATV3SchedulePresentationProbeIfEnabled(void) {
    NSString *marker=@"/tmp/Jellyfin-ATV3.presentationprobe-enable";
    if (![[NSFileManager defaultManager] fileExistsAtPath:marker]) return;
    if (![[NSFileManager defaultManager] removeItemAtPath:marker error:NULL] || ![JFATV3PlaybackBackend runtimeCompatible]) return;
    JFPresentationWrite(@"PRESENT_BEGIN probe=10 synthetic=1");
    JFATV3PresentationProbe *runner=[[JFATV3PresentationProbe alloc] init];
    [runner performSelector:@selector(begin) withObject:nil afterDelay:8];
}

// Diagnostic-only network probe. Fixed synthetic credential and controlled LAN origin.
// No session credentials, user media or presentation are reachable from this runner.
@interface JFATV3NetworkProbeRunner : NSObject {
    JFATV3PlaybackBackend *_backend;
    JFMediaGateway *_gateway;
    NSUInteger _caseIndex;
}
- (void)nextCase;
- (void)finishCase;
@end
static void JFNetworkWrite(NSString *line) {
    NSData *data=[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    int fd=open("/tmp/Jellyfin-ATV3.networkprobe",O_WRONLY|O_CREAT|O_APPEND,0600);
    if (fd>=0) { write(fd,data.bytes,data.length); close(fd); }
}
@implementation JFATV3NetworkProbeRunner
- (void)nextCase {
    NSArray *paths=@[@"/plain/clip.mp4",@"/plain/master.m3u8",@"/encrypted/master.m3u8",@"/same/master.m3u8",@"/cross/master.m3u8",@"/child/master.m3u8",@"/segment-redirect/master.m3u8"];
    if (_caseIndex>=paths.count) { JFNetworkWrite(@"NETWORK_END"); [self release]; return; }
    NSString *path=paths[_caseIndex];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"http://127.0.0.1:18780" stringByAppendingString:path]]];
    [request setValue:@"Bearer JF-PROBE-ONLY-12H1006" forHTTPHeaderField:@"Authorization"];
    _backend=[[JFATV3PlaybackBackend alloc] initWithHostController:nil];
    @try {
        NSError *error=nil;
        _gateway=[[JFMediaGateway alloc] initWithRequest:request];
        BOOL gatewayReady=[_gateway start:&error];
        BOOL prepared=gatewayReady && [_backend prepareRequest:_gateway.localRequest positionTicks:0 error:&error];
        JFNetworkWrite([NSString stringWithFormat:@"NETWORK_PREPARE case=%lu path=%@ prepared=%d code=%ld",(unsigned long)_caseIndex,path,prepared,(long)error.code]);
        if (prepared) {
            BOOL cued=((BOOL(*)(id,SEL,NSError **))objc_msgSend)(_backend.preparedPlayer,NSSelectorFromString(@"cueMediaWithError:"),&error);
            JFNetworkWrite([NSString stringWithFormat:@"NETWORK_CUE case=%lu cued=%d code=%ld",(unsigned long)_caseIndex,cued,(long)error.code]);
        }
    } @catch (NSException *exception) { JFNetworkWrite(@"NETWORK_EXCEPTION stage=prepare-or-cue"); }
    [self performSelector:@selector(finishCase) withObject:nil afterDelay:12.0];
}
- (void)finishCase {
    @try {
        id player=_backend.preparedPlayer;
        if (player) {
            NSError *error=nil;
            // 12H1006 LTAVPlayer jump-table entry 0: Stop and reset event.
            BOOL stopped=((BOOL(*)(id,SEL,int,NSError **))objc_msgSend)(player,NSSelectorFromString(@"setState:error:"),0,&error);
            JFNetworkWrite([NSString stringWithFormat:@"NETWORK_STOP case=%lu stopped=%d code=%ld",(unsigned long)_caseIndex,stopped,(long)error.code]);
        }
        [_backend discardPreparedPlayback];
    } @catch (NSException *exception) { JFNetworkWrite(@"NETWORK_EXCEPTION stage=stop"); }
    [_backend release]; _backend=nil; _caseIndex++;
    [_gateway stop]; [_gateway release]; _gateway=nil;
    [self performSelector:@selector(nextCase) withObject:nil afterDelay:2.0];
}
@end
static void JFATV3ScheduleNetworkProbeIfEnabled(void) {
    NSString *marker=@"/tmp/Jellyfin-ATV3.networkprobe-enable";
    if (![[NSFileManager defaultManager] fileExistsAtPath:marker]) return;
    // Fail closed if consumption fails: a root-owned marker must not loop on reload.
    if (![[NSFileManager defaultManager] removeItemAtPath:marker error:NULL]) return;
    if (![JFATV3PlaybackBackend runtimeCompatible]) return;
    JFNetworkWrite(@"NETWORK_BEGIN probe=9 synthetic=1 fullscreen=0 gateway=1");
    JFATV3NetworkProbeRunner *runner=[[JFATV3NetworkProbeRunner alloc] init];
    [runner performSelector:@selector(nextCase) withObject:nil afterDelay:2.0];
}


// One-shot real-server acceptance probe. It consumes the already persisted
// credential in-process and never serializes credentials, URLs, media IDs or names.
@interface JFATV3RealPlaybackProbe : NSObject {
    JFClient *_client;
    JFWorker *_worker;
    JFATV3PlaybackBackend *_backend;
    JFPlaybackController *_playback;
    NSString *_itemID;
    BOOL _sequenceStarted, _finished;
}
- (void)begin;
- (void)playbackChanged:(NSNotification *)note;
- (void)pauseStep;
- (void)resumeStep;
- (void)seekStep;
- (void)stopStep;
- (void)cleanup;
@end
static void JFRealWrite(NSString *line) {
    NSData *data=[[line stringByAppendingString:@"\\n"] dataUsingEncoding:NSUTF8StringEncoding];
    int fd=open("/tmp/Jellyfin-ATV3.realplayprobe",O_WRONLY|O_CREAT|O_APPEND,0600);
    if (fd>=0) { write(fd,data.bytes,data.length); close(fd); }
}
@implementation JFATV3RealPlaybackProbe
- (void)begin {
    NSUserDefaults *defaults=[[[NSUserDefaults alloc] initWithSuiteName:@"org.jellyfin.atv3"] autorelease];
    id configurationRaw=[defaults objectForKey:@"ServerConfiguration"];
    id credentialRaw=[defaults objectForKey:@"SessionCredential"];
    NSDictionary *configuration=[configurationRaw isKindOfClass:[NSDictionary class]] ? configurationRaw : nil;
    NSDictionary *credential=[credentialRaw isKindOfClass:[NSDictionary class]] ? credentialRaw : nil;
    NSString *server=JFNormalizeServerAddress(credential[@"server"],NULL);
    NSString *configured=JFNormalizeServerAddress(configuration[@"server"],NULL);
    NSString *device=[credential[@"deviceID"] isKindOfClass:[NSString class]] ? credential[@"deviceID"] : nil;
    NSString *token=[credential[@"token"] isKindOfClass:[NSString class]] ? credential[@"token"] : nil;
    BOOL valid=server.length && configured.length && [server isEqual:configured] && device.length && token.length &&
        [token rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location==NSNotFound;
    JFRealWrite([NSString stringWithFormat:@"REAL_BEGIN credential=%d runtime=%d",valid,[JFATV3PlaybackBackend runtimeCompatible]]);
    if (!valid || ![JFATV3PlaybackBackend runtimeCompatible]) { [self cleanup]; return; }

    _client=[[JFClient alloc] initWithURL:[NSURL URLWithString:server] deviceID:device];
    _worker=[JFWorker new];
    if (!_client || !_worker) { JFRealWrite(@"REAL_SETUP ok=0 stage=client"); [self cleanup]; return; }

    JFClient *client=_client;
    NSString *credentialToken=[[token copy] autorelease];
    __block JFATV3RealPlaybackProbe *runner=self;
    [_worker perform:^id(NSError **error) {
        if (![client authenticateToken:credentialToken error:error]) return nil;
        NSArray *libraries=[client libraries:error];
        if (!libraries || JFWorkCancelled()) return nil;
        NSDictionary *movies=nil;
        for (NSDictionary *library in libraries) {
            if (![library isKindOfClass:[NSDictionary class]]) continue;
            NSString *collection=[library[@"CollectionType"] isKindOfClass:[NSString class]] ? [library[@"CollectionType"] lowercaseString] : @"";
            if ([collection isEqual:@"movies"]) { movies=library; break; }
        }
        NSString *parent=[movies[@"Id"] isKindOfClass:[NSString class]] ? movies[@"Id"] : nil;
        if (!parent.length) return nil;
        NSArray *items=[client itemsInLibrary:parent type:@"Movie" start:0 limit:1 error:error];
        NSDictionary *item=[items.firstObject isKindOfClass:[NSDictionary class]] ? items.firstObject : nil;
        NSString *identifier=[item[@"Id"] isKindOfClass:[NSString class]] ? item[@"Id"] : nil;
        return identifier.length ? identifier : nil;
    } completion:^(id result, NSError *error) {
        if (runner->_finished) return;
        if (![result isKindOfClass:[NSString class]] || ![result length]) {
            JFRealWrite([NSString stringWithFormat:@"REAL_SETUP ok=0 stage=library code=%ld",(long)error.code]);
            [runner cleanup]; return;
        }
        runner->_itemID=[result copy];
        runner->_backend=[[JFATV3PlaybackBackend alloc] initWithHostController:nil];
        runner->_playback=[[JFPlaybackController alloc] initWithClient:runner->_client worker:runner->_worker backend:runner->_backend];
        if (!runner->_backend || !runner->_playback) { JFRealWrite(@"REAL_SETUP ok=0 stage=playback"); [runner cleanup]; return; }
        [[NSNotificationCenter defaultCenter] addObserver:runner selector:@selector(playbackChanged:) name:JFPlaybackChanged object:runner->_playback];
        __block JFATV3RealPlaybackProbe *callbackRunner=runner;
        runner->_playback.progressCallback=^(long long ticks) {
            JFRealWrite([NSString stringWithFormat:@"REAL_PROGRESS ticks=%lld",ticks]);
        };
        runner->_playback.failureCallback=^(NSString *kind) {
            JFRealWrite([NSString stringWithFormat:@"REAL_FAILURE kind=%@",kind ?: @"unknown"]);
            [callbackRunner performSelector:@selector(cleanup) withObject:nil afterDelay:2.0];
        };
        BOOL started=[runner->_playback playItem:runner->_itemID startTicks:0];
        JFRealWrite([NSString stringWithFormat:@"REAL_SETUP ok=%d playRequest=%d",started,started]);
        if (!started) [runner cleanup];
    }];
}
- (void)playbackChanged:(NSNotification *)note {
    if (_finished || note.object!=_playback) return;
    NSString *state=_playback.currentState ?: @"unknown";
    JFRealWrite([NSString stringWithFormat:@"REAL_STATE %@",state]);
    if ([state isEqual:@"playing"] && !_sequenceStarted) {
        _sequenceStarted=YES;
        [self performSelector:@selector(pauseStep) withObject:nil afterDelay:5.0];
    } else if ([state isEqual:@"stopped"]) {
        [self performSelector:@selector(cleanup) withObject:nil afterDelay:4.0];
    } else if ([state isEqual:@"failed"]) {
        [self performSelector:@selector(cleanup) withObject:nil afterDelay:2.0];
    }
}
- (void)pauseStep {
    if (_finished) return;
    BOOL ok=[_playback pause];
    JFRealWrite([NSString stringWithFormat:@"REAL_PAUSE ok=%d ticks=%lld",ok,_playback.positionTicks]);
    [self performSelector:@selector(resumeStep) withObject:nil afterDelay:2.0];
}
- (void)resumeStep {
    if (_finished) return;
    BOOL ok=[_playback resume];
    JFRealWrite([NSString stringWithFormat:@"REAL_RESUME ok=%d ticks=%lld",ok,_playback.positionTicks]);
    [self performSelector:@selector(seekStep) withObject:nil afterDelay:2.0];
}
- (void)seekStep {
    if (_finished) return;
    long long target=_playback.positionTicks+50000000LL;
    BOOL ok=[_playback seek:target];
    JFRealWrite([NSString stringWithFormat:@"REAL_SEEK ok=%d targetTicks=%lld",ok,target]);
    [self performSelector:@selector(stopStep) withObject:nil afterDelay:5.0];
}
- (void)stopStep {
    if (_finished) return;
    BOOL ok=[_playback stop];
    JFRealWrite([NSString stringWithFormat:@"REAL_STOP ok=%d ticks=%lld",ok,_playback.positionTicks]);
    [self performSelector:@selector(cleanup) withObject:nil afterDelay:5.0];
}
- (void)cleanup {
    if (_finished) return;
    _finished=YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_playback) {
        _playback.progressCallback=nil; _playback.failureCallback=nil;
        [_playback close]; [_playback release]; _playback=nil;
    }
    [_backend release]; _backend=nil;
    [_worker cancelAll]; [_worker release]; _worker=nil;
    [_client release]; _client=nil;
    [_itemID release]; _itemID=nil;
    JFRealWrite(@"REAL_END");
    [self release];
}
@end
static void JFATV3ScheduleRealPlaybackProbeIfEnabled(void) {
    NSString *marker=@"/tmp/Jellyfin-ATV3.realplayprobe-enable";
    if (![[NSFileManager defaultManager] fileExistsAtPath:marker]) return;
    if (![[NSFileManager defaultManager] removeItemAtPath:marker error:NULL]) return;
    unlink("/tmp/Jellyfin-ATV3.realplayprobe");
    JFATV3RealPlaybackProbe *runner=[[JFATV3RealPlaybackProbe alloc] init];
    [runner performSelector:@selector(begin) withObject:nil afterDelay:8.0];
}
