#import <Foundation/Foundation.h>
#import "Navigation/JFSession.h"
#import "Navigation/JFBrowser.h"
#import "API/JFClient.h"
// Test-only ownership seam, deliberately absent from the public session header.
@interface JFSession (Testing)
- (id)initWithOwnedClient:(JFClient *)client;
@end
static int checks, destroyed;
#define CHECK(...) do { __sync_fetch_and_add(&checks,1); if (!(__VA_ARGS__)) { NSLog(@"FAIL line %d: %s",__LINE__,#__VA_ARGS__); exit(1); } } while(0)
static void PumpUntil(BOOL (^done)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!done() && deadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(done());
}
static void Idle(JFSession *session) { PumpUntil(^BOOL { return !session.busy; }); }
@interface ScriptClient : JFClient {
    NSCondition *_gate;
    BOOL _started, _unblocked, _session, _reverseLibraries, _blockLibraries, _pagedMedia, _posterMedia, _posterFailure;
    NSString *_name;
    NSInteger _failure;
    NSUInteger _clears, _remoteSignOuts, _imageRequests;
}
- (void)unblock;
- (BOOL)started;
- (void)failNext:(NSInteger)code;
- (void)setReverseLibraries:(BOOL)value;
- (void)blockNextLibraries;
- (void)setPagedMedia:(BOOL)value;
- (void)setPosterMedia:(BOOL)value;
- (void)setPosterFailure:(BOOL)value;
- (NSUInteger)imageRequests;
- (NSUInteger)clears;
- (NSUInteger)remoteSignOuts;
@end
@implementation ScriptClient
- (id)init {
    if ((self=[super initWithURL:[NSURL URLWithString:@"https://fixture.invalid"] deviceID:@"test-device"])) _gate=[NSCondition new];
    return self;
}
- (BOOL)login:(NSString *)name password:(NSString *)password error:(NSError **)error {
    CHECK(![NSThread isMainThread]);
    [_gate lock];
    if ([name isEqual:@"blocked"]) { _started=YES; [_gate broadcast]; while (!_unblocked) [_gate wait]; }
    [_gate unlock];
    [_name release]; _name=[name copy];
    if ([name isEqual:@"bad"]) { *error=[NSError errorWithDomain:@"Jellyfin" code:401 userInfo:@{NSLocalizedDescriptionKey:@"SECRET"}]; return NO; }
    _session=YES; return YES;
}
- (BOOL)authenticateToken:(NSString *)token error:(NSError **)error {
    CHECK(![NSThread isMainThread]);
    [_name release]; _name=[@"restored" copy];
    if ([token isEqual:@"offline"]) {
        _session=NO; *error=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]; return NO;
    }
    if (![token isEqual:@"script-token"]) {
        _session=NO; *error=[NSError errorWithDomain:@"Jellyfin" code:401 userInfo:nil]; return NO;
    }
    _session=YES; return YES;
}
- (NSString *)sessionToken { return _session ? @"script-token" : nil; }
- (BOOL)endSession:(NSError **)error {
    CHECK(![NSThread isMainThread]); _remoteSignOuts++; [self logout]; return YES;
}
- (BOOL)hasSession { return _session; }
- (NSArray *)libraries:(NSError **)error {
    CHECK(![NSThread isMainThread]);
    [_gate lock];
    if (_blockLibraries) {
        _started=YES; [_gate broadcast];
        while (!_unblocked) [_gate wait];
        _blockLibraries=NO;
    }
    NSInteger failure=_failure; _failure=0; BOOL reverse=_reverseLibraries;
    [_gate unlock];
    if ([_name isEqual:@"libfail"]) failure=500;
    if (failure) {
        if (failure==401) [self logout];
        *error=[NSError errorWithDomain:@"Jellyfin" code:failure userInfo:@{NSLocalizedDescriptionKey:@"SECRET"}]; return nil;
    }
    NSDictionary *one=@{@"Id":@"lib1",@"Name":_name ?: @"one"};
    NSDictionary *two=@{@"Id":@"lib2",@"Name":@"two"};
    return reverse ? @[two,one] : @[one,two];
}
- (NSArray *)itemsInLibrary:(NSString *)parent type:(NSString *)type start:(NSUInteger)start limit:(NSUInteger)limit error:(NSError **)error {
    CHECK(![NSThread isMainThread]);
    if (_pagedMedia) {
        NSMutableArray *items=[NSMutableArray array];
        for (NSUInteger i=start;i<MIN(start+limit,150);i++)
            [items addObject:@{@"Id":[NSString stringWithFormat:@"movie%lu",(unsigned long)i],@"Name":@"Movie",@"Type":@"Movie"}];
        return items;
    }
    if ([type isEqual:@"Series"]) {
        if (_posterMedia) return @[@{@"Id":@"series1",@"Name":@"Series",@"Type":@"Series",@"ProductionYear":@2020,@"ImageTags":@{@"Primary":@"s1"}}];
        return @[];
    }
    if (_posterMedia) return @[
        @{@"Id":@"movie1",@"Name":@"Movie",@"Type":@"Movie",@"ProductionYear":@1999,
          @"RunTimeTicks":@1000,@"UserData":@{@"Played":@NO,@"PlaybackPositionTicks":@420},@"ImageTags":@{@"Primary":@"p1"}},
        @{@"Id":@"movie2",@"Name":@"Movie 2",@"Type":@"Movie",@"ProductionYear":@2002,
          @"RunTimeTicks":@1000,@"UserData":@{@"Played":@YES},@"ImageTags":@{@"Primary":@"p2"}}
    ];
    return @[@{@"Id":@"movie1",@"Name":@"Movie",@"Type":@"Movie"},@{@"Id":@"movie2",@"Name":@"Movie 2",@"Type":@"Movie"}];
}
- (NSData *)imageData:(NSString *)identifier backdrop:(BOOL)backdrop width:(NSUInteger)width cache:(JFImageCache *)cache error:(NSError **)error {
    CHECK(![NSThread isMainThread]);
    [_gate lock]; _imageRequests++; BOOL fail=_posterFailure; [_gate unlock];
    if (fail) {
        if (error) *error=[NSError errorWithDomain:@"Jellyfin" code:500 userInfo:nil];
        return nil;
    }
    return [[NSString stringWithFormat:@"poster-%@",identifier] dataUsingEncoding:NSUTF8StringEncoding];
}
- (NSArray *)seasons:(NSString *)series error:(NSError **)error {
    CHECK(![NSThread isMainThread]);
    [_gate lock]; NSInteger failure=_failure; _failure=0; [_gate unlock];
    if (failure) {
        if (failure==401) [self logout];
        if (error) *error=[NSError errorWithDomain:@"Jellyfin" code:failure userInfo:nil];
        return nil;
    }
    if (![series isEqual:@"series1"]) return @[];
    return @[
        @{@"Id":@"season1",@"Name":@"Season 1",@"Type":@"Season"},
        @{@"Id":@"season2",@"Name":@"Season 2",@"Type":@"Season",@"ImageTags":@{@"Primary":@"sp2"}}
    ];
}
- (NSArray *)episodes:(NSString *)series season:(NSString *)season error:(NSError **)error {
    CHECK(![NSThread isMainThread]);
    [_gate lock]; NSInteger failure=_failure; _failure=0; [_gate unlock];
    if (failure) {
        if (failure==401) [self logout];
        if (error) *error=[NSError errorWithDomain:@"Jellyfin" code:failure userInfo:nil];
        return nil;
    }
    if (![series isEqual:@"series1"] || ![@[@"season1",@"season2"] containsObject:season]) return @[];
    NSString *suffix=[season isEqual:@"season2"] ? @"2" : @"1";
    return @[
        @{@"Id":[@"episode" stringByAppendingFormat:@"%@a",suffix],@"Name":@"Episode 1",@"Type":@"Episode",@"ImageTags":@{@"Primary":@"ep1"}},
        @{@"Id":[@"episode" stringByAppendingFormat:@"%@b",suffix],@"Name":@"Episode 2",@"Type":@"Episode",@"ImageTags":@{@"Primary":@"ep2"}}
    ];
}
- (NSDictionary *)item:(NSString *)identifier error:(NSError **)error {
    CHECK(![NSThread isMainThread]);
    [_gate lock]; NSInteger failure=_failure; _failure=0; [_gate unlock];
    if (failure) {
        if (failure==401) [self logout];
        if (error) *error=[NSError errorWithDomain:@"Jellyfin" code:failure userInfo:nil];
        return nil;
    }
    BOOL episode=[identifier hasPrefix:@"episode"];
    return @{@"Id":identifier,@"Name":episode ? @"Episode" : @"Movie",@"Type":episode ? @"Episode" : @"Movie",
        @"MediaSources":@[@{@"Id":@"source1",@"MediaStreams":@[
            @{@"Type":@"Audio",@"Index":@5,@"Codec":@"aac",@"Language":@"eng",@"Title":@"Original",@"Channels":@2,@"SampleRate":@48000,@"IsDefault":@YES},
            @{@"Type":@"Audio",@"Index":@6,@"Codec":@"ac3",@"Language":@"zho",@"Title":@"Dub",@"Channels":@2,@"SampleRate":@48000,@"IsDefault":@NO},
            @{@"Type":@"Subtitle",@"Index":@7,@"Codec":@"subrip",@"Language":@"zh-hans",@"Title":@"Chinese Simplified",@"IsExternal":@YES,@"IsDefault":@YES,@"IsForced":@NO},
            @{@"Type":@"Subtitle",@"Index":@8,@"Codec":@"pgssub",@"Language":@"eng",@"Title":@"English PGS",@"IsExternal":@NO,@"IsDefault":@NO,@"IsForced":@NO}
        ]}]};
}
- (void)logout { if (_gate) CHECK(![NSThread isMainThread]); _session=NO; [_gate lock]; _clears++; [_gate unlock]; }
- (BOOL)started { [_gate lock]; BOOL v=_started; [_gate unlock]; return v; }
- (void)unblock { [_gate lock]; _unblocked=YES; [_gate broadcast]; [_gate unlock]; }
- (void)failNext:(NSInteger)code { [_gate lock]; _failure=code; [_gate unlock]; }
- (void)setReverseLibraries:(BOOL)value { [_gate lock]; _reverseLibraries=value; [_gate unlock]; }
- (void)blockNextLibraries { [_gate lock]; _started=NO; _unblocked=NO; _blockLibraries=YES; [_gate unlock]; }
- (void)setPagedMedia:(BOOL)value { [_gate lock]; _pagedMedia=value; [_gate unlock]; }
- (void)setPosterMedia:(BOOL)value { [_gate lock]; _posterMedia=value; [_gate unlock]; }
- (void)setPosterFailure:(BOOL)value { [_gate lock]; _posterFailure=value; [_gate unlock]; }
- (NSUInteger)imageRequests { [_gate lock]; NSUInteger v=_imageRequests; [_gate unlock]; return v; }
- (NSUInteger)clears { [_gate lock]; NSUInteger v=_clears; [_gate unlock]; return v; }
- (NSUInteger)remoteSignOuts { [_gate lock]; NSUInteger v=_remoteSignOuts; [_gate unlock]; return v; }
- (void)dealloc { @synchronized([ScriptClient class]) { destroyed++; } [_gate release]; _gate=nil; [_name release]; _name=nil; [super dealloc]; }
@end
static JFSession *NewSession(ScriptClient **outClient) {
    ScriptClient *client=[ScriptClient new];
    JFSession *session=[[JFSession alloc] initWithOwnedClient:client];
    *outClient=client; return session;
}
static NSInteger Page(JFSession *s) { return [s.snapshot[@"page"] integerValue]; }
int main(void) { @autoreleasepool {
    @autoreleasepool {
    CHECK(![[JFSession alloc] initWithURL:[NSURL URLWithString:@"http://fixture.invalid"] deviceID:@"test" allowHTTP:NO]);
    CHECK(![[JFSession alloc] initWithURL:[NSURL URLWithString:@"file:///bad"] deviceID:@"test" allowHTTP:YES]);
    ScriptClient *client; JFSession *session=NewSession(&client);
    __block NSUInteger deliveries=0;
    id observer=[[NSNotificationCenter defaultCenter] addObserverForName:JFSessionChanged object:session queue:nil usingBlock:^(NSNotification *n) {
        CHECK([NSThread isMainThread]); deliveries++;
        CHECK(![[[n object] errorKind] containsString:@"SECRET"]);
    }];
    CHECK(Page(session)==JFLoginPage && !session.busy);
    CHECK(![session refresh]); CHECK(![session login:@"" password:@""]);
    CHECK([session login:@"bad" password:@"SECRET"]); CHECK(session.busy);
    CHECK(![session refresh]); Idle(session);
    CHECK(Page(session)==JFLoginPage && [session.errorKind isEqual:@"authentication"]);
    CHECK(session.sessionToken==nil);
    CHECK([session login:@"libfail" password:@""]); Idle(session);
    CHECK(Page(session)==JFLibrariesPage && [session.errorKind isEqual:@"request"]);
    CHECK([session login:@"good" password:@""]); Idle(session);
    CHECK([session.snapshot[@"libraries"] count]==2);
    CHECK([session.sessionToken isEqual:@"script-token"]);
    CHECK([session handleEvent:@{@"button":@(JFDown),@"phase":@"press"}]); Idle(session);
    CHECK([session.snapshot[@"index"] integerValue]==1);
    // Refresh tracks focus by library ID, not by the old row number.
    [client setReverseLibraries:YES];
    CHECK([session refresh]); Idle(session);
    CHECK([session.snapshot[@"index"] integerValue]==0 && [session.snapshot[@"libraries"][0][@"Id"] isEqual:@"lib2"]);
    // A transient refresh failure preserves the last good list and focus.
    [client failNext:500]; CHECK([session refresh]); Idle(session);
    CHECK(Page(session)==JFLibrariesPage && [session.errorKind isEqual:@"request"]);
    CHECK([session.snapshot[@"libraries"] count]==2 && [session.snapshot[@"index"] integerValue]==0);
    CHECK([session openLibraryWithType:@"Movie"]); CHECK(![session openLibraryWithType:@"Series"]); Idle(session);
    CHECK(Page(session)==JFMediaPage);
    CHECK(![session openMediaAtIndex:20]); CHECK([session openMediaAtIndex:1]); Idle(session);
    CHECK(Page(session)==JFDetailPage && [session.snapshot[@"detail"][@"Id"] isEqual:@"movie2"]);
    CHECK([session audioTrackCount]==2); CHECK([[session audioSelectionLabel] containsString:@"Original"]);
    CHECK([session subtitleTrackCount]==1); CHECK([[session subtitleSelectionLabel] isEqual:@"Subtitles: Off"]);
    CHECK([session cycleSubtitleTrack]); CHECK([[session subtitleSelectionLabel] containsString:@"Chinese Simplified"]);
    // PGS is intentionally filtered out: only local-text SRT is selectable.
    CHECK([session subtitleTrackCount]==1);
    CHECK([session cycleSubtitleTrack]); CHECK([[session subtitleSelectionLabel] isEqual:@"Subtitles: Off"]);
    CHECK([session cycleSubtitleTrack]); CHECK([[session subtitleSelectionLabel] containsString:@"Chinese Simplified"]);
    CHECK([session cycleSubtitleTrack]); CHECK([[session subtitleSelectionLabel] isEqual:@"Subtitles: Off"]);
    CHECK([session cycleAudioTrack]); CHECK([[session audioSelectionLabel] containsString:@"Dub"]);
    CHECK([session goBack]); Idle(session);
    CHECK(Page(session)==JFMediaPage && [session.snapshot[@"mediaIndex"] integerValue]==1);
    CHECK([session goBack]); Idle(session); CHECK(Page(session)==JFLibrariesPage);
    CHECK(![session goBack]);
    // Mixed/unknown libraries may still use the explicit type chooser.
    CHECK([session handleEvent:@{@"button":@(JFSelect),@"phase":@"press"}]); Idle(session);
    CHECK(Page(session)==JFLibraryPage);
    CHECK([session openLibraryWithType:@"Series"]); Idle(session);
    CHECK(Page(session)==JFMediaPage && [session.snapshot[@"media"] count]==0 && [session.snapshot[@"mediaIndex"] integerValue]==NSNotFound);
    CHECK(![session refresh]); // Library refresh is root-only.
    CHECK([session goBack]); Idle(session); CHECK(Page(session)==JFLibraryPage);
    CHECK([session openLibraryWithType:@"Movie"]); Idle(session); CHECK(Page(session)==JFMediaPage);
    CHECK([session goBack]); Idle(session); CHECK(Page(session)==JFLibraryPage);
    CHECK([session goBack]); Idle(session); CHECK(Page(session)==JFLibrariesPage);
    [client failNext:401]; CHECK([session refresh]); Idle(session);
    CHECK(Page(session)==JFLoginPage && [session.snapshot[@"libraries"] count]==0);
    CHECK([session.errorKind isEqual:@"authentication"] && session.sessionToken==nil);
    CHECK([session login:@"good" password:@""]); Idle(session);
    [client failNext:NSURLErrorTimedOut]; CHECK([session refresh]); Idle(session);
    CHECK([session.errorKind isEqual:@"timeout"] && Page(session)==JFLibrariesPage);
    CHECK([session.sessionToken isEqual:@"script-token"]);
    CHECK([session logout]); CHECK(Page(session)==JFLoginPage && session.busy && session.sessionToken==nil); Idle(session);
    CHECK(![session refresh]); CHECK(deliveries>10);
    CHECK([session authenticateToken:@"script-token"]); Idle(session);
    CHECK(Page(session)==JFLibrariesPage && [session.sessionToken isEqual:@"script-token"]);
    CHECK([session signOut]); Idle(session);
    CHECK(Page(session)==JFLoginPage && session.sessionToken==nil && client.remoteSignOuts==1);
    CHECK([session authenticateToken:@"expired"]); Idle(session);
    CHECK(Page(session)==JFLoginPage && [session.errorKind isEqual:@"authentication"] && session.sessionToken==nil);
    CHECK([session authenticateToken:@"offline"]); Idle(session);
    CHECK(Page(session)==JFLoginPage && [session.errorKind isEqual:@"transport"] && session.sessionToken==nil);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [session close]; CHECK(session.closed && !session.busy);
    CHECK(![session login:@"good" password:@""]); CHECK(![session logout]); CHECK(![session handleEvent:@{}]);
    [session close]; [session release]; [client release];

    // A running old login intentionally ignores cancellation and mutates its model.
    // The following login must clear it serially and be the only delivered result.
    session=NewSession(&client);
    CHECK([session login:@"blocked" password:@""]); PumpUntil(^BOOL { return client.started; });
    CHECK([session login:@"latest" password:@""]); [client unblock]; Idle(session);
    CHECK([session.snapshot[@"libraries"][0][@"Name"] isEqual:@"latest"]);
    [session close]; [session release]; [client release];

    session=NewSession(&client);
    CHECK([session login:@"blocked" password:@""]); PumpUntil(^BOOL { return client.started; });
    CHECK([session logout]); [client unblock]; Idle(session);
    CHECK(Page(session)==JFLoginPage && client.clears>=2);
    [session close]; [session release]; [client release];

    // Close while authentication is in flight: no late notification or mutation of UI.
    session=NewSession(&client);
    __block NSUInteger afterClose=0;
    observer=[[NSNotificationCenter defaultCenter] addObserverForName:JFSessionChanged object:session queue:nil usingBlock:^(NSNotification *n) { afterClose++; }];
    CHECK([session login:@"blocked" password:@""]); PumpUntil(^BOOL { return client.started; });
    NSUInteger beforeClose=afterClose, beforeClears=client.clears;
    [session close]; CHECK(session.closed && Page(session)==JFLoginPage);
    CHECK(![session refresh] && ![session login:@"late" password:@""]);
    [client unblock]; PumpUntil(^BOOL { return client.clears>beforeClears; });
    CHECK(afterClose==beforeClose && Page(session)==JFLoginPage);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [session release]; [client release];

    // Close while a library refresh is in flight: stale completion must not republish.
    session=NewSession(&client);
    CHECK([session login:@"good" password:@""]); Idle(session);
    __block NSUInteger refreshAfterClose=0;
    observer=[[NSNotificationCenter defaultCenter] addObserverForName:JFSessionChanged object:session queue:nil usingBlock:^(NSNotification *n) { refreshAfterClose++; }];
    [client blockNextLibraries]; CHECK([session refresh]); PumpUntil(^BOOL { return client.started; });
    NSUInteger refreshBeforeClose=refreshAfterClose, refreshBeforeClears=client.clears;
    [session close]; CHECK(session.closed && Page(session)==JFLoginPage);
    [client unblock]; PumpUntil(^BOOL { return client.clears>refreshBeforeClears; });
    CHECK(refreshAfterClose==refreshBeforeClose && Page(session)==JFLoginPage);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [session release]; [client release];

    // Release without explicit close still invalidates delivery and keeps cleanup alive.
    session=NewSession(&client);
    CHECK([session login:@"blocked" password:@""]); PumpUntil(^BOOL { return client.started; });
    NSUInteger clears=client.clears;
    [session release]; [client unblock];
    PumpUntil(^BOOL { return client.clears>clears; });
    [client release];

    // Opening a library preloads all server pages and preserves media focus.
    session=NewSession(&client); [client setPagedMedia:YES];
    CHECK([session login:@"good" password:@""]); Idle(session);
    CHECK([session openLibraryWithType:@"Movie"]); Idle(session);
    CHECK([session.snapshot[@"media"] count]==150);
    CHECK([session handleEvent:@{@"button":@(JFDown),@"phase":@"press"}]); Idle(session);
    CHECK([session.snapshot[@"mediaIndex"] integerValue]==1);
    CHECK([session.snapshot[@"media"] count]==150);
    CHECK([session focusMediaAtIndex:149]); Idle(session);
    CHECK([session.snapshot[@"mediaIndex"] integerValue]==149);
    [session close]; [session release]; [client release];

    // Low-priority movie poster loading follows focus and never blocks/fails browsing.
    session=NewSession(&client); [client setPosterMedia:YES];
    CHECK([session login:@"good" password:@""]); Idle(session);
    CHECK([session openLibraryWithType:@"Movie"]); Idle(session);
    PumpUntil(^BOOL { return session.posterData.length>0; });
    CHECK([session.posterItemID isEqual:@"movie1"] && client.imageRequests==1);
    CHECK([session handleEvent:@{@"button":@(JFDown),@"phase":@"press"}]); Idle(session);
    PumpUntil(^BOOL { return [session.posterItemID isEqual:@"movie2"] && session.posterData.length>0; });
    CHECK(client.imageRequests==2 && [session.snapshot[@"mediaIndex"] integerValue]==1);
    CHECK([session openMediaAtIndex:1]); Idle(session);
    CHECK(Page(session)==JFDetailPage && [session.posterItemID isEqual:@"movie2"] && session.posterData.length>0);
    CHECK([session goBack]); Idle(session);
    CHECK(Page(session)==JFMediaPage && [session.posterItemID isEqual:@"movie2"] && session.posterData.length>0);
    [session close]; [session release]; [client release];

    // Async Series -> Seasons -> Episodes -> Detail preserves focus at every level.
    session=NewSession(&client); [client setPosterMedia:YES];
    CHECK([session login:@"good" password:@""]); Idle(session);
    CHECK([session openLibraryWithType:@"Series"]); Idle(session);
    CHECK(Page(session)==JFMediaPage && [session.snapshot[@"mediaIndex"] integerValue]==0);
    PumpUntil(^BOOL { return [session.posterItemID isEqual:@"series1"] && session.posterData.length>0; });
    CHECK([session openMediaAtIndex:0]); Idle(session);
    CHECK(Page(session)==JFSeasonsPage && [session.snapshot[@"media"] count]==2 && [session.snapshot[@"mediaIndex"] integerValue]==0);
    PumpUntil(^BOOL { return [session.posterItemID isEqual:@"season1"] && session.posterData.length>0; });
    NSString *seasonFallbackData=[[[NSString alloc] initWithData:session.posterData encoding:NSUTF8StringEncoding] autorelease];
    CHECK([seasonFallbackData isEqual:@"poster-series1"]);
    CHECK([session.snapshot[@"seriesID"] isEqual:@"series1"]);
    CHECK([session handleEvent:@{@"button":@(JFDown),@"phase":@"press"}]); Idle(session);
    CHECK([session.snapshot[@"mediaIndex"] integerValue]==1);
    PumpUntil(^BOOL { return [session.posterItemID isEqual:@"season2"] && session.posterData.length>0; });
    NSString *seasonOwnData=[[[NSString alloc] initWithData:session.posterData encoding:NSUTF8StringEncoding] autorelease];
    CHECK([seasonOwnData isEqual:@"poster-season2"]);
    CHECK([session openMediaAtIndex:1]); Idle(session);
    CHECK(Page(session)==JFEpisodesPage && [session.snapshot[@"media"] count]==2 && [session.snapshot[@"mediaIndex"] integerValue]==0);
    PumpUntil(^BOOL { return [session.posterItemID isEqual:@"episode2a"] && session.posterData.length>0; });
    CHECK([session handleEvent:@{@"button":@(JFDown),@"phase":@"press"}]); Idle(session);
    CHECK([session.snapshot[@"mediaIndex"] integerValue]==1);
    PumpUntil(^BOOL { return [session.posterItemID isEqual:@"episode2b"] && session.posterData.length>0; });
    CHECK([session openMediaAtIndex:1]); Idle(session);
    CHECK(Page(session)==JFDetailPage && [session.snapshot[@"detail"][@"Type"] isEqual:@"Episode"]);
    CHECK([session.posterItemID isEqual:@"episode2b"] && session.posterData.length>0);
    CHECK([session goBack]); Idle(session);
    CHECK(Page(session)==JFEpisodesPage && [session.snapshot[@"mediaIndex"] integerValue]==1 && [session.snapshot[@"media"] count]==2);
    CHECK([session goBack]); Idle(session);
    CHECK(Page(session)==JFSeasonsPage && [session.snapshot[@"mediaIndex"] integerValue]==1 && [session.snapshot[@"media"] count]==2);
    CHECK([session goBack]); Idle(session);
    CHECK(Page(session)==JFMediaPage && [session.snapshot[@"mediaIndex"] integerValue]==0);
    [session close]; [session release]; [client release];

    // A transient Series child request failure preserves the last good page and focus.
    session=NewSession(&client); [client setPosterMedia:YES];
    CHECK([session login:@"good" password:@""]); Idle(session);
    CHECK([session openLibraryWithType:@"Series"]); Idle(session);
    CHECK([session openMediaAtIndex:0]); Idle(session);
    CHECK([session handleEvent:@{@"button":@(JFDown),@"phase":@"press"}]); Idle(session);
    NSArray *stableSeasons=[[session.snapshot[@"media"] copy] autorelease];
    [client failNext:500]; CHECK([session openMediaAtIndex:1]); Idle(session);
    CHECK(Page(session)==JFSeasonsPage && [session.errorKind isEqual:@"request"]);
    CHECK([session.snapshot[@"mediaIndex"] integerValue]==1 && [session.snapshot[@"media"] isEqual:stableSeasons]);
    CHECK([session.sessionToken isEqual:@"script-token"]);
    [session close]; [session release]; [client release];

    // Authentication failure in a Series child request clears protected state.
    session=NewSession(&client); [client setPosterMedia:YES];
    CHECK([session login:@"good" password:@""]); Idle(session);
    CHECK([session openLibraryWithType:@"Series"]); Idle(session);
    [client failNext:401]; CHECK([session openMediaAtIndex:0]); Idle(session);
    CHECK(Page(session)==JFLoginPage && [session.errorKind isEqual:@"authentication"]);
    CHECK(session.sessionToken==nil && [session.snapshot[@"media"] count]==0);
    [session close]; [session release]; [client release];

    // Series library posters use the same primary-image pipeline as movies.
    session=NewSession(&client); [client setPosterMedia:YES];
    CHECK([session login:@"good" password:@""]); Idle(session);
    CHECK([session openLibraryWithType:@"Series"]); Idle(session);
    PumpUntil(^BOOL { return session.posterData.length>0; });
    CHECK([session.posterItemID isEqual:@"series1"] && client.imageRequests==1);
    CHECK([session.snapshot[@"media"][0][@"Type"] isEqual:@"Series"]);
    [session close]; [session release]; [client release];

    session=NewSession(&client); [client setPosterMedia:YES]; [client setPosterFailure:YES];
    CHECK([session login:@"good" password:@""]); Idle(session);
    CHECK([session openLibraryWithType:@"Movie"]); Idle(session);
    PumpUntil(^BOOL { return client.imageRequests==1; });
    CHECK(Page(session)==JFMediaPage && session.posterData==nil && [session.errorKind isEqual:@"none"]);
    CHECK([session.snapshot[@"media"] count]==2);
    [session close]; [session release]; [client release];

    session=NewSession(&client);
    __block BOOL finished=NO, accepted=YES;
    NSOperationQueue *queue=[NSOperationQueue new];
    [queue addOperationWithBlock:^{ BOOL result=[session login:@"wrong-thread" password:@""]; [[NSOperationQueue mainQueue] addOperationWithBlock:^{ accepted=result; finished=YES; }]; }];
    PumpUntil(^BOOL { return finished; }); CHECK(!accepted); [queue waitUntilAllOperationsAreFinished]; [queue release];
    [session close]; [session release]; [client release];
    }
    PumpUntil(^BOOL { @synchronized([ScriptClient class]) { return destroyed==14; } });
    printf("PASS: %d session assertions\n",checks);
} }
