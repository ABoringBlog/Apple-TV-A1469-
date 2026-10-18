#import <Foundation/Foundation.h>
// Pure predicate used by host regression; no worker/sink side effects.
BOOL JFV2BackgroundHoldDue(NSTimeInterval now, NSTimeInterval lastMain, BOOL armed, BOOL alreadySent);
@interface JFAppAudioLink : NSObject
+ (void)bindPlayer:(id)player plan:(NSDictionary *)plan;
+ (BOOL)startHeldPlayer:(id)player plan:(NSDictionary *)plan
                 ticks:(long long)ticks ready:(void (^)(void))ready
                failure:(void (^)(void))failure;
+ (BOOL)isBoundPlayer:(id)player;
+ (void)event:(NSString *)event plan:(NSDictionary *)plan request:(NSURLRequest *)request ticks:(long long)ticks paused:(BOOL)paused;
@end
