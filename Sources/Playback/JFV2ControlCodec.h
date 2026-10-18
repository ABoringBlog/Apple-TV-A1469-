#import <Foundation/Foundation.h>
NSData *JFV2Canonical(id value);
NSData *JFV2Envelope(NSData *key, NSString *epoch, NSDictionary *event, long long milliseconds, NSString *nonce);
BOOL JFV2Receipt(NSData *key, NSDictionary *receipt, NSString *epoch, NSString *nonce);
