#import <Foundation/Foundation.h>
#import "Playback/JFPlaybackModel.h"
#import "Playback/JFSubtitle.h"
#import "Playback/JFAudio.h"
#import "Playback/JFPlaybackController.h"
#import "Playback/JFAppAudioLink.h"
#import "Playback/JFATV3PlaybackBackend.h"
#import "Playback/JFMediaGateway.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>
#include <unistd.h>
#import "API/JFClient.h"
#import "API/JFWorker.h"
#import "JFPlaybackFixture.h"
#import "Navigation/JFSession.h"
@interface JFSession (TestClient)
- (id)initWithOwnedClient:(JFClient *)client;
@end
static id atvManagerSingleton, atvLastAsset, atvLastPlayer, atvLastController, atvStreamingType, atvVisiblePlayer;
static NSUInteger atvCueCalls, atvStateCalls, atvPresentCalls, atvEndPresentationCalls;
static BOOL atvThrowPlayer;
static double atvElapsed, atvRate;
static id ATVNilObject(id self, SEL cmd) { return nil; }
static BOOL ATVTrue(id self, SEL cmd) { return YES; }
static long ATVZeroLong(id self, SEL cmd) { return 0; }
static double ATVElapsed(id self, SEL cmd) { return atvElapsed; }
static double ATVRate(id self, SEL cmd) { return atvRate; }
static void ATVSetElapsed(id self, SEL cmd, double value) { atvElapsed=value; }
static BOOL ATVBoolError(id self, SEL cmd, NSError **error) { atvCueCalls++; return YES; }
static BOOL ATVBoolIntError(id self, SEL cmd, int state, NSError **error) {
    atvStateCalls++;
    if (state==3) atvRate=1.0;
    else if (state==0 || state==1) atvRate=0.0;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BRMPStateChanged" object:self];
    return YES;
}
static id ATVShared(id self, SEL cmd) { return atvManagerSingleton; }
static id ATVStreamingVideo(id self, SEL cmd) { return atvStreamingType; }
static id ATVPlayerForAsset(id self, SEL cmd, id asset, NSError **error) {
    if (atvThrowPlayer) [NSException raise:@"ATVMockException" format:@"mock asset rejection"];
    [atvLastAsset release]; atvLastAsset=[asset retain];
    Class playerClass=objc_getClass("BRMediaPlayer");
    id player=[[[playerClass alloc] init] autorelease];
    [atvLastPlayer release]; atvLastPlayer=[player retain]; return player;
}
static void ATVPresent(id self, SEL cmd, id player, id options) { atvPresentCalls++; atvVisiblePlayer=player; }
static void ATVEndPresentation(id self, SEL cmd) { atvEndPresentationCalls++; atvVisiblePlayer=nil; }
static id ATVPresentedPlayer(id self, SEL cmd) { return atvVisiblePlayer; }
static id ATVControllerForPlayer(id self, SEL cmd, id player) {
    Class controllerClass=objc_getClass("BRMediaPlayerController");
    id controller=[[[controllerClass alloc] init] autorelease];
    [atvLastController release]; atvLastController=[controller retain]; return controller;
}
static id ATVInitWithPlayer(id self, SEL cmd, id player) { return self; }
static void AddMethod(Class cls, const char *name, IMP imp, const char *types) {
    if (!class_addMethod(cls,sel_registerName(name),imp,types)) { fprintf(stderr,"mock add failed %s\n",name); exit(1); }
}
static void SetupATV3PlaybackRuntime(void) {
    if (objc_getClass("BRBaseMediaAsset")) return;
    Protocol *protocol=objc_allocateProtocol("BRMediaAsset"); objc_registerProtocol(protocol);
    Class mediaType=objc_allocateClassPair([NSObject class],"BRMediaType",0);
    AddMethod(object_getClass(mediaType),"streamingVideo",(IMP)ATVStreamingVideo,"@8@0:4"); objc_registerClassPair(mediaType);
    atvStreamingType=[[mediaType alloc] init];
    Class base=objc_allocateClassPair([NSObject class],"BRBaseMediaAsset",0);
    AddMethod(base,"mediaURL",(IMP)ATVNilObject,"@8@0:4"); AddMethod(base,"assetID",(IMP)ATVNilObject,"@8@0:4");
    AddMethod(base,"title",(IMP)ATVNilObject,"@8@0:4"); AddMethod(base,"mediaType",(IMP)ATVNilObject,"@8@0:4");
    AddMethod(base,"playbackMetadata",(IMP)ATVNilObject,"@8@0:4");
    AddMethod(base,"isValid",(IMP)ATVTrue,"c8@0:4"); AddMethod(base,"playable",(IMP)ATVTrue,"c8@0:4");
    AddMethod(base,"hasVideoContent",(IMP)ATVTrue,"c8@0:4"); AddMethod(base,"isScrubbable",(IMP)ATVTrue,"c8@0:4");
    AddMethod(base,"duration",(IMP)ATVZeroLong,"l8@0:4"); class_addProtocol(base,protocol); objc_registerClassPair(base);
    Class player=objc_allocateClassPair([NSObject class],"BRMediaPlayer",0);
    AddMethod(player,"cueMediaWithError:",(IMP)ATVBoolError,"c12@0:4^@8");
    AddMethod(player,"setState:error:",(IMP)ATVBoolIntError,"c16@0:4i8^@12");
    AddMethod(player,"elapsedTime",(IMP)ATVElapsed,"d8@0:4"); AddMethod(player,"rate",(IMP)ATVRate,"d8@0:4");
    AddMethod(player,"setElapsedTime:",(IMP)ATVSetElapsed,"v16@0:4d8"); objc_registerClassPair(player);
    Class manager=objc_allocateClassPair([NSObject class],"BRMediaPlayerManager",0);
    AddMethod(object_getClass(manager),"sharedInstance",(IMP)ATVShared,"@8@0:4");
    AddMethod(manager,"playerForMediaAsset:error:",(IMP)ATVPlayerForAsset,"@16@0:4@8^@12");
    AddMethod(manager,"presentPlayer:options:",(IMP)ATVPresent,"v16@0:4@8@12");
    AddMethod(manager,"endPresentation",(IMP)ATVEndPresentation,"v8@0:4");
    AddMethod(manager,"_presentedPlayer",(IMP)ATVPresentedPlayer,"@8@0:4"); objc_registerClassPair(manager);
    atvManagerSingleton=[[manager alloc] init];
    Class controller=objc_allocateClassPair([NSObject class],"BRMediaPlayerController",0);
    AddMethod(object_getClass(controller),"controllerForPlayer:",(IMP)ATVControllerForPlayer,"@12@0:4@8");
    AddMethod(controller,"initWithPlayer:",(IMP)ATVInitWithPlayer,"@12@0:4@8"); objc_registerClassPair(controller);
}
static unsigned checks=0;
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#__VA_ARGS__); exit(1); } } while(0)
static BOOL Wait(BOOL (^condition)(void)) {
    NSTimeInterval end=[NSProcessInfo processInfo].systemUptime+3;
    while (!condition() && [NSProcessInfo processInfo].systemUptime<end) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}
