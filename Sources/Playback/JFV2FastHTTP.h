#import <Foundation/Foundation.h>
// Bounded, no-redirect, private-LAN synchronous HTTP for the existing signed V2
// hello and periodic sync only. Invoked solely on JFV2EventSender's worker queue.
@interface JFV2FastHTTP : NSObject
+ (NSDictionary *)request:(NSURLRequest *)request;
@end
