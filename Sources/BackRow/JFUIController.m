#import "JFUIController.h"
#import "JFBackRow.h"
#import "JFPosterTrace.h"
#import "JFVisualUI.h"
#import "Navigation/JFArtwork.h"
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import "Navigation/JFSession.h"
#import "Navigation/JFBrowser.h"
#import "Navigation/JFMovieMetadata.h"
#import "Navigation/JFSeriesMetadata.h"
#import "Navigation/JFDetailMetadata.h"
#import "Input/JFRemote.h"
#import "API/JFServerURL.h"
#import "Playback/JFPlaybackTrace.h"
#import <objc/message.h>
#include <string.h>
static id JFNewTextEntryController(void) {
    Class cls=NSClassFromString(@"BRTextEntryController");
#if !defined(__arm__)
    return JFBRNew(cls);
#else
    SEL selector=NSSelectorFromString(@"initWithTextEntryStyle:");
    NSMethodSignature *signature=[cls instanceMethodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType,@encode(id)) || signature.numberOfArguments!=3 || strcmp([signature getArgumentTypeAtIndex:2],@encode(int))) return nil;
    return ((id(*)(id,SEL,int))objc_msgSend)([cls alloc],selector,4);
#endif
}
static BOOL JFValidPersistedToken(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] && [value length]<=8192 &&
        [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location==NSNotFound;
}
static NSDictionary *Row(NSString *title, NSString *action, BOOL enabled) {
    return @{@"title":title ?: @"",@"action":action,@"enabled":@(enabled)};
}
@interface JFUIController ()
- (void)refreshView;
- (void)clearEditor;
- (void)clearSession;
- (void)saveConfiguration;
- (NSString *)deviceID;
- (void)clearSessionCredential;
- (void)saveSessionCredential;
- (void)syncSessionCredential;
- (void)restoreSessionIfPossible;
- (void)signIn;
- (void)artworkChanged:(NSNotification *)notice;
- (void)ensureArtwork;
- (void)displayVisual;
- (void)renderPendingArtwork;
- (BOOL)moveGrid:(NSInteger)button;
@end

static NSData *JFPosterDataWithInset(NSData *data, BOOL sideInset) {
    if (![data isKindOfClass:[NSData class]] || !data.length) return data;
    CGImageSourceRef source=CGImageSourceCreateWithData((CFDataRef)data,NULL);
    if (!source) return data;
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,NULL);
    CFRelease(source);
    if (!image) return data;
    size_t width=CGImageGetWidth(image), height=CGImageGetHeight(image);
    if (!width || !height) { CGImageRelease(image); return data; }
    size_t insetY=(size_t)MAX(1.0,floor((double)height*0.04));
    size_t insetX=sideInset ? (size_t)MAX(1.0,floor((double)width*0.04)) : 0;
    size_t canvasWidth=width+insetX*2, canvasHeight=height+insetY*2;
    CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(NULL,canvasWidth,canvasHeight,8,canvasWidth*4,colorSpace,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) { CGImageRelease(image); return data; }
    CGContextClearRect(context,CGRectMake(0,0,canvasWidth,canvasHeight));
    CGContextDrawImage(context,CGRectMake(insetX,insetY,width,height),image);
    CGImageRef padded=CGBitmapContextCreateImage(context);
    CGContextRelease(context); CGImageRelease(image);
    if (!padded) return data;
    NSMutableData *encoded=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((CFMutableDataRef)encoded,CFSTR("public.png"),1,NULL);
    if (!destination) { CGImageRelease(padded); return data; }
    CGImageDestinationAddImage(destination,padded,NULL);
    BOOL ok=CGImageDestinationFinalize(destination);
    CFRelease(destination); CGImageRelease(padded);
    return ok && encoded.length ? encoded : data;
}

@implementation JFUIController
+ (NSUserDefaults *)configurationDefaults {
    return [[[NSUserDefaults alloc] initWithSuiteName:@"org.jellyfin.atv3"] autorelease];
}

