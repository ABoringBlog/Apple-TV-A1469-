#import "JFArtwork.h"
#import "API/JFClient.h"
#import "API/JFWorker.h"
#import "API/JFImageCache.h"
#import <ImageIO/ImageIO.h>
NSString * const JFArtworkChanged=@"JFArtworkChanged";
// Decode JPEG/PNG on the artwork worker, not on ATV3's main UI thread.
@interface JFDecodedBitmap : NSObject {
@public CGImageRef pixels;NSData *bytes;
}
- (id)initWithBytes:(NSData *)data;
@end
@implementation JFDecodedBitmap
- (id)initWithBytes:(NSData *)data {
    if((self=[super init])) {
        if(!data.length){[self release];return nil;}
        CGImageSourceRef source=CGImageSourceCreateWithData((CFDataRef)data,NULL);
        if(source){pixels=CGImageSourceCreateImageAtIndex(source,0,NULL);CFRelease(source);}
        if(!pixels){[self release];return nil;}
        bytes=[data copy];
    }
    return self;
}
- (void)dealloc {if(pixels)CGImageRelease(pixels);[bytes release];[super dealloc];}
@end
@implementation JFArtwork
- (NSUInteger)artworkVersion { return _artworkVersion; }
- (id)initWithURL:(NSURL *)url deviceID:(NSString *)deviceID token:(NSString *)token {
    if ((self=[super init])) {
        if (!url || !deviceID.length || !token.length) { [self release]; return nil; }
        _client=[[JFClient alloc] initWithURL:url deviceID:deviceID];
        if (!_client) { [self release]; return nil; }
        _client.timeout=7;
        _credential=[token copy]; _worker=[JFWorker new];
        // Two independent, serialized clients permit two simultaneous
        // background artwork fetch/decode tasks on the dual-core ATV3.
        _fastClient=[[JFClient alloc] initWithURL:url deviceID:deviceID];
        _fastClient.timeout=7;_fastWorker=[JFWorker new];
        // Prefetch is deliberately isolated from the UI's higher-priority art queue.
        _prefetchClient=[[JFClient alloc] initWithURL:url deviceID:deviceID];
        _prefetchClient.timeout=5;_prefetchWorker=[JFWorker new];
#if defined(__arm__)
        // ATV3 data partition, never the 480 MiB system root. 1 GiB across all
        // artwork lanes and read-only catalog metadata.
        NSString *pool=@"/var/mobile/Library/Caches/Jellyfin-ATV3/v1";
        _disk=[[JFImageCache alloc] initPersistentWithDirectory:pool capacityBytes:1024ULL*1024*1024];
        _fastDisk=[[JFImageCache alloc] initPersistentWithDirectory:pool capacityBytes:1024ULL*1024*1024];
        _prefetchDisk=[[JFImageCache alloc] initPersistentWithDirectory:pool capacityBytes:1024ULL*1024*1024];
#else
        NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:@"JFArtWindow-v1"];
        _disk=[[JFImageCache alloc] initWithDirectory:dir ttl:7*24*3600];
        NSString *dir2=[NSTemporaryDirectory() stringByAppendingPathComponent:@"JFArtWindow-v2"];
        _fastDisk=[[JFImageCache alloc] initWithDirectory:dir2 ttl:7*24*3600];
#endif
        _images=[NSMutableDictionary new]; _order=[NSMutableArray new]; _pending=[NSMutableSet new];
    }
    return self;
}
- (NSData *)imageBytesForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width {
    if(_closed || ![NSThread isMainThread])return nil;
    NSString *key=[NSString stringWithFormat:@"%@/%@/%lu",identifier?:@"",type?:@"",(unsigned long)width];
    JFDecodedBitmap *bitmap=_images[key];
    if(bitmap)return bitmap->bytes;
    CGImageRef pending=[self copyImageForID:identifier type:type width:width];
    if(pending)CGImageRelease(pending);
    return nil;
}
- (CGImageRef)copyImageForID:(NSString *)identifier type:(NSString *)type width:(NSUInteger)width {
    if (_closed || ![NSThread isMainThread] || !identifier.length || identifier.length>128 ||
        ![@[@"Primary",@"Thumb",@"Backdrop",@"Logo",@"Avatar"] containsObject:type] ||
        width<24 || width>2048) return NULL;
    NSString *key=[NSString stringWithFormat:@"%@/%@/%lu",identifier,type,(unsigned long)width];
    JFDecodedBitmap *value=_images[key];
    if (value) return CGImageRetain(value->pixels);
    if ([_pending containsObject:key]) return NULL;
    // Avoid making one failed artwork endpoint a hot polling loop.
    if ([_order containsObject:[@"fail:" stringByAppendingString:key]]) return NULL;
    [_pending addObject:key];
    BOOL archivedAtRequest=_activeArchived;
    BOOL fast=(_fetchSerial++%2)==1 && _fastClient && _fastWorker;
    JFClient *client=fast?_fastClient:_client;
    JFWorker *worker=fast?_fastWorker:_worker;
    JFImageCache *disk=fast?_fastDisk:_disk;
    NSString *credential=_credential; NSUInteger generation=_generation;
    [worker perform:^id(NSError **error) {
        BOOL authorized=fast?_fastAuthorized:_authorized;
        if (!authorized) {
            if (![client authenticateToken:credential error:error]) return nil;
            if(fast)_fastAuthorized=YES;else _authorized=YES;
        }
        NSUInteger priority=[@[@"Primary",@"Thumb"] containsObject:type]?0:
              [type isEqual:@"Avatar"]?3:(archivedAtRequest?2:1);
        NSData *bytes=[client imageDataForID:identifier type:type width:width cache:disk priority:priority error:error];
        if(!bytes.length || JFWorkCancelled())return nil;
        return [[[JFDecodedBitmap alloc] initWithBytes:bytes] autorelease];
    } completion:^(id payload,NSError *error) {
        if (_closed || generation!=_generation) return;
        [_pending removeObject:key];
        if ([payload isKindOfClass:[JFDecodedBitmap class]]) {
            _images[key]=payload;
            [_order addObject:key];
            while (_images.count>28 && _order.count) {
                NSString *old=[[_order objectAtIndex:0] retain];
                [_order removeObjectAtIndex:0];[_images removeObjectForKey:old];
                [old release];
            }
            _artworkVersion++;
            [[NSNotificationCenter defaultCenter] postNotificationName:JFArtworkChanged object:self];
        } else if (![error.domain isEqual:NSURLErrorDomain]) {
            [_order addObject:[@"fail:" stringByAppendingString:key]];
        }
    }];
    return NULL;
}
- (void)setActiveLibraryArchived:(BOOL)archived {
    if([NSThread isMainThread])_activeArchived=archived;
}
- (void)prefetchLibraries:(NSArray *)libraries {
    if (_closed || _prefetchStarted || !_prefetchClient || ![NSThread isMainThread] ||
        ![libraries isKindOfClass:[NSArray class]] || !libraries.count) return;
    _prefetchStarted=YES;
    JFClient *client=_prefetchClient;JFImageCache *disk=_prefetchDisk;
    NSString *token=_credential;
    NSArray *views=[[libraries copy] autorelease];
    [_prefetchWorker perform:^id(NSError **error) {
        if(![client authenticateToken:token error:error])return nil;
        // UI reads recent local listings instantly. This isolated low-priority
        // prefetch client updates the catalog from Jellyfin in the background.
        client.catalogNetworkOnly=YES;
        [NSThread sleepForTimeInterval:1.7];
        // Tier-order is global, not per-library: download EVERY cover before
        // spending any ATV storage or worker time on Backdrop/Logo/metadata.
        NSArray *tiers=@[[NSMutableArray array],[NSMutableArray array],
                         [NSMutableArray array],[NSMutableArray array]];
        NSMutableSet *seen=[NSMutableSet set];
        void (^add)(NSString *,NSString *,NSUInteger,NSUInteger)=
            ^(NSString *ident,NSString *kind,NSUInteger width,NSUInteger tier) {
            if(![ident isKindOfClass:[NSString class]] || !ident.length ||
               ![kind isKindOfClass:[NSString class]])return;
            NSString *key=[NSString stringWithFormat:@"%@/%@/%lu",ident,kind,(unsigned long)width];
            if([seen containsObject:key])return;
            [seen addObject:key];
            [tiers[MIN(tier,3)] addObject:@{@"id":ident,@"kind":kind,@"width":@(width)}];
        };
        void (^collect)(NSDictionary *,BOOL)=^(NSDictionary *item,BOOL archived) {
            if(![item isKindOfClass:[NSDictionary class]])return;
            NSString *ident=item[@"Id"];
            NSDictionary *tags=[item[@"ImageTags"] isKindOfClass:[NSDictionary class]]?item[@"ImageTags"]:@{};
            for(NSString *kind in @[@"Primary",@"Thumb"])
                if(tags[kind])add(ident,kind,400,0);
            if(tags[@"Logo"])add(ident,@"Logo",630,archived?2:1);
            if([item[@"BackdropImageTags"] isKindOfClass:[NSArray class]] &&
               [item[@"BackdropImageTags"] count])
                add(ident,@"Backdrop",1280,archived?2:1);
        };
        for(NSDictionary *view in views) {
            if(JFWorkCancelled())break;
            NSString *libID=view[@"Id"];
            if(![libID isKindOfClass:[NSString class]])continue;
            BOOL archived=[view[@"Name"] isKindOfClass:[NSString class]] &&
                [[view[@"Name"] lowercaseString] isEqualToString:@"archived"];
            collect(view,archived);
            NSString *collection=[view[@"CollectionType"] lowercaseString];
            NSArray *types=[collection isEqual:@"movies"]?@[@"Movie"]:
                           [collection isEqual:@"tvshows"]?@[@"Series"]:@[@"Movie",@"Series"];
            for(NSString *kind in types) {
                NSUInteger offset=0;
                for(;;) {
                    if(JFWorkCancelled())break;
                    // Mirror the interactive browser's 101-item lookahead
                    // request exactly. This populates the SAME ATV cache key.
                    NSArray *page=[client itemsInLibrary:libID type:kind start:offset limit:101 error:NULL];
                    if(!page.count)break;
                    NSUInteger visible=MIN((NSUInteger)100,page.count);
                    for(NSUInteger pos=0;pos<visible;pos++) {
                        NSDictionary *item=page[pos];
                        if(JFWorkCancelled())break;
                        collect(item,archived);
                        if([kind isEqual:@"Series"]) {
                            NSArray *seasons=[client seasons:item[@"Id"] error:NULL];
                            for(NSDictionary *season in seasons) {
                                if(JFWorkCancelled())break;
                                collect(season,archived);
                                NSArray *episodes=[client episodes:item[@"Id"] season:season[@"Id"] error:NULL];
                                for(NSDictionary *episode in episodes)collect(episode,archived);
                            }
                        }
                    }
                    if(page.count<=100 || offset>10000)break;
                    offset+=100;
                }
            }
        }
        for(NSUInteger tier=0;tier<4;tier++) {
            for(NSDictionary *request in tiers[tier]) {
                if(JFWorkCancelled())break;
                @autoreleasepool {
                    NSString *identifier=request[@"id"],*kind=request[@"kind"];
                    NSUInteger width=[request[@"width"] unsignedIntegerValue];
                    if([client hasLocalImageForID:identifier type:kind width:width cache:disk])
                        continue; // No unnecessary full-size image decode after import.
                    (void)[client imageDataForID:identifier type:kind width:width cache:disk
                        priority:tier error:NULL];
                }
                [NSThread sleepForTimeInterval:0.12];
            }
            if(JFWorkCancelled())break;
        }
        return nil;
    } completion:nil];
}
- (void)close {
    if (_closed) return;
    _closed=YES; _generation++;
    [_worker cancelAll];[_fastWorker cancelAll];[_prefetchWorker cancelAll];
    [_images removeAllObjects]; // JFDecodedBitmap dealloc releases CGImages.
}
- (void)dealloc {
    [self close]; [_client release]; [_worker release];[_fastClient release];[_fastWorker release];[_fastDisk release];[_prefetchClient release];[_prefetchWorker release];[_disk release]; [_credential release];
    [_images release]; [_pending release]; [_order release]; [super dealloc];
}
@end
