#import <Foundation/Foundation.h>
#import "API/JFClient.h"
#import "Input/JFRemote.h"
typedef NS_ENUM(NSInteger, JFPage) { JFLoginPage, JFLibrariesPage, JFLibraryPage, JFMediaPage, JFSeasonsPage, JFEpisodesPage, JFDetailPage };
// Serial worker-thread model. UI must marshal snapshots to its own thread.
// Independent navigation only; no BackRow view or player is attached.
@interface JFBrowser : NSObject {
    JFClient *_client;
    NSArray *_libraries, *_media;
    NSMutableArray *_history;
    NSDictionary *_detail;
    NSString *_seriesID, *_parentID, *_mediaType;
    NSInteger _mediaIndex;
    NSArray *_queuedLibraryMedia;
    NSUInteger _nextLibraryOffset;
    BOOL _libraryMore;
    NSInteger _index;
    JFPage _page;
}
@property(nonatomic, readonly) JFPage page;
@property(nonatomic, readonly) NSInteger index;
@property(nonatomic, readonly) NSArray *libraries;
@property(nonatomic, readonly) NSDictionary *selectedLibrary;
- (id)initWithClient:(JFClient *)client;
- (BOOL)login:(NSString *)username password:(NSString *)password error:(NSError **)error;
- (BOOL)authenticateToken:(NSString *)token error:(NSError **)error;
- (NSString *)sessionToken;
- (BOOL)refresh:(NSError **)error;
- (BOOL)refreshUncached:(NSError **)error; // explicit user refresh forces live Jellyfin
- (BOOL)handleEvent:(NSDictionary *)event;
@property(nonatomic, readonly) NSArray *media;
@property(nonatomic, readonly) NSDictionary *detail;
@property(nonatomic, readonly) NSInteger mediaIndex;
- (BOOL)openLibraryWithType:(NSString *)type error:(NSError **)error;
// Display the first ten items immediately, then fill the list in background.
- (BOOL)openFirstLibraryScreenWithType:(NSString *)type error:(NSError **)error;
- (BOOL)appendNextLibraryChunk:(NSError **)error;
@property(nonatomic, readonly) BOOL hasRemainingLibraryItems;
- (void)focusLibraryAtIndex:(NSUInteger)index;
- (BOOL)setDetailFlag:(NSString *)flag enabled:(BOOL)enabled error:(NSError **)error;
- (BOOL)openMediaAtIndex:(NSUInteger)index error:(NSError **)error;
- (BOOL)goBack;
// Copy of model state suitable for main-thread delivery via JFWorker.
- (NSDictionary *)snapshot;
- (BOOL)signOut:(NSError **)error;
- (void)logout;
@end
