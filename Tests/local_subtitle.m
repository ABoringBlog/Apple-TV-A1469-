#import <Foundation/Foundation.h>
#import "Playback/JFLocalSubtitle.h"
#import "Playback/JFLocalSubtitleOverlay.h"
#import <QuartzCore/QuartzCore.h>
#include <string.h>
static int checks=0;
#define CHECK(test) do { checks++; if (!(test)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#test); return 1; } } while(0)
int main(int argc, char **argv) { @autoreleasepool {
    if (argc==3 && !strcmp(argv[1],"--scan-rejected")) {
        NSString *listing=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]
                                                  encoding:NSUTF8StringEncoding error:NULL];
        NSUInteger total=0,valid=0;
        for (NSString *line in [listing componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"SRT_NEEDS_REVIEW "])continue;
            NSString *relative=[line substringFromIndex:[@"SRT_NEEDS_REVIEW " length]];
            @autoreleasepool {
                total++;
                NSString *root=[[[NSProcessInfo processInfo] environment] objectForKey:@"JF_SRT_SCAN_ROOT"]?:@"/tmp/jellyfin-srt-fixture";
                NSString *path=[root stringByAppendingPathComponent:relative];
                NSArray *cues=JFLocalSubtitleParse([NSData dataWithContentsOfFile:path],NULL);
                if (cues.count)valid++;
                else printf("STILL_UNSUPPORTED %s\n",[relative UTF8String]);
            }
        }
        printf("PREVIOUSLY_REJECTED_SRT total=%lu now_valid=%lu remaining=%lu\n",
            (unsigned long)total,(unsigned long)valid,(unsigned long)(total-valid));
        return total==valid ? 0 : 2;
    }
    if (argc==3 && !strcmp(argv[1],"--scan-root")) {
        NSString *root=[NSString stringWithUTF8String:argv[2]];
        NSFileManager *fm=[NSFileManager defaultManager];
        NSDirectoryEnumerator *entries=[fm enumeratorAtPath:root];
        NSUInteger total=0,valid=0,invalid=0;
        NSString *relative=nil;
        while ((relative=[entries nextObject])) {
            if (![[relative.pathExtension lowercaseString] isEqual:@"srt"]) continue;
            @autoreleasepool {
                total++;
                NSData *data=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:relative]];
                NSArray *cues=JFLocalSubtitleParse(data,NULL);
                if (cues.count) valid++;
                else { invalid++; printf("SRT_NEEDS_REVIEW %s\n",[relative UTF8String]); }
            }
        }
        printf("SRT_LIBRARY_SCAN files=%lu parsed=%lu needs_review=%lu\n",
               (unsigned long)total,(unsigned long)valid,(unsigned long)invalid);
        return invalid ? 2 : 0;
    }
    // Host-side CoreAnimation layer lifecycle (not proof of native video Z-order).
    CALayer *mockRoot=[CALayer layer];
    mockRoot.bounds=CGRectMake(0,0,1280,720);
    JFLocalSubtitleOverlay *overlay=[[JFLocalSubtitleOverlay alloc] init];
    CHECK([overlay attachToPlayerController:mockRoot]);
    CHECK(mockRoot.sublayers.count==1);
    [overlay showText:@"你好 / Hello"];
    CATextLayer *textLayer=(CATextLayer *)[mockRoot.sublayers objectAtIndex:0];
    CHECK(!textLayer.hidden && [textLayer.string isEqual:@"你好 / Hello"]);
    [overlay showText:@"你好 / Hello"];
    CHECK(mockRoot.sublayers.count==1);
    [overlay showText:nil];
    CHECK(textLayer.hidden);
    [overlay detach];
    CHECK(mockRoot.sublayers.count==0);
    [overlay release];
    NSString *srt=@"1\n00:00:01,000 --> 00:00:02,400\n你好，世界\nHello world\n\n2\n00:00:03,100 --> 00:00:04,600\n<i>Second subtitle</i>\n";
    NSData *raw=[srt dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error=nil;
    NSArray *cues=JFLocalSubtitleParse(raw,&error);
    CHECK(cues.count==2 && !error);
    CHECK(JFLocalSubtitleAtTicks(cues,0)==nil);
    CHECK(JFLocalSubtitleAtTicks(cues,10000000LL)!=nil);
    CHECK([JFLocalSubtitleAtTicks(cues,10000000LL) containsString:@"你好"]);
    CHECK(JFLocalSubtitleAtTicks(cues,24000000LL)==nil);
    CHECK(JFLocalSubtitleAtTicks(cues,31000000LL)!=nil);
    CHECK([JFLocalSubtitleAtTicks(cues,31000000LL) isEqual:@"Second subtitle"]);
    CHECK(!JFLocalSubtitleAtTicks(cues,46000000LL));
    CHECK(JFLocalSubtitleAtTicks(cues,-1)==nil);
    NSMutableString *many=[NSMutableString string];
    for (NSUInteger i=0;i<8000;i++) [many appendFormat:@"%lu\n00:00:00,000 --> 00:00:02,000\nlong test\n\n",(unsigned long)(i+1)];
    NSArray *large=JFLocalSubtitleParse([many dataUsingEncoding:NSUTF8StringEncoding],&error);
    CHECK(large.count==8000 && !error);
    CHECK(JFLocalSubtitleAtTicks(large,15000000LL)!=nil);
    CHECK(!JFLocalSubtitleParse([@"1\n00:00:02,000 --> 00:00:01,000\nbad\n" dataUsingEncoding:NSUTF8StringEncoding],&error));
    CHECK(!JFLocalSubtitleParse([@"1\n00:00:00,000 --> 00:00:02,000\nA\n\n2\n00:00:00,100 --> 00:00:02,100\nB\n" dataUsingEncoding:NSUTF8StringEncoding],&error) ? NO : YES);
    // Compare bulk random seeks against their last-started cue, independent of rendering.
    for (NSInteger t=0;t<800;t++) CHECK(JFLocalSubtitleAtTicks(large,t*10000LL)!=nil);
    printf("PASS: %d bounded local SRT parsing/timeline assertions\n",checks);
    return 0;
} }
