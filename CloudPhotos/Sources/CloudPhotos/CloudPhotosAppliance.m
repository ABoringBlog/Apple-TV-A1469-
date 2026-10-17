#import <Foundation/Foundation.h>
#import "CloudPhotosBackRow.h"

@interface CloudPhotosBundleAnchor : NSObject
@end

@implementation CloudPhotosBundleAnchor
@end

__attribute__((constructor))
static void CloudPhotosEntry(void)
{
    @autoreleasepool {
        NSLog(@"CloudPhotos: entry");
        BOOL ok = CloudPhotosRegisterBackRowClasses();
        NSLog(@"CloudPhotos: BackRow registration %@", ok ? @"OK" : @"FAILED");
    }
}
