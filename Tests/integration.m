#import <Foundation/Foundation.h>
#import "API/JFClient.h"
// JSON arrives via anonymous stdin pipe. Never print configuration, NSError userInfo,
// response bodies, headers, URLs, usernames or passwords.
static int Report(BOOL ok, const char *stage, NSError *error) {
    printf("%s: %s (error-code=%ld)\n",ok ? "PASS" : "FAIL",stage,(long)(ok ? 0 : error.code));
    return ok ? 0 : 1;
}
int main(void) { @autoreleasepool {
    NSData *input=[[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSDictionary *config=input.length<65536 ? [NSJSONSerialization JSONObjectWithData:input options:0 error:NULL] : nil;
    if (![config isKindOfClass:[NSDictionary class]]) return 2;
    for (NSString *key in @[@"url", @"mode", @"username", @"password", @"token", @"library", @"item"])
        if (config[key] && ![config[key] isKindOfClass:[NSString class]]) return 2;
    for (NSString *key in @[@"fixture", @"allow_http"])
        if (config[key] && CFGetTypeID((CFTypeRef)config[key]) != CFBooleanGetTypeID()) return 2;
    NSString *mode=config[@"mode"] ?: @"server";
    if (![@[@"server", @"probe", @"offline", @"timeout", @"tls-invalid"] containsObject:mode]) return 2;
    NSString *address=config[@"url"];
    if (!address.length || [address rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location!=NSNotFound) return 2;
    NSURL *url=[NSURL URLWithString:address];
    BOOL fixture=[config[@"fixture"] boolValue];
    if (fixture && (![address isEqual:@"http://fixture.invalid/jellyfin"] || ![mode isEqual:@"server"])) return 2;
    if ([mode isEqual:@"tls-invalid"] && ![url.scheme isEqual:@"https"]) return 2;
    for (NSString *key in @[@"library", @"item"])
        if ([config[key] length] && [config[key] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet]].location!=NSNotFound) return 2;
    if ([mode isEqual:@"server"] && ![config[@"token"] length] && (![config[@"username"] length] || !config[@"password"])) return 2;
    JFClient *client=[[[JFClient alloc] initWithURL:url deviceID:@"test-device"] autorelease];
    if (!client || (url.port && (url.port.integerValue<1 || url.port.integerValue>65535))) return 2;
    if ([url.scheme isEqual:@"http"] && !fixture && ![config[@"allow_http"] boolValue]) return 77;
    if (fixture) [NSURLProtocol registerClass:NSClassFromString(@"JFFixtureProtocol")];
    NSError *error=nil;
    if ([mode isEqual:@"timeout"]) client.timeout=0.1;
    NSDictionary *info=[client serverInfo:&error];
    if ([mode isEqual:@"tls-invalid"]) return Report(!info && [error.domain isEqual:NSURLErrorDomain] && (error.code==NSURLErrorServerCertificateHasBadDate || error.code==NSURLErrorServerCertificateUntrusted || error.code==NSURLErrorServerCertificateHasUnknownRoot || error.code==NSURLErrorServerCertificateNotYetValid),"TLS rejects invalid certificate",error);
    if ([mode isEqual:@"offline"]) return Report(!info && [error.domain isEqual:NSURLErrorDomain] && (error.code==NSURLErrorCannotConnectToHost || error.code==NSURLErrorCannotFindHost || error.code==NSURLErrorNetworkConnectionLost || error.code==NSURLErrorNotConnectedToInternet),"offline transport",error);
    if ([mode isEqual:@"timeout"]) return Report(!info && ([error.domain isEqual:NSURLErrorDomain] || [error.domain isEqual:@"Jellyfin"]) && error.code==NSURLErrorTimedOut,"connection total deadline",error);
    if (Report(info!=nil,"public server information",error)) return 1;
    if ([mode isEqual:@"probe"]) return 0;
    if (Report([config[@"token"] length] ? [client authenticateToken:config[@"token"] error:&error] : [client login:config[@"username"] password:config[@"password"] error:&error],"authentication",error)) return 1;
    @try {
    NSArray *libraries=[client libraries:&error];
    if (Report(libraries!=nil,"authenticated libraries",error)) return 1;
    if (fixture) {
        NSDictionary *task=[client libraryScanTask:&error];
        if (Report([task[@"state"] isEqual:@"Running"] && [task[@"progress"] intValue]==42,
                   "authenticated read-only library scan status",error)) return 1;
    }
    if ([config[@"library"] length]) {
        NSArray *items=[client itemsInLibrary:config[@"library"] type:@"Movie" start:0 limit:1 error:&error];
        if (Report(items!=nil && (!fixture || (items.count==1 && [items[0][@"Id"] isEqual:@"movie1"])),"first media page",error)) return 1;
        NSArray *second=[client itemsInLibrary:config[@"library"] type:@"Movie" start:1 limit:1 error:&error];
        if (Report(second!=nil && (!fixture || second.count==0),"second media page",error)) return 1;
    } else printf("SKIP: media pagination (library ID not configured)\n");
    if ([config[@"item"] length]) {
        if (Report([client item:config[@"item"] error:&error]!=nil,"media detail",error)) return 1;
        if (Report([client imageData:config[@"item"] backdrop:NO width:320 cache:nil error:&error]!=nil,"poster download",error)) return 1;
        if (Report([client imageData:config[@"item"] backdrop:YES width:1280 cache:nil error:&error]!=nil,"backdrop download",error)) return 1;
    } else printf("SKIP: detail/artwork (item ID not configured)\n");
    if (Report([client endSessionAndVerifyInvalidation:&error],"server logout and token invalidation",error)) return 1;
    return Report(!client.hasSession,"local session cleared",nil);
    } @finally { if (client.hasSession) [client endSession:NULL]; }
} }
