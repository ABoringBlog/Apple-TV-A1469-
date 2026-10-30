#import "JFBRMenu.h"
#import <CoreGraphics/CoreGraphics.h>
#import "Playback/JFPlaybackController.h"
@class JFSession, JFSessionHost, JFVisualUI, JFArtwork;
// Presentation/controller bridge only; networking and model state stay in JFSession.
@interface JFUIController : JFBRMenu {
    JFSession *_session;
    id<JFPlaybackBackend> _playbackBackend;
    JFSessionHost *_host;
    NSString *_server, *_username, *_password, *_message;
    NSUserDefaults *_configurationDefaults;
    id _editor;
    NSData *_previewSourceData, *_previewDisplayData;
    NSUInteger _editKind;
    JFVisualUI *_visual;
    JFArtwork *_artwork;
    NSString *_artworkToken, *_searchQuery, *_lastPresentedPlayerState;
    CGFloat _detailScroll;
    BOOL _searchActive, _artworkRefreshScheduled, _pendingLibraryRefresh;
    NSInteger _page;
    BOOL _allowHTTP, _observing, _passwordEntered, _previewSideInset;
}
- (NSInteger)phoneRemotePage;
- (void)probeLibraryResponsiveness:(NSArray *)probe;
- (void)synchronizeNativeSelection:(long)row;
- (BOOL)configurePlaybackBackend:(id<JFPlaybackBackend>)backend;
@property(nonatomic, readonly) JFPlaybackController *playback;
- (id)previewControlForRow:(long)row;
- (void)textDidChange:(id)sender;
- (void)textDidEndEditing:(id)sender;
@end
