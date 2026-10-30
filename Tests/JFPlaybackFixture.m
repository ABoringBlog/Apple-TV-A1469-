#import "JFPlaybackFixture.h"
static NSString *Mode;
static NSMutableArray *Reports;
static NSDictionary *LastBody;
@implementation JFPlaybackFixture
+ (void)setMode:(NSString *)mode { @synchronized(self) { [Mode release]; Mode=[mode copy]; [Reports release]; Reports=[NSMutableArray new]; [LastBody release]; LastBody=nil; } }
+ (NSArray *)reports { @synchronized(self) { return [[Reports copy] autorelease]; } }
+ (NSDictionary *)lastBody { @synchronized(self) { return [[LastBody copy] autorelease]; } }
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqual:@"playback.invalid"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSURLRequest *r=self.request; NSString *path=r.URL.path;
    NSString *mode; @synchronized([self class]) { mode=[[Mode copy] autorelease]; }
    NSInteger status=200; id body=@{}; NSDictionary *headers=@{};
    if ([path hasSuffix:@"AuthenticateByName"]) body=@{@"AccessToken":@"fixture-token",@"User":@{@"Id":@"user1"}};
    else if ([mode isEqual:@"gateway-declared-large"] && [path hasSuffix:@"master.m3u8"]) {
        body=[@"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=400000,CODECS=\"avc1.42c00c,mp4a.40.2\"\nmedia.m3u8\n" dataUsingEncoding:NSUTF8StringEncoding];
        headers=@{@"Content-Type":@"application/vnd.apple.mpegurl",@"Content-Length":@"2097152"};
    }
    else if ([mode isEqual:@"gateway-declared-large"] && [path hasSuffix:@"media.m3u8"]) {
        body=[@"#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment00.ts\n#EXT-X-ENDLIST\n" dataUsingEncoding:NSUTF8StringEncoding];
        headers=@{@"Content-Type":@"application/vnd.apple.mpegurl",@"Content-Length":@"128"};
    }
    else if ([path hasSuffix:@"PlaybackInfo"]) {
        @synchronized([self class]) { [LastBody release]; LastBody=[[NSJSONSerialization JSONObjectWithData:r.HTTPBody options:0 error:NULL] copy]; }
        if ([mode isEqual:@"slow"]) return;
        if ([mode isEqual:@"disconnect"] || [mode isEqual:@"tls"] || [mode isEqual:@"hostname"]) {
            NSInteger code=[mode isEqual:@"disconnect"] ? NSURLErrorNetworkConnectionLost : [mode isEqual:@"hostname"] ? NSURLErrorServerCertificateUntrusted : NSURLErrorSecureConnectionFailed;
            [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil]]; return;
        }
        if ([mode isEqual:@"401"]) status=401;
        else if ([mode isEqual:@"malformed"]) body=@{@"MediaSources":@"wrong"};
        else if ([mode isEqual:@"empty"]) body=@{@"PlaySessionId":@"play1",@"MediaSources":@[]};
        else if ([mode isEqual:@"oversized"]) body=[NSMutableData dataWithLength:8*1024*1024+1];
        else {
            body=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"Tests/playback.json"] options:NSJSONReadingMutableContainers error:NULL];
            if ([mode isEqual:@"fallback-movie"]) body[@"MediaSources"][0][@"Path"]=@"/media/电影/普通电影/Fixture/movie.mp4";
            if ([mode isEqual:@"fallback-tv"]) body[@"MediaSources"][0][@"Path"]=@"/media/电视剧/Fixture/episode.mp4";
            if ([mode isEqual:@"fallback-archived"]) body[@"MediaSources"][0][@"Path"]=@"/media/Archived/Fixture/movie.mp4";
        }
    } else if ([path containsString:@"/Sessions/Playing"]) {
        @synchronized([self class]) { [Reports addObject:@{@"path":path,@"body":[NSJSONSerialization JSONObjectWithData:r.HTTPBody options:0 error:NULL] ?: @{}}]; }
        status=[mode isEqual:@"report401"] ? 401 : 204;
        body=[NSData data];
    } else if ([path containsString:@"/Subtitles/"]) {
        if ([mode isEqual:@"invalid-subtitle"]) body=[NSData dataWithBytes:"\xff\xfe" length:2];
        else body=[@"1\n00:00:01,000 --> 00:00:03,000\nHello\n" dataUsingEncoding:NSUTF8StringEncoding];
    } else status=404;
    NSData *data=[body isKindOfClass:[NSData class]] ? body : [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [self.client URLProtocol:self didReceiveResponse:[[[NSHTTPURLResponse alloc] initWithURL:r.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers] autorelease] cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data]; [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
