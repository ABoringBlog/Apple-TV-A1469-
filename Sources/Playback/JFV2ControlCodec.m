#import "JFV2ControlCodec.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#include <math.h>
static NSString *Canonical(id v) {
    if (v==[NSNull null]) return @"null";
    if ([v isKindOfClass:[NSString class]]) {
        // Protocol fields are ASCII identifiers, never media URLs or paths.
        if (![v canBeConvertedToEncoding:NSASCIIStringEncoding]) return nil;
        NSData *d=[NSJSONSerialization dataWithJSONObject:@[v] options:0 error:NULL];
        NSString *s=[[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease];
        return s.length>=2 ? [s substringWithRange:NSMakeRange(1,s.length-2)] : nil;
    }
    if ([v isKindOfClass:[NSNumber class]]) {
        if (CFGetTypeID((CFTypeRef)v)==CFBooleanGetTypeID()) return [v boolValue]?@"true":@"false";
        double number=[v doubleValue];
        if (!isfinite(number) || fabs(number)>9007199254740991.0) return nil;
        // NSNumberFormatter locale independent fixed fraction, no grouping.
        NSNumberFormatter *f=[[[NSNumberFormatter alloc] init] autorelease];
        f.locale=[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
        f.numberStyle=NSNumberFormatterDecimalStyle;f.usesGroupingSeparator=NO;
        f.minimumFractionDigits=0;f.maximumFractionDigits=6;
        NSString *s=[f stringFromNumber:v];
        return [s isEqual:@"-0"]?@"0":s;
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableArray *parts=[NSMutableArray array];
        for (id k in v) if (![k isKindOfClass:[NSString class]]) return nil;
        for (NSString *k in [[v allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *a=Canonical(k),*b=Canonical(v[k]);if (!a || !b) return nil;
            [parts addObject:[NSString stringWithFormat:@"%@:%@",a,b]];
        }
        return [NSString stringWithFormat:@"{%@}",[parts componentsJoinedByString:@","]];
    }
    return nil;
}
NSData *JFV2Canonical(id value) { return [Canonical(value) dataUsingEncoding:NSASCIIStringEncoding]; }
static NSString *MAC(NSData *key,NSData *data) {
    if (key.length!=32 || !data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256,key.bytes,key.length,data.bytes,data.length,digest);
    NSMutableString *s=[NSMutableString string];
    for (unsigned i=0;i<sizeof(digest);i++) [s appendFormat:@"%02x",digest[i]];
    return s;
}
NSData *JFV2Envelope(NSData *key,NSString *epoch,NSDictionary *event,long long milliseconds,NSString *nonce) {
    if (!epoch || !event || !nonce || milliseconds<0) return nil;
    NSMutableDictionary *d=[NSMutableDictionary dictionaryWithDictionary:@{@"v":@2,@"epoch":epoch,@"event":event,@"ts_ms":@(milliseconds),@"nonce":nonce}];
    NSString *mac=MAC(key,JFV2Canonical(d));if (!mac) return nil;
    d[@"mac"]=mac;return JFV2Canonical(d);
}
BOOL JFV2Receipt(NSData *key,NSDictionary *receipt,NSString *epoch,NSString *nonce) {
    if (![receipt isKindOfClass:[NSDictionary class]] || ![receipt[@"epoch"] isEqual:epoch] || ![receipt[@"nonce"] isEqual:nonce]) return NO;
    NSString *mac=receipt[@"mac"];if (![mac isKindOfClass:[NSString class]] || mac.length!=64) return NO;
    NSMutableDictionary *d=[[receipt mutableCopy] autorelease];[d removeObjectForKey:@"mac"];
    NSString *expected=MAC(key,JFV2Canonical(d));if (!expected) return NO;
    unsigned difference=0;for (NSUInteger i=0;i<64;i++) difference|=[mac characterAtIndex:i]^[expected characterAtIndex:i];
    return difference==0;
}
