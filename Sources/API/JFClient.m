#import "JFClient.h"
#import "JFServerURL.h"
#import "JFWorker.h"
#import "Playback/JFPlaybackModel.h"
#import "Playback/JFPlaybackTrace.h"
#import "Playback/JFSubtitle.h"
#import "Playback/JFLocalSubtitle.h"
#import <CommonCrypto/CommonDigest.h>

#include <math.h>
// A credential-free Mac artwork cache. This request NEVER carries Jellyfin
// Authentication headers, session tokens or item metadata.
static NSDictionary *JFMacArtworkConfig(void) {
    NSUserDefaults *d=[[[NSUserDefaults alloc] initWithSuiteName:@"org.jellyfin.atv3"] autorelease];
    NSString *url=[d stringForKey:@"ArtworkCacheURL"],*secret=[d stringForKey:@"ArtworkCacheSecret"];
    if (![url isKindOfClass:[NSString class]] || ![secret isKindOfClass:[NSString class]] ||
        secret.length!=64) return nil;
    NSCharacterSet *hex=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    if ([secret rangeOfCharacterFromSet:hex].location!=NSNotFound) return nil;
    NSURLComponents *parsed=[NSURLComponents componentsWithString:url];
    NSString *host=parsed.host;
    if (![parsed.scheme isEqual:@"http"] || [parsed.port integerValue]!=49268 ||
        parsed.user || parsed.password || parsed.query || parsed.fragment ||
        !host.length || ![parsed.path isEqualToString:@""] ) return nil;
    NSArray *octets=[host componentsSeparatedByString:@"."];
    if(octets.count!=4) return nil;
    for(NSString *octet in octets) {
        if(octet.length>3 || !octet.length ||
           [octet rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location!=NSNotFound ||
           [octet integerValue]>255) return nil;
    }
    NSInteger first=[octets[0] integerValue],second=[octets[1] integerValue];
    BOOL privateAddress=first==10 || (first==172 && second>=16 && second<=31) ||
                        (first==192 && second==168);
    return privateAddress ? @{@"url":url,@"secret":secret} : nil;
}
static NSString *JFMacArtworkHash(NSURL *jellyfinURL, NSString *userID, NSString *path) {
    if (!jellyfinURL || !userID || !path) return nil;
    NSString *string=[NSString stringWithFormat:@"%@|%@|%@",jellyfinURL.absoluteString,userID,path];
    NSData *bytes=[string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,hash);
    NSMutableString *result=[NSMutableString stringWithCapacity:64];
    for (NSUInteger k=0;k<sizeof(hash);k++) [result appendFormat:@"%02x",hash[k]];
    return result;
}
static id Fail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Jellyfin" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
static BOOL String(id value) { return [value isKindOfClass:[NSString class]] && [value length] > 0; }
static NSString *AuthorizationValue(NSString *deviceID, NSString *token) {
    NSString *base=[NSString stringWithFormat:@"MediaBrowser Client=\"Jellyfin ATV3\", Device=\"Apple TV 3\", DeviceId=\"%@\", Version=\"0.5.22\"",deviceID];
    return token ? [base stringByAppendingFormat:@", Token=\"%@\"",token] : base;
}
// Per-request delegate: reject redirects so credentials cannot cross origins.
@interface JFTransfer : NSObject <NSURLConnectionDataDelegate> {
@public NSMutableData *data; NSURLResponse *response; NSError *error; BOOL done;
}
@end
@implementation JFTransfer
- (id)init { if ((self = [super init])) data = [NSMutableData new]; return self; }
- (NSURLRequest *)connection:(NSURLConnection *)c willSendRequest:(NSURLRequest *)r redirectResponse:(NSURLResponse *)redirect {
    if (redirect) { error = [[NSError errorWithDomain:@"Jellyfin" code:302 userInfo:@{NSLocalizedDescriptionKey:@"Redirect rejected; configure the final server URL"}] retain]; done = YES; [c cancel]; return nil; } return r;
}
- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)r { [response release]; response = [r retain]; }
- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)d {
    if ([data length] + [d length] > 8 * 1024 * 1024) { error = [[NSError errorWithDomain:@"Jellyfin" code:413 userInfo:nil] retain]; done = YES; [c cancel]; } else [data appendData:d];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)c { done = YES; }
- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)e { error = [e retain]; done = YES; }
- (void)dealloc { [data release]; [response release]; [error release]; [super dealloc]; }
@end
@implementation JFClient
@synthesize catalogNetworkOnly=_catalogNetworkOnly;
- (NSTimeInterval)timeout { return _timeout; }
- (void)setTimeout:(NSTimeInterval)value { _timeout=isfinite(value) ? fmin(300, fmax(0.05,value)) : 15; }
- (id)initWithURL:(NSURL *)url deviceID:(NSString *)deviceID {
    if ((self = [super init])) {
        NSString *address=JFNormalizeServerAddress([url absoluteString],NULL);
        if (!address || !String(deviceID) || [deviceID rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet]].location!=NSNotFound) { [self release]; return nil; }
        _baseURL=[[NSURL URLWithString:[address stringByAppendingString:@"/"]] retain];
        _deviceID = [deviceID copy]; _timeout=15;
#if defined(__arm__)
        _metadataCache=[[JFImageCache alloc] initPersistentWithDirectory:
            @"/var/mobile/Library/Caches/Jellyfin-ATV3/v1" capacityBytes:1024ULL*1024*1024];
#endif
    } return self;
}
- (NSDictionary *)request:(NSString *)path body:(NSDictionary *)body error:(NSError **)outError {
    if (outError) *outError = nil;
    if (JFWorkCancelled()) return Fail(outError, NSURLErrorCancelled, @"Request cancelled");
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:path relativeToURL:_baseURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:_timeout];
    [r setHTTPShouldHandleCookies:NO];
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [r setValue:AuthorizationValue(_deviceID,_token) forHTTPHeaderField:@"Authorization"];
    if (body) { [r setHTTPMethod:@"POST"]; [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; NSData *d = [NSJSONSerialization dataWithJSONObject:body options:0 error:outError]; if (!d) return nil; [r setHTTPBody:d]; }
    BOOL catalog=!body && _userID.length &&
        ([path hasPrefix:@"Users/"] && ([path containsString:@"/Views"] || [path containsString:@"/Items"])) ;
    catalog=catalog || (!body && _userID.length &&
       ([path hasPrefix:@"Items?"] || [path hasPrefix:@"Shows/"] ||
        ([path hasPrefix:@"Items/"] && [path rangeOfString:@"/Playback"].location==NSNotFound)));
    NSString *metaKey=catalog?[NSString stringWithFormat:@"meta|%@|%@|%@",
                       _baseURL.absoluteString,_userID,path]:nil;
    // A recently authenticated, locally cached movie listing can enter
    // instantly. Signed session login still goes to the live Jellyfin server.
    // One-hour freshness limit lets newly added films appear automatically.
    NSData *data=(!body && !_catalogNetworkOnly && [path hasPrefix:@"Items?"] &&
                  _metadataCache && metaKey) ?
        [_metadataCache freshMetadataForKey:metaKey maxAge:86400] : nil;
    BOOL servedFromLocalCatalog=(data!=nil);
    NSError *downloadError=nil;
    if(!data)data=[self downloadRequest:r error:&downloadError];
    if(!data && _metadataCache && metaKey &&
       [downloadError.domain isEqual:NSURLErrorDomain] &&
       downloadError.code!=NSURLErrorCancelled) {
        // Only a transport outage permits offline catalog metadata.
        // A 401/403/404/500 response NEVER bypasses Jellyfin authorization.
        data=[_metadataCache metadataForKey:metaKey];
    }
    if(outError)*outError=data?nil:downloadError;
    if (!data) return nil;
    // A cache HIT must be read-only: storing it again would rescan all
    // ~1,400 files in the 1-GiB pool and delay every library entry.
    if(metaKey && _metadataCache && data.length && !servedFromLocalCatalog)
        [_metadataCache storeMetadata:data forKey:metaKey];
    if (!data.length && body) return @{}; // Jellyfin POST endpoints may return 204.
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:outError];
    if (!json) return nil;
    if (![json isKindOfClass:[NSDictionary class]]) return Fail(outError, 1001, @"Expected a JSON object");
    return json;
}
// Shared bounded transport; default system TLS validation is deliberately untouched.
- (NSData *)downloadRequest:(NSURLRequest *)r error:(NSError **)outError {
    if (outError) *outError=nil;
    if (JFWorkCancelled()) return Fail(outError,NSURLErrorCancelled,@"Request cancelled");
    JFTransfer *t = [[[JFTransfer alloc] init] autorelease];
    NSURLConnection *c = [[NSURLConnection alloc] initWithRequest:r delegate:t startImmediately:YES];
    NSTimeInterval deadline=[NSProcessInfo processInfo].systemUptime + _timeout;
    while (!t->done && !JFWorkCancelled() && [NSProcessInfo processInfo].systemUptime < deadline) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    [c cancel]; [c release];
    if (JFWorkCancelled()) return Fail(outError, NSURLErrorCancelled, @"Request cancelled");
    if (!t->done) return Fail(outError, NSURLErrorTimedOut, @"Request timed out");
    if (t->error) { if (outError) *outError = t->error; return nil; }
    NSInteger status = [(NSHTTPURLResponse *)t->response statusCode];
    if (status < 200 || status >= 300) { if (status == 401) [self logout]; return Fail(outError, status, @"Server returned an HTTP error"); }
    return [[t->data copy] autorelease];
}
- (NSData *)imageData:(NSString *)identifier backdrop:(BOOL)backdrop width:(NSUInteger)width cache:(JFImageCache *)cache error:(NSError **)error {
    return [self imageDataForID:identifier type:backdrop ? @"Backdrop" : @"Primary" width:width cache:cache error:error];
}
- (BOOL)hasLocalImageForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width cache:(JFImageCache *)cache {
    if(![self hasSession] || !cache || !Identifier(identifier) || width<24 || width>2048)return NO;
    NSString *suffix=[type isEqual:@"Backdrop"]?@"Backdrop/0":type;
    if(![@[@"Primary",@"Thumb",@"Logo",@"Backdrop"] containsObject:type])return NO;
    NSString *path=[NSString stringWithFormat:@"Items/%@/Images/%@?MaxWidth=%lu",
                     identifier,suffix,(unsigned long)width];
    NSString *key=[NSString stringWithFormat:@"%@|%@|%@",_baseURL.absoluteString,_userID,path];
    return [cache containsImageForKey:key];
}
- (NSData *)imageDataForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width cache:(JFImageCache *)cache error:(NSError **)error {
    NSUInteger priority=[@[@"Primary",@"Thumb"] containsObject:type]?0:
        [type isEqual:@"Avatar"]?3:1;
    return [self imageDataForID:identifier type:type width:width cache:cache priority:priority error:error];
}
- (NSData *)imageDataForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width cache:(JFImageCache *)cache priority:(NSUInteger)priority error:(NSError **)error {
    if (error) *error=nil;
    if (![self requireID:identifier error:error]) return nil;
    if (width<1 || width>4096) return Fail(error,1007,@"Invalid image width");
    NSString *path=nil;
    if ([type isEqual:@"Avatar"] && [identifier isEqual:@"me"] && _userID)
        path=[NSString stringWithFormat:@"Users/%@/Images/Primary?MaxWidth=%lu",_userID,(unsigned long)width];
    else if ([@[@"Primary",@"Thumb",@"Backdrop",@"Logo"] containsObject:type]) {
        NSString *imageType=[type isEqual:@"Backdrop"] ? @"Backdrop/0" : type;
        path=[NSString stringWithFormat:@"Items/%@/Images/%@?MaxWidth=%lu",identifier,imageType,(unsigned long)width];
    }
    if (!path) return Fail(error,1007,@"Invalid image type or user");
    NSURLRequest *request=[self assetRequest:path];
    if (!request) return nil;
    if (JFWorkCancelled()) return Fail(error,NSURLErrorCancelled,@"Request cancelled");
    if (cache) { if (!_imageCaches) _imageCaches=[NSMutableSet new]; [_imageCaches addObject:cache]; }
    // Session namespace prevents another login/server from reusing private cached images.
    NSString *key=_userID.length ?
        [NSString stringWithFormat:@"%@|%@|%@",_baseURL.absoluteString,_userID,path] :
        [_imageNamespace stringByAppendingString:request.URL.absoluteString];
    NSData *data=[cache dataForKey:key];
    if (data) return data;
    NSDictionary *mac=JFMacArtworkConfig();
    NSString *hash=mac ? JFMacArtworkHash(_baseURL,_userID,path) : nil;
    NSURL *url=hash ? [NSURL URLWithString:[NSString stringWithFormat:@"%@/v1/art/%@",mac[@"url"],hash]] : nil;
    if (url && !JFWorkCancelled()) {
        NSMutableURLRequest *cacheGet=[NSMutableURLRequest requestWithURL:url
              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:0.65];
        [cacheGet setHTTPShouldHandleCookies:NO];
        [cacheGet setValue:mac[@"secret"] forHTTPHeaderField:@"X-JF-Art-Key"];
        NSError *ignored=nil;
        NSData *cached=[self downloadRequest:cacheGet error:&ignored];
        if (JFValidImage(cached)) {
            [cache storeData:cached forKey:key priority:priority];
            return cached;
        }
    }
    if (JFWorkCancelled()) return Fail(error,NSURLErrorCancelled,@"Request cancelled");
    data=[self downloadRequest:request error:error];
    if (!data) return nil;
    if (!JFValidImage(data)) return Fail(error,1009,@"Invalid or oversized image");
    [cache storeData:data forKey:key priority:priority];
    // Store on the same artwork worker; cache failures never affect playback.
    if(url && !JFWorkCancelled()) {
        NSMutableURLRequest *put=[NSMutableURLRequest requestWithURL:url
              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:0.65];
        [put setHTTPMethod:@"PUT"];[put setHTTPBody:data];
        [put setHTTPShouldHandleCookies:NO];
        [put setValue:mac[@"secret"] forHTTPHeaderField:@"X-JF-Art-Key"];
        (void)[self downloadRequest:put error:NULL];
    }
    return data;
}
- (NSURLRequest *)backdropRequest:(NSString *)identifier width:(NSUInteger)width error:(NSError **)error {
    if (![self requireID:identifier error:error]) return nil;
    if (width<1 || width>4096) return Fail(error,1007,@"Invalid image width");
    return [self assetRequest:[NSString stringWithFormat:@"Items/%@/Images/Backdrop/0?MaxWidth=%lu",identifier,(unsigned long)width]];
}
- (NSDictionary *)serverInfo:(NSError **)error { return [self request:@"System/Info/Public" body:nil error:error]; }
- (BOOL)login:(NSString *)username password:(NSString *)password error:(NSError **)error {
    [self logout];
    if (!String(username) || ![password isKindOfClass:[NSString class]]) { Fail(error,1002,@"Invalid login input"); return NO; }
    NSDictionary *j = [self request:@"Users/AuthenticateByName" body:@{@"Username":username,@"Pw":password} error:error];
    if (!j) return NO;
    id token = [j objectForKey:@"AccessToken"], user = [j objectForKey:@"User"];
    id uid = [user isKindOfClass:[NSDictionary class]] ? [user objectForKey:@"Id"] : nil;
    if (!String(token) || !String(uid) || [token rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) { Fail(error,1003,@"Malformed authentication response"); return NO; }
    _imageNamespace=[[[NSUUID UUID] UUIDString] copy];
    _token = [token copy]; _userID = [uid copy]; return YES;
}
- (NSDictionary *)currentUser:(NSError **)error {
    if(!_token || !_userID.length) return Fail(error,1004,@"Login required");
    // Never use a catalog cache for current account metadata: ImageTag must
    // reflect the current Jellyfin profile after edits on the web.
    return [self request:@"Users/Me" body:nil error:error];
}
- (NSData *)freshCurrentAvatarWithTag:(NSString *)tag width:(NSUInteger)width error:(NSError **)error {
    if(!_token || !_userID.length) return Fail(error,1004,@"Login required");
    if(![tag isKindOfClass:[NSString class]] || !tag.length || tag.length>128 ||
       [tag rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet]
                                    invertedSet]].location!=NSNotFound ||
       width<64 || width>1024)
        return Fail(error,1007,@"Invalid avatar version");
    NSString *path=[NSString stringWithFormat:
        @"Users/%@/Images/Primary?MaxWidth=%lu&tag=%@",_userID,(unsigned long)width,tag];
    NSURLRequest *req=[self assetRequest:path];
    NSData *data=req?[self downloadRequest:req error:error]:nil;
    if(!data || !JFValidImage(data))return nil;
    return data;
}
- (NSDictionary *)libraryScanTask:(NSError **)error {
    if (error) *error=nil;
    if (!_token || !_userID.length) return Fail(error,1004,@"Login required");
    if (JFWorkCancelled()) return Fail(error,NSURLErrorCancelled,@"Cancelled");
    // ScheduledTasks is an ARRAY endpoint, unlike the dictionary-only request:body:.
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"ScheduledTasks" relativeToURL:_baseURL]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:_timeout];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:AuthorizationValue(_deviceID,_token) forHTTPHeaderField:@"Authorization"];
    NSData *data=[self downloadRequest:request error:error];
    if (!data) return nil;
    id tasks=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![tasks isKindOfClass:[NSArray class]]) return Fail(error,1005,@"Expected tasks array");
    for (id entry in tasks) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *key=[entry[@"Key"] isKindOfClass:[NSString class]]?entry[@"Key"]:@"";
        NSString *name=[entry[@"Name"] isKindOfClass:[NSString class]]?entry[@"Name"]:@"";
        BOOL found=[key caseInsensitiveCompare:@"RefreshLibrary"]==NSOrderedSame ||
                   [name caseInsensitiveCompare:@"Scan Media Library"]==NSOrderedSame ||
                   [name caseInsensitiveCompare:@"Scan Library"]==NSOrderedSame;
        if (!found) continue;
        NSString *state=[entry[@"State"] isKindOfClass:[NSString class]]?entry[@"State"]:@"Unknown";
        NSNumber *progress=[entry[@"CurrentProgressPercentage"] isKindOfClass:[NSNumber class]]?
                           entry[@"CurrentProgressPercentage"]:nil;
        NSDictionary *last=[entry[@"LastExecutionResult"] isKindOfClass:[NSDictionary class]]?
                             entry[@"LastExecutionResult"]:@{};
        NSString *lastStatus=[last[@"Status"] isKindOfClass:[NSString class]]?last[@"Status"]:@"";
        NSString *lastEnd=[last[@"EndTimeUtc"] isKindOfClass:[NSString class]]?last[@"EndTimeUtc"]:@"";
        return @{@"state":state,@"progress":progress?:[NSNull null],
                 @"lastStatus":lastStatus,@"lastEnd":lastEnd};
    }
    return Fail(error,404,@"Scan Media Library scheduled task not found");
}
- (BOOL)requestLibraryScan:(NSError **)error {
    if (!_token || !_userID.length) {
        Fail(error,1004,@"Login required");return NO;
    }
    // Jellyfin POST /Library/Refresh: 204 response indicates scan accepted,
    // NOT that the asynchronous server scan has already finished.
    NSDictionary *result=[self request:@"Library/Refresh" body:@{} error:error];
    return result!=nil;
}
- (NSArray *)libraries:(NSError **)error {
    if (!_token) return Fail(error,1004,@"Login required");
    NSString *uid = [_userID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
    NSDictionary *j = [self request:[NSString stringWithFormat:@"Users/%@/Views",uid] body:nil error:error];
    if (!j) return nil;
    id items = [j objectForKey:@"Items"];
    if (![items isKindOfClass:[NSArray class]]) return Fail(error,1005,@"Expected Items array");
    for (id item in items) if (![item isKindOfClass:[NSDictionary class]] || !String([item objectForKey:@"Id"]) || !String([item objectForKey:@"Name"])) return Fail(error,1006,@"Malformed library item");
    return items;
}
static BOOL Identifier(id value) {
    return String(value) && [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet]].location==NSNotFound;
}
static NSString *CanonicalPlaybackID(id value) {
    if (!Identifier(value)) return nil;
    NSUInteger length=[value length];
    BOOL standard=length==36;
    if (standard) {
        NSSet *hyphens=[NSSet setWithArray:@[@8,@13,@18,@23]];
        for (NSUInteger i=0;i<length;i++) {
            BOOL shouldHyphen=[hyphens containsObject:@(i)];
            if (shouldHyphen != ([value characterAtIndex:i]=='-')) { standard=NO; break; }
        }
    }
    if (length!=32 && !standard) return value;
    NSMutableString *compact=[NSMutableString stringWithCapacity:32];
    for (NSUInteger i=0;i<length;i++) {
        unichar c=[value characterAtIndex:i];
        if (c=='-') continue;
        if (c>='A' && c<='F') c=(unichar)(c+('a'-'A'));
        BOOL digit=c>='0' && c<='9', lowerHex=c>='a' && c<='f';
        if (!digit && !lowerHex) return value;
        [compact appendFormat:@"%C",c];
    }
    return compact.length==32 ? compact : value;
}
static NSArray *PlaybackPathComponents(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return nil;
    NSMutableArray *components=[NSMutableArray array];
    for (NSString *component in [path componentsSeparatedByString:@"/"])
        if (component.length) [components addObject:component];
    return components;
}
static BOOL PlaybackTranscodePathAllowed(NSURL *url, NSURL *baseURL, NSString *itemID) {
    NSArray *base=PlaybackPathComponents(baseURL.path), *candidate=PlaybackPathComponents(url.path);
    if (!base || !candidate || candidate.count!=base.count+3) return NO;
    for (NSUInteger i=0;i<base.count;i++) if (![candidate[i] isEqual:base[i]]) return NO;
    if ([candidate[base.count] caseInsensitiveCompare:@"videos"]!=NSOrderedSame) return NO;
    NSString *expected=CanonicalPlaybackID(itemID), *actual=CanonicalPlaybackID(candidate[base.count+1]);
    if (!expected || !actual || ![actual isEqual:expected]) return NO;
    NSString *leaf=candidate.lastObject;
    return [leaf caseInsensitiveCompare:@"master.m3u8"]==NSOrderedSame;
}
- (BOOL)requireID:(NSString *)identifier error:(NSError **)error {
    if (error) *error=nil;
    if (![self hasSession]) { Fail(error,1004,@"Login required"); return NO; }
    if (!Identifier(identifier)) { Fail(error,1007,@"Invalid media identifier"); return NO; }
    return YES;
}
- (NSString *)escapedUser { return [_userID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]]; }
- (NSArray *)mediaList:(NSString *)path error:(NSError **)error {
    NSDictionary *json=[self request:path body:nil error:error];
    if (!json) return nil;
    id items=[json objectForKey:@"Items"];
    if (![items isKindOfClass:[NSArray class]]) return Fail(error,1005,@"Expected Items array");
    for (id item in items) {
        if (![item isKindOfClass:[NSDictionary class]] || !Identifier([item objectForKey:@"Id"]) || !String([item objectForKey:@"Name"]) || !String([item objectForKey:@"Type"])) return Fail(error,1006,@"Malformed media item");
    }
    return items;
}
- (NSArray *)itemsInLibrary:(NSString *)parent type:(NSString *)type start:(NSUInteger)start limit:(NSUInteger)limit error:(NSError **)error {
    if (![self requireID:parent error:error]) return nil;
    if (![@[@"Movie",@"Series"] containsObject:type] || limit<1 || limit>200) return Fail(error,1007,@"Invalid media query");
    return [self mediaList:[NSString stringWithFormat:@"Items?UserId=%@&ParentId=%@&IncludeItemTypes=%@&Recursive=true&StartIndex=%lu&Limit=%lu&SortBy=SortName&SortOrder=Ascending&Fields=Overview,MediaSources",[self escapedUser],parent,type,(unsigned long)start,(unsigned long)limit] error:error];
}
- (NSArray *)seasons:(NSString *)series error:(NSError **)error {
    if (![self requireID:series error:error]) return nil;
    return [self mediaList:[NSString stringWithFormat:@"Shows/%@/Seasons?UserId=%@",series,[self escapedUser]] error:error];
}
- (NSArray *)episodes:(NSString *)series season:(NSString *)season error:(NSError **)error {
    if (![self requireID:series error:error] || ![self requireID:season error:error]) return nil;
    return [self mediaList:[NSString stringWithFormat:@"Shows/%@/Episodes?UserId=%@&SeasonId=%@&Fields=Overview,MediaSources",series,[self escapedUser],season] error:error];
}
- (NSDictionary *)item:(NSString *)identifier error:(NSError **)error {
    if (![self requireID:identifier error:error]) return nil;
    NSDictionary *item=[self request:[NSString stringWithFormat:@"Users/%@/Items/%@?Fields=MediaSources",[self escapedUser],identifier] body:nil error:error];
    if (!item) return nil;
    if (![[item objectForKey:@"Id"] isEqual:identifier] || !String([item objectForKey:@"Name"]) || !String([item objectForKey:@"Type"])) return Fail(error,1006,@"Malformed media detail");
    return item;
}
- (NSDictionary *)playbackInfo:(NSString *)identifier error:(NSError **)error {
    if (![self requireID:identifier error:error]) return nil;
    NSDictionary *info=[self request:[NSString stringWithFormat:@"Items/%@/PlaybackInfo?UserId=%@",identifier,[self escapedUser]] body:nil error:error];
    if (!info) return nil;
    id sources=[info objectForKey:@"MediaSources"];
    if (![sources isKindOfClass:[NSArray class]]) return Fail(error,1008,@"Malformed playback information");
    for (id source in sources) if (![source isKindOfClass:[NSDictionary class]] || !Identifier([source objectForKey:@"Id"])) return Fail(error,1008,@"Malformed media source");
    return info;
}
- (NSDictionary *)playbackInfo:(NSString *)identifier startTicks:(long long)ticks subtitleIndex:(NSInteger)index error:(NSError **)error {
    return [self playbackInfo:identifier startTicks:ticks mediaSourceID:nil audioIndex:-1 subtitleIndex:index error:error];
}
- (NSDictionary *)playbackInfo:(NSString *)identifier startTicks:(long long)ticks mediaSourceID:(NSString *)source audioIndex:(NSInteger)audioIndex subtitleIndex:(NSInteger)subtitleIndex error:(NSError **)error {
    return [self playbackInfo:identifier startTicks:ticks mediaSourceID:source audioIndex:audioIndex subtitleIndex:subtitleIndex fallbackTier:0 error:error];
}
- (NSDictionary *)playbackInfo:(NSString *)identifier startTicks:(long long)ticks mediaSourceID:(NSString *)source audioIndex:(NSInteger)audioIndex subtitleIndex:(NSInteger)subtitleIndex fallbackTier:(NSUInteger)tier error:(NSError **)error {
    if (tier>2) return Fail(error,1007,@"Invalid fallback tier");
    if (![self requireID:identifier error:error]) return nil;
    BOOL boundSource=source!=nil, hasAudio=audioIndex>=0, hasSubtitle=subtitleIndex>=0;
    if (audioIndex < -1 || audioIndex>10000 || subtitleIndex < -1 || subtitleIndex>10000 ||
        (boundSource && !Identifier(source)) || (!boundSource && (hasAudio || hasSubtitle)))
        return Fail(error,1007,@"Invalid stream selection");
    NSDictionary *body=JFPlaybackBody(ticks,subtitleIndex);
    if (!body) return Fail(error,1007,@"Invalid playback parameters");
    NSMutableDictionary *request=[[body mutableCopy] autorelease]; request[@"UserId"]=_userID;
    if (tier>0) {
        request[@"EnableDirectPlay"]=@NO;
        if (tier==2) {
            request[@"EnableDirectStream"]=@NO;
            request[@"AllowVideoStreamCopy"]=@NO;
            request[@"AllowAudioStreamCopy"]=@NO;
        }
    }
// Fixed global 10 Mbps. Diagnostic exceptions retired.

    // Jellyfin applies stream indices against a pinned MediaSourceId.
    if (boundSource) request[@"MediaSourceId"]=source;
    if (hasAudio) request[@"AudioStreamIndex"]=@(audioIndex);
    // Legacy explicit-subtitle API fallback. The production player always negotiates
    // video with index=-1 and renders selected SRT separately on the device.
    if (subtitleIndex>=0) { request[@"EnableDirectPlay"]=@NO; request[@"EnableDirectStream"]=@NO; request[@"AllowVideoStreamCopy"]=@NO; request[@"AllowAudioStreamCopy"]=@NO; request[@"AlwaysBurnInSubtitleWhenTranscoding"]=@YES; }
    return [self request:[NSString stringWithFormat:@"Items/%@/PlaybackInfo",identifier] body:request error:error];
}
- (NSURLRequest *)playbackRequest:(NSDictionary *)plan error:(NSError **)error {
    if (![plan isKindOfClass:[NSDictionary class]] || ![self requireID:plan[@"itemID"] error:error] || ![self requireID:plan[@"sourceID"] error:error] || !Identifier(plan[@"playSessionID"]) || !JFTicks(plan[@"startTicks"])) {
        JFPlaybackTrace(@"REQUEST_REJECT reason=invalid-plan");
        return Fail(error,1007,@"Invalid playback plan");
    }
    NSString *method=plan[@"method"];
    if ([method isEqual:@"DirectPlay"]) return [self assetRequest:[NSString stringWithFormat:@"Videos/%@/stream?Static=true&MediaSourceId=%@&PlaySessionId=%@&StartTimeTicks=%@",plan[@"itemID"],plan[@"sourceID"],plan[@"playSessionID"],plan[@"startTicks"]]];
    if (![@[@"DirectStream",@"Transcode"] containsObject:method]) {
        JFPlaybackTrace(@"REQUEST_REJECT reason=unknown-method");
        return Fail(error,1007,@"Unknown playback method");
    }
    if (![plan[@"source"] isKindOfClass:[NSDictionary class]]) {
        JFPlaybackTrace(@"REQUEST_REJECT reason=invalid-source");
        return Fail(error,1007,@"Invalid media source");
    }
    id path=plan[@"source"][@"TranscodingUrl"];
    if (![path isKindOfClass:[NSString class]] || ![path length] || [path rangeOfString:@"\\"].location!=NSNotFound || [path rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location!=NSNotFound) {
        JFPlaybackTrace(@"REQUEST_REJECT reason=invalid-transcode-url");
        return Fail(error,1007,@"Invalid transcode URL");
    }
    NSURL *url=[[NSURL URLWithString:path relativeToURL:_baseURL] absoluteURL];
    NSNumber *basePort=_baseURL.port ?: @([_baseURL.scheme isEqual:@"https"] ? 443 : 80);
    NSNumber *port=url.port ?: @([url.scheme isEqual:@"https"] ? 443 : 80);
    NSUInteger rawEnd=[path length];
    NSRange queryMark=[path rangeOfString:@"?"], fragment=[path rangeOfString:@"#"];
    if (queryMark.location!=NSNotFound && queryMark.location<rawEnd) rawEnd=queryMark.location;
    if (fragment.location!=NSNotFound && fragment.location<rawEnd) rawEnd=fragment.location;
    NSString *rawPath=[path substringToIndex:rawEnd];
    BOOL pathAllowed=PlaybackTranscodePathAllowed(url,_baseURL,plan[@"itemID"]);
    // Only the configured same-origin /videos/<same-item-id>/<hls>.m3u8 endpoint is allowed.
    // Jellyfin may hyphenate UUIDs and vary the Videos/videos case; canonical ID comparison
    // preserves item binding without trusting an arbitrary same-origin HLS URL.
    if (![url.scheme isEqual:_baseURL.scheme] || ![url.host.lowercaseString isEqual:_baseURL.host.lowercaseString] || ![port isEqual:basePort] || url.user || url.password || url.fragment || !pathAllowed || [url.path containsString:@".."] || [rawPath containsString:@"%"]) {
        JFPlaybackTrace([NSString stringWithFormat:@"REQUEST_REJECT reason=unsafe-transcode-url sameScheme=%d sameHost=%d samePort=%d user=%d password=%d fragment=%d path=%d suffix=%d dotdot=%d percent=%d",
            [url.scheme isEqual:_baseURL.scheme],[url.host.lowercaseString isEqual:_baseURL.host.lowercaseString],[port isEqual:basePort],
            url.user!=nil,url.password!=nil,url.fragment!=nil,pathAllowed,[url.path.lowercaseString hasSuffix:@".m3u8"],
            [url.path containsString:@".."],[rawPath containsString:@"%"]]);
        return Fail(error,1007,@"Unsafe transcode URL");
    }
    NSURLComponents *parts=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    NSMutableArray *query=[NSMutableArray array];
    NSSet *controlled=[NSSet setWithArray:@[@"api_key",@"access_token",@"token",@"mediasourceid",@"playsessionid",@"starttimeticks",@"audiostreamindex",@"subtitlestreamindex",@"videocodec",@"audiocodec",@"maxwidth",@"maxheight",@"maxframerate",@"videobitrate",@"audiobitrate",@"maxaudiochannels",@"audiocodec",@"profile",@"level",@"videobitdepth",@"allowvideostreamcopy",@"allowaudiostreamcopy",@"requireavc",@"videorangetype",@"segmentlength"]];
    for (NSURLQueryItem *item in parts.queryItems) if (![controlled containsObject:item.name.lowercaseString]) [query addObject:item];
    BOOL copy=[method isEqual:@"DirectStream"];
    BOOL hasBurnInSubtitle=JFTicks(plan[@"subtitleStreamIndex"]) && [plan[@"subtitleStreamIndex"] integerValue]>=0;
    BOOL videoCopy=copy || (!hasBurnInSubtitle && [plan[@"allowVideoCopy"] boolValue]);
    BOOL audioCopy=copy;
    long long duration=[plan[@"durationTicks"] longLongValue];
    NSString *segmentLength=(duration>0 && duration<=108000000000LL) ? @"3" : @"6"; // 3 hours.
    // Dynamic HLS segment endpoints reject StartTimeTicks. Resume is applied by the native player
    // after cue via setElapsedTime:, so keep HLS segment URLs free of StartTimeTicks.
    NSMutableDictionary *values=[NSMutableDictionary dictionaryWithDictionary:@{@"MediaSourceId":plan[@"sourceID"],@"PlaySessionId":plan[@"playSessionID"],
        @"VideoCodec":videoCopy ? @"copy" : @"h264",@"AudioCodec":audioCopy ? @"copy" : @"aac",@"MaxWidth":@"1920",@"MaxHeight":@"1080",@"MaxFramerate":@"30",
        @"VideoBitrate":@"8000000",@"AudioBitrate":@"192000",@"MaxAudioChannels":@"2",@"Profile":@"high",@"Level":@"40",@"VideoBitDepth":@"8",@"VideoRangeType":@"SDR",
        @"AllowVideoStreamCopy":videoCopy ? @"true" : @"false",@"AllowAudioStreamCopy":audioCopy ? @"true" : @"false",@"RequireAvc":@"true",@"SegmentLength":segmentLength}];
    NSNumber *transportAudio=plan[@"transportAudioStreamIndex"] ?: plan[@"audioStreamIndex"];
    if (JFTicks(transportAudio) && [transportAudio integerValue]>=0 && [transportAudio integerValue]<=10000)
        values[@"AudioStreamIndex"]=[transportAudio stringValue];
    if (JFTicks(plan[@"subtitleStreamIndex"]) && [plan[@"subtitleStreamIndex"] integerValue]>=0 && [plan[@"subtitleStreamIndex"] integerValue]<=10000)
        values[@"SubtitleStreamIndex"]=[plan[@"subtitleStreamIndex"] stringValue];
    for (NSString *key in [[values allKeys] sortedArrayUsingSelector:@selector(compare:)]) [query addObject:[NSURLQueryItem queryItemWithName:key value:values[key]]];
    parts.queryItems=query;
    return [self assetRequest:parts.URL.absoluteString];
}
- (BOOL)setUserFlag:(NSString *)flag item:(NSString *)identifier enabled:(BOOL)enabled error:(NSError **)error {
    if (![self requireID:identifier error:error] || ![@[@"Played",@"Favorite"] containsObject:flag]) return NO;
    NSString *endpoint=[flag isEqual:@"Played"] ? @"PlayedItems" : @"FavoriteItems";
    NSString *path=[NSString stringWithFormat:@"Users/%@/%@/%@",_userID,endpoint,identifier];
    NSMutableURLRequest *request=[[self assetRequest:path] mutableCopy];
    [request setHTTPMethod:enabled ? @"POST" : @"DELETE"];
    // Jellyfin returns an updated UserItemData object or HTTP 204.
    NSData *response=[self downloadRequest:request error:error];
    [request release];
    return response!=nil;
}
- (BOOL)reportPlayback:(NSString *)event body:(NSDictionary *)body error:(NSError **)error {
    if (![@[@"Playing",@"Progress",@"Stopped"] containsObject:event] || ![body isKindOfClass:[NSDictionary class]] ||
        ![self requireID:body[@"ItemId"] error:error] || !Identifier(body[@"MediaSourceId"]) || !Identifier(body[@"PlaySessionId"]) || !JFTicks(body[@"PositionTicks"])) { Fail(error,1007,@"Invalid playback report"); return NO; }
    NSString *path=[event isEqual:@"Playing"] ? @"Sessions/Playing" : [@"Sessions/Playing/" stringByAppendingString:event];
    return [self request:path body:body error:error]!=nil;
}
- (NSURLRequest *)subtitleRequest:(NSString *)item mediaSource:(NSString *)source index:(NSInteger)index error:(NSError **)error {
    if (![self requireID:item error:error] || ![self requireID:source error:error]) return nil;
    if (index<0 || index>10000) return Fail(error,1007,@"Invalid subtitle index");
    return [self assetRequest:[NSString stringWithFormat:@"Videos/%@/%@/Subtitles/%ld/Stream.srt",item,source,(long)index]];
}
- (NSData *)subtitleData:(NSString *)item mediaSource:(NSString *)source index:(NSInteger)index error:(NSError **)error {
    NSURLRequest *request=[self subtitleRequest:item mediaSource:source index:index error:error];
    if (!request) return nil;
    NSData *data=[self downloadRequest:request error:error];
    // Client sidecar SRT is parsed locally; tolerate isolated malformed/zero-length
    // cues rather than rejecting an entire otherwise-valid subtitle file.
    if (!data || !JFLocalSubtitleParse(data,error)) return nil;
    return data;
}
- (NSArray *)localSubtitleCues:(NSString *)item mediaSource:(NSString *)source index:(NSInteger)index error:(NSError **)error {
    NSURLRequest *request=[self subtitleRequest:item mediaSource:source index:index error:error];
    if (!request) return nil;
    NSData *data=[self downloadRequest:request error:error];
    if (!data || JFWorkCancelled()) return nil;
    return JFLocalSubtitleParse(data,error);
}
- (NSURLRequest *)assetRequest:(NSString *)path {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:path relativeToURL:_baseURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:_timeout];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:AuthorizationValue(_deviceID,_token) forHTTPHeaderField:@"Authorization"];
    return request;
}
- (NSURLRequest *)posterRequest:(NSString *)identifier width:(NSUInteger)width error:(NSError **)error {
    if (![self requireID:identifier error:error]) return nil;
    if (width<1 || width>4096) return Fail(error,1007,@"Invalid poster width");
    return [self assetRequest:[NSString stringWithFormat:@"Items/%@/Images/Primary?MaxWidth=%lu",identifier,(unsigned long)width]];
}
- (NSURLRequest *)streamRequest:(NSString *)identifier mediaSource:(NSString *)source error:(NSError **)error {
    if (![self requireID:identifier error:error] || ![self requireID:source error:error]) return nil;
    return [self assetRequest:[NSString stringWithFormat:@"Videos/%@/stream?Static=true&MediaSourceId=%@",identifier,source]];
}
- (BOOL)authenticateToken:(NSString *)token error:(NSError **)error {
    [self logout];
    if (!String(token) || [token rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location!=NSNotFound) { Fail(error,1003,@"Invalid credential"); return NO; }
    _token=[token copy];
    NSDictionary *user=[self request:@"Users/Me" body:nil error:error];
    if (!Identifier(user[@"Id"])) { [self logout]; if (user) Fail(error,1003,@"Malformed user"); return NO; }
    _userID=[user[@"Id"] copy]; _imageNamespace=[[[NSUUID UUID] UUIDString] copy]; return YES;
}
- (NSString *)sessionToken { return [[_token copy] autorelease]; }
- (BOOL)endSession:(NSError **)error {
    BOOL result=YES;
    if (_token) result=[self request:@"Sessions/Logout" body:@{} error:error]!=nil;
    [self logout]; return result;
}
- (BOOL)endSessionAndVerifyInvalidation:(NSError **)error {
    if (![self hasSession]) { Fail(error,1004,@"Login required"); return NO; }
    NSURLRequest *probe=[[self assetRequest:@"Users/Me"] retain];
    BOOL loggedOut=[self endSession:error];
    if (!loggedOut) { [probe release]; return NO; }
    NSError *rejection=nil;
    NSData *data=[self downloadRequest:probe error:&rejection]; [probe release];
    if (!data && [rejection.domain isEqual:@"Jellyfin"] && rejection.code==401) return YES;
    if (error) *error=rejection ?: [NSError errorWithDomain:@"Jellyfin" code:1010 userInfo:nil];
    return NO;
}
- (BOOL)hasSession { return _token != nil && _userID != nil; }
- (void)logout { for (JFImageCache *cache in _imageCaches) [cache invalidate]; [_imageCaches release]; _imageCaches=nil; [_imageNamespace release]; _imageNamespace=nil; [_token release]; _token = nil; [_userID release]; _userID = nil; }
- (void)dealloc { [self logout]; [_metadataCache release]; [_baseURL release]; [_deviceID release]; [super dealloc]; }
@end
