#import "JFAudio.h"
#import "JFPlaybackModel.h"

static id JFAudioBad(NSError **error) {
    if (error) *error=[NSError errorWithDomain:@"JFAudio" code:2201 userInfo:nil];
    return nil;
}
NSArray *JFAudioTracks(NSArray *sources, NSError **error) {
    if (error) *error=nil;
    if (![sources isKindOfClass:[NSArray class]] || sources.count>64) return JFAudioBad(error);
    NSMutableArray *tracks=[NSMutableArray array];
    NSMutableSet *keys=[NSMutableSet set];
    for (id value in sources) {
        if (![value isKindOfClass:[NSDictionary class]] || !JFMediaID(value[@"Id"])) return JFAudioBad(error);
        id raw=value[@"MediaStreams"];
        if (!raw) continue;
        if (![raw isKindOfClass:[NSArray class]] || [raw count]>256) return JFAudioBad(error);
        for (id stream in raw) {
            if (![stream isKindOfClass:[NSDictionary class]]) return JFAudioBad(error);
            if (![stream[@"Type"] isEqual:@"Audio"]) continue;
            id index=stream[@"Index"], codec=stream[@"Codec"];
            if (!JFTicks(index) || [index integerValue]>10000 || ![codec isKindOfClass:[NSString class]] || ![codec length]) return JFAudioBad(error);
            NSString *key=[NSString stringWithFormat:@"%@:%@",value[@"Id"],index];
            if ([keys containsObject:key]) return JFAudioBad(error);
            for (NSString *name in @[@"Language",@"Title"])
                if (stream[name] && ![stream[name] isKindOfClass:[NSString class]]) return JFAudioBad(error);
            if (stream[@"IsDefault"] && CFGetTypeID((CFTypeRef)stream[@"IsDefault"])!=CFBooleanGetTypeID()) return JFAudioBad(error);
            for (NSString *name in @[@"Channels",@"SampleRate"])
                if (stream[name] && (!JFTicks(stream[name]) || [stream[name] longLongValue]<=0)) return JFAudioBad(error);
            [keys addObject:key];
            [tracks addObject:@{
                @"sourceID":value[@"Id"], @"index":index, @"codec":[codec lowercaseString],
                @"language":stream[@"Language"] ?: @"und", @"title":stream[@"Title"] ?: @"",
                @"channels":stream[@"Channels"] ?: @0, @"sampleRate":stream[@"SampleRate"] ?: @0,
                @"default":@([stream[@"IsDefault"] boolValue])
            }];
        }
    }
    return tracks;
}
NSDictionary *JFAudioDefaultTrack(NSArray *tracks) {
    if (![tracks isKindOfClass:[NSArray class]] || !tracks.count) return nil;
    NSDictionary *firstCompatible=nil;
    for (id track in tracks) {
        if (![track isKindOfClass:[NSDictionary class]]) continue;
        BOOL compatible=[track[@"codec"] isEqual:@"aac"] &&
            [track[@"channels"] integerValue]>0 && [track[@"channels"] integerValue]<=2 &&
            [track[@"sampleRate"] integerValue]>0 && [track[@"sampleRate"] integerValue]<=48000;
        if (compatible && !firstCompatible) firstCompatible=track;
        if (compatible && [track[@"default"] boolValue]) return track;
    }
    return firstCompatible ?: ([tracks[0] isKindOfClass:[NSDictionary class]] ? tracks[0] : nil);
}
NSString *JFAudioTrackLabel(NSDictionary *track) {
    if (![track isKindOfClass:[NSDictionary class]] || !JFMediaID(track[@"sourceID"]) || !JFTicks(track[@"index"]) ||
        ![track[@"codec"] isKindOfClass:[NSString class]] || ![track[@"codec"] length]) return nil;
    NSString *title=[track[@"title"] isKindOfClass:[NSString class]] ? track[@"title"] : @"";
    NSString *language=[track[@"language"] isKindOfClass:[NSString class]] ? track[@"language"] : @"und";
    NSString *base=title.length ? title : (![language isEqual:@"und"] && language.length ? language : [NSString stringWithFormat:@"Track %ld",(long)[track[@"index"] integerValue]]);
    NSMutableArray *parts=[NSMutableArray arrayWithObject:base];
    if (title.length && language.length && ![language isEqual:@"und"]) [parts addObject:language];
    [parts addObject:[track[@"codec"] uppercaseString]];
    NSInteger channels=[track[@"channels"] integerValue];
    if (channels>0) [parts addObject:[NSString stringWithFormat:@"%ldch",(long)channels]];
    return [parts componentsJoinedByString:@" · "];
}
