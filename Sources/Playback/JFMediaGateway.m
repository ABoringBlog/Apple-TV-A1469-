#import "JFMediaGateway.h"
#import "JFPlaybackTrace.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>

static BOOL JFSend(int fd, NSData *data) {
    const char *bytes=data.bytes; NSUInteger left=data.length;
    while (left) { ssize_t n=send(fd,bytes,left,0); if (n<=0) return NO; bytes+=n; left-=(NSUInteger)n; }
    return YES;
}
static BOOL JFSendText(int fd, NSString *text) { return JFSend(fd,[text dataUsingEncoding:NSUTF8StringEncoding]); }
static NSString *JFHeader(NSHTTPURLResponse *response, NSString *name) {
    for (NSString *key in response.allHeaderFields) if ([key caseInsensitiveCompare:name]==NSOrderedSame) return [response.allHeaderFields[key] description];
    return nil;
}
static const NSUInteger JFMaxPlaylistBytes=4*1024*1024;
static BOOL JFHeaderSafe(NSString *value) { return value && [value rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location==NSNotFound; }
static NSString *JFSafeErrorDomain(NSError *error) {
    NSString *domain=[error.domain isKindOfClass:[NSString class]] ? error.domain : nil;
    if (!domain.length || domain.length>64) return @"other";
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    return [domain rangeOfCharacterFromSet:[allowed invertedSet]].location==NSNotFound ? domain : @"other";
}
static NSString *JFGatewayKind(NSURL *url) {
    return [url.pathExtension.lowercaseString isEqual:@"m3u8"] ? @"playlist" : @"media";
}
static BOOL JFReferenceBasicSafe(NSString *reference) {
    return [reference isKindOfClass:[NSString class]] && reference.length && reference.length<=8192 &&
        [reference rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location==NSNotFound &&
        [reference rangeOfString:@"#"].location==NSNotFound;
}
static BOOL JFReferenceNeedsImmediateValidation(NSString *reference) {
    if ([reference hasPrefix:@"//"]) return YES;
    NSRange colon=[reference rangeOfString:@":"];
    if (colon.location==NSNotFound) return NO;
    NSUInteger boundary=reference.length;
    NSRange slash=[reference rangeOfString:@"/"], query=[reference rangeOfString:@"?"];
    if (slash.location!=NSNotFound && slash.location<boundary) boundary=slash.location;
    if (query.location!=NSNotFound && query.location<boundary) boundary=query.location;
    return colon.location<boundary;
}
static BOOL JFReferenceIsPlaylist(NSString *reference) {
    NSUInteger end=reference.length;
    NSRange query=[reference rangeOfString:@"?"];
    if (query.location!=NSNotFound) end=query.location;
    NSString *path=[reference substringToIndex:end];
    return [path.lowercaseString hasSuffix:@".m3u8"];
}
static NSUInteger JFRouteIndex(NSString *path) {
    NSString *prefix=@"/jf/resource";
    if (![path isKindOfClass:[NSString class]] || ![path hasPrefix:prefix] || path.length<=prefix.length+4) return NSNotFound;
    NSRange dot=[path rangeOfString:@"." options:0 range:NSMakeRange(prefix.length,path.length-prefix.length)];
    if (dot.location==NSNotFound || dot.location==prefix.length) return NSNotFound;
    NSString *digits=[path substringWithRange:NSMakeRange(prefix.length,dot.location-prefix.length)];
    if (digits.length>5 || [digits rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location!=NSNotFound) return NSNotFound;
    NSString *suffix=[[path substringFromIndex:dot.location+1] lowercaseString];
    if (![@[@"bin",@"m3u8"] containsObject:suffix]) return NSNotFound;
    unsigned long long value=strtoull(digits.UTF8String,NULL,10);
    return value>0 && value<=8192 ? (NSUInteger)value : NSNotFound;
}
@interface JFMediaGateway ()
- (BOOL)stopped;
- (NSString *)routeForReference:(NSString *)reference relativeTo:(NSURL *)base;
- (NSString *)routeForReferenceLocked:(NSString *)reference relativeTo:(NSURL *)base;
- (NSString *)registeredRouteForReference:(NSString *)storedReference base:(NSURL *)storedBase;
- (NSURL *)resolvedURLForRoute:(id)entry;
- (void)listen;
- (void)serve:(NSNumber *)descriptor;
@end

@interface JFMediaTransfer : NSObject <NSURLConnectionDataDelegate> {
@public JFMediaGateway *gateway; int fd; BOOL done, failed, headersSent, playlist, head, firstDataLogged;
    NSTimeInterval requestStarted;
    NSMutableData *body; NSURL *url; NSHTTPURLResponse *response;
}
@end
@implementation JFMediaTransfer
- (NSCachedURLResponse *)connection:(NSURLConnection *)c willCacheResponse:(NSCachedURLResponse *)cached { return nil; }
- (NSURLRequest *)connection:(NSURLConnection *)c willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirect {
    if (redirect) {
        JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_UPSTREAM redirect=1 kind=%@",JFGatewayKind(url)]);
        failed=YES; done=YES; [c cancel]; return nil;
    }
    return request;
}
- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)r {
    if (![r isKindOfClass:[NSHTTPURLResponse class]]) {
        JFPlaybackTrace(@"GATEWAY_UPSTREAM response=nonhttp");
        failed=done=YES; [c cancel]; return;
    }
    response=[(NSHTTPURLResponse *)r retain];
    NSInteger status=response.statusCode;
    NSUInteger headerMillis=(NSUInteger)MAX(0,([NSProcessInfo processInfo].systemUptime-requestStarted)*1000.0);
    NSString *kind=JFGatewayKind(url);
    if ([kind isEqual:@"m3u8"])
        JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_TTFB phase=headers kind=%@ ms=%lu status=%ld",kind,(unsigned long)headerMillis,(long)status]);
    if ([kind isEqual:@"m3u8"] || (status!=200 && status!=206))
        JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_UPSTREAM status=%ld kind=%@",(long)status,kind]);
    if (status!=200 && status!=206) {
        // Return only status, never upstream headers, body, URL or error descriptions.
        NSInteger safeStatus=[@[@401,@403,@404,@416] containsObject:@(status)] ? status : 502;
        JFSendText(fd,[NSString stringWithFormat:@"HTTP/1.1 %ld Media unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",(long)safeStatus]);
        headersSent=YES; failed=done=YES; [c cancel]; return;
    }
    NSString *type=JFHeader(response,@"Content-Type");
    NSString *encoding=JFHeader(response,@"Content-Encoding");
    if (encoding.length && ![encoding.lowercaseString isEqual:@"identity"]) {
        JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_UPSTREAM encoding=other kind=%@",JFGatewayKind(url)]);
        failed=done=YES; [c cancel]; return;
    }
    if (playlist)
        JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_UPSTREAM encoding=%@ kind=%@",encoding.length ? @"identity" : @"none",JFGatewayKind(url)]);
    playlist=[url.pathExtension.lowercaseString isEqual:@"m3u8"] || [type.lowercaseString containsString:@"mpegurl"];
    if (playlist) {
        if (status!=200) {
            JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_PLAYLIST accept=0 status=%ld",(long)status]);
            failed=done=YES; [c cancel]; return;
        }
        JFPlaybackTrace(@"GATEWAY_PLAYLIST accept=1");
        body=[NSMutableData new];
    } else {
        NSMutableString *headers=[NSMutableString stringWithFormat:@"HTTP/1.1 %ld OK\r\nConnection: close\r\nCache-Control: no-store\r\n",(long)status];
        if (JFHeaderSafe(type)) [headers appendFormat:@"Content-Type: %@\r\n",type];
        if (response.expectedContentLength>=0) [headers appendFormat:@"Content-Length: %lld\r\n",response.expectedContentLength];
        NSString *range=JFHeader(response,@"Content-Range");
        if (JFHeaderSafe(range)) [headers appendFormat:@"Content-Range: %@\r\n",range];
        [headers appendString:@"Accept-Ranges: bytes\r\n\r\n"];
        headersSent=YES;
        if (!JFSendText(fd,headers) || head) { done=YES; [c cancel]; }
    }
}
- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)data {
    if ([gateway stopped]) { failed=done=YES; [c cancel]; return; }
    if (!firstDataLogged && data.length) {
        firstDataLogged=YES;
        NSUInteger firstDataMillis=(NSUInteger)MAX(0,([NSProcessInfo processInfo].systemUptime-requestStarted)*1000.0);
        NSString *kind=JFGatewayKind(url);
        if ([kind isEqual:@"m3u8"] || firstDataMillis>=200)
            JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_TTFB phase=data kind=%@ ms=%lu",kind,(unsigned long)firstDataMillis]);
    }
    if (playlist) {
        if (body.length+data.length>JFMaxPlaylistBytes) {
            JFPlaybackTrace(@"GATEWAY_PLAYLIST body-limit=1");
            failed=done=YES; [c cancel];
        } else [body appendData:data];
    } else if (!JFSend(fd,data)) { failed=done=YES; [c cancel]; }
}
- (void)connectionDidFinishLoading:(NSURLConnection *)c {
    if (playlist) {
        NSData *rewritten=[gateway rewritePlaylist:body URL:url];
        JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_PLAYLIST rewrite=%d",rewritten!=nil]);
        if (!rewritten) failed=YES;
        else {
            headersSent=YES;
            BOOL sent=JFSendText(fd,[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",(unsigned long)rewritten.length]);
            if (!sent || (!head && !JFSend(fd,rewritten))) failed=YES;
        }
    }
    done=YES;
}
- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)error {
    JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_UPSTREAM fail=1 domain=%@ code=%ld",JFSafeErrorDomain(error),(long)error.code]);
    failed=done=YES;
}
- (void)dealloc { [body release]; [url release]; [response release]; [super dealloc]; }
@end

@implementation JFMediaGateway
@synthesize localRequest=_localRequest;
+ (NSURL *)allowedURL:(NSString *)reference relativeTo:(NSURL *)base origin:(NSURL *)origin {
    if (![reference isKindOfClass:[NSString class]] || !reference.length || reference.length>8192 || !base || !origin ||
        [reference rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location!=NSNotFound) return nil;
    NSURL *url=[[NSURL URLWithString:reference relativeToURL:base] absoluteURL];
    if (!url || url.user || url.password || url.fragment || ![@[@"http",@"https"] containsObject:url.scheme.lowercaseString] ||
        ![url.scheme.lowercaseString isEqual:origin.scheme.lowercaseString] || ![url.host.lowercaseString isEqual:origin.host.lowercaseString]) return nil;
    NSInteger port=url.port ? url.port.integerValue : ([url.scheme.lowercaseString isEqual:@"https"] ? 443 : 80);
    NSInteger originalPort=origin.port ? origin.port.integerValue : ([origin.scheme.lowercaseString isEqual:@"https"] ? 443 : 80);
    if (port!=originalPort || port<1 || port>65535) return nil;
    NSURLComponents *parts=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    NSMutableArray *query=[NSMutableArray array];
    for (NSURLQueryItem *item in parts.queryItems) {
        if ([@[@"api_key",@"apikey",@"x-emby-token",@"x-mediabrowser-token",@"access_token",@"token",@"authorization"] containsObject:item.name.lowercaseString]) continue;
        [query addObject:item];
    }
    parts.queryItems=query.count ? query : nil;
    return parts.URL;
}
- (id)initWithRequest:(NSURLRequest *)request {
    if ((self=[super init])) {
        _listener=-1;
        if (![request isKindOfClass:[NSURLRequest class]] || ![request valueForHTTPHeaderField:@"Authorization"].length ||
            ![[self class] allowedURL:request.URL.absoluteString relativeTo:request.URL origin:request.URL]) { [self release]; return nil; }
        _source=[request copy]; _lock=[NSLock new]; _routes=[NSMutableArray new]; [_routes addObject:[NSNull null]]; _playlistCache=[NSMutableDictionary new]; _clients=[NSMutableSet new];
    }
    return self;
}
- (BOOL)stopped { [_lock lock]; BOOL value=_stopped; [_lock unlock]; return value; }
- (NSString *)registeredRouteForReference:(NSString *)storedReference base:(NSURL *)storedBase {
    if (!storedReference.length || !storedBase || _routes.count>8192) return nil;
    NSUInteger index=_routes.count;
    [_routes addObject:@[storedReference,storedBase]];
    NSString *ext=JFReferenceIsPlaylist(storedReference) ? @"m3u8" : @"bin";
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/jf/resource%lu.%@",_port,(unsigned long)index,ext];
}
- (NSString *)routeForReferenceLocked:(NSString *)reference relativeTo:(NSURL *)base {
    if (!JFReferenceBasicSafe(reference) || !base) return nil;
    NSString *storedReference=reference;
    NSURL *storedBase=base;
    if (JFReferenceNeedsImmediateValidation(reference)) {
        NSURL *resolved=[[self class] allowedURL:reference relativeTo:base origin:_source.URL];
        if (!resolved) return nil;
        storedReference=resolved.absoluteString;
        storedBase=_source.URL;
    }
    return [self registeredRouteForReference:storedReference base:storedBase];
}
- (NSString *)routeForReference:(NSString *)reference relativeTo:(NSURL *)base {
    [_lock lock];
    NSString *result=[[self routeForReferenceLocked:reference relativeTo:base] retain];
    [_lock unlock];
    return [result autorelease];
}
- (NSURL *)resolvedURLForRoute:(id)entry {
    if (![entry isKindOfClass:[NSArray class]] || [entry count]!=2) return nil;
    NSString *reference=[entry objectAtIndex:0];
    NSURL *base=[entry objectAtIndex:1];
    return [[self class] allowedURL:reference relativeTo:base origin:_source.URL];
}
- (NSData *)rewritePlaylist:(NSData *)data URL:(NSURL *)url {
    NSTimeInterval started=[NSProcessInfo processInfo].systemUptime;
    if (data.length>JFMaxPlaylistBytes) { JFPlaybackTrace(@"GATEWAY_REWRITE ok=0 reason=size"); return nil; }
    NSString *cacheKey=url.absoluteString;
    if (cacheKey.length) {
        [_lock lock];
        NSDictionary *cached=[[_playlistCache objectForKey:cacheKey] retain];
        [_lock unlock];
        NSData *cachedInput=[cached objectForKey:@"input"];
        NSData *cachedOutput=[cached objectForKey:@"output"];
        if ([cachedInput isEqualToData:data] && cachedOutput.length) {
            NSData *result=[[cachedOutput retain] autorelease];
            [cached release];
            NSUInteger millis=(NSUInteger)MAX(0,([NSProcessInfo processInfo].systemUptime-started)*1000.0);
            JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_REWRITE cache=1 ms=%lu",(unsigned long)millis]);
            return result;
        }
        [cached release];
    }

    NSString *text=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (![text hasPrefix:@"#EXTM3U"] || [text containsString:@"#EXT-X-DEFINE"] || [text containsString:@"{$"]) {
        JFPlaybackTrace(@"GATEWAY_REWRITE ok=0 reason=format"); return nil;
    }

    NSMutableArray *lines=[NSMutableArray array];
    NSRegularExpression *attributes=[NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]*)\"" options:0 error:NULL];
    NSString *failure=nil;
    [_lock lock];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line=[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length && ![line hasPrefix:@"#"]) {
            NSString *route=[self routeForReferenceLocked:line relativeTo:url];
            if (!route) { failure=@"child"; break; }
            [lines addObject:route];
        } else if ([line containsString:@"URI="]) {
            NSArray *matches=[attributes matchesInString:line options:0 range:NSMakeRange(0,line.length)];
            if (!matches.count) { failure=@"attribute"; break; }
            NSMutableString *replacement=[[line mutableCopy] autorelease];
            for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
                NSRange range=[match rangeAtIndex:1];
                NSString *route=[self routeForReferenceLocked:[line substringWithRange:range] relativeTo:url];
                if (!route) { failure=@"attribute-child"; break; }
                [replacement replaceCharactersInRange:range withString:route];
            }
            if (failure) break;
            [lines addObject:replacement];
        } else [lines addObject:line];
    }
    NSUInteger routes=_routes.count>0 ? _routes.count-1 : 0;
    [_lock unlock];
    if (failure) {
        JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_REWRITE ok=0 reason=%@",failure]);
        return nil;
    }

    NSData *rewritten=[[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (rewritten.length && cacheKey.length) {
        [_lock lock];
        if (_playlistCache.count>=4 && ![_playlistCache objectForKey:cacheKey]) {
            NSString *oldest=[[_playlistCache allKeys] firstObject];
            if (oldest) [_playlistCache removeObjectForKey:oldest];
        }
        [_playlistCache setObject:@{@"input":data,@"output":rewritten} forKey:cacheKey];
        [_lock unlock];
    }
    NSUInteger millis=(NSUInteger)MAX(0,([NSProcessInfo processInfo].systemUptime-started)*1000.0);
    JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_REWRITE ok=1 routes=%lu ms=%lu",(unsigned long)routes,(unsigned long)millis]);
    return rewritten;
}
- (BOOL)start:(NSError **)error {
    if (error) *error=nil;
    if (_listener!=-1 || _localRequest || _stopped) return NO;
    int fd=socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in address={0}; address.sin_len=sizeof(address); address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    socklen_t size=sizeof(address);
    if (fd<0 || bind(fd,(struct sockaddr *)&address,sizeof(address)) || getsockname(fd,(struct sockaddr *)&address,&size) || listen(fd,8)) {
        if (fd>=0) close(fd);
        if (error) *error=[NSError errorWithDomain:@"JFMediaGateway" code:1 userInfo:nil]; return NO;
    }
    _listener=fd; _port=ntohs(address.sin_port);
    NSString *route=[self routeForReference:_source.URL.absoluteString relativeTo:_source.URL];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:route]];
    // Non-secret local marker satisfies the native preparation contract; it is never sent upstream.
    [request setValue:@"JF-Local-Media" forHTTPHeaderField:@"Authorization"];
    _localRequest=[request copy];
    [NSThread detachNewThreadSelector:@selector(listen) toTarget:self withObject:nil]; return YES;
}
- (void)listen {
    @autoreleasepool {
        int listener=_listener;
        while (![self stopped]) {
            struct pollfd ready={listener,POLLIN,0};
            if (poll(&ready,1,200)<=0) continue;
            if ([self stopped]) break;
            int fd=accept(listener,NULL,NULL);
            if (fd<0) { if (errno==EINTR) continue; break; }
            int one=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
            struct timeval timeout={15,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)); setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
            [_lock lock]; BOOL allowed=!_stopped && _clients.count<8;
            if (allowed) [_clients addObject:@(fd)]; [_lock unlock];
            if (!allowed) { close(fd); continue; }
            [NSThread detachNewThreadSelector:@selector(serve:) toTarget:self withObject:@(fd)];
        }
        [_lock lock]; close(listener); _listener=-1; [_lock unlock];
    }
}
- (void)serve:(NSNumber *)descriptor {
    @autoreleasepool {
        int fd=descriptor.intValue;
        @try {
            NSMutableData *data=[NSMutableData data]; BOOL complete=NO;
            while (data.length<16384 && ![self stopped]) {
                char bytes[1024]; ssize_t n=recv(fd,bytes,sizeof(bytes),0); if (n<=0) break;
                [data appendBytes:bytes length:(NSUInteger)n];
                if (data.length>=4 && [data rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0,data.length)].location!=NSNotFound) { complete=YES; break; }
            }
            NSString *text=complete ? [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] autorelease] : nil;
            NSArray *lines=[text componentsSeparatedByString:@"\r\n"];
            NSArray *first=[lines.firstObject componentsSeparatedByString:@" "];
            BOOL head=[first.firstObject isEqual:@"HEAD"];
            BOOL valid=first.count==3 && (head || [first.firstObject isEqual:@"GET"]);
            NSURL *url=nil; id routeEntry=nil; NSString *range=nil,*host=nil;
            if (valid) {
                NSUInteger routeIndex=JFRouteIndex(first[1]);
                [_lock lock];
                if (routeIndex!=NSNotFound && routeIndex<_routes.count) routeEntry=[[_routes objectAtIndex:routeIndex] retain];
                [_lock unlock];
                url=[[self resolvedURLForRoute:routeEntry] retain];
                [routeEntry release];
                if (!url) valid=NO;
            }
            for (NSString *line in lines) {
                NSRange colon=[line rangeOfString:@":"]; if (colon.location==NSNotFound) continue;
                NSString *name=[[line substringToIndex:colon.location] lowercaseString];
                NSString *value=[[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([name isEqual:@"range"]) range=value;
                if ([name isEqual:@"host"]) host=value;
                if ([name isEqual:@"transfer-encoding"] || [name isEqual:@"content-length"]) valid=NO;
            }
            if (![host isEqual:[NSString stringWithFormat:@"127.0.0.1:%u",_port]]) valid=NO;
            if (range && [range rangeOfString:@"^bytes=([0-9]+-[0-9]*|-[0-9]+)$" options:NSRegularExpressionSearch].location==NSNotFound) valid=NO;
            if (!valid || !url) {
                JFPlaybackTrace(@"GATEWAY_CLIENT valid=0");
                JFSendText(fd,@"HTTP/1.1 400 Bad request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } else {
                NSString *clientKind=JFGatewayKind(url);
                if ([clientKind isEqual:@"m3u8"] || head || range)
                    JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_CLIENT valid=1 kind=%@ head=%d range=%d",clientKind,head,range!=nil]);
                NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
                [request setHTTPShouldHandleCookies:NO];
                [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
                for (NSString *name in @[@"Authorization",@"Accept",@"Accept-Language",@"User-Agent"]) {
                    NSString *value=[_source valueForHTTPHeaderField:name];
                    if (JFHeaderSafe(value)) [request setValue:value forHTTPHeaderField:name];
                }
                if (range && ![url.pathExtension.lowercaseString isEqual:@"m3u8"]) [request setValue:range forHTTPHeaderField:@"Range"];
                JFMediaTransfer *transfer=[JFMediaTransfer new]; transfer->gateway=self; transfer->fd=fd; transfer->head=head; transfer->url=[url retain];
                transfer->requestStarted=[NSProcessInfo processInfo].systemUptime;
                NSURLConnection *connection=[[NSURLConnection alloc] initWithRequest:request delegate:transfer startImmediately:YES];
                if (!connection) {
                    JFPlaybackTrace([NSString stringWithFormat:@"GATEWAY_UPSTREAM connection=0 kind=%@",JFGatewayKind(url)]);
                    transfer->done=transfer->failed=YES;
                }
                while (!transfer->done && ![self stopped]) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                [connection cancel]; [connection release];
                if (!transfer->headersSent && ![self stopped]) JFSendText(fd,@"HTTP/1.1 502 Media unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                [transfer release];
            }
            [url release];
        } @catch (NSException *exception) { /* No exception text or credentials in logs. Socket closes below. */ }
        [_lock lock]; [_clients removeObject:descriptor]; close(fd); [_lock unlock];
    }
}
- (void)stop {
    [_lock lock]; _stopped=YES;
    if (_listener>=0) shutdown(_listener,SHUT_RDWR);
    for (NSNumber *fd in _clients) shutdown(fd.intValue,SHUT_RDWR);
    [_lock unlock];
}
- (void)dealloc { [self stop]; [_source release]; [_lock release]; [_routes release]; [_playlistCache release]; [_clients release]; [_localRequest release]; [super dealloc]; }
@end
