#import <Foundation/Foundation.h>
@interface JFFixtureProtocol : NSURLProtocol @end
static BOOL loggedOut=NO;
static NSString *RequestToken(NSURLRequest *r) {
    NSString *auth=[r valueForHTTPHeaderField:@"Authorization"];
    NSRange start=[auth rangeOfString:@"Token=\""];
    if (start.location==NSNotFound) return nil;
    NSString *tail=[auth substringFromIndex:start.location+start.length];
    NSRange end=[tail rangeOfString:@"\""];
    return end.location==NSNotFound ? nil : [tail substringToIndex:end.location];
}
@implementation JFFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return [[[r URL] host] isEqual:@"fixture.invalid"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
    NSURLRequest *r=[self request]; NSString *p=[[r URL] path]; NSInteger status=200; id body=@{};
    NSDictionary *routes=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"Tests/media.json"] options:0 error:NULL];
    NSString *key=[r.URL query] ? [p stringByAppendingFormat:@"?%@",[r.URL query]] : p;
    NSDictionary *route=[routes objectForKey:key];
    // Production first-screen browsing now requests 11 records rather than
    // 101. Mirror the fixture's same server response at the smaller limit.
    if(!route && [p isEqual:@"/jellyfin/Items"] &&
       [key containsString:@"StartIndex=0&Limit=11"]) {
        NSString *full=[key stringByReplacingOccurrencesOfString:@"Limit=11"
                                                       withString:@"Limit=101"];
        route=routes[full];
    }
    if ([p hasSuffix:@"/PlaybackInfo"] && [r.HTTPMethod isEqual:@"POST"]) {
        body=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"Tests/playback.json"] options:0 error:NULL];
        route=@{@"status":@200,@"body":body};
    }
    if (route) {
        status=[[route objectForKey:@"status"] integerValue]; body=[route objectForKey:@"body"];
        if (![RequestToken(r) isEqual:@"fixture-token"]) { status=401; body=@{}; }
    }
    if ([p containsString:@"/Images/"]) {
        static NSUInteger retries=0;
        status=200;
        if (![RequestToken(r) isEqual:@"fixture-token"]) status=401;
        else if ([p containsString:@"/expired/"]) status=401;
        else if ([p containsString:@"/retry/"] && retries++==0) status=503;
        NSData *data=[p containsString:@"/broken/"] ? [@"bad image" dataUsingEncoding:NSUTF8StringEncoding] : [NSData dataWithContentsOfFile:@"Tests/pixel.png"];
        NSHTTPURLResponse *response=[[[NSHTTPURLResponse alloc] initWithURL:r.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"image/png"}] autorelease];
        [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [[self client] URLProtocol:self didLoadData:data]; [[self client] URLProtocolDidFinishLoading:self]; return;
    }
    if ([p hasPrefix:@"/tls/"]) { [[self client] URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorServerCertificateUntrusted userInfo:nil]]; return; }
    if ([p hasPrefix:@"/slow/"]) return; // Deliberately never completes.
    if ([p hasPrefix:@"/disconnect/"]) { [[self client] URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]]; return; }
    if ([p hasPrefix:@"/redirect/"]) {
        NSHTTPURLResponse *response=[[[NSHTTPURLResponse alloc] initWithURL:[r URL] statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Location":@"http://other.invalid/"}] autorelease];
        [[self client] URLProtocol:self wasRedirectedToRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://other.invalid/"]] redirectResponse:response]; return;
    }
    if ([p hasPrefix:@"/oversize/"]) body=[NSMutableData dataWithLength:8*1024*1024+1];
    else if (route) {}
    else if ([p hasPrefix:@"/invalid/"]) body=[@"{broken" dataUsingEncoding:NSUTF8StringEncoding];
    else if ([p hasPrefix:@"/array/"]) body=@[];
    else if ([p hasPrefix:@"/http500/"]) status=500;
    else if ([p isEqual:@"/jellyfin/System/Info/Public"]) body=@{@"ServerName":@"测试服务器"};
    else if ([p isEqual:@"/jellyfin/Users/AuthenticateByName"] && [[r HTTPMethod] isEqual:@"POST"]) {
        loggedOut=NO;
        id b=[NSJSONSerialization JSONObjectWithData:[r HTTPBody] options:0 error:NULL];
        NSString *name=[b objectForKey:@"Username"],*auth=[r valueForHTTPHeaderField:@"Authorization"];
        if (![auth hasPrefix:@"MediaBrowser "] || [auth rangeOfString:@"DeviceId=\"test-device\""].location==NSNotFound || ![[r valueForHTTPHeaderField:@"Content-Type"] isEqual:@"application/json"]) status=400;
        else if ([name isEqual:@"bad"]) status=401;
        else if ([name isEqual:@"shape"]) body=@{@"AccessToken":[NSNull null],@"User":@[]};
        else if ([@[@"empty",@"items"] containsObject:name]) body=@{@"AccessToken":name,@"User":@{@"Id":@"user1"}};
        else if ([b isEqual:@{@"Username":@"测试用户",@"Pw":@"p\"ass"}]) body=@{@"AccessToken":@"fixture-token",@"User":@{@"Id":@"user1"}};
        else status=400;
    } else if ([p containsString:@"/Sessions/Playing"]) { status=204; body=[NSData data];
    } else if ([p isEqual:@"/jellyfin/Sessions/Logout"]) { loggedOut=YES; status=204; body=[NSData data];
    } else if ([p isEqual:@"/jellyfin/Users/Me"]) {
        if (loggedOut || ![RequestToken(r) isEqual:@"fixture-token"]) status=401;
        else body=@{@"Id":@"user1"};
    } else if ([p isEqual:@"/jellyfin/Users/user1/Views"]) {
        NSString *token=RequestToken(r);
        if ([token isEqual:@"empty"]) body=@{@"Items":@[]};
        else if ([token isEqual:@"items"]) body=@{@"Items":@[[NSNull null]]};
        else if ([token isEqual:@"fixture-token"]) body=@{@"Items":@[@{@"Id":@"lib1",@"Name":@"电影",@"CollectionType":@"movies"}]};
        else status=401;
    } else status=404;
    NSData *data=[body isKindOfClass:[NSData class]] ? body : [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    NSHTTPURLResponse *response=[[[NSHTTPURLResponse alloc] initWithURL:[r URL] statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}] autorelease];
    [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [[self client] URLProtocol:self didLoadData:data]; [[self client] URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
