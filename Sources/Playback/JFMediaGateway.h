#import <Foundation/Foundation.h>

// Request-by-request credential boundary for the native media loader.
// Only the configured origin is reachable. Redirects and external HLS references fail closed.
@interface JFMediaGateway : NSObject {
    NSURLRequest *_source;
    NSLock *_lock;
    NSMutableArray *_routes;
    NSMutableDictionary *_playlistCache;
    NSMutableSet *_clients;
    int _listener;
    unsigned short _port;
    BOOL _stopped;
    NSURLRequest *_localRequest;
}
- (id)initWithRequest:(NSURLRequest *)request;
- (BOOL)start:(NSError **)error;
- (void)stop;
@property(nonatomic, readonly) NSURLRequest *localRequest;
// Pure policy and playlist transform are exposed for offline contract tests.
+ (NSURL *)allowedURL:(NSString *)reference relativeTo:(NSURL *)base origin:(NSURL *)origin;
- (NSData *)rewritePlaylist:(NSData *)data URL:(NSURL *)url;
@end
