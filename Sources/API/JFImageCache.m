#import "JFImageCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
BOOL JFValidImage(NSData *data) {
    if (!data.length || data.length>8*1024*1024) return NO;
    CGImageSourceRef source=CGImageSourceCreateWithData((CFDataRef)data,NULL);
    if (!source) return NO;
    NSDictionary *properties=(NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source,0,NULL);
    double w=[properties[(id)kCGImagePropertyPixelWidth] doubleValue], h=[properties[(id)kCGImagePropertyPixelHeight] doubleValue];
    BOOL valid=w>0 && h>0 && w*h<=16*1024*1024;
    CGImageRef image=valid ? CGImageSourceCreateImageAtIndex(source,0,NULL) : NULL;
    valid=image!=NULL;
    if (image) CGImageRelease(image);
    [properties release]; CFRelease(source); return valid;
}
@interface JFImageCache ()
- (void)persistentStore:(NSData *)data forKey:(NSString *)key priority:(NSUInteger)priority metadata:(BOOL)metadata;
@end
@implementation JFImageCache
- (id)initWithDirectory:(NSString *)directory ttl:(NSTimeInterval)ttl {
    if ((self=[super init])) {
        if (!directory.length || !isfinite(ttl) || ttl<=0) { [self release]; return nil; }
        _directory=[directory copy]; _ttl=ttl; _memory=[NSMutableDictionary new];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]) { [self release]; return nil; }
    } return self;
}
- (id)initPersistentWithDirectory:(NSString *)directory capacityBytes:(unsigned long long)capacity {
    if(capacity<1024*1024 || capacity>1024ULL*1024*1024)return nil;
    if((self=[self initWithDirectory:directory ttl:90*24*3600])) {
        _capacity=capacity;_persistent=YES;
    }
    return self;
}
- (NSString *)digest:(NSString *)key {
    NSData *bytes=[key dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString *name=[NSMutableString stringWithCapacity:64];
    for(NSUInteger i=0;i<sizeof(digest);i++)[name appendFormat:@"%02x",digest[i]];
    return name;
}
- (NSString *)priorityPath:(NSString *)key tier:(NSUInteger)tier metadata:(BOOL)metadata {
    NSString *prefix=metadata?@"3m":[NSString stringWithFormat:@"%lu",(unsigned long)MIN(tier,3)];
    return [_directory stringByAppendingPathComponent:[prefix stringByAppendingString:[self digest:key]]];
}
- (NSString *)path:(NSString *)key {
    NSData *bytes=[key dataUsingEncoding:NSUTF8StringEncoding]; unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest); NSMutableString *name=[NSMutableString string];
    for (NSUInteger i=0;i<sizeof(digest);i++) [name appendFormat:@"%02x",digest[i]];
    return [_directory stringByAppendingPathComponent:name];
}
- (void)purgeMemory { [_memory removeAllObjects]; _memoryBytes=0; }
- (NSArray *)files { return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory error:NULL]; }
- (BOOL)ownedName:(NSString *)name {
    return name.length==64 && [name rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
- (void)invalidate {
    [self purgeMemory];
    // Auth/session termination is not a cache reset: persistent files are
    // namespaced by the Jellyfin server + user ID and survive ATV restarts.
    if(_persistent)return;
    @synchronized([JFImageCache class]) {
        for (NSString *name in [self files]) if ([self ownedName:name] ||
             (_persistent && [self poolName:name]))
            [[NSFileManager defaultManager] removeItemAtPath:[_directory stringByAppendingPathComponent:name] error:NULL];
    }
}
- (void)remember:(NSData *)data path:(NSString *)path date:(NSDate *)date {
    if (_memoryBytes+data.length>8*1024*1024) [self purgeMemory];
    NSDictionary *old=_memory[path]; _memoryBytes-=[old[@"data"] length];
    _memory[path]=@{@"data":data,@"date":date}; _memoryBytes+=data.length;
}
- (NSData *)dataForKey:(NSString *)key {
    if (!key.length) return nil;
    if(_persistent) {
        @synchronized([JFImageCache class]) {
            return [self persistentData:key metadata:NO];
        }
    }
    NSString *path=[self path:key]; NSDictionary *entry=_memory[path];
    NSDictionary *attr=[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    NSDate *date=entry[@"date"] ?: attr[NSFileModificationDate];
    if (!date || -date.timeIntervalSinceNow>=_ttl || date.timeIntervalSinceNow>1) {
        if (entry) { _memoryBytes-=[entry[@"data"] length]; [_memory removeObjectForKey:path]; }
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL]; return nil;
    }
    if (entry) return entry[@"data"];
    if (![attr[NSFileType] isEqual:NSFileTypeRegular] || [attr[NSFileSize] unsignedLongLongValue]>8*1024*1024) return nil;
    NSData *data=[NSData dataWithContentsOfFile:path];
    if (!JFValidImage(data)) { [[NSFileManager defaultManager] removeItemAtPath:path error:NULL]; return nil; }
    [self remember:data path:path date:date]; return data;
}
- (void)storeData:(NSData *)data forKey:(NSString *)key {
    if(_persistent){[self storeData:data forKey:key priority:0];return;}
    if (!key.length || !JFValidImage(data)) return;
    NSString *path=[self path:key];
    // Bound disk usage to 32 MiB; remove expired and oldest entries before writing.
    NSFileManager *fm=[NSFileManager defaultManager]; NSMutableArray *entries=[NSMutableArray array]; unsigned long long total=0;
    for (NSString *name in [self files]) {
        if (![self ownedName:name]) continue;
        NSString *p=[_directory stringByAppendingPathComponent:name]; NSDictionary *a=[fm attributesOfItemAtPath:p error:NULL];
        if ([p isEqual:path] || ![a[NSFileType] isEqual:NSFileTypeRegular] || -[a[NSFileModificationDate] timeIntervalSinceNow]>=_ttl) { [fm removeItemAtPath:p error:NULL]; continue; }
        total+=[a[NSFileSize] unsignedLongLongValue]; [entries addObject:@{@"path":p,@"date":a[NSFileModificationDate],@"size":a[NSFileSize]}];
    }
    [entries sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"date" ascending:YES]]];
    for (NSDictionary *e in entries) { if (total+data.length<=32*1024*1024) break; [fm removeItemAtPath:e[@"path"] error:NULL]; total-=[e[@"size"] unsignedLongLongValue]; }
    if ([data writeToFile:path options:NSDataWritingAtomic error:NULL]) [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:NULL];
    [self remember:data path:path date:[NSDate date]];
}
// Persistent pool operations are serialized across the UI, fast, and prefetch
// worker cache instances. Files contain only verified image bytes or bounded JSON;
// credentials and library filenames are never stored.
- (BOOL)poolName:(NSString *)name {
    if(name.length!=65 && name.length!=66)return NO;
    BOOL m=name.length==66;
    if(m && ![name hasPrefix:@"3m"])return NO;
    if(!m && ![@[@"0",@"1",@"2",@"3"] containsObject:[name substringToIndex:1]])return NO;
    NSString *suffix=[name substringFromIndex:m?2:1];
    return [self ownedName:suffix];
}
- (NSArray *)poolFiles {
    NSArray *all=[self files];NSMutableArray *result=[NSMutableArray array];
    for(NSString *name in all)if([self poolName:name])[result addObject:name];
    return result;
}
- (NSData *)persistentData:(NSString *)key metadata:(BOOL)metadata {
    NSFileManager *fm=[NSFileManager defaultManager];
    for(NSUInteger p=0;p<4;p++) {
        if(metadata && p>0)break;
        NSString *path=[self priorityPath:key tier:p metadata:metadata];
        NSDictionary *attr=[fm attributesOfItemAtPath:path error:NULL];
        if(!attr)continue;
        BOOL regular=[attr[NSFileType] isEqual:NSFileTypeRegular];
        unsigned long long length=[attr[NSFileSize] unsignedLongLongValue];
        NSTimeInterval ttl=metadata?24*3600:_ttl;
        NSDate *date=attr[NSFileModificationDate];
        if(!regular || !length || length>(metadata?1024*1024:8*1024*1024) ||
           !date || -date.timeIntervalSinceNow>ttl || date.timeIntervalSinceNow>60) {
            [fm removeItemAtPath:path error:NULL];continue;
        }
        NSData *data=[NSData dataWithContentsOfFile:path];
        BOOL valid=metadata ?
            ([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]!=nil) :
            JFValidImage(data);
        if(!valid){[fm removeItemAtPath:path error:NULL];continue;}
        return data;
    }
    return nil;
}
- (BOOL)containsImageForKey:(NSString *)key {
    if(!_persistent || !key.length)return NO;
    @synchronized([JFImageCache class]) {
        NSFileManager *fm=[NSFileManager defaultManager];
        for(NSUInteger tier=0;tier<4;tier++) {
            NSString *path=[self priorityPath:key tier:tier metadata:NO];
            NSDictionary *attr=[fm attributesOfItemAtPath:path error:NULL];
            if([attr[NSFileType] isEqual:NSFileTypeRegular] &&
               [attr[NSFileSize] unsignedLongLongValue]>0 &&
               [attr[NSFileSize] unsignedLongLongValue]<=8*1024*1024 &&
               -[attr[NSFileModificationDate] timeIntervalSinceNow]<_ttl)return YES;
        }
    }
    return NO;
}
- (NSData *)freshMetadataForKey:(NSString *)key maxAge:(NSTimeInterval)age {
    if(!_persistent || !key.length || !isfinite(age) || age<=0 || age>86400)return nil;
    @synchronized([JFImageCache class]) {
        NSString *path=[self priorityPath:key tier:3 metadata:YES];
        NSDictionary *attr=[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        NSDate *modified=attr[NSFileModificationDate];
        if(![attr[NSFileType] isEqual:NSFileTypeRegular] || !modified ||
           -modified.timeIntervalSinceNow>age || modified.timeIntervalSinceNow>10)
            return nil;
        return [self persistentData:key metadata:YES];
    }
}
- (NSData *)metadataForKey:(NSString *)key {
    if(!_persistent || !key.length)return nil;
    @synchronized([JFImageCache class]) {return [self persistentData:key metadata:YES];}
}
- (void)storeMetadata:(NSData *)json forKey:(NSString *)key {
    if(!_persistent || !key.length || json.length>1024*1024 || !json.length ||
       ![NSJSONSerialization JSONObjectWithData:json options:0 error:NULL])return;
    @synchronized([JFImageCache class]) {
        [self persistentStore:json forKey:key priority:3 metadata:YES];
    }
}
- (void)persistentStore:(NSData *)data forKey:(NSString *)key
               priority:(NSUInteger)priority metadata:(BOOL)metadata {
    if(!data.length || data.length>8*1024*1024)return;
    NSString *target=[self priorityPath:key tier:priority metadata:metadata];
    NSFileManager *fm=[NSFileManager defaultManager];
    // Globally bound ALL persistent entries, including JSON. Reap lower-tier
    // material before high-priority posters. Same-tier reaps oldest first.
    NSMutableArray *entries=[NSMutableArray array];
    unsigned long long used=0;
    for(NSString *name in [self poolFiles]) {
        NSString *p=[_directory stringByAppendingPathComponent:name];
        NSDictionary *a=[fm attributesOfItemAtPath:p error:NULL];
        if(![a[NSFileType] isEqual:NSFileTypeRegular]){[fm removeItemAtPath:p error:NULL];continue;}
        BOOL isMeta=[name hasPrefix:@"3m"];
        NSDate *date=a[NSFileModificationDate];
        NSTimeInterval ttl=isMeta?24*3600:_ttl;
        if(!date || -date.timeIntervalSinceNow>ttl || date.timeIntervalSinceNow>60){
            [fm removeItemAtPath:p error:NULL];continue;
        }
        if([p isEqual:target])continue;
        NSNumber *size=a[NSFileSize];used+=[size unsignedLongLongValue];
        NSInteger tier=isMeta?3:[[name substringToIndex:1] integerValue];
        [entries addObject:@{@"path":p,@"size":size,@"date":date,@"tier":@(tier)}];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSInteger ta=[a[@"tier"] integerValue],tb=[b[@"tier"] integerValue];
        if(ta!=tb)return ta>tb?NSOrderedAscending:NSOrderedDescending;
        return [a[@"date"] compare:b[@"date"]];
    }];
    for(NSDictionary *e in entries) {
        if(used+data.length<=_capacity)break;
        if([e[@"tier"] integerValue]<(NSInteger)priority)break;
        if([fm removeItemAtPath:e[@"path"] error:NULL])used-=[e[@"size"] unsignedLongLongValue];
    }
    if(used+data.length>_capacity)return;
    // Preserve headroom for ATV's own logs/database on its data partition.
    NSDictionary *fs=[fm attributesOfFileSystemForPath:_directory error:NULL];
    if([fs[NSFileSystemFreeSize] unsignedLongLongValue] <
       1024ULL*1024*1024+data.length)return;
    if([data writeToFile:target options:NSDataWritingAtomic error:NULL])
        [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:target error:NULL];
}
- (void)storeData:(NSData *)data forKey:(NSString *)key priority:(NSUInteger)priority {
    if(!key.length || priority>3 || !JFValidImage(data))return;
    if(!_persistent){[self storeData:data forKey:key];return;}
    @synchronized([JFImageCache class]) {
        NSString *present=nil;
        for(NSUInteger tier=0;tier<4;tier++) {
            NSString *candidate=[self priorityPath:key tier:tier metadata:NO];
            if([[NSFileManager defaultManager] fileExistsAtPath:candidate]){present=candidate;break;}
        }
        NSString *target=[self priorityPath:key tier:priority metadata:NO];
        if(present && ![present isEqual:target]) {
            // Downgrade/upgrade by moving the existing verified image; no
            // duplicate copies of the same logical artwork in two tiers.
            if([[NSFileManager defaultManager] moveItemAtPath:present toPath:target error:NULL])return;
        } else if(present)return;
        [self persistentStore:data forKey:key priority:priority metadata:NO];
    }
}
- (void)dealloc { [_directory release]; [_memory release]; [super dealloc]; }
@end
