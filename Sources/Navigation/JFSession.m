#import "JFSession.h"
#import "Playback/JFPlaybackTrace.h"
#import "JFPosterTrace.h"
#import "JFBrowser.h"
#import "JFMovieMetadata.h"
#import "API/JFWorker.h"
#import "Playback/JFPlaybackModel.h"
#import "Playback/JFAudio.h"
#import "Playback/JFSubtitle.h"
NSString * const JFSessionChanged = @"JFSessionChanged";
// Retained by delivery blocks, but never retains the session or host. Main thread only.
@interface JFSessionDelivery : NSObject {
@public JFSession *owner;
}
@end
@implementation JFSessionDelivery
@end
static NSDictionary *EmptySnapshot(void) {
    return @{@"page":@(JFLoginPage), @"libraries":@[], @"index":@(NSNotFound),
             @"media":@[], @"mediaIndex":@(NSNotFound), @"detail":@{}};
}
static NSString *ErrorKind(NSError *error) {
    if (!error) return @"none";
    if ([error.domain isEqual:@"Jellyfin"] && (error.code==401 || error.code==1003)) return @"authentication";
    if (([error.domain isEqual:NSURLErrorDomain] || [error.domain isEqual:@"Jellyfin"]) && error.code==NSURLErrorTimedOut) return @"timeout";
    if ([error.domain isEqual:NSURLErrorDomain]) {
        if (error.code<=NSURLErrorSecureConnectionFailed && error.code>=NSURLErrorClientCertificateRequired) return @"tls";
        return @"transport";
    }
    return @"request";
}
@interface JFSession ()
- (id)initWithOwnedClient:(JFClient *)client;
- (BOOL)submit:(void (^)(JFBrowser *, NSError **))action;
- (void)queueNextLibraryChunk;
- (BOOL)submitAuthentication:(void (^)(JFBrowser *, NSError **))action;
- (void)interruptPosterLoad;
- (void)clearPoster;
- (void)updatePosterForSnapshot;
- (void)clearAudioSelection;
- (NSArray *)audioTracksForDetail;
- (NSDictionary *)selectedAudioTrackForDetail;
- (void)clearSubtitleSelection;
- (NSArray *)subtitleTracksForDetail;
- (NSDictionary *)selectedSubtitleTrackForDetail;
- (NSDictionary *)defaultAudioTrackForSource:(NSString *)source tracks:(NSArray *)tracks;
@end
@implementation JFSession
@synthesize snapshot=_snapshot, errorKind=_errorKind, errorDomain=_errorDomain, errorCode=_errorCode, busy=_busy, closed=_closed;
- (NSString *)sessionToken { return [[_sessionToken copy] autorelease]; }
- (NSData *)posterData { return [[_posterData copy] autorelease]; }
- (NSString *)posterItemID { return [[_posterItemID copy] autorelease]; }
- (id)initWithURL:(NSURL *)url deviceID:(NSString *)deviceID allowHTTP:(BOOL)allowHTTP {
    JFClient *client=nil;
    if ([NSThread isMainThread] && (allowHTTP || [[url.scheme lowercaseString] isEqual:@"https"]))
        client=[[JFClient alloc] initWithURL:url deviceID:deviceID];
    self=[self initWithOwnedClient:client]; [client release]; return self;
}
// Internal test seam; no client/browser accessor exists in the public interface.
- (id)initWithOwnedClient:(JFClient *)client {
    if ((self=[super init])) {
        if (!client || ![NSThread isMainThread]) { [self release]; return nil; }
        _playbackClient=[client retain]; _browser=[[JFBrowser alloc] initWithClient:client]; _worker=[JFWorker new];
        NSArray *cacheDirs=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES);
        NSString *cacheRoot=cacheDirs.count ? cacheDirs[0] : NSTemporaryDirectory();
        _artworkCache=[[JFImageCache alloc] initWithDirectory:[cacheRoot stringByAppendingPathComponent:@"Jellyfin-ATV3/Posters"] ttl:7*24*60*60];
        _delivery=[JFSessionDelivery new]; _delivery->owner=self;
        _snapshot=[EmptySnapshot() copy]; _errorKind=[@"none" copy]; _audioIndex=-1; _subtitleIndex=-1;
    }
    return self;
}
- (void)publish { [[NSNotificationCenter defaultCenter] postNotificationName:JFSessionChanged object:self]; }
- (void)interruptPosterLoad {
    if (!_posterTask) return;
    [_posterTask cancel]; [_posterTask release]; _posterTask=nil; _posterGeneration++;
    if (!_posterData) { [_posterItemID release]; _posterItemID=nil; }
}
- (void)clearPoster {
    [self interruptPosterLoad];
    [_posterData release]; _posterData=nil;
    [_posterItemID release]; _posterItemID=nil;
    _posterGeneration++;
}
- (void)setVisualArtworkMode:(BOOL)enabled {
    if(![NSThread isMainThread] || _closed)return;
    if(_visualArtworkMode==enabled)return;
    _visualArtworkMode=enabled;
    if(enabled) {
        // The new photo grid fetches from the independent Mac artwork queue.
        // Don't enqueue the obsolete 360px poster on the SAME serial worker
        // as navigation/authentication. That caused multi-second Select lag.
        [self interruptPosterLoad];
        [_posterData release];_posterData=nil;
        [_posterItemID release];_posterItemID=nil;
    }
}
- (void)updatePosterForSnapshot {
    NSInteger page=[_snapshot[@"page"] integerValue];
    if(_visualArtworkMode &&
       [@[@(JFMediaPage),@(JFSeasonsPage),@(JFEpisodesPage)] containsObject:@(page)]) {
        [self interruptPosterLoad];
        return;
    }
    BOOL posterPage=[@[@(JFMediaPage),@(JFSeasonsPage),@(JFEpisodesPage)] containsObject:@(page)];
    if (!posterPage) {
        JFPosterTrace([NSString stringWithFormat:@"POSTER_SKIP page=%ld",(long)page]);
        [self interruptPosterLoad];
        if (page!=JFDetailPage) { [_posterData release]; _posterData=nil; [_posterItemID release]; _posterItemID=nil; }
        return;
    }
    NSArray *items=_snapshot[@"media"]; NSInteger index=[_snapshot[@"mediaIndex"] integerValue];
    if (index<0 || index==(NSInteger)NSNotFound || (NSUInteger)index>=items.count) {
        JFPosterTrace(@"POSTER_CLEAR invalid-selection"); [self clearPoster]; return;
    }
    NSDictionary *item=items[(NSUInteger)index];
    if (![@[@"Movie",@"Series",@"Season",@"Episode"] containsObject:item[@"Type"]] || ![item[@"Id"] isKindOfClass:[NSString class]]) {
        JFPosterTrace(@"POSTER_CLEAR unsupported-type-or-id"); [self clearPoster]; return;
    }
    NSString *identifier=item[@"Id"];
    NSDictionary *meta=JFMovieMetadata(item);
    BOOL hasPrimary=[meta[@"primaryImageTag"] isKindOfClass:[NSString class]];
    BOOL seasonFallback=NO;
    NSString *sourceID=identifier;
    if (!hasPrimary && [item[@"Type"] isEqual:@"Season"]) {
        NSString *seriesID=_snapshot[@"seriesID"];
        if ([seriesID isKindOfClass:[NSString class]] && seriesID.length) {
            sourceID=seriesID; seasonFallback=YES;
        }
    }
    JFPosterTrace([NSString stringWithFormat:@"POSTER_SELECT index=%ld primary=%d seasonFallback=%d",(long)index,hasPrimary,seasonFallback]);
    if ([_posterItemID isEqual:identifier]) { JFPosterTrace(@"POSTER_SKIP same-item"); return; }

    [self clearPoster];
    _posterItemID=[identifier copy];
    if (!hasPrimary && !seasonFallback) { JFPosterTrace(@"POSTER_SKIP no-primary"); return; }

    NSUInteger posterGeneration=++_posterGeneration;
    NSInteger selectedIndex=index;
    NSString *itemID=[[identifier copy] autorelease];
    NSString *requestID=[[sourceID copy] autorelease];
    JFClient *client=_playbackClient; JFImageCache *cache=_artworkCache; JFSessionDelivery *delivery=_delivery;
    JFPosterTrace([NSString stringWithFormat:@"POSTER_REQUEST_START index=%ld width=360 fallback=%d",(long)selectedIndex,seasonFallback]);
    _posterTask=[[_worker perform:^id(NSError **error) {
        return [client imageData:requestID backdrop:NO width:360 cache:cache error:error];
    } completion:^(id result,NSError *error) {
        JFSession *session=delivery->owner;
        NSUInteger bytes=[result isKindOfClass:[NSData class]] ? [result length] : 0;
        JFPosterTrace([NSString stringWithFormat:@"POSTER_REQUEST_DONE index=%ld bytes=%lu error=%ld",(long)selectedIndex,(unsigned long)bytes,(long)error.code]);
        if (!session || session->_closed || session->_posterGeneration!=posterGeneration ||
            ![session->_posterItemID isEqual:itemID]) { JFPosterTrace(@"POSTER_CALLBACK_STALE"); return; }
        [session->_posterTask release]; session->_posterTask=nil;
        if ([error.domain isEqual:@"Jellyfin"] && error.code==401) {
            JFPosterTrace(@"POSTER_AUTH_FAILURE"); [session logout]; return;
        }
        if (![result isKindOfClass:[NSData class]] || ![result length]) {
            JFPosterTrace(@"POSTER_DATA_INVALID"); return;
        }
        [session->_posterData release]; session->_posterData=[result copy];
        JFPosterTrace([NSString stringWithFormat:@"POSTER_DATA_READY bytes=%lu",(unsigned long)[session->_posterData length]]);
        [session publish];
    }] retain];
}
- (void)clearAudioSelection {
    [_audioItemID release]; _audioItemID=nil;
    [_audioSourceID release]; _audioSourceID=nil;
    _audioIndex=-1;
}
- (NSArray *)audioTracksForDetail {
    if (_closed || [_snapshot[@"page"] integerValue]!=JFDetailPage) return @[];
    NSDictionary *detail=_snapshot[@"detail"];
    NSError *error=nil;
    NSArray *tracks=JFAudioTracks(detail[@"MediaSources"],&error);
    return tracks ?: @[];
}
- (NSDictionary *)selectedAudioTrackForDetail {
    if (_closed || [_snapshot[@"page"] integerValue]!=JFDetailPage) return nil;
    NSDictionary *detail=_snapshot[@"detail"];
    NSString *item=[detail[@"Id"] isKindOfClass:[NSString class]] ? detail[@"Id"] : nil;
    if (!item.length) return nil;
    NSArray *tracks=[self audioTracksForDetail];
    if (![_audioItemID isEqual:item]) {
        [self clearAudioSelection]; _audioItemID=[item copy];
    }
    for (NSDictionary *track in tracks)
        if ([_audioSourceID isEqual:track[@"sourceID"]] && _audioIndex==[track[@"index"] integerValue]) return track;
    NSDictionary *selected=JFAudioDefaultTrack(tracks);
    [_audioSourceID release]; _audioSourceID=[selected[@"sourceID"] copy];
    _audioIndex=selected ? [selected[@"index"] integerValue] : -1;
    return selected;
}
- (NSDictionary *)defaultAudioTrackForSource:(NSString *)source tracks:(NSArray *)tracks {
    if (!JFMediaID(source) || ![tracks isKindOfClass:[NSArray class]]) return nil;
    NSDictionary *first=nil;
    for (NSDictionary *track in tracks) {
        if (![track[@"sourceID"] isEqual:source]) continue;
        if (!first) first=track;
        if ([track[@"default"] boolValue]) return track;
    }
    return first;
}
- (void)clearSubtitleSelection {
    [_subtitleItemID release]; _subtitleItemID=nil;
    [_subtitleSourceID release]; _subtitleSourceID=nil;
    _subtitleIndex=-1;
}
- (NSArray *)subtitleTracksForDetail {
    if (_closed || [_snapshot[@"page"] integerValue]!=JFDetailPage) return @[];
    NSError *error=nil;
    NSArray *tracks=JFSubtitleTracksForSources(_snapshot[@"detail"][@"MediaSources"],&error);
    return tracks ?: @[];
}
- (NSDictionary *)selectedSubtitleTrackForDetail {
    if (_closed || [_snapshot[@"page"] integerValue]!=JFDetailPage) return nil;
    NSDictionary *detail=_snapshot[@"detail"];
    NSString *item=[detail[@"Id"] isKindOfClass:[NSString class]] ? detail[@"Id"] : nil;
    if (!item.length) return nil;
    if (![_subtitleItemID isEqual:item]) {
        [self clearSubtitleSelection]; _subtitleItemID=[item copy];
        // Prefer a sidecar named CHS*.srt. The Jellyfin title may be localized,
        // so match the original path basename when available as well.
        for (NSDictionary *candidate in [self subtitleTracksForDetail]) {
            NSString *codec=candidate[@"codec"];
            if (![candidate[@"external"] boolValue] ||
                ![@[@"srt",@"subrip"] containsObject:codec]) continue;
            NSString *name=[candidate[@"path"] lastPathComponent];
            NSString *title=candidate[@"title"];
            if (![[name uppercaseString] hasPrefix:@"CHS"] &&
                ![[title uppercaseString] hasPrefix:@"CHS"]) continue;
            _subtitleSourceID=[candidate[@"sourceID"] copy];
            _subtitleIndex=[candidate[@"index"] integerValue];
            break;
        }
    }
    if (_subtitleIndex<0 || !_subtitleSourceID) return nil;
    for (NSDictionary *track in [self subtitleTracksForDetail])
        if ([_subtitleSourceID isEqual:track[@"sourceID"]] && _subtitleIndex==[track[@"index"] integerValue]) return track;
    [_subtitleSourceID release]; _subtitleSourceID=nil; _subtitleIndex=-1;
    return nil;
}
- (NSUInteger)audioTrackCount {
    if (![NSThread isMainThread] || _closed) return 0;
    return [[self audioTracksForDetail] count];
}
- (NSString *)audioSelectionLabel {
    if (![NSThread isMainThread] || _closed || [self audioTrackCount]<2) return nil;
    NSString *label=JFAudioTrackLabel([self selectedAudioTrackForDetail]);
    return label.length ? [@"Audio: " stringByAppendingString:label] : nil;
}
- (BOOL)cycleAudioTrack {
    if (![NSThread isMainThread] || _closed || _busy || [_snapshot[@"page"] integerValue]!=JFDetailPage) return NO;
    NSArray *tracks=[self audioTracksForDetail];
    if (tracks.count<2) return NO;
    NSDictionary *current=[self selectedAudioTrackForDetail];
    NSUInteger at=NSNotFound;
    for (NSUInteger i=0;i<tracks.count;i++) {
        NSDictionary *track=tracks[i];
        if ([track[@"sourceID"] isEqual:current[@"sourceID"]] && [track[@"index"] isEqual:current[@"index"]]) { at=i; break; }
    }
    if (at==NSNotFound) at=0;
    NSDictionary *next=tracks[(at+1)%tracks.count];
    NSDictionary *detail=_snapshot[@"detail"];
    NSString *item=[detail[@"Id"] isKindOfClass:[NSString class]] ? detail[@"Id"] : nil;
    if (!item.length) return NO;
    NSString *state=_playback.currentState;
    BOOL active=[@[@"playing",@"paused"] containsObject:state ?: @""];
    long long ticks=active ? _playback.positionTicks : [self resumeTicksForDetail];
    if (active && ![_playback stop]) return NO;
    [_audioSourceID release]; _audioSourceID=[next[@"sourceID"] copy]; _audioIndex=[next[@"index"] integerValue];
    if (_subtitleSourceID && ![_subtitleSourceID isEqual:_audioSourceID]) {
        [_subtitleSourceID release]; _subtitleSourceID=nil; _subtitleIndex=-1;
    }
    [self publish];
    if (active) return [_playback playItem:item startTicks:ticks mediaSourceID:_audioSourceID audioIndex:_audioIndex subtitleIndex:_subtitleIndex];
    return YES;
}
- (NSUInteger)subtitleTrackCount {
    if (![NSThread isMainThread] || _closed) return 0;
    NSUInteger count=0;
    for (NSDictionary *track in [self subtitleTracksForDetail])
        if ([@[@"srt",@"subrip"] containsObject:track[@"codec"]]) count++;
    return count;
}
- (NSString *)subtitleSelectionLabel {
    if (![NSThread isMainThread] || _closed || [self subtitleTrackCount]==0) return nil;
    NSDictionary *track=[self selectedSubtitleTrackForDetail];
    if (!track) return @"Subtitles: Off";
    NSString *label=JFSubtitleTrackLabel(track);
    return label.length ? [@"Subtitles: " stringByAppendingString:label] : @"Subtitles: Off";
}
- (BOOL)cycleSubtitleTrack {
    if (![NSThread isMainThread] || _closed || _busy || [_snapshot[@"page"] integerValue]!=JFDetailPage) return NO;
    NSMutableArray *tracks=[NSMutableArray array];
    for (NSDictionary *track in [self subtitleTracksForDetail])
        if ([@[@"srt",@"subrip"] containsObject:track[@"codec"]]) [tracks addObject:track];
    if (!tracks.count) return NO;
    NSDictionary *current=[self selectedSubtitleTrackForDetail], *next=nil;
    if (!current) next=tracks[0];
    else {
        NSUInteger at=NSNotFound;
        for (NSUInteger i=0;i<tracks.count;i++) {
            NSDictionary *track=tracks[i];
            if ([track[@"sourceID"] isEqual:current[@"sourceID"]] && [track[@"index"] isEqual:current[@"index"]]) { at=i; break; }
        }
        if (at!=NSNotFound && at+1<tracks.count) next=tracks[at+1];
    }
    NSDictionary *detail=_snapshot[@"detail"];
    NSString *item=[detail[@"Id"] isKindOfClass:[NSString class]] ? detail[@"Id"] : nil;
    if (!item.length) return NO;
    NSString *state=_playback.currentState;
    BOOL active=[@[@"playing",@"paused"] containsObject:state ?: @""];
    // Commit to the active player before mutating the UI selection. A subtitle
    // track from another media version must not silently switch video sources.
    if (active) {
        NSString *playingSource=[_playback currentMediaSourceID];
        NSString *targetSource=next ? next[@"sourceID"] : playingSource;
        if (!playingSource || ![targetSource isEqual:playingSource] ||
            ![_playback selectLocalSubtitleForItem:item mediaSourceID:targetSource
                                           index:(next ? [next[@"index"] integerValue] : -1)])
            return NO;
    }
    if (next) {
        [_subtitleSourceID release]; _subtitleSourceID=[next[@"sourceID"] copy]; _subtitleIndex=[next[@"index"] integerValue];
        NSArray *audio=[self audioTracksForDetail];
        NSDictionary *selected=[self selectedAudioTrackForDetail];
        if (selected && ![selected[@"sourceID"] isEqual:_subtitleSourceID]) {
            NSDictionary *replacement=[self defaultAudioTrackForSource:_subtitleSourceID tracks:audio];
            [_audioSourceID release]; _audioSourceID=[replacement[@"sourceID"] copy];
            _audioIndex=replacement ? [replacement[@"index"] integerValue] : -1;
        }
    } else {
        [_subtitleSourceID release]; _subtitleSourceID=nil; _subtitleIndex=-1;
    }
    [self publish];
    return YES;
}
- (void)resetSnapshot {
    [self clearPoster]; [self clearAudioSelection]; [self clearSubtitleSelection];
    [_snapshot release]; _snapshot=[EmptySnapshot() copy];
    [_errorKind release]; _errorKind=[@"none" copy];
    [_errorDomain release]; _errorDomain=nil; _errorCode=0;
}
- (void)queueNextLibraryChunk {
    if(_closed || _busy || _libraryContinuationScheduled ||
       [_snapshot[@"page"] integerValue]!=JFMediaPage ||
       ![_browser hasRemainingLibraryItems])return;
    _libraryContinuationScheduled=YES;
    NSUInteger serial=_libraryContinuationSerial,gen=_generation;
    JFSessionDelivery *delivery=_delivery;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        JFSession *session=delivery->owner;
        if(!session || session->_closed || session->_generation!=gen ||
           session->_libraryContinuationSerial!=serial)return;
        if(session->_busy || [session->_snapshot[@"page"] integerValue]!=JFMediaPage) {
            session->_libraryContinuationScheduled=NO;return;
        }
        JFBrowser *browser=session->_browser;
        [session->_worker perform:^id(NSError **error) {
            BOOL ok=[browser appendNextLibraryChunk:error];
            return ok?[browser snapshot]:nil;
        } completion:^(id result,NSError *error) {
            JFSession *owner=delivery->owner;
            if(!owner || owner->_closed || owner->_generation!=gen ||
               owner->_libraryContinuationSerial!=serial)return;
            owner->_libraryContinuationScheduled=NO;
            if(result && !owner->_busy &&
               [owner->_snapshot[@"page"] integerValue]==JFMediaPage) {
                NSUInteger previous=[owner->_snapshot[@"media"] count];
                if([result[@"media"] count]>previous) {
                    [owner->_snapshot release];owner->_snapshot=[result copy];
                    [owner updatePosterForSnapshot];
                    [owner publish];
                }
            }
            // Never let a background page failure blank an already loaded list.
            if(!error && !owner->_busy)[owner queueNextLibraryChunk];
        }];
    });
}
- (BOOL)submit:(void (^)(JFBrowser *, NSError **))action {
    if (![NSThread isMainThread] || _closed || _busy) return NO;
    _busy=YES; [_errorKind release]; _errorKind=[@"none" copy]; [_errorDomain release]; _errorDomain=nil; _errorCode=0;
    NSUInteger generation=_generation;
    JFBrowser *browser=_browser; JFSessionDelivery *delivery=_delivery;
    [_worker perform:^id(NSError **error) {
        action(browser,error);
        return [browser snapshot];
    } completion:^(id result, NSError *error) {
        JFSession *session=delivery->owner;
        if (!session || session->_closed || session->_generation!=generation) return;
        [session->_snapshot release]; session->_snapshot=[result copy];
        NSString *kind=ErrorKind(error);
        [session->_errorKind release]; session->_errorKind=[kind copy];
        [session->_errorDomain release]; session->_errorDomain=[error.domain copy]; session->_errorCode=error.code;
        if ([kind isEqual:@"authentication"]) { [session->_sessionToken release]; session->_sessionToken=nil; }
        session->_busy=NO;
        [session updatePosterForSnapshot];
        [session publish];
        [session queueNextLibraryChunk];
    }];
    [self publish]; return YES;
}
- (BOOL)submitAuthentication:(void (^)(JFBrowser *, NSError **))action {
    if (![NSThread isMainThread] || _closed || _busy) return NO;
    _busy=YES; [_errorKind release]; _errorKind=[@"none" copy]; [_errorDomain release]; _errorDomain=nil; _errorCode=0;
    NSUInteger generation=_generation;
    JFBrowser *browser=_browser; JFSessionDelivery *delivery=_delivery;
    [_worker perform:^id(NSError **error) {
        action(browser,error);
        id token=[browser sessionToken] ?: [NSNull null];
        return @{ @"snapshot":[browser snapshot], @"token":token };
    } completion:^(id result, NSError *error) {
        JFSession *session=delivery->owner;
        if (!session || session->_closed || session->_generation!=generation) return;
        NSDictionary *payload=[result isKindOfClass:[NSDictionary class]] ? result : @{};
        id snapshot=payload[@"snapshot"], token=payload[@"token"];
        [session->_snapshot release]; session->_snapshot=[snapshot isKindOfClass:[NSDictionary class]] ? [snapshot copy] : [EmptySnapshot() copy];
        [session->_sessionToken release]; session->_sessionToken=[token isKindOfClass:[NSString class]] ? [token copy] : nil;
        [session->_errorKind release]; session->_errorKind=[ErrorKind(error) copy];
        [session->_errorDomain release]; session->_errorDomain=[error.domain copy]; session->_errorCode=error.code;
        session->_busy=NO;
        [session updatePosterForSnapshot];
        [session publish];
    }];
    [self publish]; return YES;
}
- (BOOL)login:(NSString *)username password:(NSString *)password {
    if (![NSThread isMainThread] || _closed || ![username isKindOfClass:[NSString class]] || !username.length || ![password isKindOfClass:[NSString class]]) return NO;
    // Copy mutable caller inputs before crossing threads.
    NSString *name=[[username copy] autorelease], *secret=[[password copy] autorelease];
    _generation++; [_worker cancelAll]; [_playback invalidateSession]; _busy=NO; [self resetSnapshot];
    [_sessionToken release]; _sessionToken=nil;
    return [self submitAuthentication:^(JFBrowser *browser, NSError **error) { [browser login:name password:secret error:error]; }];
}
- (BOOL)authenticateToken:(NSString *)token {
    if (![NSThread isMainThread] || _closed || ![token isKindOfClass:[NSString class]] || !token.length) return NO;
    NSString *credential=[[token copy] autorelease];
    _generation++; [_worker cancelAll]; [_playback invalidateSession]; _busy=NO; [self resetSnapshot];
    [_sessionToken release]; _sessionToken=nil;
    return [self submitAuthentication:^(JFBrowser *browser, NSError **error) { [browser authenticateToken:credential error:error]; }];
}
- (BOOL)refresh {
    if (![NSThread isMainThread] || _closed || _busy) return NO;
    if ([_snapshot[@"page"] integerValue]!=JFLibrariesPage) return NO;
    return [self submit:^(JFBrowser *browser, NSError **error) { [browser refreshUncached:error]; }];
}
- (BOOL)openLibraryWithType:(NSString *)type {
    if (![NSThread isMainThread] || _closed || _busy) return NO;
    if (![@[@"Movie",@"Series"] containsObject:type] || ![@[@(JFLibrariesPage),@(JFLibraryPage)] containsObject:_snapshot[@"page"]] || [_snapshot[@"index"] integerValue]==NSNotFound) return NO;
    NSString *copy=[[type copy] autorelease];
    return [self submit:^(JFBrowser *browser, NSError **error) { [browser openLibraryWithType:copy error:error]; }];
}
- (BOOL)openLibraryAtIndex:(NSUInteger)index type:(NSString *)type {
    if(![NSThread isMainThread] || _closed || _busy ||
       [_snapshot[@"page"] integerValue]!=JFLibrariesPage ||
       index>=[_snapshot[@"libraries"] count] ||
       ![@[@"Movie",@"Series"] containsObject:type])return NO;
    NSString *kind=[[type copy] autorelease];
    // A separate focusLibraryAtIndex: publishes the transient index to
    // BackRow before the media page is ready, which makes the highlight
    // jump to a stale library (frequently Archived). Commit only inside the
    // same serialized worker task that opens the library.
    _libraryContinuationSerial++;
    _libraryContinuationScheduled=NO;
    return [self submit:^(JFBrowser *browser,NSError **error) {
        [browser focusLibraryAtIndex:index];
        [browser openFirstLibraryScreenWithType:kind error:error];
    }];
}
- (BOOL)focusLibraryAtIndex:(NSUInteger)index {
    if (![NSThread isMainThread] || _closed || _busy ||
        [_snapshot[@"page"] integerValue]!=JFLibrariesPage ||
        index>=[_snapshot[@"libraries"] count]) return NO;
    if ([_snapshot[@"index"] unsignedIntegerValue]==index) return YES;
    NSMutableDictionary *changed=[_snapshot mutableCopy];changed[@"index"]=@(index);
    [_snapshot release];_snapshot=[changed copy];[changed release];
    JFBrowser *browser=_browser;
    // Serialize the worker's browser selection before the subsequent open request.
    [_worker perform:^id(NSError **error) { [browser focusLibraryAtIndex:index];return nil; } completion:nil];
    [self publish];return YES;
}
- (BOOL)setDetailFlag:(NSString *)flag enabled:(BOOL)enabled {
    if (![NSThread isMainThread] || _closed || _busy ||
        [_snapshot[@"page"] integerValue]!=JFDetailPage ||
        ![@[@"Played",@"Favorite"] containsObject:flag]) return NO;
    return [self submit:^(JFBrowser *browser,NSError **error) {
        [browser setDetailFlag:flag enabled:enabled error:error];
    }];
}
- (BOOL)focusMediaAtIndex:(NSUInteger)index {
    if (![NSThread isMainThread] || _closed || _busy) return NO;
    NSInteger page=[_snapshot[@"page"] integerValue];
    if (![@[@(JFMediaPage),@(JFSeasonsPage),@(JFEpisodesPage)] containsObject:@(page)] ||
        index>=[_snapshot[@"media"] count]) return NO;
    if ([_snapshot[@"mediaIndex"] unsignedIntegerValue]==index) return YES;
    NSMutableDictionary *changed=[_snapshot mutableCopy];
    changed[@"mediaIndex"]=@(index);
    [_snapshot release]; _snapshot=[changed copy]; [changed release];
    [self updatePosterForSnapshot];
    [self publish];
    return YES;
}
- (BOOL)openMediaAtIndex:(NSUInteger)index {
    if (![NSThread isMainThread] || _closed || _busy) return NO;
    NSInteger page=[_snapshot[@"page"] integerValue];
    if (page<JFMediaPage || page==JFDetailPage || index>=[_snapshot[@"media"] count]) return NO;
    return [self submit:^(JFBrowser *browser, NSError **error) { [browser openMediaAtIndex:index error:error]; }];
}
- (BOOL)handleEvent:(NSDictionary *)event {
    if (![NSThread isMainThread] || _closed || _busy || ![event isKindOfClass:[NSDictionary class]]) return NO;
    id button=event[@"button"], phase=event[@"phase"];
    if (![button isKindOfClass:[NSNumber class]] || ![@[@"press",@"repeat",@"hold",@"release"] containsObject:phase]) return NO;
    NSInteger b=[button integerValue], page=[_snapshot[@"page"] integerValue];
    if (b==JFMenu && [phase isEqual:@"press"]) return [self goBack];
    // Network selection must be explicit: library type is chosen by the host.
    BOOL movement=(b==JFUp || b==JFDown) && ![phase isEqual:@"release"];
    BOOL librarySelect=b==JFSelect && [phase isEqual:@"press"] && page==JFLibrariesPage;
    if (!(movement || librarySelect) || page==JFLoginPage || page==JFDetailPage || page==JFLibraryPage) return NO;
    if ((page==JFLibrariesPage ? [_snapshot[@"libraries"] count] : [_snapshot[@"media"] count])==0) return NO;
    NSDictionary *copy=@{@"button":@([button integerValue]),@"phase":[[phase copy] autorelease]};
    return [self submit:^(JFBrowser *browser, NSError **error) { [browser handleEvent:copy]; }];
}
- (BOOL)goBack {
    if (![NSThread isMainThread] || _closed || _busy) return NO;
    NSInteger page=[_snapshot[@"page"] integerValue];
    if (page==JFLoginPage || page==JFLibrariesPage) return NO;
    return [self submit:^(JFBrowser *browser, NSError **error) {
        if (browser.page==JFLibraryPage) [browser handleEvent:@{@"button":@(JFMenu),@"phase":@"press"}];
        else [browser goBack];
    }];
}
- (JFPlaybackController *)playback { return _playback; }
- (BOOL)configurePlaybackBackend:(id<JFPlaybackBackend>)backend {
    if (![NSThread isMainThread] || _closed || _busy || _playback || !backend) return NO;
    _playback=[[JFPlaybackController alloc] initWithClient:_playbackClient worker:_worker backend:backend];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackChanged:) name:JFPlaybackChanged object:_playback];
    return _playback!=nil;
}
- (void)playbackChanged:(NSNotification *)notification {
    if (_closed || notification.object!=_playback) return;
    if ([_playback.errorKind isEqual:@"authentication"] && [_playback.currentState isEqual:@"failed"]) {
        if ([self logout]) { [_errorKind release]; _errorKind=[@"authentication" copy]; [self publish]; }
        return;
    }
    [self publish];
}
- (long long)resumeTicksForDetail {
    if (![NSThread isMainThread] || _closed || [_snapshot[@"page"] integerValue]!=JFDetailPage) return 0;
    NSDictionary *detail=_snapshot[@"detail"];
    NSString *item=[detail[@"Id"] isKindOfClass:[NSString class]] ? detail[@"Id"] : nil;
    if (!item.length) return 0;
    long long local=[_playback resumeTicksForItem:item];
    if (local>0) return local;
    NSDictionary *user=[detail[@"UserData"] isKindOfClass:[NSDictionary class]] ? detail[@"UserData"] : nil;
    id ticks=user[@"PlaybackPositionTicks"], runtime=detail[@"RunTimeTicks"];
    if (!JFTicks(ticks) || [ticks longLongValue]<=0) return 0;
    long long value=[ticks longLongValue];
    if (JFTicks(runtime) && [runtime longLongValue]>0 && value>=[runtime longLongValue]) return 0;
    return value;
}
- (BOOL)playDetail {
    if (![NSThread isMainThread] || _closed || _busy || [_snapshot[@"page"] integerValue]!=JFDetailPage) return NO;
    NSDictionary *detail=_snapshot[@"detail"];
    [self selectedAudioTrackForDetail]; [self selectedSubtitleTrackForDetail];
    if (_subtitleSourceID && _audioSourceID && ![_subtitleSourceID isEqual:_audioSourceID]) {
        [_subtitleSourceID release]; _subtitleSourceID=nil; _subtitleIndex=-1;
    }
    NSString *source=_subtitleSourceID ?: _audioSourceID;
    return [_playback playItem:detail[@"Id"] startTicks:[self resumeTicksForDetail] mediaSourceID:source audioIndex:_audioIndex subtitleIndex:_subtitleIndex];
}
- (BOOL)resumeDetailPlayback {
    if (![NSThread isMainThread] || _closed || _busy || [_snapshot[@"page"] integerValue]!=JFDetailPage || !_playback) return NO;
    NSDictionary *detail=_snapshot[@"detail"];
    NSString *item=[detail[@"Id"] isKindOfClass:[NSString class]] ? detail[@"Id"] : nil;
    if (!item.length) return NO;

    NSString *state=_playback.currentState;
    // A true pause must resume the already-cued native player. Rebuilding PlaybackInfo/Gateway/HLS
    // here caused a full stream restart and multi-second rebuffer on every Pause -> Resume.
    if ([state isEqual:@"paused"]) {
        JFPlaybackTrace(@"DETAIL_RESUME mode=native");
        return [_playback resume];
    }
    if ([state isEqual:@"setup"] || [state isEqual:@"playing"]) return NO;

    long long ticks=[self resumeTicksForDetail];
    [self selectedAudioTrackForDetail]; [self selectedSubtitleTrackForDetail];
    if (_subtitleSourceID && _audioSourceID && ![_subtitleSourceID isEqual:_audioSourceID]) {
        [_subtitleSourceID release]; _subtitleSourceID=nil; _subtitleIndex=-1;
    }
    NSString *source=_subtitleSourceID ?: _audioSourceID;
    JFPlaybackTrace(@"DETAIL_RESUME mode=reopen");
    return [_playback playItem:item startTicks:ticks mediaSourceID:source audioIndex:_audioIndex subtitleIndex:_subtitleIndex];
}
- (BOOL)signOut {
    if (![NSThread isMainThread] || _closed) return NO;
    _generation++; [_worker cancelAll]; [_playback invalidateSession]; _busy=NO; [self resetSnapshot];
    [_sessionToken release]; _sessionToken=nil;
    return [self submit:^(JFBrowser *browser, NSError **error) { [browser signOut:error]; }];
}
- (BOOL)logout {
    if (![NSThread isMainThread] || _closed) return NO;
    _generation++; [_worker cancelAll]; [_playback invalidateSession]; _busy=NO; [self resetSnapshot];
    [_sessionToken release]; _sessionToken=nil;
    return [self submit:^(JFBrowser *browser, NSError **error) { [browser logout]; }];
}
- (void)close {
    if (![NSThread isMainThread] || _closed) return;
    _closed=YES; _generation++; _busy=NO;
    [self clearPoster];
    if (_delivery) _delivery->owner=nil;
    [_worker cancelAll];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:JFPlaybackChanged object:_playback];
    [_playback close]; [self resetSnapshot]; [_sessionToken release]; _sessionToken=nil;
    JFBrowser *browser=_browser; JFWorker *worker=_worker;
    // Work retains worker until cleanup executes even when the host releases session.
    // Its work block is released by JFTask after execution, breaking this temporary cycle.
    [worker perform:^id(NSError **error) { [browser logout]; (void)[worker class]; return nil; } completion:nil];
}
- (void)dealloc {
    NSAssert([NSThread isMainThread], @"Release JFSession on main thread");
    [self close]; [_playback release]; [_playbackClient release]; [_artworkCache release]; [_delivery release]; [_worker release]; [_browser release];
    [_posterTask release]; [_posterData release]; [_posterItemID release];
    [_audioItemID release]; [_audioSourceID release];
    [_subtitleItemID release]; [_subtitleSourceID release];
    [_snapshot release]; [_errorKind release]; [_errorDomain release]; [_sessionToken release]; [super dealloc];
}
@end
