#import "JFLocalSubtitle.h"
#import <CoreFoundation/CoreFoundation.h>
static NSArray *JFLocalBad(NSError **error) {
    if (error) *error=[NSError errorWithDomain:@"JFLocalSubtitle" code:2301 userInfo:nil];
    return nil;
}
static BOOL JFLocalDigits(NSString *s) {
    if (!s.length || s.length>4) return NO;
    for (NSUInteger i=0;i<s.length;i++) {
        unichar ch=[s characterAtIndex:i];if (ch<'0'||ch>'9')return NO;
    }
    return YES;
}
static long long JFLocalTimestamp(NSString *source) {
    NSString *value=[source stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray *fields=[value componentsSeparatedByString:@":"];
    if (fields.count!=3 || !JFLocalDigits(fields[0]) || !JFLocalDigits(fields[1]))return -1;
    NSString *last=[fields[2] stringByReplacingOccurrencesOfString:@"." withString:@","];
    NSArray *ss=[last componentsSeparatedByString:@","];
    if (ss.count!=2 || !JFLocalDigits(ss[0]) || !JFLocalDigits(ss[1]) || [ss[1] length]>3)return -1;
    long long h=[fields[0] longLongValue],m=[fields[1] longLongValue],s=[ss[0] longLongValue];
    if (h>99 || m>59 || s>59)return -1;
    long long ms=[ss[1] longLongValue];
    if ([ss[1] length]==1)ms*=100;
    if ([ss[1] length]==2)ms*=10;
    return (((h*60+m)*60+s)*1000+ms)*10000LL;
}
NSArray *JFLocalSubtitleParse(NSData *data, NSError **error) {
    if (error)*error=nil;
    if (![data isKindOfClass:[NSData class]] || !data.length || data.length>2*1024*1024)return JFLocalBad(error);
    NSString *text=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!text && data.length>=2) {
        const unsigned char *b=[data bytes];
        if (b[0]==0xFF && b[1]==0xFE)text=[[[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding] autorelease];
        if (b[0]==0xFE && b[1]==0xFF)text=[[[NSString alloc] initWithData:data encoding:NSUTF16BigEndianStringEncoding] autorelease];
    }
    if (!text) {
        NSStringEncoding encoding=CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        text=[[[NSString alloc] initWithData:data encoding:encoding] autorelease];
    }
    if (!text || [text rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound)return JFLocalBad(error);
    if ([text hasPrefix:@"\uFEFF"])text=[text substringFromIndex:1];
    text=[[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray *cues=[NSMutableArray array];
    NSRegularExpression *style=[NSRegularExpression regularExpressionWithPattern:@"</?(?:i|b|u|font)(?:\\s+[^>]*)?>" options:NSRegularExpressionCaseInsensitive error:NULL];
    NSArray *blocks=[text componentsSeparatedByString:@"\n\n"];
    if (blocks.count>12000)return JFLocalBad(error);
    for (NSString *block in blocks) {
        NSArray *lines=[block componentsSeparatedByString:@"\n"];
        if (lines.count<2 || lines.count>42)continue;
        NSUInteger timeLine=NSNotFound;
        for (NSUInteger i=0;i<MIN((NSUInteger)3,lines.count);i++)
            if ([lines[i] containsString:@"-->"]) {timeLine=i;break;}
        if (timeLine==NSNotFound || timeLine+1>=lines.count)continue;
        NSArray *times=[lines[timeLine] componentsSeparatedByString:@"-->"];
        if (times.count!=2)continue;
        long long start=JFLocalTimestamp(times[0]),end=JFLocalTimestamp(times[1]);
        // Real-world SRT often contains zero-length or inverted cue intervals.
        // Ignore those cues rather than rendering or rejecting an entire feature film.
        if (start<0 || end<=start || end>9007199254740991LL)continue;
        NSString *body=[[lines subarrayWithRange:NSMakeRange(timeLine+1,lines.count-timeLine-1)] componentsJoinedByString:@"\n"];
        body=[body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!body.length || body.length>2048)continue;
        body=[style stringByReplacingMatchesInString:body options:0 range:NSMakeRange(0,body.length) withTemplate:@""];
        if (!body.length)continue;
        [cues addObject:@{@"start":@(start),@"end":@(end),@"text":body}];
        if (cues.count>10000)return JFLocalBad(error);
    }
    [cues sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];
    return cues.count ? [NSArray arrayWithArray:cues] : JFLocalBad(error);
}
NSString *JFLocalSubtitleAtTicks(NSArray *cues, long long ticks) {
    if (![cues isKindOfClass:[NSArray class]] || !cues.count || ticks<0)return nil;
    NSUInteger lo=0,hi=cues.count;
    while (lo<hi) {
        NSUInteger mid=lo+(hi-lo)/2;
        if ([cues[mid][@"start"] longLongValue]<=ticks)lo=mid+1;
        else hi=mid;
    }
    if (!lo)return nil;
    NSDictionary *cue=cues[lo-1];
    return ticks<[cue[@"end"] longLongValue] ? cue[@"text"] : nil;
}
