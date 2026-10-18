#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>
@class JFArtwork;
// Pure BackRow raster surface. The login screen keeps its original native list.
@interface JFVisualUI : NSObject {
    id _host; // non-owning; closed before controller deallocation
    id _surface;
    id _focus; // Native CoreAnimation-backed BRControl, never rasterized
    id _detailPoster; // Movie details cover receives the same native fade
    NSData *_detailPosterData;
    NSMutableArray *_tiles, *_tileStamps; // persistent, native image controls
    NSMutableArray *_nativeCaptions; // 15 x (name, year) CATextLayer pairs
    id _captionHost; // overlay above image tiles, not hidden underneath them
    NSMutableArray *_captionStamps;
    NSUInteger _captionCount;
    NSString *_captionScope;
    NSInteger _captionRow;
    BOOL _nativeCaptionReady;
    BOOL _tilesReady;
    CGColorRef _focusColor;
    dispatch_queue_t _sceneQueue;
    NSMutableDictionary *_sceneCache;
    NSMutableArray *_sceneOrder;
    NSString *_pendingSceneKey;
    NSString *_lastDrawKey, *_viewScope;
    NSInteger _visibleFirstRow;
    NSInteger _lastTileRow, _lastTilePage;
    NSUInteger _lastTileArtworkVersion, _lastTileCount;
    NSString *_lastTileScope;
    BOOL _lastTileSearch;
    CGRect _focusFrame;
    CFTimeInterval _sharedScrollStart;
    BOOL _loginFocusTransition, _focusRevealScheduled;
    BOOL _closed;
}
- (id)initWithController:(id)controller;
- (void)renderSnapshot:(NSDictionary *)snapshot
                  rows:(NSArray *)rows
             selection:(long)selection
               artwork:(JFArtwork *)artwork
                poster:(NSData *)poster
              username:(NSString *)username
                search:(BOOL)search
                 query:(NSString *)query
                scroll:(CGFloat)scroll;
+ (CGFloat)maxScrollForDetail:(NSDictionary *)detail rows:(NSArray *)rows;
- (BOOL)usingNativeFocus;
- (void)hide;
- (void)close;
@end
