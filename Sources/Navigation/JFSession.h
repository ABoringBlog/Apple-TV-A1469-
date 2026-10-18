#import <Foundation/Foundation.h>
#import "Playback/JFPlaybackController.h"
@class JFBrowser, JFWorker, JFSessionDelivery, JFTask, JFImageCache;
// Main-thread API. Changed notifications are synchronous on main, object=self.
// Hosts must remove observers and close before releasing their last session reference.
extern NSString * const JFSessionChanged;
@interface JFSession : NSObject {
    JFBrowser *_browser;
    JFClient *_playbackClient;
    JFPlaybackController *_playback;
    JFWorker *_worker;
    JFTask *_posterTask;
    JFImageCache *_artworkCache;
    JFSessionDelivery *_delivery;
    NSDictionary *_snapshot;
    NSString *_errorKind, *_errorDomain, *_sessionToken;
    NSData *_posterData;
    NSString *_posterItemID;
    NSString *_audioItemID, *_audioSourceID;
    NSString *_subtitleItemID, *_subtitleSourceID;
    NSInteger _audioIndex, _subtitleIndex;
    NSInteger _errorCode;
    NSUInteger _generation, _posterGeneration, _libraryContinuationSerial;
    BOOL _libraryContinuationScheduled;
    BOOL _busy, _closed, _visualArtworkMode;
}
- (id)initWithURL:(NSURL *)url deviceID:(NSString *)deviceID allowHTTP:(BOOL)allowHTTP;
@property(nonatomic, readonly, copy) NSDictionary *snapshot;
@property(nonatomic, readonly, copy) NSString *errorKind; // none/authentication/timeout/transport/request
@property(nonatomic, readonly, copy) NSString *errorDomain; // Safe diagnostic metadata only.
@property(nonatomic, readonly) NSInteger errorCode;
@property(nonatomic, readonly, copy) NSString *sessionToken; // Sensitive; never included in snapshot/logging.
@property(nonatomic, readonly, copy) NSData *posterData; // Non-secret, current selected movie only.
@property(nonatomic, readonly, copy) NSString *posterItemID;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL closed;
// YES means accepted. Normal commands reject while busy/closed or on a non-main thread.
// Login supersedes previous work. Credentials live only in the pending work block.
- (BOOL)login:(NSString *)username password:(NSString *)password;
- (BOOL)authenticateToken:(NSString *)token;
- (BOOL)refresh;
- (BOOL)openLibraryWithType:(NSString *)type;
- (BOOL)openLibraryAtIndex:(NSUInteger)index type:(NSString *)type; // atomic select + open, no intermediate focus publish
- (void)setVisualArtworkMode:(BOOL)enabled;
- (BOOL)focusMediaAtIndex:(NSUInteger)index;
- (BOOL)focusLibraryAtIndex:(NSUInteger)index;
- (BOOL)setDetailFlag:(NSString *)flag enabled:(BOOL)enabled;
- (BOOL)openMediaAtIndex:(NSUInteger)index;
- (BOOL)handleEvent:(NSDictionary *)event;
- (BOOL)goBack;
// Optional adapter injection; production has no unverified player implementation.
- (BOOL)configurePlaybackBackend:(id<JFPlaybackBackend>)backend;
@property(nonatomic, readonly, retain) JFPlaybackController *playback;
- (long long)resumeTicksForDetail;
- (BOOL)playDetail;
- (BOOL)resumeDetailPlayback;
- (NSUInteger)audioTrackCount;
- (NSString *)audioSelectionLabel;
- (BOOL)cycleAudioTrack;
- (NSUInteger)subtitleTrackCount;
- (NSString *)subtitleSelectionLabel;
- (BOOL)cycleSubtitleTrack;
- (BOOL)signOut; // Server logout plus local invalidation.
- (BOOL)logout;  // Local invalidation only.
// Terminal, idempotent; suppresses delivery and serially clears authentication/model.
- (void)close;
@end
