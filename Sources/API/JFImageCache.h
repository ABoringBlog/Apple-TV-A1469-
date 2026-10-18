#import <Foundation/Foundation.h>
BOOL JFValidImage(NSData *data);
// Worker-confined. Dedicated directory, no URLs/headers/credentials on disk.
// TTL is absolute since insertion. Eviction is oldest insertion first.
@interface JFImageCache : NSObject {
    NSString *_directory;
    NSMutableDictionary *_memory;
    NSUInteger _memoryBytes;
    NSTimeInterval _ttl;
    unsigned long long _capacity;
    BOOL _persistent;
}
- (id)initWithDirectory:(NSString *)directory ttl:(NSTimeInterval)ttl;
// 1 GiB shared budget across all artwork and JSON metadata priority levels.
// 0=all covers, 1=non-Archived backdrops/logos, 2=Archived, 3=metadata.
- (id)initPersistentWithDirectory:(NSString *)directory capacityBytes:(unsigned long long)capacity;
- (void)storeData:(NSData *)data forKey:(NSString *)key priority:(NSUInteger)priority;
- (BOOL)containsImageForKey:(NSString *)key; // cheap worker-only existence test, no image decode
- (NSData *)metadataForKey:(NSString *)key;
- (NSData *)freshMetadataForKey:(NSString *)key maxAge:(NSTimeInterval)age;
- (void)storeMetadata:(NSData *)json forKey:(NSString *)key;
- (NSData *)dataForKey:(NSString *)key;
- (void)storeData:(NSData *)data forKey:(NSString *)key;
- (void)purgeMemory;
- (void)invalidate; // Call on logout, server changes, or explicit image refresh.
@end
