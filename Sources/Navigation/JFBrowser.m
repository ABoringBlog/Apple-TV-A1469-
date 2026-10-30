#import "JFBrowser.h"
#import "../JFPosterTrace.h"
static const NSUInteger JFMediaPageSize=100;
// We fetch server pages privately, but never expose a partial list to BackRow.
// Fail explicitly if a server returns an unreasonable amount of data rather
// than truncating a library or exhausting Apple TV 3 memory.
static const NSUInteger JFMaxListEntries=10000;
static NSArray *JFVisiblePage(NSArray *items) {
    if (items.count<=JFMediaPageSize) return items;
    return [items subarrayWithRange:NSMakeRange(0,JFMediaPageSize)];
}
static NSArray *JFAppendUniqueMedia(NSArray *existing, NSArray *page) {
    NSMutableArray *combined=[NSMutableArray arrayWithArray:existing];
    NSMutableSet *ids=[NSMutableSet set];
    for (NSDictionary *item in existing) {
        id identifier=item[@"Id"]; if (identifier) [ids addObject:identifier];
    }
    for (NSDictionary *item in page) {
        id identifier=item[@"Id"];
        if (!identifier || [ids containsObject:identifier]) continue;
        [ids addObject:identifier]; [combined addObject:item];
    }
    return combined;
}
@implementation JFBrowser
@synthesize page=_page, index=_index, libraries=_libraries, media=_media, detail=_detail, mediaIndex=_mediaIndex;
- (BOOL)hasRemainingLibraryItems {return _libraryMore;}
- (id)initWithClient:(JFClient *)client {
    if ((self=[super init])) {
        if (!client) { [self release]; return nil; }
        _client=[client retain]; _libraries=[NSArray new]; _index=NSNotFound;
        _media=[NSArray new]; _history=[NSMutableArray new]; _mediaIndex=NSNotFound;
    } return self;
}
- (NSDictionary *)selectedLibrary {
    return _index!=NSNotFound && _index>=0 && (NSUInteger)_index<[_libraries count] ? [_libraries objectAtIndex:_index] : nil;
}
- (void)clear {
    [_libraries release]; _libraries=[NSArray new]; _index=NSNotFound;
}
- (BOOL)login:(NSString *)username password:(NSString *)password error:(NSError **)error {
    [self logout];
    if (![_client login:username password:password error:error]) return NO;
    _page=JFLibrariesPage;
    return [self refresh:error];
}
- (BOOL)authenticateToken:(NSString *)token error:(NSError **)error {
    [self logout];
    if (![_client authenticateToken:token error:error]) return NO;
    _page=JFLibrariesPage;
    return [self refresh:error];
}
- (NSString *)sessionToken { return [_client sessionToken]; }
- (BOOL)refresh:(NSError **)error {
    NSString *selectedID=[[[self selectedLibrary] objectForKey:@"Id"] copy];
    NSArray *items=[_client libraries:error];
    if (!items) {
        if (![_client hasSession]) {
            [self clearMedia]; [self clear]; _page=JFLoginPage;
        } else _page=JFLibrariesPage; // Keep the last good list/focus on transient failures.
        [selectedID release]; return NO;
    }
    [self clearMedia]; [self clear];
    [_libraries release]; _libraries=[[NSArray alloc] initWithArray:items copyItems:YES];
    _index=[items count] ? 0 : NSNotFound;
    for (NSUInteger i=0;i<[_libraries count];i++) {
        if ([[[_libraries objectAtIndex:i] objectForKey:@"Id"] isEqual:selectedID]) { _index=(NSInteger)i; break; }
    }
    [selectedID release]; _page=JFLibrariesPage; return YES;
}
- (BOOL)refreshAndScan:(NSError **)error {
    // Network worker only. Fail visibly if current Jellyfin user cannot scan.
    if (![_client requestLibraryScan:error]) return NO;
    return [self refreshUncached:error];
}
- (BOOL)refreshUncached:(NSError **)error {
    // Explicit refresh is opt-in and invalidates future catalog fast-path reads
    // for this authenticated client. Initial auto-login still uses the cache.
    _client.catalogNetworkOnly=YES;
    return [self refresh:error];
}
- (BOOL)handleEvent:(NSDictionary *)event {
    id phase=[event objectForKey:@"phase"], button=[event objectForKey:@"button"];
    if (![phase isKindOfClass:[NSString class]] || ![button isKindOfClass:[NSNumber class]]) return NO;
    NSInteger b=[button integerValue];
    BOOL press=[phase isEqual:@"press"];
    BOOL move=press || [phase isEqual:@"repeat"] || [phase isEqual:@"hold"];
    if (_page>=JFMediaPage) {
        if (b==JFMenu && press) return [self goBack];
        if (_page!=JFDetailPage && _media.count && (b==JFUp || b==JFDown) && move) {
            if (b==JFUp && _mediaIndex>0) _mediaIndex--;
            if (b==JFDown && (NSUInteger)(_mediaIndex+1)<_media.count) _mediaIndex++;
            return YES;
        }
        return NO; // Selection performs I/O: caller explicitly queues openMediaAtIndex:error:.
    }
    if (_page==JFLibraryPage && b==JFMenu && press) { _page=JFLibrariesPage; return YES; }
    if (_page!=JFLibrariesPage || ![self selectedLibrary]) return NO;
    if ((b==JFUp || b==JFDown) && move) {
        if (b==JFUp && _index>0) _index--;
        if (b==JFDown && (NSUInteger)(_index+1)<[_libraries count]) _index++;
        return YES;
    }
    if (b==JFSelect && press) { _page=JFLibraryPage; return YES; }
    return NO; // Menu at root belongs to the eventual host UI.
}
- (void)focusLibraryAtIndex:(NSUInteger)index {
    if (_page==JFLibrariesPage && index<_libraries.count) _index=(NSInteger)index;
}
- (BOOL)setDetailFlag:(NSString *)flag enabled:(BOOL)enabled error:(NSError **)error {
    if (_page!=JFDetailPage || !_detail[@"Id"] || ![@[@"Played",@"Favorite"] containsObject:flag]) return NO;
    NSString *identifier=_detail[@"Id"];
    if (![_client setUserFlag:flag item:identifier enabled:enabled error:error]) return NO;
    NSDictionary *updated=[_client item:identifier error:error];
    if (!updated) return NO;
    [_detail release];_detail=[updated copy];
    return YES;
}
- (void)clearMedia {
    [_queuedLibraryMedia release];_queuedLibraryMedia=nil;
    _libraryMore=NO;_nextLibraryOffset=0;
    [_media release]; _media=[NSArray new]; [_history removeAllObjects];
    [_detail release]; _detail=nil; [_seriesID release]; _seriesID=nil;
    [_parentID release]; _parentID=nil; [_mediaType release]; _mediaType=nil;
    _mediaIndex=NSNotFound;
}
- (NSDictionary *)snapshot {
    return @{@"page":@(_page), @"libraries":_libraries, @"index":@(_index),
             @"media":_media, @"mediaIndex":@(_mediaIndex), @"detail":_detail ?: @{},
             @"seriesID":_seriesID ?: @""};
}
- (void)push {
    [_history addObject:@{@"page":@(_page),@"media":_media,@"index":@(_mediaIndex),@"series":_seriesID ?: @""}];
}
- (BOOL)mediaFailed {
    if (![_client hasSession]) [self logout];
    return NO;
}
- (BOOL)openFirstLibraryScreenWithType:(NSString *)type error:(NSError **)error {
    if(error)*error=nil;
    NSString *ident=[[self selectedLibrary] objectForKey:@"Id"];
    if(!ident || ![@[@"Movie",@"Series"] containsObject:type])return NO;
    // Use a genuinely small first request: 10 visible items + 1 lookahead.
    // Remaining pages are appended after the UI is already interactive.
    NSTimeInterval fetchStart=[NSProcessInfo processInfo].systemUptime;
    JFPosterTrace([NSString stringWithFormat:
        @"PERF_LIBRARY_FETCH_START uptime_ms=%lld limit=11",
        (long long)(fetchStart*1000.0)]);
    NSArray *page=[_client itemsInLibrary:ident type:type
                              start:0 limit:11 error:error];
    NSTimeInterval fetchEnd=[NSProcessInfo processInfo].systemUptime;
    JFPosterTrace([NSString stringWithFormat:
        @"PERF_LIBRARY_FETCH_DONE duration_ms=%lld count=%lu error=%ld",
        (long long)((fetchEnd-fetchStart)*1000.0),
        (unsigned long)page.count,(long)(error&&*error?(*error).code:0)]);
    if(!page)return [self mediaFailed];
    NSArray *first=JFVisiblePage(page);
    NSArray *visible=[first subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)10,first.count))];
    // The eleventh item is lookahead only; the next server page starts at
    // index ten, so it must not be published as a separate one-item update.
    NSArray *deferred=@[];
    JFPage sourcePage=_page;
    [self clearMedia];_page=sourcePage;[self push];
    _parentID=[ident copy];_mediaType=[type copy];
    [_media release];_media=[JFAppendUniqueMedia(@[],visible) copy];
    _mediaIndex=_media.count?0:NSNotFound;
    _queuedLibraryMedia=[deferred copy];
    _nextLibraryOffset=10;
    _libraryMore=page.count>10;
    if(!_libraryMore)_nextLibraryOffset=NSNotFound;
    _page=JFMediaPage;
    return YES;
}
- (BOOL)appendNextLibraryChunk:(NSError **)error {
    if(error)*error=nil;
    if(!_libraryMore || _page!=JFMediaPage)return NO;
    NSArray *next=nil;
    BOOL hasNext=NO;
    if(_queuedLibraryMedia.count) {
        next=[[_queuedLibraryMedia retain] autorelease];
        [_queuedLibraryMedia release];_queuedLibraryMedia=nil;
        hasNext=_nextLibraryOffset!=NSNotFound;
    } else if(_nextLibraryOffset!=NSNotFound) {
        NSArray *probe=[_client itemsInLibrary:_parentID type:_mediaType
                 start:_nextLibraryOffset limit:JFMediaPageSize+1 error:error];
        if(!probe) {
            // Preserve already-visible movies on a transient page failure.
            _libraryMore=NO;
            return NO;
        }
        next=JFVisiblePage(probe);
        hasNext=probe.count>JFMediaPageSize;
        _nextLibraryOffset=hasNext?(_nextLibraryOffset+next.count):NSNotFound;
    } else hasNext=NO;
    if(next.count) {
        NSArray *combined=JFAppendUniqueMedia(_media,next);
        if(combined.count>JFMaxListEntries || combined.count==_media.count) {
            _libraryMore=NO;return NO;
        }
        [_media release];_media=[combined copy];
    }
    _libraryMore=hasNext;
    return YES;
}
- (BOOL)openLibraryWithType:(NSString *)type error:(NSError **)error {
    if (error) *error=nil;
    NSString *identifier=[[self selectedLibrary] objectForKey:@"Id"];
    if (!identifier) {
        if (error) *error=[NSError errorWithDomain:@"Jellyfin" code:1007
                                         userInfo:@{NSLocalizedDescriptionKey:@"No library selected"}];
        return NO;
    }
    // Jellyfin may cap the response size. Fetch every page privately on our
    // session worker before publishing one complete immutable list to BackRow.
    // A failure leaves the current page and its selection untouched.
    NSArray *combined=@[];
    NSUInteger offset=0;
    for (;;) {
        NSArray *probe=[_client itemsInLibrary:identifier type:type
                                         start:offset limit:JFMediaPageSize+1 error:error];
        if (!probe) return [self mediaFailed];
        NSArray *visible=JFVisiblePage(probe);
        NSUInteger previous=combined.count;
        combined=JFAppendUniqueMedia(combined,visible);
        if (combined.count>JFMaxListEntries || (visible.count && combined.count==previous)) {
            if (error) *error=[NSError errorWithDomain:@"Jellyfin" code:1007
                                             userInfo:@{NSLocalizedDescriptionKey:@"Invalid or oversized library listing"}];
            return NO;
        }
        if (probe.count<=JFMediaPageSize) break;
        offset+=visible.count; // Never skip the look-ahead item.
    }
    JFPage sourcePage=_page;
    [self clearMedia]; _page=sourcePage; [self push];
    _parentID=[identifier copy]; _mediaType=[type copy];
    [_media release]; _media=[combined copy]; _mediaIndex=combined.count ? 0 : NSNotFound;
    _page=JFMediaPage;
    return YES;
}
- (BOOL)openMediaAtIndex:(NSUInteger)index error:(NSError **)error {
    if (error) *error=nil;
    if (_page<JFMediaPage || _page==JFDetailPage || index>=_media.count) {
        if (error) *error=[NSError errorWithDomain:@"Jellyfin" code:1007 userInfo:@{NSLocalizedDescriptionKey:@"Invalid navigation selection"}];
        return NO;
    }
    NSDictionary *selected=_media[index]; NSString *type=selected[@"Type"], *identifier=selected[@"Id"];
    NSArray *items=nil; NSDictionary *detail=nil; JFPage next;
    if ([type isEqual:@"Series"]) { items=[_client seasons:identifier error:error]; next=JFSeasonsPage; }
    else if ([type isEqual:@"Season"]) { items=[_client episodes:_seriesID season:identifier error:error]; next=JFEpisodesPage; }
    else if ([type isEqual:@"Movie"] || [type isEqual:@"Episode"]) { detail=[_client item:identifier error:error]; next=JFDetailPage; }
    else {
        if (error) *error=[NSError errorWithDomain:@"Jellyfin" code:1007 userInfo:@{NSLocalizedDescriptionKey:@"Unsupported media type"}];
        return NO;
    }
    if (!items && !detail) return [self mediaFailed];
    _mediaIndex=index; [self push];
    if (next==JFSeasonsPage) { [_seriesID release]; _seriesID=[identifier copy]; }
    [_detail release]; _detail=[detail copy]; [_media release]; _media=items ? [items copy] : [NSArray new];
    _mediaIndex=items.count ? 0 : NSNotFound; _page=next; return YES;
}
- (BOOL)goBack {
    NSDictionary *frame=[[_history lastObject] retain];
    if (!frame) return NO;
    _page=[frame[@"page"] integerValue]; _mediaIndex=[frame[@"index"] integerValue];
    [_media release]; _media=[frame[@"media"] retain];
    [_seriesID release]; _seriesID=[frame[@"series"] copy];
    [_detail release]; _detail=nil;
    [_history removeLastObject]; [frame release]; return YES;
}
- (BOOL)signOut:(NSError **)error {
    [self clearMedia]; BOOL result=[_client endSession:error]; [self clear]; _page=JFLoginPage; return result;
}
- (void)logout { [self clearMedia]; [_client logout]; [self clear]; _page=JFLoginPage; }
- (void)dealloc {
    [_client release]; [_libraries release]; [_media release]; [_queuedLibraryMedia release]; [_history release];
    [_detail release]; [_seriesID release]; [_parentID release]; [_mediaType release]; [super dealloc];
}
@end