static NSMutableDictionary *Info(void) { return [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"Tests/playback.json"] options:NSJSONReadingMutableContainers error:NULL]; }
static JFClient *Client(void) { JFClient *c=[[[JFClient alloc] initWithURL:[NSURL URLWithString:@"http://playback.invalid/jellyfin"] deviceID:@"test-device"] autorelease]; CHECK([c login:@"test" password:@"test" error:NULL]); return c; }
int main(void) { @autoreleasepool {
    [NSURLProtocol registerClass:[JFPlaybackFixture class]]; [JFPlaybackFixture setMode:@"normal"];
    NSDictionary *profile=JFProvisionalDeviceProfile();
    CHECK([profile[@"Name"] containsString:@"SERVER-FIRST"]);
    NSString *profileJSON=[[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:profile options:0 error:NULL] encoding:NSUTF8StringEncoding] autorelease];
    for (NSString *unsupported in @[@"ac3",@"hevc",@"av1",@"dolby",@"hdr"]) CHECK(![profileJSON.lowercaseString containsString:unsupported]);
    NSArray *subtitleProfiles=profile[@"SubtitleProfiles"];
    CHECK([subtitleProfiles isKindOfClass:[NSArray class]] && subtitleProfiles.count==8);
    for (NSDictionary *subtitleProfile in subtitleProfiles) {
        CHECK([subtitleProfile[@"Format"] isKindOfClass:[NSString class]] && [subtitleProfile[@"Format"] length]>0);
        CHECK([subtitleProfile[@"Method"] isEqual:@"External"]);
    }
    CHECK(!JFPlaybackBody(-1,-1)); CHECK(!JFPlaybackBody(0,-2)); CHECK(!JFPlaybackBody(0,10001)); CHECK([JFPlaybackBody(90,-1)[@"StartTimeTicks"] longLongValue]==90);
    // Main-thread stall must proactively send one authenticated pause well
    // before Mac's 5s active watchdog; never pause before commit or twice.
    CHECK(!JFV2BackgroundHoldDue(102.0,100.5,YES,NO));
    CHECK(JFV2BackgroundHoldDue(102.1,100.0,YES,NO));
    CHECK(!JFV2BackgroundHoldDue(110.0,100.0,NO,NO));
    CHECK(!JFV2BackgroundHoldDue(110.0,100.0,YES,YES));
    CHECK(!JFV2BackgroundHoldDue(110.0,0.0,YES,NO));
    for (id invalid in @[@YES,@(-1),@(NAN),@(INFINITY),@1.5,@"1",[NSNull null]]) CHECK(!JFTicks(invalid));
    CHECK(!JFMediaID(@"../id")); CHECK(!JFMediaID(@"id?token=x"));
    NSError *error=nil; NSMutableDictionary *info=Info();
    NSDictionary *plan=JFPlaybackPlan(info,@"movie1",100,&error);
    CHECK([plan[@"method"] isEqual:@"DirectPlay"]); CHECK(!error); CHECK([plan[@"startTicks"] longLongValue]==100);
    CHECK([JFPlaybackPlanForSource(info,@"movie1",100,@"source1",&error)[@"sourceID"] isEqual:@"source1"]);
    CHECK(!JFPlaybackPlanForSource(info,@"movie1",100,@"missing",&error));
    CHECK(!JFPlaybackPlan(info,@"movie1",6000000001LL,&error));
    CHECK(!JFPlaybackPlan(@{},@"movie1",0,&error)); CHECK(!JFPlaybackPlan((id)@[],@"movie1",0,&error));
    for (id value in @[@[],@"bad",@[[NSNull null]]]) { NSMutableDictionary *bad=Info(); bad[@"MediaSources"]=value; CHECK(!JFPlaybackPlan(bad,@"movie1",0,&error)); }
    for (NSString *key in @[@"Id",@"RunTimeTicks",@"MediaStreams"]) { NSMutableDictionary *bad=Info(); bad[@"MediaSources"][0][key]=[NSNull null]; CHECK(!JFPlaybackPlan(bad,@"movie1",0,&error)); }
    info[@"MediaSources"][0][@"Container"]=@"mkv";
    CHECK([JFPlaybackPlan(info,@"movie1",0,&error)[@"method"] isEqual:@"DirectStream"]);
    // Current Jellyfin video PlaybackInfo suppresses SupportsDirectStream. Recover only a
    // server-identified container-only remux through the existing HLS copy path.
    info=Info();
    info[@"MediaSources"][0][@"SupportsDirectStream"]=@NO;
    info[@"MediaSources"][0][@"SupportsDirectPlay"]=@NO;
    info[@"MediaSources"][0][@"TranscodingUrl"]=@"/jellyfin/Videos/movie1/master.m3u8?TranscodeReasons=ContainerNotSupported";
    CHECK([JFPlaybackPlan(info,@"movie1",0,&error)[@"method"] isEqual:@"DirectStream"]);
    info[@"MediaSources"][0][@"TranscodingUrl"]=@"/jellyfin/Videos/movie1/master.m3u8?TranscodeReasons=SubtitleCodecNotSupported";
    CHECK([JFPlaybackPlan(info,@"movie1",0,&error)[@"method"] isEqual:@"Transcode"]);
    info[@"MediaSources"][0][@"TranscodingUrl"]=@"/jellyfin/Videos/movie1/master.m3u8?TranscodeReasons=ContainerNotSupported,%20VideoCodecNotSupported";
    CHECK([JFPlaybackPlan(info,@"movie1",0,&error)[@"method"] isEqual:@"Transcode"]);
    info=Info();
    info[@"MediaSources"][0][@"Container"]=@"mkv";
    info[@"MediaSources"][0][@"MediaStreams"][0][@"Codec"]=@"hevc";
    CHECK([JFPlaybackPlan(info,@"movie1",0,&error)[@"method"] isEqual:@"Transcode"]);

    // A source with AAC + AC3 must not lose Direct Play merely for having >1 audio track.
    NSMutableDictionary *multi=Info();
    NSMutableDictionary *otherAudio=[@{@"Type":@"Audio",@"Index":@5,@"Codec":@"ac3",
        @"Channels":@6,@"SampleRate":@48000,@"IsDefault":@YES} mutableCopy];
    [multi[@"MediaSources"][0][@"MediaStreams"] addObject:otherAudio]; [otherAudio release];
    multi[@"MediaSources"][0][@"TranscodingUrl"]=[NSNull null];
    NSDictionary *multiPlan=JFPlaybackPlanForSourceAndAudio(multi,@"movie1",0,@"source1",-1,&error);
    CHECK([multiPlan[@"method"] isEqual:@"DirectPlay"]);
    CHECK([multiPlan[@"audioStreamIndex"] integerValue]==1);
    CHECK([JFPlaybackPlanForSourceAndAudio(multi,@"movie1",0,@"source1",1,&error)[@"method"] isEqual:@"DirectPlay"]);
    // AC3 user choice remains bound to original track #5. The video can
    // DirectPlay its independently available AAC native transport track #1;
    // the Mac bridge supplies decoded AAC for original track #5.
    NSDictionary *selectedAC3=JFPlaybackPlanForSourceAndAudio(multi,@"movie1",0,@"source1",5,&error);
    CHECK([selectedAC3[@"method"] isEqual:@"DirectPlay"]);
    CHECK([selectedAC3[@"audioStreamIndex"] integerValue]==5);
    CHECK([JFPlaybackReport(selectedAC3,0,NO)[@"AudioStreamIndex"] integerValue]==5);
    CHECK(JFVideoTransportAACIndex(multi,@"source1")==1);
    CHECK(JFVideoTransportAACIndex(multi,@"nonexistent")==-1);
    CHECK(JFVideoTransportAACIndex(multi,nil)==-1);
    // Default AC3 must not control video format negotiation when user
    // selects AC3 audio for the separate authenticated Mac AAC cache.
    multi[@"MediaSources"][0][@"MediaStreams"][1][@"IsDefault"]=@NO;
    CHECK(JFVideoTransportAACIndex(multi,@"source1")==1);
    CHECK([JFPlaybackPlanForSourceAndAudio(multi,@"movie1",0,@"source1",5,&error)[@"audioStreamIndex"] integerValue]==5);
    CHECK(!JFPlaybackPlanForSourceAndAudio(multi,@"movie1",0,@"source1",6,&error));
    CHECK(!JFPlaybackPlanForSourceAndAudio(multi,@"movie1",0,@"source1",10001,&error));

    // Compatible H.264 video with incompatible audio should preserve video and transcode audio only.
    NSMutableDictionary *audioOnly=Info();
    audioOnly[@"MediaSources"][0][@"SupportsDirectPlay"]=@NO;
    audioOnly[@"MediaSources"][0][@"SupportsDirectStream"]=@NO;
    audioOnly[@"MediaSources"][0][@"MediaStreams"][1][@"Codec"]=@"ac3";
    NSDictionary *audioOnlyPlan=JFPlaybackPlan(audioOnly,@"movie1",0,&error);
    CHECK([audioOnlyPlan[@"method"] isEqual:@"Transcode"]);
    CHECK([audioOnlyPlan[@"allowVideoCopy"] boolValue]);
    // URL-level mixed copy/transcode assertions are checked after the client fixture is created.
    info[@"MediaSources"][0][@"SupportsTranscoding"]=@NO; CHECK(!JFPlaybackPlan(info,@"movie1",0,&error));
    for (NSArray *pair in @[@[@"Width",@3840],@[@"Height",@2160],@[@"BitDepth",@10],@[@"VideoRange",@"HDR"],@[@"RealFrameRate",@60],@[@"Level",@51],@[@"Codec",@"av1"]]) {
        NSMutableDictionary *bad=Info(); bad[@"MediaSources"][0][@"MediaStreams"][0][pair[0]]=pair[1]; CHECK([JFPlaybackPlan(bad,@"movie1",0,&error)[@"method"] isEqual:@"Transcode"]);
    }
    // VFR MP4 r_frame_rate can be 50, 60 or 90000 while the Jellyfin
    // ReferenceFrameRate (AverageFrameRate) is within the ATV3's 30fps envelope.
    for (NSArray *rates in @[@[@90000,@24.000174],@[@60,@29.99975],@[@90000,@30.000227],@[@50,@24.999828]]) {
        NSMutableDictionary *vfr=Info();
        vfr[@"MediaSources"][0][@"MediaStreams"][0][@"RealFrameRate"]=rates[0];
        vfr[@"MediaSources"][0][@"MediaStreams"][0][@"AverageFrameRate"]=rates[1];
        NSDictionary *vfrPlan=JFPlaybackPlan(vfr,@"movie1",0,&error);
        CHECK([vfrPlan[@"method"] isEqual:@"DirectPlay"]);
        CHECK([vfrPlan[@"videoRejectMask"] unsignedIntegerValue]==0);
    }
    NSMutableDictionary *badAvg=Info();
    badAvg[@"MediaSources"][0][@"MediaStreams"][0][@"RealFrameRate"]=@60;
    badAvg[@"MediaSources"][0][@"MediaStreams"][0][@"AverageFrameRate"]=@31;
    CHECK([JFPlaybackPlan(badAvg,@"movie1",0,&error)[@"method"] isEqual:@"Transcode"]);
    CHECK(![JFPlaybackPlan(badAvg,@"movie1",0,&error)[@"allowVideoCopy"] boolValue]);
    NSDictionary *activeProfile=JFProvisionalDeviceProfile();
    BOOL sawFps=NO;
    for (NSDictionary *codecProfile in activeProfile[@"CodecProfiles"])
        for (NSDictionary *condition in codecProfile[@"Conditions"])
            if ([condition[@"Property"] isEqual:@"VideoFramerate"])
                sawFps=[condition[@"Value"] isEqual:@"30.01"];
    CHECK(sawFps);
    JFClient *client=Client();
    NSURLRequest *audioOnlyRequest=[client playbackRequest:audioOnlyPlan error:&error];
    CHECK(audioOnlyRequest!=nil);
    CHECK([audioOnlyRequest.URL.query containsString:@"VideoCodec=copy"]);
    CHECK([audioOnlyRequest.URL.query containsString:@"AudioCodec=aac"]);
    CHECK([audioOnlyRequest.URL.query containsString:@"AllowVideoStreamCopy=true"]);
    CHECK([audioOnlyRequest.URL.query containsString:@"AllowAudioStreamCopy=false"]);

    // Burn-in subtitles must disable video copy even when the source video is otherwise compatible.
    NSMutableDictionary *burnPlan=[[audioOnlyPlan mutableCopy] autorelease];
    burnPlan[@"subtitleStreamIndex"]=@2;
    NSURLRequest *burnRequest=[client playbackRequest:burnPlan error:&error];
    CHECK(burnRequest!=nil);
    CHECK([burnRequest.URL.query containsString:@"VideoCodec=h264"]);
    CHECK([burnRequest.URL.query containsString:@"AudioCodec=aac"]);
    CHECK([burnRequest.URL.query containsString:@"AllowVideoStreamCopy=false"]);
    CHECK([client playbackInfo:@"movie1" startTicks:100 mediaSourceID:@"source1" audioIndex:1 subtitleIndex:-1 error:&error]);
    CHECK([[JFPlaybackFixture lastBody][@"MediaSourceId"] isEqual:@"source1"]);
    CHECK([[JFPlaybackFixture lastBody][@"AudioStreamIndex"] integerValue]==1);
    CHECK(![client playbackInfo:@"movie1" startTicks:100 mediaSourceID:nil audioIndex:1 subtitleIndex:-1 error:&error]);
    CHECK([client playbackInfo:@"movie1" startTicks:100 mediaSourceID:@"source1" audioIndex:1 subtitleIndex:2 error:&error]);
    CHECK([[JFPlaybackFixture lastBody][@"MediaSourceId"] isEqual:@"source1"]);
    CHECK([[JFPlaybackFixture lastBody][@"AudioStreamIndex"] integerValue]==1);
    CHECK([[JFPlaybackFixture lastBody][@"SubtitleStreamIndex"] integerValue]==2);
    CHECK(![[JFPlaybackFixture lastBody][@"EnableDirectPlay"] boolValue]);
    CHECK(![[JFPlaybackFixture lastBody][@"EnableDirectStream"] boolValue]);
    CHECK(![[JFPlaybackFixture lastBody][@"AllowVideoStreamCopy"] boolValue]);
    CHECK(![[JFPlaybackFixture lastBody][@"AllowAudioStreamCopy"] boolValue]);
    CHECK([[JFPlaybackFixture lastBody][@"AlwaysBurnInSubtitleWhenTranscoding"] boolValue]);
    CHECK(![client playbackInfo:@"movie1" startTicks:100 mediaSourceID:nil audioIndex:-1 subtitleIndex:2 error:&error]);
    CHECK([client playbackInfo:@"movie1" startTicks:100 mediaSourceID:@"source1" audioIndex:-1 subtitleIndex:-1 fallbackTier:1 error:&error]);
    CHECK(![[JFPlaybackFixture lastBody][@"EnableDirectPlay"] boolValue]);
    CHECK([[JFPlaybackFixture lastBody][@"EnableDirectStream"] boolValue]);
    CHECK([[JFPlaybackFixture lastBody][@"AllowVideoStreamCopy"] boolValue]);
    CHECK([client playbackInfo:@"movie1" startTicks:100 mediaSourceID:@"source1" audioIndex:-1 subtitleIndex:-1 fallbackTier:2 error:&error]);
    CHECK(![[JFPlaybackFixture lastBody][@"EnableDirectPlay"] boolValue]);
    CHECK(![[JFPlaybackFixture lastBody][@"EnableDirectStream"] boolValue]);
    CHECK(![[JFPlaybackFixture lastBody][@"AllowVideoStreamCopy"] boolValue]);
    CHECK(![[JFPlaybackFixture lastBody][@"AllowAudioStreamCopy"] boolValue]);
    CHECK(![client playbackInfo:@"movie1" startTicks:100 mediaSourceID:@"source1" audioIndex:-1 subtitleIndex:-1 fallbackTier:3 error:&error]);
    NSURLRequest *direct=[client playbackRequest:plan error:&error]; CHECK(direct!=nil); CHECK([direct.URL.query containsString:@"StartTimeTicks=100"]); CHECK(![direct.URL.absoluteString containsString:@"fixture-token"]); CHECK([[direct valueForHTTPHeaderField:@"Authorization"] containsString:@"Token=\"fixture-token\""] && ![direct valueForHTTPHeaderField:@"X-Emby-Token"]);
    NSURL *origin=[NSURL URLWithString:@"https://media.invalid:443/base/master.m3u8"];
    for (NSString *ref in @[@"media.m3u8",@"../seg.ts",@"/key.bin",@"https://media.invalid/seg.ts",@"//media.invalid:443/seg.ts"])
        CHECK([JFMediaGateway allowedURL:ref relativeTo:origin origin:origin]!=nil);
    for (NSString *ref in @[@"http://media.invalid/seg.ts",@"https://other.invalid/seg.ts",@"https://media.invalid:444/seg.ts",@"file:///tmp/x",@"data:bad",@"https://user:pass@media.invalid/x",@"/x#fragment",@"/bad path",@"\n",@"//other.invalid/x",@"ftp://media.invalid/x"])
        CHECK(![JFMediaGateway allowedURL:ref relativeTo:origin origin:origin]);
    NSURL *clean=[JFMediaGateway allowedURL:@"seg.ts?api_key=synthetic&Token=synthetic&keep=1&X-Emby-Token=synthetic" relativeTo:origin origin:origin];
    CHECK([clean.query isEqual:@"keep=1"]);
    NSMutableURLRequest *gatewayRequest=[NSMutableURLRequest requestWithURL:origin];
    [gatewayRequest setValue:@"Bearer synthetic-only" forHTTPHeaderField:@"Authorization"];
    JFMediaGateway *gateway=[[[JFMediaGateway alloc] initWithRequest:gatewayRequest] autorelease];
    CHECK(gateway!=nil);
    NSString *playlist=@"#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin?api_key=synthetic\"\n#EXTINF:2,\nseg.ts\n#EXT-X-ENDLIST\n";
    NSData *rewritten=[gateway rewritePlaylist:[playlist dataUsingEncoding:NSUTF8StringEncoding] URL:origin];
    NSString *rewrittenText=[[[NSString alloc] initWithData:rewritten encoding:NSUTF8StringEncoding] autorelease];
    CHECK([rewrittenText containsString:@"http://127.0.0.1:"] && ![rewrittenText containsString:@"synthetic"] && ![rewrittenText containsString:@"media.invalid"]);
    for (NSString *bad in @[@"garbage",@"#EXTM3U\nhttps://other.invalid/seg.ts\n",@"#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"https://other.invalid/key\"\n",@"#EXTM3U\n#EXT-X-MEDIA:URI=unquoted\n",@"#EXTM3U\n#EXT-X-DEFINE:NAME=\"x\",VALUE=\"y\"\n",@"#EXTM3U\n{$variable}\n"])
        CHECK(![gateway rewritePlaylist:[bad dataUsingEncoding:NSUTF8StringEncoding] URL:origin]);
    NSMutableString *largeAllowed=[NSMutableString stringWithString:@"#EXTM3U\n#"];
    [largeAllowed appendString:[@"" stringByPaddingToLength:2*1024*1024 withString:@"x" startingAtIndex:0]];
    CHECK([[gateway rewritePlaylist:[largeAllowed dataUsingEncoding:NSUTF8StringEncoding] URL:origin] length]>1024*1024);
    NSMutableString *manySegments=[NSMutableString stringWithString:@"#EXTM3U\n#EXT-X-TARGETDURATION:3\n"];
    for (NSUInteger i=0;i<3200;i++) [manySegments appendFormat:@"#EXTINF:3,\nsegment%04lu.ts?opaque=%@\n",(unsigned long)i,[@"z" stringByPaddingToLength:780 withString:@"z" startingAtIndex:0]];
    NSTimeInterval rewriteStart=[NSProcessInfo processInfo].systemUptime;
    NSData *manyRewritten=[gateway rewritePlaylist:[manySegments dataUsingEncoding:NSUTF8StringEncoding] URL:origin];
    NSTimeInterval rewriteSeconds=[NSProcessInfo processInfo].systemUptime-rewriteStart;
    // Keep the original one-second performance gate by default. During an
    // explicitly marked busy-host functional run, check correctness separately.
    BOOL busyHost=getenv("JF_BENCHMARK_ALLOW_BUSY_HOST")!=NULL;
    CHECK(manyRewritten.length>0 && rewriteSeconds<(busyHost?10.0:1.0));
    NSData *duplicate=[gateway rewritePlaylist:[@"#EXTM3U\nsegment0000.ts?opaque=z\nsegment0000.ts?opaque=z\n" dataUsingEncoding:NSUTF8StringEncoding] URL:origin];
    CHECK(duplicate.length>0);
    NSMutableData *oversized=[NSMutableData dataWithLength:4*1024*1024+1]; CHECK(![gateway rewritePlaylist:oversized URL:origin]);
    [gateway stop];

    [JFPlaybackFixture setMode:@"gateway-declared-large"];
    NSMutableURLRequest *declaredLargeRequest=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://playback.invalid/jellyfin/Videos/movie1/master.m3u8"]];
    [declaredLargeRequest setValue:@"Bearer synthetic-only" forHTTPHeaderField:@"Authorization"];
    JFMediaGateway *declaredLargeGateway=[[[JFMediaGateway alloc] initWithRequest:declaredLargeRequest] autorelease];
    CHECK([declaredLargeGateway start:&error]);
    NSURLResponse *declaredLargeResponse=nil; NSError *declaredLargeError=nil;
    NSData *declaredLargeBody=[NSURLConnection sendSynchronousRequest:declaredLargeGateway.localRequest returningResponse:&declaredLargeResponse error:&declaredLargeError];
    CHECK(!declaredLargeError && [(NSHTTPURLResponse *)declaredLargeResponse statusCode]==200);
    CHECK(declaredLargeBody.length>0 && declaredLargeBody.length<1024*1024);
    CHECK([[[NSString alloc] initWithData:declaredLargeBody encoding:NSUTF8StringEncoding] autorelease] != nil);
    [declaredLargeGateway stop];
    [JFPlaybackFixture setMode:@"normal"];

    SetupATV3PlaybackRuntime(); CHECK([JFATV3PlaybackBackend runtimeCompatible]);
    JFATV3PlaybackBackend *native=[[[JFATV3PlaybackBackend alloc] initWithHostController:nil] autorelease];
    CHECK([native prepareRequest:direct positionTicks:100 error:&error] && native.prepared && !error);
    CHECK(native.preparedAsset==atvLastAsset && native.preparedPlayer==atvLastPlayer && native.preparedPlayerController==atvLastController);
    id nativeURL=((id(*)(id,SEL))objc_msgSend)(native.preparedAsset,NSSelectorFromString(@"mediaURL"));
    NSString *nativeType=((id(*)(id,SEL))objc_msgSend)(native.preparedAsset,NSSelectorFromString(@"mediaType"));
    CHECK([nativeURL isKindOfClass:[NSString class]] && [nativeURL isEqual:direct.URL.absoluteString] && ![nativeURL containsString:@"fixture-token"]);
    CHECK(nativeType==atvStreamingType && [nativeType isKindOfClass:objc_getClass("BRMediaType")]);
    NSDictionary *metadata=((id(*)(id,SEL))objc_msgSend)(native.preparedAsset,NSSelectorFromString(@"playbackMetadata"));
    CHECK([metadata[@"BRMediaAssetMetadataHTTPHeaders"][@"Authorization"] isEqual:[direct valueForHTTPHeaderField:@"Authorization"]]);
    CHECK([metadata[@"kBRMediaAssetReferenceRestrictions"] unsignedIntegerValue]==5);
    NSMutableURLRequest *headerRequest=[[direct mutableCopy] autorelease];
    for (NSString *name in @[@"Host",@"Connection",@"Content-Length",@"Cookie",@"Transfer-Encoding",@"X-Emby-Token"]) [headerRequest setValue:@"forbidden" forHTTPHeaderField:name];
    [headerRequest setValue:@"video/*" forHTTPHeaderField:@"Accept"];
    CHECK([native prepareRequest:headerRequest positionTicks:0 error:&error]);
    [headerRequest setValue:@"mutated" forHTTPHeaderField:@"Authorization"];
    metadata=((id(*)(id,SEL))objc_msgSend)(native.preparedAsset,NSSelectorFromString(@"playbackMetadata"));
    CHECK([metadata[@"BRMediaAssetMetadataHTTPHeaders"][@"Authorization"] isEqual:[direct valueForHTTPHeaderField:@"Authorization"]]);
    CHECK([metadata[@"BRMediaAssetMetadataHTTPHeaders"][@"Accept"] isEqual:@"video/*"]);
    for (NSString *name in @[@"Host",@"Connection",@"Content-Length",@"Cookie",@"Transfer-Encoding",@"X-Emby-Token"]) CHECK(!metadata[@"BRMediaAssetMetadataHTTPHeaders"][name]);
    CHECK(atvCueCalls==0 && atvStateCalls==0 && atvPresentCalls==0);
    NSMutableURLRequest *noAuth=[[direct mutableCopy] autorelease]; [noAuth setValue:nil forHTTPHeaderField:@"Authorization"];
    CHECK(![native prepareRequest:noAuth positionTicks:0 error:&error] && error.code==3004 && !native.prepared);
    NSMutableURLRequest *unsafe=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://user@playback.invalid/video.mp4"]]; [unsafe setValue:@"secret" forHTTPHeaderField:@"Authorization"];
    CHECK(![native prepareRequest:unsafe positionTicks:0 error:&error] && error.code==3003 && !native.prepared);
    __block NSString *foundationEvent=nil; __block long long foundationTicks=-1;
    [native startRequest:direct positionTicks:100 event:^(NSString *event,long long ticks){ [foundationEvent release]; foundationEvent=[event copy]; foundationTicks=ticks; }];
    CHECK([foundationEvent isEqual:@"started"] && atvCueCalls==1 && atvPresentCalls==1 && atvStateCalls>=1);
    CHECK(native.prepared && atvRate==1.0 && atvElapsed>0.0);
    [native pause]; CHECK(atvRate==0.0);
    [native resume]; CHECK(atvRate==1.0);
    [native seek:300000000LL event:^(NSString *event,long long ticks){ [foundationEvent release]; foundationEvent=[event copy]; foundationTicks=ticks; }];
    CHECK(fabs(atvElapsed-30.0)<0.001);
    atvElapsed=42.0;
    [native performSelector:@selector(sampleProgress)];
    CHECK([foundationEvent isEqual:@"progress"] && foundationTicks==420000000LL);
    atvElapsed=12.0;
    [native performSelector:@selector(sampleProgress)];
    CHECK([foundationEvent isEqual:@"progress"] && foundationTicks==120000000LL);
    atvElapsed=0.0;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BRMediaPlayerControllerWasPopped" object:native.preparedPlayer];
    CHECK([foundationEvent isEqual:@"popped"] && foundationTicks==120000000LL);
    [native stop];
    [foundationEvent release]; foundationEvent=nil; foundationTicks=-1;
    // Silent native disappearance: firmware does not always post WasPopped.
    [native startRequest:direct positionTicks:100 event:^(NSString *event,long long ticks){ [foundationEvent release]; foundationEvent=[event copy]; foundationTicks=ticks; }];
    atvElapsed=42.0; [native performSelector:@selector(sampleProgress)];
    CHECK([foundationEvent isEqual:@"progress"] && foundationTicks==420000000LL);
    // Paused playback must retain its presentation and captions.
    [native pause]; [native performSelector:@selector(sampleProgress)];
    CHECK(![foundationEvent isEqual:@"popped"]);
    // Temporary nil/different manager identity must NOT terminate the movie.
    id fixturePlayer=native.preparedPlayer;
    atvVisiblePlayer=nil; [native performSelector:@selector(sampleProgress)];
    CHECK(![foundationEvent isEqual:@"popped"] && atvEndPresentationCalls==0);
    atvVisiblePlayer=[NSObject new]; [native performSelector:@selector(sampleProgress)];
    CHECK(![foundationEvent isEqual:@"popped"]);
    [atvVisiblePlayer release]; atvVisiblePlayer=fixturePlayer;
    [native performSelector:@selector(sampleProgress)];
    CHECK(![foundationEvent isEqual:@"popped"] && atvRate==0.0);
    // Genuine persistent native presentation disappearance, even WITHOUT a
    // WasPopped notification, eventually stops, preserving resume position.
    atvVisiblePlayer=nil; [native performSelector:@selector(sampleProgress)];
    CHECK(![foundationEvent isEqual:@"popped"]);
    CHECK(Wait(^BOOL { return [foundationEvent isEqual:@"popped"]; }));
    CHECK(foundationTicks==420000000LL);
    [native stop];
    [foundationEvent release]; foundationEvent=nil; foundationTicks=-1;
    [native startRequest:direct positionTicks:100 event:^(NSString *event,long long ticks){ [foundationEvent release]; foundationEvent=[event copy]; foundationTicks=ticks; }];
    atvElapsed=42.0; [native performSelector:@selector(sampleProgress)];
    atvElapsed=0.0;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BRMediaPlayerPlaylistAssetPlayedToEndTime" object:native.preparedPlayer];
    CHECK([foundationEvent isEqual:@"ended"] && foundationTicks==420000000LL);
    [native stop]; CHECK(!native.prepared && atvEndPresentationCalls==1);
    [foundationEvent release]; foundationEvent=nil;
    unlink("/tmp/Jellyfin-ATV3.playbacktrace");
    [native startRequest:direct positionTicks:0 event:^(NSString *event,long long ticks){ [foundationEvent release]; foundationEvent=[event copy]; }];
    NSError *nativeFixtureError=[NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11800 userInfo:@{NSLocalizedDescriptionKey:@"DO_NOT_LOG_THIS_DESCRIPTION"}];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BRMediaPlayerPlaybackError" object:native.preparedPlayer userInfo:@{@"error":nativeFixtureError}];
    CHECK([foundationEvent isEqual:@"failure"]);
    NSString *trace=[NSString stringWithContentsOfFile:@"/tmp/Jellyfin-ATV3.playbacktrace" encoding:NSUTF8StringEncoding error:NULL];
    CHECK([trace containsString:@"NATIVE_NOTIFICATION playback-error hasError=1 domain=AVFoundationErrorDomain code=-11800"]);
    CHECK(![trace containsString:@"DO_NOT_LOG_THIS_DESCRIPTION"]);
    [native stop]; [foundationEvent release]; foundationEvent=nil;
    atvThrowPlayer=YES; CHECK(![native prepareRequest:direct positionTicks:0 error:&error]); CHECK(error.code==3008 && [error.userInfo[@"JFExceptionName"] isEqual:@"ATVMockException"] && [error.userInfo[@"JFExceptionReason"] containsString:@"mock asset rejection"]); CHECK(!native.prepared); atvThrowPlayer=NO;
    info=Info(); info[@"MediaSources"][0][@"MediaStreams"][0][@"Codec"]=@"hevc";
    info[@"MediaSources"][0][@"TranscodingUrl"]=@"/jellyfin/Videos/movie1/master.m3u8?api_key=SECRET&VideoCodec=hevc&MaxWidth=9999&SegmentLength=3&StartTimeTicks=50";
    NSDictionary *transcode=JFPlaybackPlan(info,@"movie1",50,&error);
    NSMutableDictionary *selectedTranscode=[[transcode mutableCopy] autorelease];
    selectedTranscode[@"audioStreamIndex"]=@1; selectedTranscode[@"subtitleStreamIndex"]=@2;
    NSURLRequest *request=[client playbackRequest:selectedTranscode error:&error]; CHECK(request!=nil); CHECK(![request.URL.absoluteString containsString:@"SECRET"]); CHECK([request.URL.query containsString:@"VideoCodec=h264"]); CHECK([request.URL.query containsString:@"MaxWidth=1920"]); CHECK([request.URL.query containsString:@"SegmentLength=3"] && ![request.URL.query containsString:@"SegmentLength=6"]); CHECK(![request.URL.query.lowercaseString containsString:@"starttimeticks"]);
    CHECK([request.URL.query containsString:@"AudioStreamIndex=1"]); CHECK([request.URL.query containsString:@"SubtitleStreamIndex=2"]); CHECK([request.URL.query containsString:@"AllowVideoStreamCopy=false"]); CHECK([request.URL.query containsString:@"AllowAudioStreamCopy=false"]);
    NSMutableDictionary *longInfo=Info(); longInfo[@"MediaSources"][0][@"MediaStreams"][0][@"Codec"]=@"hevc"; longInfo[@"MediaSources"][0][@"RunTimeTicks"]=@108000000001LL;
    longInfo[@"MediaSources"][0][@"TranscodingUrl"]=@"/jellyfin/Videos/movie1/master.m3u8?SegmentLength=3";
    NSDictionary *longPlan=JFPlaybackPlan(longInfo,@"movie1",0,&error); NSURLRequest *longRequest=[client playbackRequest:longPlan error:&error];
    CHECK(longRequest!=nil && [longRequest.URL.query containsString:@"SegmentLength=6"] && ![longRequest.URL.query containsString:@"SegmentLength=3"]);
    NSMutableDictionary *guidInfo=Info();
    guidInfo[@"MediaSources"][0][@"MediaStreams"][0][@"Codec"]=@"hevc";
    NSString *compactID=@"00112233445566778899aabbccddeeff";
    guidInfo[@"MediaSources"][0][@"TranscodingUrl"]=@"/jellyfin/videos/00112233-4455-6677-8899-AABBCCDDEEFF/master.m3u8?api_key=SECRET";
    NSDictionary *guidPlan=JFPlaybackPlan(guidInfo,compactID,0,&error);
    CHECK(guidPlan && [[client playbackRequest:guidPlan error:&error].URL.path isEqual:@"/jellyfin/videos/00112233-4455-6677-8899-AABBCCDDEEFF/master.m3u8"]);
    for (NSString *url in @[
        @"/jellyfin/videos/00112233-4455-6677-8899-AABBCCDDEEFE/master.m3u8",
        @"/jellyfin/video/00112233-4455-6677-8899-AABBCCDDEEFF/master.m3u8",
        @"/jellyfin/videos/00112233-4455-6677-8899-AABBCCDDEEFF/extra/master.m3u8",
        @"/jellyfin/videos/001122334-455-6677-8899-AABBCCDDEEFF/master.m3u8",
        @"/jellyfin/videos/00112233-4455-6677-8899-AABBCCDDEEFF/index.m3u8",
        @"/jellyfin/videos/00112233-4455-6677-8899-AABBCCDDEEFF/%6daster.m3u8"]) {
        NSMutableDictionary *bad=[guidInfo mutableCopy];
        NSMutableArray *sources=[[[guidInfo objectForKey:@"MediaSources"] mutableCopy] autorelease];
        NSMutableDictionary *source=[[[sources objectAtIndex:0] mutableCopy] autorelease];
        [source setObject:url forKey:@"TranscodingUrl"]; [sources replaceObjectAtIndex:0 withObject:source];
        [bad setObject:sources forKey:@"MediaSources"];
        CHECK(![client playbackRequest:JFPlaybackPlan(bad,compactID,0,&error) error:&error]);
        [bad release];
    }
    CHECK([native prepareRequest:request positionTicks:50 error:&error]);
    id hlsType=((id(*)(id,SEL))objc_msgSend)(native.preparedAsset,NSSelectorFromString(@"mediaType")); CHECK(hlsType==atvStreamingType); [native discardPreparedPlayback];
    for (NSString *url in @[@"https://evil.invalid/jellyfin/Videos/movie1/a.m3u8",@"//evil.invalid/a.m3u8",@"/Videos/movie1/a.m3u8",@"/jellyfin/Videos/movie1/../x.m3u8",@"http://user@playback.invalid/jellyfin/Videos/movie1/a.m3u8",@"/jellyfin/Videos/movie1/a.m3u8#x",@"/jellyfin/Videos/movie1/%252e%252e/a.m3u8"]) {
        NSMutableDictionary *bad=Info(); bad[@"MediaSources"][0][@"Container"]=@"mkv"; bad[@"MediaSources"][0][@"TranscodingUrl"]=url;
        CHECK(![client playbackRequest:JFPlaybackPlan(bad,@"movie1",0,&error) error:&error]);
    }
    CHECK(JFPlaybackReport(plan,0,NO)); CHECK(!JFPlaybackReport(plan,-1,NO)); CHECK(!JFPlaybackReport(plan,6000000001LL,NO));
    NSMutableDictionary *audioPlan=[[plan mutableCopy] autorelease]; audioPlan[@"audioStreamIndex"]=@1; audioPlan[@"subtitleStreamIndex"]=@2;
    CHECK([JFPlaybackReport(audioPlan,0,NO)[@"AudioStreamIndex"] integerValue]==1);
    CHECK([JFPlaybackReport(audioPlan,0,NO)[@"SubtitleStreamIndex"] integerValue]==2);
    NSArray *audioTracks=JFAudioTracks(@[@{@"Id":@"source1",@"MediaStreams":@[
        @{@"Type":@"Audio",@"Index":@1,@"Codec":@"aac",@"Language":@"eng",@"Title":@"Original",@"Channels":@2,@"SampleRate":@48000,@"IsDefault":@YES},
        @{@"Type":@"Audio",@"Index":@2,@"Codec":@"ac3",@"Language":@"zho",@"Title":@"Dub",@"Channels":@2,@"SampleRate":@48000,@"IsDefault":@NO}
    ]}],&error);
    CHECK(audioTracks.count==2); CHECK([JFAudioDefaultTrack(audioTracks)[@"index"] integerValue]==1);
    CHECK([JFAudioTrackLabel(audioTracks[1]) containsString:@"Dub"]);
    CHECK(!JFAudioTracks(@[@{@"Id":@"source1",@"MediaStreams":@[@{@"Type":@"Audio",@"Index":@1,@"Codec":@"aac"},@{@"Type":@"Audio",@"Index":@1,@"Codec":@"aac"}]}],&error));
    NSArray *tracks=JFSubtitleTracks(Info()[@"MediaSources"][0][@"MediaStreams"],&error); CHECK(tracks.count==3);
    NSArray *sourceTracks=JFSubtitleTracksForSources(Info()[@"MediaSources"],&error); CHECK(sourceTracks.count==3);
    CHECK([sourceTracks[0][@"sourceID"] isEqual:@"source1"]); CHECK([JFAudioTrackLabel(audioTracks[0]) containsString:@"Original"]);
    CHECK([JFSubtitleTrackLabel(sourceTracks[0]) containsString:@"SRT"]);
    CHECK([JFSubtitleSelection(tracks,2,NO,&error)[@"strategy"] isEqual:@"local-srt"]);
    CHECK([JFSubtitleSelection(tracks,3,NO,&error)[@"strategy"] isEqual:@"preprocess-required"]);
    CHECK([JFSubtitleSelection(tracks,3,YES,&error)[@"strategy"] isEqual:@"preprocess-required"]);
    CHECK([JFSubtitleSelection(tracks,4,NO,&error)[@"strategy"] isEqual:@"preprocess-required"]);
    CHECK([JFSubtitleSelection(tracks,-1,NO,&error)[@"strategy"] isEqual:@"off"]); CHECK(!JFSubtitleSelection(tracks,8,NO,&error));
    for (NSString *codec in @[@"srt",@"ssa",@"pgs",@"dvdsub",@"unknown"]) {
        NSArray *selected=JFSubtitleTracks(@[@{@"Type":@"Subtitle",@"Index":@7,@"Codec":codec,@"IsExternal":@NO}],&error);
        NSDictionary *selection=JFSubtitleSelection(selected,7,NO,&error);
        if ([codec isEqual:@"unknown"]) CHECK(!selection);
        else CHECK([selection[@"strategy"] isEqual:([codec isEqual:@"srt"] ? @"local-srt" : @"preprocess-required")]);
    }
    CHECK(!JFSubtitleSelection((id)@{},1,NO,&error));
    CHECK(!JFSubtitleSelection(@[[NSNull null]],1,NO,&error));
    CHECK(!JFSubtitleTracks(@[@{@"Type":@"Subtitle",@"Index":@(-1),@"Codec":@"srt"}],&error));
    CHECK(!JFSubtitleTracks(@[@{@"Type":@"Subtitle",@"Index":@0,@"Codec":@"srt",@"IsExternal":@"true"}],&error));
    CHECK(!JFSubtitleTracks(@[Info()[@"MediaSources"][0][@"MediaStreams"][2],Info()[@"MediaSources"][0][@"MediaStreams"][2]],&error));
    CHECK([client subtitleData:@"movie1" mediaSource:@"source1" index:2 error:&error]!=nil);
    // Playback uses the single-pass, already-parsed SRT path.
    NSArray *downloadedCues=[client localSubtitleCues:@"movie1" mediaSource:@"source1" index:2 error:&error];
    CHECK(downloadedCues.count>0 && !error);
    CHECK(![client subtitleRequest:@"../x" mediaSource:@"source1" index:2 error:&error]); CHECK(![client subtitleRequest:@"movie1" mediaSource:@"source1" index:-1 error:&error]);
    for (NSData *data in @[[NSData data],[NSData dataWithBytes:"\xff" length:1],[NSMutableData dataWithLength:2*1024*1024+1],[@"not SRT" dataUsingEncoding:NSUTF8StringEncoding],[@"1\n00:00:03,000 --> 00:00:01,000\nx" dataUsingEncoding:NSUTF8StringEncoding]]) CHECK(!JFSubtitleText(data,&error));
    CHECK(JFSubtitleText([@"\uFEFF1\r\n00:00:01,000 --> 00:00:02,000\r\n字幕" dataUsingEncoding:NSUTF8StringEncoding],&error));
    [JFPlaybackFixture setMode:@"invalid-subtitle"]; CHECK(![client subtitleData:@"movie1" mediaSource:@"source1" index:2 error:&error]);
    [JFPlaybackFixture setMode:@"normal"];
    JFWorker *worker=[JFWorker new]; JFMockPlaybackBackend *backend=[JFMockPlaybackBackend new];
    JFPlaybackController *controller=[[JFPlaybackController alloc] initWithClient:client worker:worker backend:backend];
    CHECK([controller playItem:@"movie1" startTicks:100]); CHECK(![controller playItem:@"movie1" startTicks:0]); CHECK(Wait(^BOOL { return backend.starts==1; }));
    CHECK(![controller playItem:@"movie1" startTicks:0 mediaSourceID:nil audioIndex:-1 subtitleIndex:2]);
    CHECK([JFPlaybackFixture lastBody][@"DeviceProfile"]!=nil); CHECK([[JFPlaybackFixture lastBody][@"StartTimeTicks"] longLongValue]==100);
    [backend emit:@"started" ticks:0]; CHECK([controller.currentState isEqual:@"playing"]);
    CHECK([[controller currentMediaSourceID] isEqual:@"source1"]);
    CHECK(![controller selectLocalSubtitleForItem:@"movie1" mediaSourceID:@"other-source" index:2]);
    CHECK(Wait(^BOOL { return [JFPlaybackFixture reports].count==1; }));
    CHECK([controller pause]); CHECK([controller.currentState isEqual:@"paused"]); CHECK(![controller pause]);
    [backend emit:@"progress" ticks:500]; CHECK(controller.positionTicks==100);
    CHECK([controller resume]);
    CHECK([controller seekBySeconds:300]); CHECK(controller.positionTicks==3000000100LL);
    CHECK([controller seekBySeconds:-300]); CHECK(controller.positionTicks==100);
    CHECK([controller seekBySeconds:-300]); CHECK(controller.positionTicks==0);
    CHECK(![controller seekBySeconds:-300]); CHECK(![controller seekBySeconds:601]);
    JFBackendEvent beforeSeek=[[backend capturedEvent] copy]; CHECK(![controller seek:-1]); CHECK(![controller seek:6000000001LL]); CHECK([controller seek:200000000]); beforeSeek(@"progress",500000000); CHECK(controller.positionTicks==200000000); [beforeSeek release];
    __block NSUInteger progress=0; controller.progressCallback=^(long long ticks) { progress++; };
    [backend emit:@"progress" ticks:300000000]; CHECK(progress==1); CHECK(controller.positionTicks==300000000);
    [backend emit:@"progress" ticks:120000000]; CHECK(controller.positionTicks==120000000);
    [backend emit:@"paused" ticks:120000000]; CHECK([controller.currentState isEqual:@"paused"] && controller.positionTicks==120000000);
    [backend emit:@"resumed" ticks:120000000]; CHECK([controller.currentState isEqual:@"playing"] && controller.positionTicks==120000000);
    JFBackendEvent late=[[backend capturedEvent] copy];
    [backend emit:@"popped" ticks:120000000]; CHECK([controller.currentState isEqual:@"stopped"] && [controller resumeTicksForItem:@"movie1"]==120000000);
    CHECK(![controller stop]); CHECK([controller resumeTicksForItem:@"movie2"]==0); CHECK([controller currentMediaSourceID]==nil);
    late(@"progress",500000000); late(@"started",0); CHECK([controller.currentState isEqual:@"stopped"]); [late release];
    CHECK(Wait(^BOOL { return [[[JFPlaybackFixture reports] lastObject][@"path"] hasSuffix:@"Stopped"]; }));
    CHECK([controller playItem:@"movie1" startTicks:0]); CHECK(Wait(^BOOL { return backend.starts==2; })); [backend emit:@"started" ticks:0]; [backend emit:@"progress" ticks:5900000000LL]; [backend emit:@"ended" ticks:5900000000LL]; CHECK([controller.currentState isEqual:@"stopped"] && controller.positionTicks==6000000000LL && [controller resumeTicksForItem:@"movie1"]==0);
    [controller close]; [controller release]; [worker cancelAll]; [worker release]; [backend release];
    for (NSString *mode in @[@"401",@"malformed",@"empty",@"disconnect",@"tls",@"hostname",@"oversized",@"slow"]) {
        [JFPlaybackFixture setMode:mode]; JFClient *c=Client(); c.timeout=0.1;
        JFWorker *w=[JFWorker new]; JFMockPlaybackBackend *b=[JFMockPlaybackBackend new]; JFPlaybackController *p=[[JFPlaybackController alloc] initWithClient:c worker:w backend:b];
        CHECK([p playItem:@"movie1" startTicks:0]); CHECK(Wait(^BOOL { return [p.currentState isEqual:@"failed"]; })); CHECK(b.starts==0);
        if ([mode isEqual:@"401"]) CHECK(!c.hasSession && [p.errorKind isEqual:@"authentication"]);
        if (![mode isEqual:@"401"]) {
            [JFPlaybackFixture setMode:@"normal"];
            CHECK([p playItem:@"movie1" startTicks:0]); CHECK(Wait(^BOOL { return b.starts==1; }));
            [b emit:@"started" ticks:0]; CHECK([p.currentState isEqual:@"playing"]);
            CHECK([p stop]); CHECK([p.currentState isEqual:@"stopped"]);
        }
        [p close]; [p release]; [w cancelAll]; [w release]; [b release];
    }
    // Actual controller/native failure ladder: DP -> video/audio copy-only remux
    // -> transcode. Archived must NOT change on failure; TV episodes do qualify.
    for (NSString *mode in @[@"fallback-movie",@"fallback-tv",@"fallback-archived"]) {
        [JFPlaybackFixture setMode:mode];
        JFWorker *fw=[JFWorker new]; JFMockPlaybackBackend *fb=[JFMockPlaybackBackend new];
        JFPlaybackController *fp=[[JFPlaybackController alloc] initWithClient:Client() worker:fw backend:fb];
        CHECK([fp playItem:@"movie1" startTicks:100]);
        CHECK(Wait(^BOOL { return fb.starts==1; }));
        CHECK([fb.lastRequest.URL.absoluteString containsString:@"Static=true"]);
        [fb emit:@"failure" ticks:100];
        if ([mode isEqual:@"fallback-archived"]) {
            CHECK([fp.currentState isEqual:@"failed"]);
            CHECK(fb.starts==1);
        } else {
            CHECK(Wait(^BOOL { return fb.starts==2; }));
            CHECK([fb.lastRequest.URL.query containsString:@"VideoCodec=copy"]);
            CHECK([fb.lastRequest.URL.query containsString:@"AudioCodec=copy"]);
            CHECK([fb.lastRequest.URL.query containsString:@"AllowVideoStreamCopy=true"]);
            [fb emit:@"failure" ticks:100];
            CHECK(Wait(^BOOL { return fb.starts==3; }));
            CHECK([fb.lastRequest.URL.query containsString:@"VideoCodec=h264"]);
            CHECK([fb.lastRequest.URL.query containsString:@"AudioCodec=aac"]);
            CHECK([fb.lastRequest.URL.query containsString:@"AllowVideoStreamCopy=false"]);
            [fb emit:@"failure" ticks:100];
            CHECK([fp.currentState isEqual:@"failed"] && fb.starts==3);
        }
        [fp close];[fp release];[fw cancelAll];[fw release];[fb release];
    }
    [JFPlaybackFixture setMode:@"slow"];
    worker=[JFWorker new]; backend=[JFMockPlaybackBackend new]; controller=[[JFPlaybackController alloc] initWithClient:Client() worker:worker backend:backend];
    CHECK([controller playItem:@"movie1" startTicks:0]); CHECK(Wait(^BOOL { return [JFPlaybackFixture lastBody]!=nil; })); CHECK([controller stop]); CHECK([controller.currentState isEqual:@"stopped"]); CHECK(backend.starts==0);
    [controller close]; [controller release]; [worker cancelAll]; [worker release]; [backend release];
    [JFPlaybackFixture setMode:@"normal"];
    worker=[JFWorker new]; backend=[JFMockPlaybackBackend new]; controller=[[JFPlaybackController alloc] initWithClient:Client() worker:worker backend:backend];
    CHECK([controller playItem:@"movie1" startTicks:0]); CHECK(Wait(^BOOL { return backend.starts==1; })); [backend emit:@"started" ticks:0];
    __block JFPlaybackController *closing=controller;
    controller.progressCallback=^(long long ticks) { [closing close]; [closing release]; closing=nil; };
    [backend emit:@"progress" ticks:1000]; CHECK(!closing); [backend emit:@"ended" ticks:2000];
    [worker cancelAll]; [worker release]; [backend release];
    // 401 during reporting invalidates authentication and closes active playback.
    [JFPlaybackFixture setMode:@"report401"];
    client=Client(); worker=[JFWorker new]; backend=[JFMockPlaybackBackend new];
    controller=[[JFPlaybackController alloc] initWithClient:client worker:worker backend:backend];
    CHECK([controller playItem:@"movie1" startTicks:0]); CHECK(Wait(^BOOL { return backend.starts==1; }));
    [backend emit:@"started" ticks:0]; CHECK(Wait(^BOOL { return [controller.currentState isEqual:@"failed"]; })); CHECK(!client.hasSession);
    CHECK([controller.errorKind isEqual:@"authentication"]);
    [controller close]; [controller release]; [worker cancelAll]; [worker release]; [backend release];
    // Logout cancels setup before clearing the shared client on its serial worker.
    [JFPlaybackFixture setMode:@"slow"]; client=Client();
    JFSession *session=[[JFSession alloc] initWithOwnedClient:client]; backend=[JFMockPlaybackBackend new];
    CHECK([session configurePlaybackBackend:backend]); CHECK([session.playback playItem:@"movie1" startTicks:0]);
    CHECK(Wait(^BOOL { return [JFPlaybackFixture lastBody]!=nil; }));
    CHECK([session logout]); CHECK(Wait(^BOOL { return !session.busy; })); CHECK(!client.hasSession); CHECK(backend.starts==0);
    CHECK([session.playback.currentState isEqual:@"stopped"]);
    [session close]; [session release]; [backend release];
    // Failure callback may release its owner; captured callbacks remain inert afterwards.
    [JFPlaybackFixture setMode:@"normal"]; worker=[JFWorker new]; backend=[JFMockPlaybackBackend new];
    controller=[[JFPlaybackController alloc] initWithClient:Client() worker:worker backend:backend];
    CHECK([controller playItem:@"movie1" startTicks:0]); CHECK(Wait(^BOOL { return backend.starts==1; }));
    late=[[backend capturedEvent] copy]; __block JFPlaybackController *failing=controller;
    controller.failureCallback=^(NSString *kind) { [failing close]; [failing release]; failing=nil; };
    [backend emit:@"failure" ticks:0]; CHECK(!failing); late(@"started",0); late(@"ended",0); [late release];
    [worker cancelAll]; [worker release]; [backend release];
    // Subtitle selection changes server negotiation; no device renderer is asserted.
    [JFPlaybackFixture setMode:@"normal"]; client=Client();
    CHECK(![client playbackInfo:@"movie1" startTicks:0 subtitleIndex:2 error:&error]);
    CHECK([client playbackInfo:@"movie1" startTicks:0 mediaSourceID:@"source1" audioIndex:-1 subtitleIndex:2 error:&error]);
    CHECK(![[JFPlaybackFixture lastBody][@"EnableDirectPlay"] boolValue]);
    CHECK([[JFPlaybackFixture lastBody][@"AlwaysBurnInSubtitleWhenTranscoding"] boolValue]);
    [atvManagerSingleton release]; atvManagerSingleton=nil; [atvLastAsset release]; atvLastAsset=nil; [atvLastPlayer release]; atvLastPlayer=nil; [atvLastController release]; atvLastController=nil; [atvStreamingType release]; atvStreamingType=nil;
    printf("PASS: %u playback/subtitle assertions\n",checks);
} return 0; }
