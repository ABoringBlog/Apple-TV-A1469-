#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
@class JFClient, JFWorker, JFImageCache;
extern NSString * const JFArtworkChanged;
// Main-thread artwork window with a dedicated serial network worker. Rendering
// never performs disk access or network I/O. Returned CGImage is retained.
@interface JFArtwork : NSObject {
    JFClient *_client;
    JFWorker *_worker;
    JFWorker *_fastWorker;
    JFClient *_fastClient;
    JFImageCache *_fastDisk;
    BOOL _fastAuthorized;
    NSUInteger _fetchSerial;
    JFWorker *_prefetchWorker;
    JFClient *_prefetchClient;
    JFImageCache *_disk;
    JFImageCache *_prefetchDisk;
    BOOL _activeArchived;
    NSString *_credential;
    NSMutableDictionary *_images;
    NSMutableSet *_pending;
    NSMutableArray *_order;
    BOOL _authorized, _closed, _prefetchStarted;
    NSUInteger _generation, _artworkVersion;
}
- (id)initWithURL:(NSURL *)url deviceID:(NSString *)deviceID token:(NSString *)token;
@property(nonatomic,readonly) NSUInteger artworkVersion;
- (CGImageRef)copyImageForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width;
- (NSData *)imageBytesForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width;
- (void)prefetchLibraries:(NSArray *)libraries;
- (void)setActiveLibraryArchived:(BOOL)archived;
- (void)close;
@end
