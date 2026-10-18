#import "JFSubtitle.h"
#import "JFPlaybackModel.h"
static id Bad(NSError **error) { if (error) *error=[NSError errorWithDomain:@"JFSubtitle" code:2101 userInfo:nil]; return nil; }
NSArray *JFSubtitleTracks(NSArray *streams, NSError **error) {
    if (error) *error=nil;
    if (![streams isKindOfClass:[NSArray class]] || streams.count>256) return Bad(error);
    NSMutableArray *tracks=[NSMutableArray array]; NSMutableSet *indices=[NSMutableSet set];
    for (id stream in streams) {
        if (![stream isKindOfClass:[NSDictionary class]]) return Bad(error);
        if (![stream[@"Type"] isEqual:@"Subtitle"]) continue;
        id index=stream[@"Index"], codec=stream[@"Codec"];
        if (!JFTicks(index) || [index integerValue]>10000 || [indices containsObject:index] || ![codec isKindOfClass:[NSString class]] || ![codec length]) return Bad(error);
        for (NSString *key in @[@"IsExternal",@"IsForced",@"IsDefault"])
            if (stream[key] && CFGetTypeID((CFTypeRef)stream[key])!=CFBooleanGetTypeID()) return Bad(error);
        for (NSString *key in @[@"Language",@"Title"])
            if (stream[key] && ![stream[key] isKindOfClass:[NSString class]]) return Bad(error);
        [indices addObject:index];
        [tracks addObject:@{@"index":index,@"codec":[codec lowercaseString],@"external":@([stream[@"IsExternal"] boolValue]),
            @"forced":@([stream[@"IsForced"] boolValue]),@"default":@([stream[@"IsDefault"] boolValue]),
            @"language":stream[@"Language"] ?: @"und",@"title":stream[@"Title"] ?: @"",
            @"path":[stream[@"Path"] isKindOfClass:[NSString class]] ? stream[@"Path"] : @""}];
    }
    return tracks;
}
NSArray *JFSubtitleTracksForSources(NSArray *sources, NSError **error) {
    if (error) *error=nil;
    if (![sources isKindOfClass:[NSArray class]] || sources.count>64) return Bad(error);
    NSMutableArray *all=[NSMutableArray array]; NSMutableSet *keys=[NSMutableSet set];
    for (id source in sources) {
        if (![source isKindOfClass:[NSDictionary class]] || !JFMediaID(source[@"Id"])) return Bad(error);
        id streams=source[@"MediaStreams"];
        if (!streams) continue;
        NSArray *tracks=JFSubtitleTracks(streams,error);
        if (!tracks) return nil;
        for (NSDictionary *track in tracks) {
            NSString *key=[NSString stringWithFormat:@"%@:%@",source[@"Id"],track[@"index"]];
            if ([keys containsObject:key]) return Bad(error);
            [keys addObject:key];
            NSMutableDictionary *copy=[[track mutableCopy] autorelease];
            copy[@"sourceID"]=source[@"Id"]; [all addObject:copy];
        }
    }
    return all;
}
static NSString *SubtitleCodecLabel(NSString *codec) {
    if ([@[@"srt",@"subrip"] containsObject:codec]) return @"SRT";
    if ([@[@"ass",@"ssa"] containsObject:codec]) return @"ASS";
    if ([@[@"pgs",@"pgssub",@"hdmv_pgs_subtitle"] containsObject:codec]) return @"PGS";
    if ([codec isEqual:@"dvdsub"]) return @"DVD";
    return [codec uppercaseString];
}
NSString *JFSubtitleTrackLabel(NSDictionary *track) {
    if (![track isKindOfClass:[NSDictionary class]] || !JFTicks(track[@"index"]) ||
        ![track[@"codec"] isKindOfClass:[NSString class]] || ![track[@"codec"] length]) return nil;
    NSString *title=[track[@"title"] isKindOfClass:[NSString class]] ? track[@"title"] : @"";
    NSString *language=[track[@"language"] isKindOfClass:[NSString class]] ? track[@"language"] : @"und";
    NSString *base=title.length ? title : (![language isEqual:@"und"] && language.length ? language : [NSString stringWithFormat:@"Track %ld",(long)[track[@"index"] integerValue]]);
    NSMutableArray *parts=[NSMutableArray arrayWithObject:base];
    if (title.length && language.length && ![language isEqual:@"und"]) [parts addObject:language];
    [parts addObject:SubtitleCodecLabel(track[@"codec"])];
    if ([track[@"external"] boolValue]) [parts addObject:@"External"];
    if ([track[@"forced"] boolValue]) [parts addObject:@"Forced"];
    return [parts componentsJoinedByString:@" · "];
}
NSDictionary *JFSubtitleSelection(NSArray *tracks, NSInteger index, BOOL preserve, NSError **error) {
    if (error) *error=nil;
    if (![tracks isKindOfClass:[NSArray class]]) return Bad(error);
    if (index==-1) return @{@"index":@(-1),@"strategy":@"off",@"provisional":@NO};
    for (NSDictionary *track in tracks) {
        if (![track isKindOfClass:[NSDictionary class]] || !JFTicks(track[@"index"]) || ![track[@"codec"] isKindOfClass:[NSString class]]) return Bad(error);
        if ([track[@"index"] integerValue]!=index) continue;
        NSString *codec=track[@"codec"];
        if (![@[@"srt",@"subrip",@"ass",@"ssa",@"pgs",@"pgssub",@"hdmv_pgs_subtitle",@"dvdsub"] containsObject:codec]) return Bad(error);
        // SRT is composed over the original video locally; complex formats
        // must be preprocessed to SRT, not silently trigger video burn-in.
        BOOL local=[@[@"srt",@"subrip"] containsObject:codec];
        return @{@"index":@(index),
                 @"strategy":local ? @"local-srt" : @"preprocess-required",
                 @"provisional":@NO,@"losesStyling":@( !local )};
    }
    return Bad(error);
}
NSString *JFSubtitleText(NSData *data, NSError **error) {
    if (error) *error=nil;
    if (![data isKindOfClass:[NSData class]] || !data.length || data.length>2*1024*1024) return Bad(error);
    NSString *text=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!text || [text rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound) return Bad(error);
    if ([text hasPrefix:@"\uFEFF"]) text=[text substringFromIndex:1];
    text=[[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSString *normalized=[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *cues=[normalized componentsSeparatedByString:@"\n\n"];
    NSRegularExpression *time=[NSRegularExpression regularExpressionWithPattern:@"^[0-9]{2}:[0-5][0-9]:[0-5][0-9],[0-9]{3} --> [0-9]{2}:[0-5][0-9]:[0-5][0-9],[0-9]{3}$" options:0 error:NULL];
    NSUInteger count=0;
    for (NSString *cue in cues) {
        if (!cue.length) continue;
        NSArray *lines=[cue componentsSeparatedByString:@"\n"];
        if (lines.count<3 || ![lines[0] length] || [lines[0] rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location!=NSNotFound ||
            ![time numberOfMatchesInString:lines[1] options:0 range:NSMakeRange(0,[lines[1] length])]) return Bad(error);
        NSArray *times=[lines[1] componentsSeparatedByString:@" --> "];
        if ([times[0] compare:times[1]]!=NSOrderedAscending || ![[[lines subarrayWithRange:NSMakeRange(2,lines.count-2)] componentsJoinedByString:@"\n"] length]) return Bad(error);
        count++;
    }
    return count ? text : Bad(error);
}
