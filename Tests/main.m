#import <Foundation/Foundation.h>
#import "API/JFClient.h"
#import "API/JFServerURL.h"
#import "API/JFWorker.h"
#import "Navigation/JFBrowser.h"
#import "Navigation/JFMovieMetadata.h"
#import "Navigation/JFSeriesMetadata.h"
#import "Navigation/JFDetailMetadata.h"
#import "Input/JFRemote.h"
#import "BackRow/JFBackRow.h"
#import <objc/runtime.h>
#import "JFDeviceABIFixture.h"
static int checks;
static int popped;
@interface JFMockEvent : NSObject
@property int remoteAction, value;
@property unsigned int originator;
@end
@implementation JFMockEvent
@end
@interface JFMockStack : NSObject
- (void)popController;
@end
@implementation JFMockStack
- (void)popController { popped++; }
@end
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { NSLog(@"FAIL line %d: %s",__LINE__,#__VA_ARGS__); exit(1); } } while(0)
// Explicit test doubles, NOT private interface declarations or firmware evidence.
@interface JFMockAppliance : NSObject
- (id)initWithApplianceInfo:(id)info;
- (id)applianceCategories;
- (id)controllerForIdentifier:(id)i args:(id)a;
- (id)applianceController;
@end
@implementation JFMockAppliance
- (id)initWithApplianceInfo:(id)info { return [super init]; }
- (id)applianceCategories { return nil; }
- (id)controllerForIdentifier:(id)i args:(id)a { return nil; }
- (id)applianceController { return nil; }
@end
@interface JFMockController : NSObject
- (BOOL)brEventAction:(id)e;
- (id)stack;
@end
@implementation JFMockController
- (BOOL)brEventAction:(id)e {
    if ([e isKindOfClass:[JFMockEvent class]]) {
        JFMockEvent *remote=(JFMockEvent *)e;
        if (remote.originator==1 && remote.remoteAction==1 && remote.value==1) return YES;
    }
    return NO;
}
- (id)stack { return [[[JFMockStack alloc] init] autorelease]; }
@end
// Scripted API for deterministic navigation, separate from HTTP transport coverage.
@interface JFNavigationClient : JFClient
@property(nonatomic, retain) NSArray *items;
@property(nonatomic) BOOL expired, failed, overlapPages;
@property(nonatomic) NSUInteger pageRequests, totalItems;
@end
@implementation JFNavigationClient
- (NSArray *)libraries:(NSError **)error {
    if (error) *error=nil;
    if (_expired || _failed) {
        if (error) *error=[NSError errorWithDomain:@"Fixture" code:_expired ? 401 : 500 userInfo:nil];
        return nil;
    }
    return _items;
}
- (NSArray *)itemsInLibrary:(NSString *)parent type:(NSString *)type start:(NSUInteger)start limit:(NSUInteger)limit error:(NSError **)error {
    if (error) *error=nil;
    _pageRequests++;
    if (_failed || _expired) { if (error) *error=[NSError errorWithDomain:@"Fixture" code:_expired ? 401 : 500 userInfo:nil]; return nil; }
    NSUInteger total=_totalItems ?: 101;
    NSUInteger actualStart=(_overlapPages && start>0) ? start-1 : start;
    NSMutableArray *result=[NSMutableArray array];
    for (NSUInteger i=actualStart;i<MIN(actualStart+limit,total);i++)
        [result addObject:@{@"Id":[NSString stringWithFormat:@"%@%lu",[type isEqual:@"Series"] ? @"series" : @"movie",(unsigned long)i],
                            @"Name":[type isEqual:@"Series"] ? @"Series" : @"Movie",@"Type":type}];
    return result;
}
- (NSDictionary *)item:(NSString *)identifier error:(NSError **)error {
    if (error) *error=nil;
    if (_failed || _expired) { if (error) *error=[NSError errorWithDomain:@"Fixture" code:_expired ? 401 : 500 userInfo:nil]; return nil; }
    return @{@"Id":identifier,@"Name":@"Movie",@"Type":@"Movie"};
}
- (BOOL)hasSession { return !_expired; }
- (void)dealloc { [_items release]; [super dealloc]; }
@end
int main(int argc,char **argv) { @autoreleasepool {
    NSDictionary *addresses=@{
        @"  HTTPS://Example.COM:443/jellyfin///  ":@"https://example.com/jellyfin",
        @"http://192.168.1.2:8096/jellyfin/":@"http://192.168.1.2:8096/jellyfin",
        @"example.com:8920/base/path/":@"https://example.com:8920/base/path",
        @"http://localhost:80/":@"http://localhost",
        @"https://[::1]:8920/jellyfin/":@"https://[::1]:8920/jellyfin",
        @"https://example.com/a%20b/":@"https://example.com/a%20b"};
    for (NSString *input in addresses) {
        NSError *error=nil; CHECK([JFNormalizeServerAddress(input,&error) isEqual:addresses[input]] && !error);
    }
    for (NSString *input in @[@"",@"https://",@"ftp://example.com",@"https:/example.com",@"http://user:pw@example.com",
         @"https://example.com?key=x",@"https://example.com#fragment",@"http://example.com:",@"http://example.com:0",
         @"http://example.com:65536",@"http://example.com:abc",@"http://999.1.2.3",@"https://bad host",@"https://a..b",
         @"https://-bad.example",@"https://example.com/../base",@"https://example.com/%2e%2e/",@"https://example.com/%GG",
         @"https://example.com/%00",@"https://example.com/a%2f../",@"https://example.com/\\evil"]) {
        NSError *error=nil; CHECK(!JFNormalizeServerAddress(input,&error) && error!=nil);
    }
    CHECK(argc==2);
    if (strcmp(argv[1], "http://fixture.invalid")==0) [NSURLProtocol registerClass:NSClassFromString(@"JFFixtureProtocol")];
    CHECK(!JFRegisterBackRowClasses());
    JFRegisterCategoryFixture();
    objc_registerClassPair(objc_allocateClassPair([JFMockAppliance class],"BRBaseAppliance",0));
    objc_registerClassPair(objc_allocateClassPair([JFMockController class],"BRController",0));
    CHECK(JFRegisterBackRowClasses()); CHECK(JFRegisterBackRowClasses());
    CHECK(class_getSuperclass(objc_getClass("JellyfinAppliance"))==objc_getClass("BRBaseAppliance"));
    JFMockController *controller=[[[objc_getClass("JellyfinController") alloc] init] autorelease];
    JFMockEvent *event=[[[JFMockEvent alloc] init] autorelease];
    event.originator=1; event.value=1; event.remoteAction=1;
    CHECK([controller brEventAction:event]); CHECK(popped==0);
    event.value=0; CHECK([controller brEventAction:event]); CHECK(popped==0);
    event.remoteAction=999; event.value=1; CHECK(![controller brEventAction:event]);
    CHECK(![controller brEventAction:[NSObject new]]);
    event.remoteAction=3; event.originator=2; CHECK(![controller brEventAction:event]);
    JFRemote *r=[[[JFRemote alloc] init] autorelease];
    NSInteger actions[]={3,4,6,7,5,1}; NSInteger buttons[]={JFUp,JFDown,JFLeft,JFRight,JFSelect,JFMenu};
    for(int i=0;i<6;i++) {
        NSDictionary *e=[r action:actions[i] value:1 time:1]; CHECK([[e objectForKey:@"button"] integerValue]==buttons[i]); CHECK([[e objectForKey:@"phase"] isEqual:@"press"]);
        CHECK([[[r action:actions[i] value:1 time:1.7] objectForKey:@"phase"] isEqual:@"hold"]);
        CHECK([[[r action:actions[i] value:0 time:2] objectForKey:@"phase"] isEqual:@"release"]);
    }
    CHECK(![r action:999 value:1 time:3]); CHECK(![r action:3 value:0 time:3]);
    for (NSNumber *a in @[@2,@8,@9,@22,@23,@24]) { CHECK([[[r action:[a integerValue] value:1 time:4] objectForKey:@"phase"] isEqual:@"hold"] || [[[r action:[a integerValue] value:1 time:4] objectForKey:@"phase"] isEqual:@"repeat"]); [r action:[a integerValue] value:0 time:5]; }
    NSDictionary *movieMeta=JFMovieMetadata(@{
        @"Name":@"Example", @"ProductionYear":@1999, @"RunTimeTicks":@1000,
        @"UserData":@{@"Played":@NO,@"PlaybackPositionTicks":@420},
        @"ImageTags":@{@"Primary":@"tag1"}});
    CHECK([movieMeta[@"name"] isEqual:@"Example"] && [movieMeta[@"year"] integerValue]==1999);
    CHECK(![movieMeta[@"watched"] boolValue] && [movieMeta[@"resumePercent"] integerValue]==42);
    CHECK([movieMeta[@"primaryImageTag"] isEqual:@"tag1"]);
    CHECK([JFMovieRowTitle(@{@"Name":@"Example",@"ProductionYear":@1999,@"RunTimeTicks":@1000,
                             @"UserData":@{@"Played":@NO,@"PlaybackPositionTicks":@420}})
           isEqual:@"Example  1999"]);
    CHECK([JFMovieRowTitle(@{@"Name":@"Seen",@"ProductionYear":@2001,
                             @"UserData":@{@"Played":@YES,@"PlaybackPositionTicks":@500}})
           isEqual:@"Seen  2001"]);
    CHECK([JFMovieRowTitle(@{@"Name":@"Fallback",@"ProductionYear":@"bad",@"RunTimeTicks":@100,
                             @"UserData":@{@"Played":@2,@"PlaybackPositionTicks":@500},
                             @"ImageTags":@"bad"})
           isEqual:@"Fallback"]);
    CHECK([JFMovieRowTitle(@{@"Name":@"Percent",@"UserData":@{@"PlayedPercentage":@12.9}})
           isEqual:@"Percent"]);
    CHECK([JFMovieRowTitle(@{@"Name":@"Done",@"RunTimeTicks":@100,@"UserData":@{@"PlaybackPositionTicks":@100}})
           isEqual:@"Done"]);
    CHECK([JFSeasonRowTitle(@{@"Name":@"Season 1",@"IndexNumber":@1}) isEqual:@"Season 1"]);
    CHECK([JFSeasonRowTitle(@{@"IndexNumber":@0}) isEqual:@"Season 0"]);
    CHECK([JFEpisodeRowTitle(@{@"Name":@"Pilot",@"ParentIndexNumber":@1,@"IndexNumber":@2}) isEqual:@"S01E02  Pilot"]);
    CHECK([JFEpisodeRowTitle(@{@"Name":@"Special",@"IndexNumber":@3}) isEqual:@"E03  Special"]);
    CHECK([JFEpisodeRowTitle(@{@"Name":@"Fallback",@"ParentIndexNumber":@"bad",@"IndexNumber":@NO}) isEqual:@"Fallback"]);
    NSDictionary *detailMeta=@{@"Name":@"Example",@"Type":@"Movie",@"ProductionYear":@1999,@"RunTimeTicks":@61200000000LL,@"CommunityRating":@8.25,@"OfficialRating":@"R",@"Genres":@[@"Drama",@"Crime",@"Drama"]};
    CHECK([JFDetailTitle(detailMeta) isEqual:@"Example  1999"]);
    CHECK([JFDetailFacts(detailMeta) isEqual:@"1999  •  1h 42m  •  8.2/10  •  R"]);
    CHECK([JFDetailGenres(detailMeta) isEqual:@"Drama, Crime"]);
    CHECK([JFDetailTitle(@{@"Name":@"Pilot",@"Type":@"Episode",@"ParentIndexNumber":@1,@"IndexNumber":@2}) isEqual:@"S01E02  Pilot"]);
    CHECK(JFDetailFacts(@{@"RunTimeTicks":@0,@"CommunityRating":@11})==nil);
    CHECK(JFDetailGenres(@{@"Genres":@[@1,@""]})==nil);
    CHECK([JFDetailTitle(nil) isEqual:@"Jellyfin — Details"]);
    CHECK([JFDetailTitle(@{@"Name":@"No Year",@"Type":@"Movie",@"ProductionYear":@"bad"}) isEqual:@"No Year"]);
    CHECK([JFDetailTitle(@{@"Name":@"Special",@"Type":@"Episode",@"IndexNumber":@3}) isEqual:@"E03  Special"]);
    CHECK([JFDetailFacts(@{@"RunTimeTicks":@300000000LL}) isEqual:@"1 min"]);
    CHECK([JFDetailFacts(@{@"CommunityRating":@0,@"OfficialRating":@"PG"}) isEqual:@"0.0/10  •  PG"]);
    CHECK([JFDetailFacts(@{@"CustomRating":@"PG-13"}) isEqual:@"PG-13"]);
    CHECK([JFDetailFacts(@{@"OfficialRating":@"R",@"CustomRating":@"PG-13"}) isEqual:@"R"]);
    CHECK(JFDetailFacts(@{@"OfficialRating":@"",@"CustomRating":@""})==nil);
    CHECK(JFDetailFacts(@{@"ProductionYear":@YES,@"RunTimeTicks":@NO,@"CommunityRating":@NO,@"OfficialRating":@""})==nil);
    CHECK([JFDetailGenres(@{@"Genres":@[@"Drama",@1,@"Drama",@"Comedy"]}) isEqual:@"Drama, Comedy"]);

    CHECK(![[[JFClient alloc] initWithURL:[NSURL URLWithString:@"file:///tmp"] deviceID:@"test"] autorelease]);
    CHECK(![[[JFClient alloc] initWithURL:[NSURL URLWithString:@"https://example.com"] deviceID:@"bad\"id"] autorelease]);
    NSString *base=[NSString stringWithUTF8String:argv[1]];
    JFClient *c=[[[JFClient alloc] initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/jellyfin"]] deviceID:@"test-device"] autorelease];
    NSError *error=nil; CHECK(![c libraries:&error] && error.code==1004);
    CHECK([[[c serverInfo:&error] objectForKey:@"ServerName"] isEqual:@"测试服务器"]);
    CHECK([c login:@"测试用户" password:@"p\"ass" error:&error]);
    CHECK([[c currentUser:&error][@"PrimaryImageTag"] isEqual:@"tag001"]);
    NSData *latestAvatar=[c freshCurrentAvatarWithTag:@"tag001" width:180 error:&error];
    CHECK(latestAvatar.length>0);
    CHECK(![c freshCurrentAvatarWithTag:@"../../bad" width:180 error:&error] && error.code==1007);
    NSArray *items=[c libraries:&error]; CHECK(items.count==1); CHECK([[[items objectAtIndex:0] objectForKey:@"Name"] isEqual:@"电影"]);
    CHECK(![c login:@"bad" password:@"x" error:&error] && error.code==401); CHECK(![c libraries:&error]);
    CHECK(![c login:@"shape" password:@"x" error:&error] && error.code==1003);
    for (NSString *path in @[@"invalid",@"array",@"http500",@"redirect",@"disconnect"]) {
        JFClient *f=[[[JFClient alloc] initWithURL:[NSURL URLWithString:[base stringByAppendingFormat:@"/%@",path]] deviceID:@"test"] autorelease];
        error=nil; CHECK(![f serverInfo:&error]); CHECK(error!=nil);
    }
    CHECK([c login:@"empty" password:@"x" error:&error]); CHECK([[c libraries:&error] count]==0);
    CHECK([c login:@"items" password:@"x" error:&error]); CHECK(![c libraries:&error] && error.code==1006);
    [c logout]; CHECK(![c libraries:&error]);
    JFBrowser *browser=[[[JFBrowser alloc] initWithClient:c] autorelease];
    CHECK(browser.page==JFLoginPage && browser.index==NSNotFound);
    CHECK(![browser refresh:&error] && browser.page==JFLoginPage);
    CHECK([browser login:@"测试用户" password:@"p\"ass" error:&error]);
    CHECK(browser.page==JFLibrariesPage && browser.libraries.count==1);
    CHECK([[browser.selectedLibrary objectForKey:@"Id"] isEqual:@"lib1"]);
    CHECK([browser handleEvent:@{@"button":@(JFSelect),@"phase":@"press"}] && browser.page==JFLibraryPage);
    CHECK(![browser handleEvent:@{@"button":@(JFMenu),@"phase":@"release"}] && browser.page==JFLibraryPage);
    CHECK([browser handleEvent:@{@"button":@(JFMenu),@"phase":@"press"}] && browser.page==JFLibrariesPage);
    CHECK(![browser handleEvent:@{@"button":@(JFMenu),@"phase":@"press"}]);
    CHECK(![browser login:@"bad" password:@"x" error:&error] && browser.page==JFLoginPage && !browser.selectedLibrary);
    CHECK([browser login:@"empty" password:@"x" error:&error] && browser.index==NSNotFound);
    CHECK(![browser handleEvent:@{@"button":@(JFSelect),@"phase":@"press"}]);
    CHECK(![browser login:@"items" password:@"x" error:&error] && browser.page==JFLibrariesPage && error.code==1006);
    [browser logout]; CHECK(browser.page==JFLoginPage && ![c hasSession]);
    JFNavigationClient *nc=[[[JFNavigationClient alloc] initWithURL:[NSURL URLWithString:@"http://fixture.invalid"] deviceID:@"test"] autorelease];
    nc.items=@[@{@"Id":@"a",@"Name":@"A"},@{@"Id":@"b",@"Name":@"B"}];
    JFBrowser *nav=[[[JFBrowser alloc] initWithClient:nc] autorelease];
    CHECK([nav refresh:&error] && nav.index==0);
    CHECK([nav handleEvent:@{@"button":@(JFUp),@"phase":@"press"}] && nav.index==0);
    CHECK([nav handleEvent:@{@"button":@(JFDown),@"phase":@"repeat"}] && nav.index==1);
    CHECK([nav handleEvent:@{@"button":@(JFDown),@"phase":@"hold"}] && nav.index==1);
    CHECK(![nav handleEvent:@{@"button":@(JFUp),@"phase":@"release"}] && nav.index==1);
    CHECK(![nav handleEvent:@{@"button":@"bad",@"phase":@"press"}]);
    CHECK(![nav handleEvent:@{@"button":@(JFSelect),@"phase":@"repeat"}]);
    CHECK([nav refresh:&error] && nav.index==1);
    nc.items=@[nc.items[1],nc.items[0]];
    CHECK([nav refresh:&error] && nav.index==0 && [[nav.selectedLibrary objectForKey:@"Id"] isEqual:@"b"]);
    nc.items=@[@{@"Id":@"c",@"Name":@"C"}];
    CHECK([nav refresh:&error] && nav.index==0);
    nc.failed=YES; CHECK(![nav refresh:&error] && error.code==500 && nav.page==JFLibrariesPage && [[nav.selectedLibrary objectForKey:@"Id"] isEqual:@"c"]);
    nc.failed=NO; CHECK([nav refresh:&error] && !error);
    nc.expired=YES; CHECK(![nav refresh:&error] && error.code==401 && nav.page==JFLoginPage && !nav.selectedLibrary);
    CHECK(![[[JFBrowser alloc] initWithClient:nil] autorelease]);
    CHECK([c login:@"测试用户" password:@"p\"ass" error:&error]);
    for (NSString *type in @[@"Movie",@"Series"]) {
        NSArray *media=[c itemsInLibrary:@"lib1" type:type start:0 limit:1 error:&error];
        CHECK(media.count==1 && [[media[0] objectForKey:@"Type"] isEqual:type]);
        CHECK([[c itemsInLibrary:@"lib1" type:type start:1 limit:1 error:&error] count]==0 && !error);
    }
    CHECK([[c seasons:@"series1" error:&error] count]==1);
    CHECK([[c episodes:@"series1" season:@"season1" error:&error] count]==1);
    CHECK([[[c item:@"movie1" error:&error] objectForKey:@"Overview"] isEqual:@"Detail"]);
    CHECK([[[c item:@"episode1" error:&error] objectForKey:@"Type"] isEqual:@"Episode"]);
    CHECK([[[c playbackInfo:@"movie1" error:&error] objectForKey:@"MediaSources"] count]==1);
    CHECK(![c playbackInfo:@"broken" error:&error] && error.code==1008);
    CHECK(![c item:@"broken" error:&error] && error.code==1006);
    CHECK(![c seasons:@"broken" error:&error] && error.code==1006);
    CHECK(![c itemsInLibrary:@"lib1" type:@"Audio" start:0 limit:1 error:&error] && error.code==1007);
    CHECK(![c itemsInLibrary:@"lib1" type:@"Movie" start:0 limit:0 error:&error] && error.code==1007);
    for (NSString *identifier in @[@"",@"..",@"a/b",@"a?x=1",@"https://other.invalid"]) CHECK(![c item:identifier error:&error] && error.code==1007);
    NSURLRequest *poster=[c posterRequest:@"movie1" width:300 error:&error];
    CHECK([poster.URL.path isEqual:@"/jellyfin/Items/movie1/Images/Primary"] && [poster.URL.query isEqual:@"MaxWidth=300"]);
    CHECK([[poster valueForHTTPHeaderField:@"Authorization"] containsString:@"Token=\"fixture-token\""] && ![poster valueForHTTPHeaderField:@"X-Emby-Token"] && ![poster.URL.absoluteString containsString:@"fixture-token"]);
    CHECK(![c posterRequest:@"movie1" width:0 error:&error]);
    NSURLRequest *stream=[c streamRequest:@"movie1" mediaSource:@"source1" error:&error];
    CHECK([stream.URL.path isEqual:@"/jellyfin/Videos/movie1/stream"] && [stream.URL.query isEqual:@"Static=true&MediaSourceId=source1"]);
    CHECK(![c streamRequest:@"movie1" mediaSource:@"../bad" error:&error]);
    CHECK(![c seasons:@"denied" error:&error] && error.code==401 && !c.hasSession);
    CHECK(![c posterRequest:@"movie1" width:300 error:&error] && error.code==1004);
    CHECK([c login:@"测试用户" password:@"p\"ass" error:&error]);
    CHECK([browser login:@"测试用户" password:@"p\"ass" error:&error]);
    CHECK([browser openLibraryWithType:@"Movie" error:&error] && browser.page==JFMediaPage && browser.media.count==1);
    NSDictionary *oldSnapshot=[[browser snapshot] retain];
    CHECK([browser openMediaAtIndex:0 error:&error] && browser.page==JFDetailPage && [browser.detail[@"Id"] isEqual:@"movie1"]);
    CHECK([oldSnapshot[@"media"] count]==1 && [oldSnapshot[@"page"] integerValue]==JFMediaPage); [oldSnapshot release];
    CHECK([browser goBack] && browser.page==JFMediaPage && browser.mediaIndex==0);
    CHECK([browser goBack] && browser.page==JFLibrariesPage);
    CHECK(![browser goBack]);
    CHECK([browser openLibraryWithType:@"Series" error:&error]);
    CHECK(![browser openMediaAtIndex:99 error:&error] && error.code==1007 && browser.page==JFMediaPage);
    CHECK([browser openMediaAtIndex:0 error:&error] && browser.page==JFSeasonsPage);
    CHECK([browser openMediaAtIndex:0 error:&error] && browser.page==JFEpisodesPage);
    CHECK([browser openMediaAtIndex:0 error:&error] && browser.page==JFDetailPage);
    CHECK([browser handleEvent:@{@"button":@(JFMenu),@"phase":@"press"}] && browser.page==JFEpisodesPage);
    CHECK([browser goBack] && browser.page==JFSeasonsPage);
    CHECK([browser goBack] && browser.page==JFMediaPage);
    [browser logout]; CHECK(browser.media.count==0 && !browser.detail && ![browser goBack]);
    CHECK([c login:@"测试用户" password:@"p\"ass" error:&error]);
    nc.expired=NO; nc.failed=NO; nc.totalItems=101; CHECK([nav refresh:&error]);
    NSUInteger requests=nc.pageRequests;
    CHECK([nav openLibraryWithType:@"Movie" error:&error] && nav.media.count==101);
    CHECK(nc.pageRequests==requests+2); // 101-item lookahead, then final page.
    CHECK([nav openMediaAtIndex:100 error:&error] && nav.page==JFDetailPage);
    CHECK([nav goBack] && nav.mediaIndex==100 && nav.media.count==101);
    CHECK([nav goBack]); // Media -> Libraries
    nc.failed=YES;
    CHECK(![nav openLibraryWithType:@"Movie" error:&error] && error.code==500);
    CHECK(nav.page==JFLibrariesPage && nav.media.count==0);
    nc.failed=NO;

    // A library with exactly 100 records has no second request or hidden items.
    nc.totalItems=100; nc.overlapPages=NO;
    requests=nc.pageRequests;
    CHECK([nav openLibraryWithType:@"Movie" error:&error] && nav.media.count==100);
    CHECK(nc.pageRequests==requests+1);
    CHECK([nav goBack]);

    // Series is also fully assembled before exposing the list.
    nc.totalItems=101;
    CHECK([nav openLibraryWithType:@"Series" error:&error] && nav.media.count==101);
    CHECK([nav.media[100][@"Type"] isEqual:@"Series"]);
    CHECK([nav goBack]);

    // The final complete list deduplicates overlapping server pages.
    nc.totalItems=201; nc.overlapPages=YES;
    requests=nc.pageRequests;
    CHECK([nav openLibraryWithType:@"Movie" error:&error] && nav.media.count==201);
    CHECK(nc.pageRequests==requests+3);
    NSMutableSet *pageIDs=[NSMutableSet set];
    for (NSDictionary *item in nav.media) [pageIDs addObject:item[@"Id"]];
    CHECK(pageIDs.count==nav.media.count);
    nc.overlapPages=NO;
    // Progressive grid: publish only first visible ten movies, then deliver
    // additional pages without losing IDs, sort order, or back navigation.
    CHECK([nav goBack] && nav.page==JFLibrariesPage);
    requests=nc.pageRequests;
    CHECK([nav openFirstLibraryScreenWithType:@"Movie" error:&error]);
    CHECK(nav.page==JFMediaPage && nav.media.count==10 && nav.hasRemainingLibraryItems);
    CHECK(nc.pageRequests==requests+1);
    CHECK([nav appendNextLibraryChunk:&error] && nav.media.count==110);
    CHECK([nav appendNextLibraryChunk:&error] && nav.media.count==201);
    CHECK(!nav.hasRemainingLibraryItems && ![nav appendNextLibraryChunk:&error]);
    CHECK([nav.media[200][@"Id"] isEqual:@"movie200"]);
    CHECK([nav goBack] && nav.page==JFLibrariesPage);
    // Restore the Media navigation state expected by the next auth expiry test.
    CHECK([nav openLibraryWithType:@"Movie" error:&error]);

    nc.expired=YES;
    CHECK(![nav openMediaAtIndex:0 error:&error] && error.code==401 && nav.page==JFLoginPage && !nav.media.count && ![nav goBack]);
    JFClient *large=[[[JFClient alloc] initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/oversize"]] deviceID:@"test"] autorelease];
    CHECK(![large serverInfo:&error] && error.code==413);
    JFWorker *worker=[JFWorker new];
    __block BOOL delivered=NO;
    [worker perform:^id(NSError **e) { return [c serverInfo:e]; } completion:^(id result,NSError *e) {
        CHECK([NSThread isMainThread] && !e && [result objectForKey:@"ServerName"]); delivered=YES;
    }];
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:3];
    while (!delivered && [end timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(delivered);
    JFClient *slow=[[[JFClient alloc] initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/slow"]] deviceID:@"test"] autorelease];
    slow.timeout=0.1; delivered=NO;
    [worker perform:^id(NSError **e) { return [slow serverInfo:e]; } completion:^(id result,NSError *e) {
        CHECK(!result && e.code==NSURLErrorTimedOut); delivered=YES;
    }];
    end=[NSDate dateWithTimeIntervalSinceNow:3];
    while (!delivered && [end timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(delivered);
    slow.timeout=5;
    JFTask *task=[worker perform:^id(NSError **e) { return [slow serverInfo:e]; } completion:^(id result,NSError *e) { CHECK(NO); }];
    end=[NSDate dateWithTimeIntervalSinceNow:2];
    while (!task.executing && !task.finished && [end timeIntervalSinceNow]>0) [NSThread sleepForTimeInterval:0.005];
    [task cancel];
    end=[NSDate dateWithTimeIntervalSinceNow:1];
    while (!task.finished && [end timeIntervalSinceNow]>0) [NSThread sleepForTimeInterval:0.005];
    CHECK(task.finished);
    // Cancel after work finishes but before the main queue delivers the result.
    task=[worker perform:^id(NSError **e) { return @"late"; } completion:^(id result,NSError *e) { CHECK(NO); }];
    [task waitUntilFinished]; [task cancel];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    task=[worker perform:^id(NSError **e) { return @"late"; } completion:^(id result,NSError *e) { CHECK(NO); }];
    [task waitUntilFinished]; [worker cancelAll];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    CHECK(task.cancelled);
    // Release the UI's client reference immediately: copied work owns it safely.
    JFClient *temporary=[[JFClient alloc] initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/jellyfin"]] deviceID:@"test"];
    delivered=NO;
    [worker perform:^id(NSError **e) { return [temporary serverInfo:e]; } completion:^(id result,NSError *e) { CHECK(result && !e); delivered=YES; }];
    [temporary release];
    end=[NSDate dateWithTimeIntervalSinceNow:3];
    while (!delivered && [end timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(delivered);
    // A queued task cancelled before execution must not run its work or callback.
    NSCondition *gate=[NSCondition new]; __block BOOL gateOpen=NO;
    JFTask *blocker=[worker perform:^id(NSError **e) { [gate lock]; while (!gateOpen) [gate wait]; [gate unlock]; return nil; } completion:nil];
    JFTask *queued=[worker perform:^id(NSError **e) { CHECK(NO); return nil; } completion:^(id result,NSError *e) { CHECK(NO); }];
    [queued cancel]; [gate lock]; gateOpen=YES; [gate signal]; [gate unlock];
    [blocker waitUntilFinished]; [queued waitUntilFinished]; CHECK(queued.cancelled);
    [gate release];
    [worker release];
    // Image download + real ImageIO validation; no cached credentials or URL metadata.
    NSString *cachePath=[@"build" stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    JFImageCache *cache=[[[JFImageCache alloc] initWithDirectory:cachePath ttl:60] autorelease];
    CHECK(cache);
    NSData *pixel=[NSData dataWithContentsOfFile:@"Tests/pixel.png"];
    CHECK(JFValidImage(pixel)); CHECK(!JFValidImage([@"bad" dataUsingEncoding:NSUTF8StringEncoding]));
    [cache storeData:pixel forKey:@"test-key"];
    CHECK([[cache dataForKey:@"test-key"] isEqual:pixel]);
    [cache purgeMemory]; CHECK([[cache dataForKey:@"test-key"] isEqual:pixel]);
    NSArray *files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:cachePath error:NULL];
    CHECK(files.count==1 && [files[0] length]==64);
    [cache invalidate]; CHECK(![cache dataForKey:@"test-key"]);
    // Persistent 1 GiB ATV cache: stable lookups across distinct instances,
    // fixed on-disk priority names, and same-pool JSON metadata.
    NSString *poolPath=[cachePath stringByAppendingString:@"-persistent"];
    JFImageCache *pool=[[[JFImageCache alloc]initPersistentWithDirectory:poolPath capacityBytes:1024ULL*1024*1024] autorelease];
    CHECK(pool);
    [pool storeData:pixel forKey:@"cover" priority:0];
    [pool storeData:pixel forKey:@"archivedBackdrop" priority:2];
    NSData *summary=[@"{\"Items\":[]}" dataUsingEncoding:NSUTF8StringEncoding];
    [pool storeMetadata:summary forKey:@"metadata"];
    files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:poolPath error:NULL];
    NSUInteger covers=0,archived=0,metadata=0;
    for(NSString *entry in files) {
        if(entry.length==65 && [entry hasPrefix:@"0"])covers++;
        if(entry.length==65 && [entry hasPrefix:@"2"])archived++;
        if(entry.length==66 && [entry hasPrefix:@"3m"])metadata++;
    }
    CHECK(covers==1 && archived==1 && metadata==1);
    JFImageCache *reopened=[[[JFImageCache alloc]initPersistentWithDirectory:poolPath capacityBytes:1024ULL*1024*1024] autorelease];
    CHECK([[reopened dataForKey:@"cover"] isEqual:pixel]);
    CHECK([[reopened dataForKey:@"archivedBackdrop"] isEqual:pixel]);
    CHECK([[reopened metadataForKey:@"metadata"] isEqual:summary]);
    CHECK([[reopened freshMetadataForKey:@"metadata" maxAge:3600] isEqual:summary]);
    NSString *metadataPath=nil;
    for(NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:poolPath error:NULL])
        if([name hasPrefix:@"3m"]){metadataPath=[poolPath stringByAppendingPathComponent:name];break;}
    CHECK(metadataPath!=nil);
    [[NSFileManager defaultManager] setAttributes:@{
        NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-5400]}
        ofItemAtPath:metadataPath error:NULL];
    CHECK([reopened freshMetadataForKey:@"metadata" maxAge:3600]==nil);
    CHECK([[reopened freshMetadataForKey:@"metadata" maxAge:14400] isEqual:summary]);
    CHECK([[reopened freshMetadataForKey:@"metadata" maxAge:86400] isEqual:summary]);
    [pool invalidate];CHECK([[reopened dataForKey:@"cover"] isEqual:pixel]);
    [[NSFileManager defaultManager] removeItemAtPath:poolPath error:NULL];
    CHECK([c login:@"测试用户" password:@"p\"ass" error:&error]);
    CHECK([[c imageData:@"movie1" backdrop:NO width:320 cache:cache error:&error] isEqual:pixel] && !error);
    CHECK([[c imageData:@"movie1" backdrop:NO width:320 cache:cache error:&error] isEqual:pixel]);
    [cache purgeMemory];
    CHECK([[c imageData:@"movie1" backdrop:NO width:320 cache:cache error:&error] isEqual:pixel]);
    CHECK([[c imageData:@"movie1" backdrop:YES width:1280 cache:cache error:&error] isEqual:pixel]);
    CHECK(![c imageData:@"broken" backdrop:NO width:320 cache:cache error:&error] && error.code==1009);
    CHECK(![c imageData:@"retry" backdrop:NO width:320 cache:cache error:&error] && error.code==503);
    CHECK([[c imageData:@"retry" backdrop:NO width:320 cache:cache error:&error] isEqual:pixel] && !error);
    CHECK(![c imageData:@"movie1" backdrop:YES width:0 cache:cache error:&error] && error.code==1007);
    CHECK(![c imageData:@"expired" backdrop:NO width:320 cache:cache error:&error] && error.code==401);
    CHECK(!c.hasSession);
    CHECK([[[NSFileManager defaultManager] contentsOfDirectoryAtPath:cachePath error:NULL] count]==0);
    CHECK(![c imageData:@"movie1" backdrop:NO width:320 cache:cache error:&error] && error.code==1004);
    JFImageCache *shortCache=[[[JFImageCache alloc] initWithDirectory:cachePath ttl:0.01] autorelease];
    [shortCache storeData:pixel forKey:@"expires"]; [NSThread sleepForTimeInterval:0.02];
    CHECK(![shortCache dataForKey:@"expires"]);
    [shortCache storeData:pixel forKey:@"corrupt"]; [shortCache purgeMemory];
    files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:cachePath error:NULL];
    [@"broken" writeToFile:[cachePath stringByAppendingPathComponent:files[0]] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    CHECK(![shortCache dataForKey:@"corrupt"]);
    [[NSFileManager defaultManager] removeItemAtPath:cachePath error:NULL];
    printf("PASS: %d assertions (runtime mocks, remote input, request/response transport, JSON)\n",checks);
} return 0; }