- (id)initWithController:(id)controller {
    if ((self=[super initWithController:controller])) {
        _configurationDefaults=[[[self class] configurationDefaults] retain];
        id saved=[_configurationDefaults objectForKey:@"ServerConfiguration"];
        NSDictionary *config=[saved isKindOfClass:[NSDictionary class]] ? saved : @{};
        NSString *address=JFNormalizeServerAddress(config[@"server"],NULL);
        _server=[(address ?: @"") copy];
        _username=[([config[@"username"] isKindOfClass:[NSString class]] ? config[@"username"] : @"") copy];
        _allowHTTP=[config[@"allowHTTP"] isKindOfClass:[NSNumber class]] && [config[@"allowHTTP"] boolValue];
        _password=[@"" copy]; _message=[@"" copy]; _page=JFLoginPage;
        _searchQuery=[@"" copy]; _visual=[[JFVisualUI alloc] initWithController:controller];
        [self restoreSessionIfPossible];
        [self refreshView];
    }
    return self;
}
- (JFPlaybackController *)playback { return _session.playback; }
- (id)previewControlForRow:(long)row {
    NSInteger page=_session ? [_session.snapshot[@"page"] integerValue] : -1;
    JFPosterTrace([NSString stringWithFormat:@"UI_PREVIEW_ENTER row=%ld page=%ld",row,(long)page]);
    BOOL detailPage=page==JFDetailPage;
    if (_closed || !_session || ![@[@(JFMediaPage),@(JFSeasonsPage),@(JFEpisodesPage),@(JFDetailPage)] containsObject:@(page)]) { JFPosterTrace(@"UI_PREVIEW_REJECT state"); return nil; }
    NSDictionary *item=nil;
    if (detailPage) {
        if (row<0 || (NSUInteger)row>=_rows.count) { JFPosterTrace(@"UI_PREVIEW_REJECT row"); return nil; }
        item=_session.snapshot[@"detail"];
    } else {
        if (row<0 || (NSUInteger)row>=_rows.count || ![_rows[(NSUInteger)row][@"action"] isEqual:@"media"]) { JFPosterTrace(@"UI_PREVIEW_REJECT row"); return nil; }
        NSArray *items=_session.snapshot[@"media"];
        NSUInteger actual=[_rows[(NSUInteger)row][@"mediaIndex"] unsignedIntegerValue];
        if (actual>=items.count) { JFPosterTrace(@"UI_PREVIEW_REJECT item-range"); return nil; }
        item=items[actual];
    }
    if (![@[@"Movie",@"Series",@"Season",@"Episode"] containsObject:item[@"Type"]]) { JFPosterTrace(@"UI_PREVIEW_REJECT non-poster-media"); return nil; }
    if (![item[@"Id"] isEqual:_session.posterItemID]) { JFPosterTrace(@"UI_PREVIEW_REJECT poster-id-mismatch"); return nil; }
    NSData *data=_session.posterData;
    JFPosterTrace([NSString stringWithFormat:@"UI_PREVIEW_DATA bytes=%lu",(unsigned long)data.length]);
    if (!data.length) return nil;
    BOOL sideInset=[item[@"Type"] isEqual:@"Episode"];
    if (_previewSourceData!=data || _previewSideInset!=sideInset) {
        [_previewSourceData release]; _previewSourceData=[data retain];
        [_previewDisplayData release]; _previewDisplayData=[JFPosterDataWithInset(data,sideInset) retain];
        _previewSideInset=sideInset;
        JFPosterTrace([NSString stringWithFormat:@"UI_PREVIEW_INSET source=%lu display=%lu side=%d",(unsigned long)data.length,(unsigned long)_previewDisplayData.length,sideInset]);
    }
    NSData *displayData=_previewDisplayData.length ? _previewDisplayData : data;

    Class imageClass=NSClassFromString(@"ATVImage");
    Class previewClass=NSClassFromString(@"BRAsyncImageControl");
    JFPosterTrace([NSString stringWithFormat:@"UI_PREVIEW_CLASSES image=%d preview=%d",imageClass!=Nil,previewClass!=Nil]);
    id image=JFBRObjectWithObject(imageClass,@"imageWithData:",displayData);
    JFPosterTrace([NSString stringWithFormat:@"UI_PREVIEW_IMAGE created=%d",image!=nil]);
    if (!image) return nil;
    id preview=[JFBRNew(previewClass) autorelease];
    JFPosterTrace([NSString stringWithFormat:@"UI_PREVIEW_CONTROLLER created=%d",preview!=nil]);
    if (!preview) return nil;
    BOOL aspectFit=JFBRSetBool(preview,@"setCropAndFill:",NO);
    JFPosterTrace([NSString stringWithFormat:@"UI_PREVIEW_ASPECT_FIT success=%d",aspectFit]);
    if (!aspectFit) return nil;
    BOOL imageSet=JFBRCall(preview,@"setImage:",@[image]);
    JFPosterTrace([NSString stringWithFormat:@"UI_PREVIEW_SETIMAGE success=%d",imageSet]);
    if (!imageSet) return nil;
    JFPosterTrace(@"UI_PREVIEW_READY");
    return preview;
}
- (BOOL)configurePlaybackBackend:(id<JFPlaybackBackend>)backend {
    if (![NSThread isMainThread] || _closed || _playbackBackend || !backend) return NO;
    // Saved-session restore may already be running here. Keep the verified backend
    // and attach it as soon as the session leaves its busy authentication state.
    _playbackBackend=[backend retain];
    if (_session && !_session.busy && !_session.playback)
        (void)[_session configurePlaybackBackend:_playbackBackend];
    [self refreshView]; return YES;
}
- (void)setMessage:(NSString *)message { [_message release]; _message=[message copy]; }
- (void)observe {
    if (_session && !_observing) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionChanged:) name:JFSessionChanged object:_session]; _observing=YES;
    }
}
- (void)unobserve {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:JFSessionChanged object:_session]; _observing=NO;
}
- (BOOL)activate {
    if (_closed) return NO;
    // Returning from an input controller without delegate completion means cancellation.
    if (_editor) [self clearEditor];
    [self syncSessionCredential];
    [self observe]; [self refreshView];
    BOOL ready=[super activate]; if (!ready) [self unobserve]; else [self displayVisual]; return ready;
}
- (void)deactivate { [_visual hide]; [self unobserve]; [super deactivate]; }
- (void)saveConfiguration {
    [_configurationDefaults setObject:@{@"server":_server,@"username":_username,@"allowHTTP":@(_allowHTTP)} forKey:@"ServerConfiguration"];
    if (![_configurationDefaults synchronize]) [self setMessage:@"Could not save configuration — try again"];
}
- (NSString *)deviceID {
    NSString *device=[_configurationDefaults stringForKey:@"DeviceID"];
    NSCharacterSet *invalid=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet];
    if (!device.length || [device rangeOfCharacterFromSet:invalid].location!=NSNotFound) {
        device=[[NSUUID UUID] UUIDString];
        [_configurationDefaults setObject:device forKey:@"DeviceID"];
        [_configurationDefaults synchronize];
    }
    return device;
}
- (void)clearSessionCredential {
    [_configurationDefaults removeObjectForKey:@"SessionCredential"];
    [_configurationDefaults synchronize];
}
- (void)saveSessionCredential {
    NSString *token=_session.sessionToken;
    NSString *address=JFNormalizeServerAddress(_server,NULL);
    NSString *device=[self deviceID];
    if (!JFValidPersistedToken(token) || !address.length || !device.length) return;
    NSDictionary *credential=@{@"version":@1,@"server":address,@"deviceID":device,@"token":token};
    if (![[ _configurationDefaults objectForKey:@"SessionCredential"] isEqual:credential]) {
        [_configurationDefaults setObject:credential forKey:@"SessionCredential"];
        if (![_configurationDefaults synchronize]) [self setMessage:@"Could not save sign-in — sign in again next launch"];
    }
}
- (void)syncSessionCredential {
    if ([_session.errorKind isEqual:@"authentication"]) { [self clearSessionCredential]; return; }
    if (_session.sessionToken.length) [self saveSessionCredential];
}
- (void)restoreSessionIfPossible {
    id raw=[_configurationDefaults objectForKey:@"SessionCredential"];
    if (!raw) return;
    if (![raw isKindOfClass:[NSDictionary class]]) { [self clearSessionCredential]; return; }
    NSDictionary *credential=raw;
    NSString *token=credential[@"token"], *server=JFNormalizeServerAddress(credential[@"server"],NULL);
    NSString *device=credential[@"deviceID"], *current=JFNormalizeServerAddress(_server,NULL), *expected=[self deviceID];
    BOOL valid=[credential[@"version"] isKindOfClass:[NSNumber class]] && [credential[@"version"] integerValue]==1 &&
        JFValidPersistedToken(token) && server.length && [server isEqual:current] &&
        [device isKindOfClass:[NSString class]] && [device isEqual:expected] &&
        (_allowHTTP || ![[[NSURL URLWithString:server] scheme] isEqual:@"http"]);
    if (!valid) { [self clearSessionCredential]; return; }
    _session=[[JFSession alloc] initWithURL:[NSURL URLWithString:server] deviceID:expected allowHTTP:_allowHTTP];
    if (!_session) { [self clearSessionCredential]; return; }
    _host=[[JFSessionHost alloc] initWithSession:_session];
    if (_playbackBackend) [_session configurePlaybackBackend:_playbackBackend];
    if (![_session authenticateToken:token]) { [self clearSession]; [self clearSessionCredential]; }
}
- (void)clearSession {
    if (_artwork) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:JFArtworkChanged object:_artwork];
        [_artwork close]; [_artwork release]; _artwork=nil;
        [_artworkToken release]; _artworkToken=nil;
    }
    [self unobserve]; [_host close]; [_session close];
    [_host release]; _host=nil; [_session release]; _session=nil;
    [_password release]; _password=[@"" copy]; _passwordEntered=NO;
}
- (void)close {
    if (_closed) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(renderPendingArtwork) object:nil];
    _artworkRefreshScheduled=NO;
    [self clearEditor]; [self clearSession]; [_visual close];
    [_previewSourceData release]; _previewSourceData=nil; [_previewDisplayData release]; _previewDisplayData=nil; _previewSideInset=NO;
    [_server release]; _server=[@"" copy]; [_username release]; _username=[@"" copy];
    [super close];
}
- (void)artworkChanged:(NSNotification *)notice {
    if (_closed || notice.object!=_artwork || !_active || _editor || _artworkRefreshScheduled)return;
    // Throttle, never debounce: the first poster should not wait behind all
    // 10 pending thumbnails before the user sees anything.
    _artworkRefreshScheduled=YES;
    [self performSelector:@selector(renderPendingArtwork) withObject:nil afterDelay:0.065];
}
- (void)renderPendingArtwork {
    _artworkRefreshScheduled=NO;
    if(!_closed && _active && !_editor)[self displayVisual];
}
- (void)ensureArtwork {
    NSString *token=_session.sessionToken;
    if (!token.length || [_session.snapshot[@"page"] integerValue]==JFLoginPage) {
        if (_artwork) {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:JFArtworkChanged object:_artwork];
            [_artwork close]; [_artwork release]; _artwork=nil;
            [_artworkToken release];_artworkToken=nil;
        }
        return;
    }
    if ([_artworkToken isEqual:token] && _artwork) return;
    // Only enable when real BackRow supports our image surface. Host
    // regression mocks keep their original preview-loading mechanism.
    if (NSClassFromString(@"BRImageControl"))
        [_session setVisualArtworkMode:YES];
    if (_artwork) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:JFArtworkChanged object:_artwork];
        [_artwork close]; [_artwork release];_artwork=nil;
    }
    [_artworkToken release];_artworkToken=[token copy];
    _artwork=[[JFArtwork alloc] initWithURL:[NSURL URLWithString:_server]
                                   deviceID:[self deviceID] token:token];
    if (_artwork) {
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(artworkChanged:) name:JFArtworkChanged object:_artwork];
        // ATV3's TouchRemote network events contend with the aggressive
        // per-library background 101-item + cover scan on the A5 device.
        // Keep the existing persistent artwork cache and on-demand poster
        // loaders, but do NOT start the speculative whole-library crawler.
        JFPosterTrace(@"ARTWORK_EAGER_PREFETCH_DISABLED");
    }
}
- (void)displayVisual {
    if (!_active || _closed || _editor) return;
    NSTimeInterval visualStart=[NSProcessInfo processInfo].systemUptime;
    if (_page==JFDetailPage && [_session.playback.currentState isEqual:@"playing"])
        return; // The native fullscreen player, not our grid, owns the display.
    [self ensureArtwork];
    NSArray *libraries=_session.snapshot[@"libraries"];
    NSUInteger index=[_session.snapshot[@"index"] unsignedIntegerValue];
    NSDictionary *current=[libraries isKindOfClass:[NSArray class]] && index<libraries.count?libraries[index]:nil;
    [_artwork setActiveLibraryArchived:[current[@"Name"] isKindOfClass:[NSString class]] &&
        [[current[@"Name"] lowercaseString] isEqualToString:@"archived"]];
    // No speculative full-library scan on every visual pass; on-demand art
    // still loads through copyImageForID: and existing disk cache.
    [_visual renderSnapshot:_session.snapshot rows:_rows selection:_selection
                   artwork:_artwork poster:_session.posterData username:_username
                    search:_searchActive query:_searchQuery scroll:_detailScroll];
    NSTimeInterval visualDuration=[NSProcessInfo processInfo].systemUptime-visualStart;
    if(visualDuration>0.075)
        JFPosterTrace([NSString stringWithFormat:
            @"PERF_VISUAL_SLOW page=%ld duration_ms=%lld rows=%lu",
            (long)_page,(long long)(visualDuration*1000.0),(unsigned long)_rows.count]);
}
- (void)sessionChanged:(NSNotification *)notification {
    if (_closed || notification.object!=_session) return;
    [self setMessage:@""]; [self syncSessionCredential];
    if (_pendingLibraryRefresh && !_session.busy) {
        _pendingLibraryRefresh=NO;
        if ([_session.errorKind isEqual:@"none"])
            JFPosterTrace(@"LIBRARY_SCAN_REQUEST_ACCEPTED");
        else JFPosterTrace([NSString stringWithFormat:@"LIBRARY_SCAN_REQUEST_FAILED code=%ld",
                                  (long)_session.errorCode]);
    }
    NSString *state=_session.playback.currentState;
    // Backend progress is published every second even when the user is in
    // full-screen playback. Do not encode a hidden 720p JPEG for each tick.
    if (_page==JFDetailPage && [state isEqual:@"playing"] &&
        [_lastPresentedPlayerState isEqual:@"playing"]) return;
    if (_playbackBackend && !_session.busy && !_session.playback)
        (void)[_session configurePlaybackBackend:_playbackBackend];
    [self refreshView];
    // BackRow preview requests while the image is absent/mismatched only
    // trigger repeated expensive controller refreshes. The native grid already
    // draws its focus; refresh the legacy preview once the matching image exists.
    BOOL ready=YES;
    if(_page==JFMediaPage) {
        NSString *itemID=nil;
        if(_selection>=0 && (NSUInteger)_selection<_rows.count)
            itemID=_rows[(NSUInteger)_selection][@"itemID"];
        ready=(_session.posterData.length>0 && itemID.length &&
               [itemID isEqual:_session.posterItemID]);
    }
    BOOL updated=ready?JFBRCall(_controller,@"updatePreviewController",@[]):NO;
    if(!ready) JFPosterTrace(@"UI_PREVIEW_SKIPPED_UNREADY");
    else JFPosterTrace([NSString stringWithFormat:@"UI_UPDATE_PREVIEW invoked=%d",updated]);
}
- (void)refreshView {
    if (_closed) return;
    NSTimeInterval refreshStart=[NSProcessInfo processInfo].systemUptime;
    NSDictionary *snapshot=_session.snapshot;
    NSInteger page=snapshot ? [snapshot[@"page"] integerValue] : JFLoginPage;
    if (page!=_page) {
        JFBRResetRemoteForPageChange(_controller);
        _selection=page==JFLibrariesPage?MAX(0,[snapshot[@"index"] integerValue]):0;
        _page=page;
        [_lastPresentedPlayerState release];_lastPresentedPlayerState=nil;
        _searchActive=NO;_detailScroll=0;
        [_searchQuery release];_searchQuery=[@"" copy];
    }
    BOOL busy=_session.busy;
    BOOL restoring=page==JFLoginPage && busy && [_configurationDefaults objectForKey:@"SessionCredential"]!=nil;
    NSMutableArray *rows=[NSMutableArray array]; NSString *title=@"Jellyfin";
    if (restoring) {
        title=@"Jellyfin — Restoring session…";
        [rows addObject:Row(@"Restoring saved sign-in…",@"none",NO)];
    } else if (page==JFLoginPage) {
        [rows addObject:Row(_server.length ? [@"Server: " stringByAppendingString:_server] : @"Server address",@"server",!busy)];
        [rows addObject:Row(_username.length ? [@"Username: " stringByAppendingString:_username] : @"Username",@"username",!busy)];
        [rows addObject:Row(_passwordEntered ? @"Password: Entered" : @"Password",@"password",!busy)];
        [rows addObject:Row(@"Sign in",@"signin",!busy && _server.length && _username.length && _passwordEntered)];
        [rows addObject:Row(_allowHTTP ? @"Allow HTTP: On" : @"Allow HTTP: Off",@"http",!busy)];
    } else if (page==JFLibrariesPage) {
        title=@"Jellyfin — Libraries";
        NSArray *items=snapshot[@"libraries"];
        for (NSDictionary *item in items) [rows addObject:Row(item[@"Name"],@"library",!busy)];
        if (!items.count) [rows addObject:Row(@"No libraries available",@"none",NO)];
        // Grid focus is owned by _selection. Never overwrite it from an
        // asynchronous browser snapshot or the highlight jumps to Archived.
        [rows addObject:Row(@"Refresh libraries",@"refresh",!busy)];
        [rows addObject:Row(@"Sign out",@"logout",!busy)];
    } else if (page==JFLibraryPage) {
        NSArray *libraries=snapshot[@"libraries"];
        NSInteger selected=[snapshot[@"index"] integerValue];
        NSDictionary *library=(selected>=0 && selected!=(NSInteger)NSNotFound && (NSUInteger)selected<libraries.count) ? libraries[(NSUInteger)selected] : nil;
        NSString *name=[library[@"Name"] isKindOfClass:[NSString class]] ? library[@"Name"] : nil;
        NSString *collection=[library[@"CollectionType"] isKindOfClass:[NSString class]] ? [library[@"CollectionType"] lowercaseString] : @"";
        title=name.length ? [@"Jellyfin — " stringByAppendingString:name] : @"Jellyfin — Browse library";
        if ([collection isEqual:@"movies"]) {
            [rows addObject:Row(@"Movies",@"movies",!busy)];
        } else if ([collection isEqual:@"tvshows"]) {
            [rows addObject:Row(@"TV shows",@"series",!busy)];
        } else if (!collection.length || [collection isEqual:@"mixed"]) {
            [rows addObject:Row(@"Movies",@"movies",!busy)];
            [rows addObject:Row(@"TV shows",@"series",!busy)];
        } else {
            [rows addObject:Row(@"This library type is not supported yet",@"none",NO)];
        }
        [rows addObject:Row(@"Back",@"back",!busy)];
    } else if (page==JFDetailPage) {
        NSDictionary *detail=snapshot[@"detail"];
        title=JFDetailTitle(detail);
        NSDictionary *userData=[detail[@"UserData"] isKindOfClass:[NSDictionary class]] ? detail[@"UserData"] : @{};
        NSString *state=_session.playback.currentState;
        if ([@[@"playing",@"paused",@"setup"] containsObject:state]) title=[title stringByAppendingFormat:@" — %@",state];
        BOOL playing=[state isEqual:@"playing"],paused=[state isEqual:@"paused"];
        long long resume=[_session resumeTicksForDetail];
        NSString *primary=playing?@"Pause":paused?@"Resume":(resume>0?@"Resume playback":@"Play");
        // Keep the focused Play row selectable while its asynchronous setup
        // starts. The event handler already rejects commands when busy.
        [rows addObject:Row(primary,playing?@"pause":paused?@"resume":@"play",YES)];
        BOOL played=[userData[@"Played"] boolValue],favorite=[userData[@"IsFavorite"] boolValue];
        [rows addObject:Row(played?@"✓ Watched":@"✓ Mark watched",@"watched",YES)];
        [rows addObject:Row(favorite?@"♥ Favorite":@"♡ Favorite",@"favorite",YES)];
        NSString *subtitle=[_session subtitleSelectionLabel];
        if(subtitle.length)[rows addObject:Row(subtitle,@"subtitle",!busy)];
        NSString *audio=[_session audioSelectionLabel];
        if(audio.length)[rows addObject:Row(audio,@"audio",!busy)];
        [rows addObject:Row(@"Information",@"info",YES)];
        if (_selection<0 || (NSUInteger)_selection>=rows.count)_selection=0;
    } else {
        title=page==JFSeasonsPage ? @"Jellyfin — Seasons" : page==JFEpisodesPage ? @"Jellyfin — Episodes" : @"Jellyfin — Media";
        NSArray *items=snapshot[@"media"];
        if (page==JFMediaPage && _searchActive)
            [rows addObject:Row(_searchQuery.length?_searchQuery:@"Search this library",@"search-edit",!busy)];
        NSUInteger matched=0;
        for (NSUInteger i=0;i<items.count;i++) {
            NSDictionary *item=items[i];
            NSString *label=nil;
            if (page==JFMediaPage && [item[@"Type"] isEqual:@"Movie"])label=JFMovieRowTitle(item);
            else if (page==JFSeasonsPage)label=JFSeasonRowTitle(item);
            else if (page==JFEpisodesPage)label=JFEpisodeRowTitle(item);
            else label=item[@"Name"];
            NSString *name=[item[@"Name"] isKindOfClass:[NSString class]]?item[@"Name"]:@"";
            if (page==JFMediaPage && _searchActive && _searchQuery.length &&
                [name rangeOfString:_searchQuery options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location==NSNotFound)
                continue;
            NSMutableDictionary *row=[[Row(label,@"media",!busy) mutableCopy] autorelease];
            row[@"itemID"]=item[@"Id"]?:@"";
            row[@"mediaIndex"]=@(i);
            row[@"name"]=name;
            if ([item[@"ProductionYear"] isKindOfClass:[NSNumber class]])
                row[@"year"]=item[@"ProductionYear"];
            [rows addObject:row];matched++;
        }
        if (!matched) {
            NSString *empty=page==JFSeasonsPage ? @"No seasons available" : page==JFEpisodesPage ? @"No episodes available" : @"No media available";
            [rows addObject:Row(empty,@"none",NO)];
        }
        // Every list shows its complete contents; trailing Back remains selectable.
        // Do not clamp against items.count: that would trap the cursor on the last
        // media entry when focused on the Back action during a poster refresh.
        if (page==JFMediaPage && _searchActive) {
            [rows addObject:Row(@"Close search",@"search-close",!busy)];
        } else {
            [rows addObject:Row(@"Back",@"back",!busy)];
            [rows addObject:Row(@"Search",@"search",page==JFMediaPage&&!busy)];
        }
        if (_selection<0 || (NSUInteger)_selection>=rows.count) _selection=0;
    }
    // Progressive pagination appends media after the user may have focused
    // Back/Search. Those action rows shift right; preserve focus by action,
    // not by their old numeric index.
    if(page==JFMediaPage && !busy && _selection>=0 &&
       (NSUInteger)_selection<_rows.count) {
        NSString *oldAction=_rows[(NSUInteger)_selection][@"action"];
        if([@[@"back",@"search",@"search-close",@"search-edit"] containsObject:oldAction])
            for(NSUInteger i=0;i<rows.count;i++)
                if([rows[i][@"action"] isEqual:oldAction]){_selection=(NSInteger)i;break;}
    }
    NSString *error=_session.errorKind;
    NSString *message=page==JFLibrariesPage && _session.scanStatus.length ?
                     _session.scanStatus : _message;
    if ([error isEqual:@"authentication"]) message=_session.errorCode ? [NSString stringWithFormat:@"Sign in again — authentication failed (%ld)",(long)_session.errorCode] : @"Sign in again — session expired or credentials rejected";
    else if ([error isEqual:@"timeout"]) message=@"Request timed out — try again";
    else if ([error isEqual:@"tls"]) message=@"Secure connection failed — check the server certificate and Apple TV date";
    else if ([error isEqual:@"transport"]) message=@"Cannot reach the server — check its address and your network";
    else if ([error isEqual:@"request"] && page==JFLibrariesPage && _session.errorCode==403)
        message=@"Library scan denied — Jellyfin administrator required";
    else if ([error isEqual:@"request"]) message=_session.errorCode ? [NSString stringWithFormat:@"Request failed (%ld)",(long)_session.errorCode] : @"Request failed — try again";
    if (message.length) [rows addObject:Row(message,@"none",NO)];
    if (busy) title=[title stringByAppendingString:@" — Loading…"];
    // Empty libraries, seasons, episodes and zero-result searches have a
    // disabled explanatory row. Focus the first enabled Back/Search control.
    // Every library row is temporarily disabled during async open. Do not
    // reset its focus to row 0 (Archived) while the user-selected Movie/Erotic
    // tile is awaiting the next page. Commands are already blocked when busy.
    if(_selection<0 || (NSUInteger)_selection>=rows.count ||
       (!busy && ![rows[(NSUInteger)_selection][@"enabled"] boolValue])) {
        _selection=0;
        while((NSUInteger)_selection<rows.count &&
              ![rows[(NSUInteger)_selection][@"enabled"] boolValue]) _selection++;
        if((NSUInteger)_selection>=rows.count)_selection=0;
    }
    [self displayTitle:title rows:rows selection:_selection];
    [_lastPresentedPlayerState release];
    _lastPresentedPlayerState=[_session.playback.currentState copy];
    [self displayVisual];
    NSTimeInterval refreshDuration=[NSProcessInfo processInfo].systemUptime-refreshStart;
    if(refreshDuration>0.075)
        JFPosterTrace([NSString stringWithFormat:
            @"PERF_REFRESH_SLOW page=%ld busy=%d duration_ms=%lld rows=%lu",
            (long)page,busy,(long long)(refreshDuration*1000.0),
            (unsigned long)rows.count]);
}
- (void)clearEditor {
    if (!_editor) return;
    JFBRCall(_editor,@"setTextFieldDelegate:",@[[NSNull null]]);
    JFBRCall(_editor,@"setInitialTextEntryText:",@[@""]);
    [_editor release]; _editor=nil; _editKind=0;
}
- (void)edit:(NSUInteger)kind {
    if (_editor || _closed || _session.busy) return;
    id stack=JFBRObject(_controller,@"stack");
    if (!JFBRProtocolMatches([self class],@"BRTextFieldDelegate",@[@"textDidChange:",@"textDidEndEditing:"])) {
        [self setMessage:@"Text input is unavailable"]; [self refreshView]; return;
    }
    id editor=JFNewTextEntryController();
    BOOL valid=JFBRHas(stack,@"pushController:",@encode(void),@[@"@"]) && JFBRHas(stack,@"popController",@encode(void),@[]) &&
        JFBRHas(editor,@"setTextFieldDelegate:",@encode(void),@[@"@"]) &&
        JFBRHas(editor,@"setInitialTextEntryText:",@encode(void),@[@"@"]) &&
        JFBRHas(editor,@"setTextEntryTextFieldLabel:",@encode(void),@[@"@"]) &&
        JFBRHas(editor,@"editor",@encode(id),@[]);
    id field=JFBRObject(JFBRObject(editor,@"editor"),@"textField");
    valid=valid && JFBRHas(field,@"stringValue",@encode(id),@[]);
    if (kind==3) valid=valid && JFBRSetBool(editor,@"setShowUserEnteredText:",NO);
    if (!valid) { [editor release]; [self setMessage:@"Text input is unavailable"]; [self refreshView]; return; }
    NSString *label=kind==1?@"Server URL":kind==2?@"Username":kind==3?@"Password":@"Search this library";
    JFBRCall(editor,@"setTextEntryTextFieldLabel:",@[label]);
    JFBRCall(editor,@"setInitialTextEntryText:",@[kind==1 ? _server : kind==2 ? _username : @""]);
    JFBRCall(editor,@"setTextFieldDelegate:",@[self]);
    _editor=editor; _editKind=kind;
    JFBRCall(stack,@"pushController:",@[editor]);
}
// Required BRTextFieldDelegate callback. Submission occurs only on end-editing.
- (void)textDidChange:(id)sender { (void)sender; }
- (void)textDidEndEditing:(id)sender {
    if (![NSThread isMainThread] || _closed || !_editor || sender!=JFBRObject(JFBRObject(_editor,@"editor"),@"textField")) return;
    id value=JFBRObject(sender,@"stringValue");
    if (![value isKindOfClass:[NSString class]]) return;
    NSString *text=[value copy]; NSUInteger kind=_editKind;
    id stack=[JFBRObject(_controller,@"stack") retain];
    [self clearEditor];
    // Retain through reentrant pop/activation callbacks.
    [self retain]; JFBRCall(stack,@"popController",@[]); [stack release];
    if (!_closed) {
        [self setMessage:@""];
        if (kind==1) {
            NSError *error=nil;
            NSString *address=text.length ? JFNormalizeServerAddress(text,&error) : @"";
            if (!address) [self setMessage:error.localizedDescription];
            else {
                if (![_server isEqual:address]) { [self clearSessionCredential]; [self clearSession]; }
                [_server release]; _server=[address copy]; [self saveConfiguration];
            }
        } else if (kind==2) {
            if (![_username isEqual:text]) { [self clearSessionCredential]; [self clearSession]; }
            [_username release]; _username=[text copy]; [self saveConfiguration];
        } else if (kind==4) {
            [_searchQuery release];_searchQuery=[text copy];_searchActive=YES;_selection=0;
        } else { [_password release]; _password=[text copy]; _passwordEntered=YES; }
        [self refreshView];
    }
    [text release]; [self release];
}
- (void)signIn {
    if (_closed || _session.busy || !_passwordEntered) return;
    NSString *address=JFNormalizeServerAddress(_server,NULL);
    if (!address) { [self setMessage:@"Enter a valid server address"]; [self refreshView]; return; }
    if (!_allowHTTP && [[[NSURL URLWithString:address] scheme] isEqual:@"http"]) {
        [self setMessage:@"HTTP is disabled — enable Allow HTTP or use HTTPS"]; [self refreshView]; return;
    }
    NSString *secret=[_password copy];
    [self clearSessionCredential]; [self clearSession]; [self setMessage:@""];
    NSString *device=[self deviceID];
    _session=[[JFSession alloc] initWithURL:[NSURL URLWithString:address] deviceID:device allowHTTP:_allowHTTP];
    if (_session) {
        _host=[[JFSessionHost alloc] initWithSession:_session]; [self observe];
        if (_playbackBackend) [_session configurePlaybackBackend:_playbackBackend];
        [_session login:_username password:secret];
    } else [self setMessage:@"Check the server URL; HTTP requires Allow HTTP"];
    [secret release]; [self refreshView];
}
- (void)probeLibraryResponsiveness:(NSArray *)probe {
    if(_closed || probe.count!=2)return;
    NSTimeInterval start=[probe[0] doubleValue], expected=[probe[1] doubleValue];
    NSTimeInterval now=[NSProcessInfo processInfo].systemUptime;
    JFPosterTrace([NSString stringWithFormat:
        @"PERF_MAINLOOP_WATCH expected_ms=%lld actual_ms=%lld lag_ms=%lld page=%ld busy=%d",
        (long long)(expected*1000.0),(long long)((now-start)*1000.0),
        (long long)(MAX(0.0,now-start-expected)*1000.0),
        (long)[self phoneRemotePage],_session.busy]);
}
- (NSInteger)phoneRemotePage {
    // Read-only model page: event processing stays on the main thread.
    return _session ? [_session.snapshot[@"page"] integerValue] : -1;
}
- (void)synchronizeNativeSelection:(long)row {
    if (![NSThread isMainThread] || !_active || _closed || _editor || _session.busy || ![self rowSelectable:row]) return;
    if (_session && [_session.snapshot[@"page"] integerValue]!=JFLoginPage) return;
    JFPosterTrace([NSString stringWithFormat:@"NATIVE_SYNC from=%ld to=%ld",(long)_selection,row]);
    _selection=row;
    if ([_rows[(NSUInteger)row][@"action"] isEqual:@"media"])
        [_session focusMediaAtIndex:(NSUInteger)row];
}
- (void)selectRow:(long)row {
    if (![NSThread isMainThread] || !_active || _closed || _editor || _session.busy || ![self rowSelectable:row]) return;
    NSString *action=_rows[row][@"action"];
    // Native callbacks must agree with our controlled focus; never select a stale model row.
    if (([action isEqual:@"library"] || [action isEqual:@"media"]) && row!=_selection) return;
    _selection=row;
    if ([action isEqual:@"server"]) [self edit:1];
    else if ([action isEqual:@"username"]) [self edit:2];
    else if ([action isEqual:@"password"]) [self edit:3];
    else if ([action isEqual:@"signin"]) [self signIn];
    else if ([action isEqual:@"http"]) {
        _allowHTTP=!_allowHTTP;
        if (!_allowHTTP && [[[NSURL URLWithString:_server] scheme] isEqual:@"http"]) { [self clearSessionCredential]; [self clearSession]; }
        [self saveConfiguration]; [self refreshView];
    }
    else if ([action isEqual:@"library"]) {
        // The animated grid keeps cursor focus locally. Only commit the
        // library to the serialized browser worker on SELECT.
        NSArray *libraries=_session.snapshot[@"libraries"];
        NSDictionary *library=(row>=0 && (NSUInteger)row<libraries.count) ? libraries[(NSUInteger)row] : nil;
        NSString *collection=[library[@"CollectionType"] isKindOfClass:[NSString class]] ? [library[@"CollectionType"] lowercaseString] : @"";
        if ([collection isEqual:@"movies"] || [collection isEqual:@"tvshows"]) {
            // Keep the visually selected tile in place until the new media
            // snapshot arrives. No intermediate model focus notification.
            NSString *kind=[collection isEqual:@"movies"]?@"Movie":@"Series";
            NSTimeInterval started=[NSProcessInfo processInfo].systemUptime;
            JFPosterTrace([NSString stringWithFormat:
                @"LIBRARY_OPEN_ATOMIC index=%ld uptime_ms=%lld",
                (long)row,(long long)(started*1000.0)]);
            // One-shot, low-overhead main-thread heartbeat. A 4–5 second UI
            // stall is distinguishable from a slow but asynchronous HTTP fetch.
            for(NSNumber *delay in @[@0.25,@1.0])
                [self performSelector:@selector(probeLibraryResponsiveness:)
                     withObject:@[@(started),delay] afterDelay:[delay doubleValue]];
            if (![_session openLibraryAtIndex:(NSUInteger)row type:kind]) {
                [self setMessage:@"Browse request did not start"]; [self refreshView];
            }
        } else {
            // Mixed library: commit the actual selected index, then let the
            // original type chooser handle its two possibilities.
            (void)[_session focusLibraryAtIndex:(NSUInteger)row];
            [_host handleRemoteEvent:@{@"button":@(JFSelect),@"phase":@"press"}];
        }
    }
    else if ([action isEqual:@"media"]) [_session openMediaAtIndex:[_rows[(NSUInteger)row][@"mediaIndex"] unsignedIntegerValue]];
    else if ([action isEqual:@"movies"]) { if (![_session openLibraryWithType:@"Movie"]) { [self setMessage:@"Browse request did not start"]; [self refreshView]; } }
    else if ([action isEqual:@"series"]) { if (![_session openLibraryWithType:@"Series"]) { [self setMessage:@"Browse request did not start"]; [self refreshView]; } }
    else if ([action isEqual:@"search"]) {
        [_searchQuery release];_searchQuery=[@"" copy];
        _searchActive=YES;_selection=0;[self refreshView];
    }
    else if ([action isEqual:@"search-close"]) {
        _searchActive=NO;_selection=0;[self refreshView];
    }
    else if ([action isEqual:@"search-edit"]) {
        [_searchQuery release];_searchQuery=[@"" copy];
        [self edit:4];
    }
    else if ([action isEqual:@"watched"]) {
        BOOL prior=[_session.snapshot[@"detail"][@"UserData"][@"Played"] boolValue];
        if(![_session setDetailFlag:@"Played" enabled:!prior])[self setMessage:@"Cannot change watched status"];
    }
    else if ([action isEqual:@"favorite"]) {
        BOOL prior=[_session.snapshot[@"detail"][@"UserData"][@"IsFavorite"] boolValue];
        if(![_session setDetailFlag:@"Favorite" enabled:!prior])[self setMessage:@"Cannot change favorite status"];
    }
    else if ([action isEqual:@"info"]) { /* Non-interactive metadata pane. */ }
    else if ([action isEqual:@"refresh"]) {
        JFPosterTrace([NSString stringWithFormat:@"LIBRARY_SCAN_BUTTON_ACTIVATED selected=%ld",(long)_selection]);
        _pendingLibraryRefresh=YES;
        if (![_session refresh]) {
            _pendingLibraryRefresh=NO;
            [self setMessage:@"Library refresh unavailable — try again"];
            JFPosterTrace(@"LIBRARY_SCAN_REQUEST_REJECTED_LOCALLY");
            [self refreshView];
        }
    }
    else if ([action isEqual:@"logout"]) { [self clearSessionCredential]; [_session signOut]; }
    else if ([action isEqual:@"play"]) [_session playDetail];
    else if ([action isEqual:@"pause"]) [_session.playback pause];
    else if ([action isEqual:@"resume"]) [_session resumeDetailPlayback];
    else if ([action isEqual:@"seek-back"]) [_session.playback seekBySeconds:-300];
    else if ([action isEqual:@"seek-forward"]) [_session.playback seekBySeconds:300];
    else if ([action isEqual:@"audio"]) { if (![_session cycleAudioTrack]) [self setMessage:@"Audio track change failed"]; [self refreshView]; }
    else if ([action isEqual:@"subtitle"]) { if (![_session cycleSubtitleTrack]) [self setMessage:@"Subtitle change failed"]; [self refreshView]; }
    else if ([action isEqual:@"stop"]) [_session.playback stop];
    else if ([action isEqual:@"back"]) [_session goBack];
}
- (JFHostEventResult)handleEvent:(NSDictionary *)event {
    if (![NSThread isMainThread] || !_active || _closed || _editor || ![event isKindOfClass:[NSDictionary class]]) return JFHostEventUnhandled;
    id button=event[@"button"], phase=event[@"phase"];
    if (![button isKindOfClass:[NSNumber class]] || ![phase isKindOfClass:[NSString class]] ||
        ![@[@"press",@"release",@"hold",@"repeat"] containsObject:phase]) return JFHostEventUnhandled;
    NSInteger b=[button integerValue];
    if (b<JFUp || b>JFMenu || ![button isEqualToNumber:@(b)]) return JFHostEventUnhandled;
    if (_session.busy) return JFHostEventConsumed;
    if (b==JFMenu) {
        if (![phase isEqual:@"press"]) return JFHostEventConsumed;
        NSInteger page=[_session.snapshot[@"page"] integerValue];
        if (_searchActive && page==JFMediaPage) {
            _searchActive=NO;_selection=0;[self refreshView];return JFHostEventConsumed;
        }
        NSString *playbackState=_session.playback.currentState;
        BOOL playbackActive=[@[@"setup",@"playing",@"paused"] containsObject:playbackState ?: @""];
        if (page==JFDetailPage && playbackActive) {
            // Queue navigation before stop publishes a synchronous Detail refresh.
            // This avoids losing the second Menu press during the stopped-state redraw.
            BOOL backing=[_session goBack];
            BOOL stopped=[_session.playback stop];
            JFPlaybackTrace([NSString stringWithFormat:@"MENU_DETAIL backQueued=%d stopped=%d",backing,stopped]);
            if (backing || stopped) return JFHostEventConsumed;
        }
        if ([_session.playback stop]) return JFHostEventConsumed;
        return _host ? [_host handleRemoteEvent:event] : ([_session goBack] ? JFHostEventConsumed : JFHostEventExitRequested);
    }
    if ([phase isEqual:@"release"]) return JFHostEventConsumed;
    JFPosterTrace([NSString stringWithFormat:@"MODEL_REMOTE button=%ld phase=%@ selected=%ld snapshotIndex=%ld snapshotMediaIndex=%ld",(long)b,phase,(long)_selection,(long)[_session.snapshot[@"index"] integerValue],(long)[_session.snapshot[@"mediaIndex"] integerValue]]);
    // Single left/right presses seek by five minutes while a movie is active.
    // Ignore hold/repeat so a held key cannot accidentally skip whole chapters.
    NSString *playbackState=_session.playback.currentState;
    if ((b==JFLeft || b==JFRight) && [phase isEqual:@"press"] &&
        [_session.snapshot[@"page"] integerValue]==JFDetailPage &&
        ([@"playing" isEqual:playbackState] || [@"paused" isEqual:playbackState])) {
        [_session.playback seekBySeconds:(b==JFRight ? 300 : -300)];
        return JFHostEventConsumed;
    }
    if (b==JFSelect) {
        if ([phase isEqual:@"press"]) [self selectRow:_selection];
        return JFHostEventConsumed;
    }
    if ([@[@(JFLeft),@(JFRight),@(JFUp),@(JFDown)] containsObject:@(b)] &&
        [_session.snapshot[@"page"] integerValue]!=JFLoginPage &&
        [_session.snapshot[@"page"] integerValue]!=JFLibraryPage) {
        [self moveGrid:b];return JFHostEventConsumed;
    }
    if (b!=JFUp && b!=JFDown) return JFHostEventConsumed;
    long step=b==JFUp ? -1 : 1, next=_selection+step;
    while (next>=0 && (NSUInteger)next<_rows.count && ![self rowSelectable:next]) next+=step;
    if (next<0 || (NSUInteger)next>=_rows.count) return JFHostEventConsumed;
    NSString *action=_rows[next][@"action"], *previous=_rows[_selection][@"action"];
    if ([action isEqual:@"library"] || [action isEqual:@"media"]) {
        if ([action isEqual:previous]) {
            // Keep model ownership of media/library focus. The completion redraws it.
            _selection=next;
            if ([action isEqual:@"media"]) [_session focusMediaAtIndex:(NSUInteger)next];
            else [_session handleEvent:event];
            return JFHostEventConsumed;
        }
        // Re-entering a list from its action rows restores the model's current focus.
        _selection=[_session.snapshot[[action isEqual:@"library"] ? @"index" : @"mediaIndex"] longValue];
    } else _selection=next;
    [self refreshView]; return JFHostEventConsumed;
}
// Grid geometry is owned by this presentation layer. Browser/worker state is
// updated only for media focus and selected library; no network calls on arrows.
- (BOOL)moveGrid:(NSInteger)b {
    if (_closed || !_session || _session.busy || !_rows.count) return NO;
    NSInteger page=[_session.snapshot[@"page"] integerValue], old=_selection,next=old;
    BOOL horizontal=(b==JFLeft||b==JFRight);
    if (page==JFLibrariesPage) {
        NSInteger count=[_session.snapshot[@"libraries"] count];
        if (old>=0 && old<count) {
            if (b==JFLeft && old%4>0)next--;
            if (b==JFRight && old%4<3 && old+1<count)next++;
            if (b==JFUp)next=old>=4?old-4:count+(old%4>=(count>2?2:1)?1:0);
            if (b==JFDown && old+4<count)next=old+4;
        } else {
            if (horizontal)next=b==JFLeft?count:count+1;
            if (b==JFDown && count) {
                // Header actions enter the left/right half of the first row.
                NSInteger column=old==count+1?3:0;
                next=MIN(column,count-1);
            }
        }
        if (next==old || next<0 || (NSUInteger)next>=_rows.count || ![self rowSelectable:next])return YES;
        _selection=next;
        if([_visual usingNativeFocus]) {
            [self displayVisual];return YES;
        }
        if(next<count) {
            BOOL changed=[_session.snapshot[@"index"] integerValue]!=next;
            if ([_session focusLibraryAtIndex:(NSUInteger)next] && changed)
                return YES; // Session notification already redrew the grid.
        }
        [self refreshView];return YES;
    }
    if(page==JFDetailPage) {
        NSInteger last=(NSInteger)_rows.count-1;
        if(old==last && !horizontal) {
            if(b==JFDown) {
                CGFloat maxScroll=[JFVisualUI maxScrollForDetail:_session.snapshot[@"detail"] rows:_rows];
                _detailScroll=fmin(maxScroll,_detailScroll+74);[self displayVisual];return YES;
            }
            if(b==JFUp && _detailScroll>0) { _detailScroll=fmax(0,_detailScroll-74);[self displayVisual];return YES;}
        }
        if(old<3) {
            if(b==JFLeft && old>0)next=old-1;
            if(b==JFRight && old<2)next=old+1;
            if(b==JFDown)next=MIN(3,last);
        } else {
            if(b==JFUp)next=old==3?0:old-1;
            if(b==JFDown)next=MIN(old+1,last);
        }
        if(next>=0 && next<(NSInteger)_rows.count && [self rowSelectable:next]) {
            _selection=next;[self refreshView];
        }
        return YES;
    }
    NSInteger start=_searchActive&&page==JFMediaPage?1:0;
    NSInteger end=(NSInteger)_rows.count-(_searchActive&&page==JFMediaPage?1:2);
    NSInteger count=MAX(0,end-start);
    if (old>=start && old<end) {
        NSInteger index=old-start;
        if (b==JFLeft && index%5>0)next=old-1;
        if (b==JFRight && index%5<4 && index+1<count)next=old+1;
        if (b==JFUp)next=index>=5?old-5:(_searchActive&&page==JFMediaPage?0:end+(index%5>=3?1:0));
        if (b==JFDown && index+5<count)next=old+5;
    } else if (_searchActive && page==JFMediaPage) {
        if(old==0 && b==JFDown && count)next=1;
        else if(old==end && b==JFDown && count)next=1;
        else if(old==end && b==JFUp)next=0;
        else if(old==0 && b==JFRight)next=end;
        else if(old==end && b==JFLeft)next=0;
    } else {
        if (horizontal)next=b==JFLeft?end:end+1;
        if(b==JFDown && count)next=start+(old==end+1?MIN(4,count-1):0);
    }
    if(next!=old && next>=0 && (NSUInteger)next<_rows.count && [self rowSelectable:next]) {
        _selection=next;
        if([_visual usingNativeFocus]) {
            // The common case is moving among the ten visible movie tiles.
            // Do ONLY a compositor focus animation; a full renderSnapshot
            // would synchronously probe posters and rebuild row captions.
            if(page==JFMediaPage &&
               [_visual animateMovieFocusOnlyWithSnapshot:_session.snapshot
                    rows:_rows selection:_selection search:_searchActive])
                return YES;
            [self displayVisual];return YES; // row window changed or new page
        }
        NSDictionary *row=_rows[(NSUInteger)next];
        if([row[@"action"] isEqual:@"media"]) {
            NSUInteger nextIndex=[row[@"mediaIndex"] unsignedIntegerValue];
            BOOL changed=[_session.snapshot[@"mediaIndex"] unsignedIntegerValue]!=nextIndex;
            if ([_session focusMediaAtIndex:nextIndex] && changed)
                return YES; // Avoid a second full-screen JPEG encode per keypress.
        }
        [self refreshView];
    }
    return YES;
}
- (void)dealloc {
    [self close]; [_visual release];[_artwork release];[_artworkToken release];[_searchQuery release];[_lastPresentedPlayerState release]; [_previewSourceData release]; [_previewDisplayData release]; [_playbackBackend release]; [_server release]; [_username release]; [_password release]; [_configurationDefaults release]; [_message release]; [super dealloc];
}
@end
