#import <Foundation/Foundation.h>
#import "JFImageCache.h"
// Synchronous worker-thread API. Never call from the BackRow event thread.
@interface JFClient : NSObject <NSURLConnectionDelegate> {
    NSTimeInterval _timeout;
    JFImageCache *_metadataCache;
    BOOL _catalogNetworkOnly;
    NSMutableSet *_imageCaches;
    NSURL *_baseURL;
    NSString *_deviceID, *_token, *_userID, *_imageNamespace;
}
- (id)initWithURL:(NSURL *)url deviceID:(NSString *)deviceID;
@property(nonatomic) NSTimeInterval timeout;
@property(nonatomic) BOOL catalogNetworkOnly; // dedicated background refetch client only // 0.05..300 seconds; set on the owning worker.
- (NSDictionary *)serverInfo:(NSError **)error;
- (BOOL)login:(NSString *)username password:(NSString *)password error:(NSError **)error;
- (NSArray *)libraries:(NSError **)error;
// All IDs are server identifiers (ASCII alphanumeric, '-' or '_'), never paths.
- (NSArray *)itemsInLibrary:(NSString *)parent type:(NSString *)type start:(NSUInteger)start limit:(NSUInteger)limit error:(NSError **)error;
- (NSArray *)seasons:(NSString *)series error:(NSError **)error;
- (NSArray *)episodes:(NSString *)series season:(NSString *)season error:(NSError **)error;
- (NSDictionary *)item:(NSString *)identifier error:(NSError **)error;
- (BOOL)setUserFlag:(NSString *)flag item:(NSString *)identifier enabled:(BOOL)enabled error:(NSError **)error;
- (NSDictionary *)playbackInfo:(NSString *)identifier error:(NSError **)error;
// Independent playback API. Requests carry authentication headers, never log them.
- (NSDictionary *)playbackInfo:(NSString *)identifier startTicks:(long long)ticks subtitleIndex:(NSInteger)index error:(NSError **)error;
- (NSDictionary *)playbackInfo:(NSString *)identifier startTicks:(long long)ticks mediaSourceID:(NSString *)source audioIndex:(NSInteger)audioIndex subtitleIndex:(NSInteger)subtitleIndex error:(NSError **)error;
- (NSURLRequest *)playbackRequest:(NSDictionary *)plan error:(NSError **)error;
- (BOOL)reportPlayback:(NSString *)event body:(NSDictionary *)body error:(NSError **)error;
- (NSURLRequest *)subtitleRequest:(NSString *)item mediaSource:(NSString *)source index:(NSInteger)index error:(NSError **)error;
- (NSData *)subtitleData:(NSString *)item mediaSource:(NSString *)source index:(NSInteger)index error:(NSError **)error;
// Playback path: fetch + parse once off the main thread; return immutable cues.
- (NSArray *)localSubtitleCues:(NSString *)item mediaSource:(NSString *)source index:(NSInteger)index error:(NSError **)error;
// Authenticated image bytes use the same bounded/cancellable transport as JSON.
- (NSData *)imageData:(NSString *)identifier backdrop:(BOOL)backdrop width:(NSUInteger)width cache:(JFImageCache *)cache error:(NSError **)error;
- (NSData *)imageDataForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width cache:(JFImageCache *)cache error:(NSError **)error;
- (NSData *)imageDataForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width cache:(JFImageCache *)cache priority:(NSUInteger)priority error:(NSError **)error;
- (BOOL)hasLocalImageForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width cache:(JFImageCache *)cache;
- (NSURLRequest *)backdropRequest:(NSString *)identifier width:(NSUInteger)width error:(NSError **)error;
- (NSURLRequest *)posterRequest:(NSString *)identifier width:(NSUInteger)width error:(NSError **)error;
- (NSURLRequest *)streamRequest:(NSString *)identifier mediaSource:(NSString *)source error:(NSError **)error;
// Worker-only integration/session operations; no credential logging.
- (BOOL)authenticateToken:(NSString *)token error:(NSError **)error;
- (NSString *)sessionToken; // Worker-thread copy; never include in snapshots or logs.
- (BOOL)endSession:(NSError **)error;
- (BOOL)endSessionAndVerifyInvalidation:(NSError **)error;
- (BOOL)hasSession;
- (void)logout;
@end
