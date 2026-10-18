#import "JFPlaybackModel.h"
#include <math.h>
BOOL JFMediaID(id value) {
    return [value isKindOfClass:[NSString class]] && [value length]>0 && [value length]<=256 &&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet]].location==NSNotFound;
}
BOOL JFTicks(id value) {
    return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((CFTypeRef)value)!=CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue]>=0 && [value doubleValue]<=9007199254740991.0 &&
        [value doubleValue]==(double)[value longLongValue];
}
static NSDictionary *Condition(NSString *property, NSString *value) {
    return @{@"Condition":@"LessThanEqual",@"Property":property,@"Value":value,@"IsRequired":@YES};
}
NSDictionary *JFProvisionalDeviceProfile(void) {
    return @{@"Name":@"Apple TV 3 — SERVER-FIRST playback (DP only when strictly compatible)", @"MaxStreamingBitrate":@10000000,
        @"DirectPlayProfiles":@[@{@"Container":@"mp4,m4v,mov",@"Type":@"Video",@"VideoCodec":@"h264",@"AudioCodec":@"aac"}],
        @"TranscodingProfiles":@[@{@"Container":@"ts",@"Type":@"Video",@"Protocol":@"hls",@"VideoCodec":@"h264",@"AudioCodec":@"aac",@"MaxAudioChannels":@"2",@"Context":@"Streaming"}],
        @"CodecProfiles":@[@{@"Type":@"Video",@"Codec":@"h264",@"Conditions":@[Condition(@"Width",@"1920"),Condition(@"Height",@"1080"),Condition(@"VideoBitDepth",@"8"),Condition(@"VideoFramerate",@"30.01"),Condition(@"VideoLevel",@"40"),@{@"Condition":@"Equals",@"Property":@"VideoRangeType",@"Value":@"SDR",@"IsRequired":@YES}]},
            @{@"Type":@"VideoAudio",@"Codec":@"aac",@"Conditions":@[Condition(@"AudioChannels",@"2"),Condition(@"AudioSampleRate",@"48000")]}],
        // Negotiation-only declarations: unselected embedded subtitle tracks must not
        // disqualify otherwise-compatible DirectPlay sources on Jellyfin 12.
        // The active player fetches SRT cues separately and renders locally, with
        // SubtitleStreamIndex=-1 in the video PlaybackInfo request.
        @"SubtitleProfiles":@[
            @{@"Format":@"srt",@"Method":@"External"},
            @{@"Format":@"subrip",@"Method":@"External"},
            @{@"Format":@"ass",@"Method":@"External"},
            @{@"Format":@"ssa",@"Method":@"External"},
            @{@"Format":@"pgs",@"Method":@"External"},
            @{@"Format":@"pgssub",@"Method":@"External"},
            @{@"Format":@"hdmv_pgs_subtitle",@"Method":@"External"},
            @{@"Format":@"dvdsub",@"Method":@"External"}
        ]};
}
NSDictionary *JFPlaybackBody(long long start, NSInteger subtitle) {
    if (start<0 || start>9007199254740991LL || subtitle < -1 || subtitle>10000) return nil;
    return @{@"DeviceProfile":JFProvisionalDeviceProfile(),@"StartTimeTicks":@(start),@"SubtitleStreamIndex":@(subtitle),
        @"MaxStreamingBitrate":@10000000,@"MaxAudioChannels":@2,@"EnableDirectPlay":@YES,@"EnableDirectStream":@YES,
        @"EnableTranscoding":@YES,@"AllowVideoStreamCopy":@YES,@"AllowAudioStreamCopy":@YES,@"AutoOpenLiveStream":@NO};
}
static BOOL Bounded(id n, double maximum) { return [n isKindOfClass:[NSNumber class]] && isfinite([n doubleValue]) && [n doubleValue]>0 && [n doubleValue]<=maximum; }
static BOOL Flag(id v) { return v && CFGetTypeID((CFTypeRef)v)==CFBooleanGetTypeID() && [v boolValue]; }
NSInteger JFVideoTransportAACIndex(NSDictionary *info, NSString *sourceID) {
    if (![info isKindOfClass:[NSDictionary class]] || !JFMediaID(sourceID)) return -1;
    for (id source in info[@"MediaSources"]) {
        if (![source isKindOfClass:[NSDictionary class]] || ![source[@"Id"] isEqual:sourceID]) continue;
        NSInteger found=-1;
        for (id stream in source[@"MediaStreams"]) {
            if (![stream isKindOfClass:[NSDictionary class]] || ![stream[@"Type"] isEqual:@"Audio"]) continue;
            if (![stream[@"Codec"] isEqual:@"aac"] || !Bounded(stream[@"Channels"],2) ||
                !Bounded(stream[@"SampleRate"],48000) || !JFTicks(stream[@"Index"]) ||
                [stream[@"Index"] integerValue]>10000) continue;
            if (found<0 || [stream[@"IsDefault"] boolValue]) found=[stream[@"Index"] integerValue];
        }
        return found;
    }
    return -1;
}
// The Jellyfin 12 server prefers AverageFrameRate for the device profile's
// ReferenceFrameRate. MP4 VFR files can report 50, 60, or 90000 as the
// r_frame_rate although their actual stream is 24/25/30 fps. Match the
// server's safe reference decision instead of rejecting its DirectPlay offer.
// 30.01 only tolerates minor duration/packet-count rounding (<0.04%).
static BOOL JFATV3VideoFramerateOK(NSDictionary *video) {
    id average=video[@"AverageFrameRate"];
    if (Bounded(average,120)) return [average doubleValue]<=30.01;
    return Bounded(video[@"RealFrameRate"],30.01);
}
static BOOL ContainerOnlyRemuxReason(id value) {
    if (![value isKindOfClass:[NSString class]] || ![value length]) return NO;
    NSURLComponents *parts=[NSURLComponents componentsWithString:value];
    NSString *reason=nil;
    for (NSURLQueryItem *item in parts.queryItems)
        if ([item.name.lowercaseString isEqual:@"transcodereasons"]) { reason=item.value; break; }
    if (!reason.length) return NO;
    BOOL found=NO;
    for (NSString *raw in [reason componentsSeparatedByString:@","]) {
        NSString *part=[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!part.length) continue;
        found=YES;
        if (![part isEqual:@"ContainerNotSupported"]) return NO;
    }
    return found;
}
static id Invalid(NSError **error, NSInteger code) { if (error) *error=[NSError errorWithDomain:@"JFPlayback" code:code userInfo:nil]; return nil; }
NSDictionary *JFPlaybackPlan(NSDictionary *info, NSString *item, long long start, NSError **error) {
    return JFPlaybackPlanForSource(info,item,start,nil,error);
}
NSDictionary *JFPlaybackPlanForSource(NSDictionary *info, NSString *item, long long start, NSString *preferredSource, NSError **error) {
    return JFPlaybackPlanForSourceAndAudio(info,item,start,preferredSource,-1,error);
}
NSDictionary *JFPlaybackPlanForSourceAndAudio(NSDictionary *info, NSString *item, long long start, NSString *preferredSource, NSInteger requestedAudio, NSError **error) {
    if (requestedAudio < -1 || requestedAudio>10000) return Invalid(error,2001);
    if (error) *error=nil;
    if ((preferredSource && !JFMediaID(preferredSource)) || !JFMediaID(item) || !JFTicks(@(start)) || ![info isKindOfClass:[NSDictionary class]] || !JFMediaID(info[@"PlaySessionId"]) ||
        ![info[@"MediaSources"] isKindOfClass:[NSArray class]] || ![info[@"MediaSources"] count] || [info[@"MediaSources"] count]>64 || (info[@"ErrorCode"] && info[@"ErrorCode"]!=[NSNull null])) return Invalid(error,2001);
    NSMutableArray *candidates=[NSMutableArray array];
    for (id value in info[@"MediaSources"]) {
        if (![value isKindOfClass:[NSDictionary class]]) return Invalid(error,2001);
        NSDictionary *s=value;
        if (!JFMediaID(s[@"Id"]) || !JFTicks(s[@"RunTimeTicks"]) || [s[@"RunTimeTicks"] longLongValue]==0 ||
            ![s[@"MediaStreams"] isKindOfClass:[NSArray class]] || [s[@"MediaStreams"] count]>256) return Invalid(error,2001);
        if (preferredSource && ![s[@"Id"] isEqual:preferredSource]) continue;
        if (start>[s[@"RunTimeTicks"] longLongValue]) continue;
        if (Flag(s[@"RequiresOpening"]) || Flag(s[@"IsInfiniteStream"])) continue;
        NSDictionary *video=nil; NSUInteger videos=0,audios=0;
        NSDictionary *chosenAudio=nil, *nativeAudio=nil;
        for (id stream in s[@"MediaStreams"]) {
            if (![stream isKindOfClass:[NSDictionary class]] || ![stream[@"Type"] isKindOfClass:[NSString class]]) return Invalid(error,2001);
            if ([stream[@"Type"] isEqual:@"Video"]) { video=stream; videos++; }
            if ([stream[@"Type"] isEqual:@"Audio"]) {
                audios++;
                // Separate the native video's playable AAC from the user's
                // selected sound. The Mac bridge independently authenticates
                // and plays the selected original track from its AAC cache.
                // Selecting AC3 must not silently change the selected language.
                BOOL indexed=JFTicks(stream[@"Index"]) && [stream[@"Index"] integerValue]<=10000;
                BOOL usable=indexed && [stream[@"Codec"] isEqual:@"aac"] && Bounded(stream[@"Channels"],2) && Bounded(stream[@"SampleRate"],48000);
                if (usable && (!nativeAudio || [stream[@"IsDefault"] boolValue])) nativeAudio=stream;
                if (requestedAudio>=0 && indexed && [stream[@"Index"] integerValue]==requestedAudio) chosenAudio=stream;
            }
        }
        // No implicit fallback when a requested track is absent: it could
        // silently play a different dubbed language.
        if (requestedAudio>=0 && !chosenAudio) continue;
        if (requestedAudio<0) chosenAudio=nativeAudio;
        // Ambiguous audio/video tracks are negotiated through the server, never assumed direct.
        NSUInteger videoRejectMask=0;
        if (videos!=1) videoRejectMask|=1u<<0;
        if (![[video objectForKey:@"Codec"] isEqual:@"h264"]) videoRejectMask|=1u<<1;
        if (!Bounded([video objectForKey:@"Width"],1920)) videoRejectMask|=1u<<2;
        if (!Bounded([video objectForKey:@"Height"],1080)) videoRejectMask|=1u<<3;
        if (!Bounded([video objectForKey:@"BitDepth"],8)) videoRejectMask|=1u<<4;
        if (!JFATV3VideoFramerateOK(video)) videoRejectMask|=1u<<5;
        if (!Bounded([video objectForKey:@"Level"],40)) videoRejectMask|=1u<<6;
        if (![[video objectForKey:@"VideoRange"] isEqual:@"SDR"]) videoRejectMask|=1u<<7;
        BOOL v=videoRejectMask==0;
        BOOL a=nativeAudio!=nil;
        BOOL container=[@[@"mp4",@"m4v",@"mov"] containsObject:s[@"Container"] ?: @""];
        NSString *method=nil;
        BOOL hasHLS=[s[@"TranscodingUrl"] isKindOfClass:[NSString class]] && [s[@"TranscodingUrl"] length];
        // Jellyfin currently disables video SupportsDirectStream in normal PlaybackInfo responses.
        // Recover only the safe remux case the server itself identified as container-only:
        // codecs already satisfy the ATV3 profile and no subtitle/codec/bitrate reason is present.
        BOOL safeContainerRemux=v && a && Flag(s[@"SupportsTranscoding"]) && hasHLS && ContainerOnlyRemuxReason(s[@"TranscodingUrl"]);
        if (v && a && container && Flag(s[@"SupportsDirectPlay"])) method=@"DirectPlay";
        else if (v && a && hasHLS && (Flag(s[@"SupportsDirectStream"]) || safeContainerRemux)) method=@"DirectStream";
        else if (Flag(s[@"SupportsTranscoding"]) && hasHLS) method=@"Transcode";
        if (!method) continue;
        NSMutableDictionary *candidate=[NSMutableDictionary dictionaryWithDictionary:@{@"itemID":item,@"sourceID":s[@"Id"],@"playSessionID":info[@"PlaySessionId"],@"method":method,
            @"durationTicks":s[@"RunTimeTicks"],@"startTicks":@(start),@"provisional":@YES,@"source":s,
            @"videoRejectMask":@(videoRejectMask),@"videoCount":@(videos),@"audioCount":@(audios)}];
        // If the selected source's video is already within the ATV3 H.264/1080p/SDR envelope,
        // preserve it during HLS transcoding and let the server convert only audio. This avoids
        // wasting server work and dramatically reduces segment startup latency.
        if ([method isEqual:@"Transcode"] && v) candidate[@"allowVideoCopy"]=@YES;
        if (chosenAudio) candidate[@"audioStreamIndex"]=chosenAudio[@"Index"];
        [candidates addObject:candidate];
    }
    for (NSString *method in @[@"DirectPlay",@"DirectStream",@"Transcode"])
        for (NSDictionary *plan in candidates) if ([plan[@"method"] isEqual:method]) return plan;
    return Invalid(error,2002);
}
NSDictionary *JFPlaybackReport(NSDictionary *plan, long long ticks, BOOL paused) {
    if (!JFMediaID(plan[@"itemID"]) || !JFMediaID(plan[@"sourceID"]) || !JFMediaID(plan[@"playSessionID"]) ||
        !JFTicks(@(ticks)) || ticks>[plan[@"durationTicks"] longLongValue]) return nil;
    NSMutableDictionary *report=[NSMutableDictionary dictionaryWithDictionary:@{@"ItemId":plan[@"itemID"],@"MediaSourceId":plan[@"sourceID"],@"PlaySessionId":plan[@"playSessionID"],
        @"PositionTicks":@(ticks),@"IsPaused":@(paused),@"CanSeek":@YES,@"PlayMethod":plan[@"method"]}];
    if (JFTicks(plan[@"audioStreamIndex"]) && [plan[@"audioStreamIndex"] integerValue]<=10000) report[@"AudioStreamIndex"]=plan[@"audioStreamIndex"];
    if (JFTicks(plan[@"subtitleStreamIndex"]) && [plan[@"subtitleStreamIndex"] integerValue]<=10000) report[@"SubtitleStreamIndex"]=plan[@"subtitleStreamIndex"];
    return report;
}
