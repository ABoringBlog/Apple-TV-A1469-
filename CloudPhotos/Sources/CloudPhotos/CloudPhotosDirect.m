// iCloud Photos H.264 live video on Apple TV 3.
// Based on the tested FoliaDirect AVSampleBufferDisplayLayer transport.
// No HLS media player, no AVPlayer read-ahead buffering.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <stdio.h>
extern NSString *CloudPhotosClientSecret(void);
extern void CloudPhotosDirectStreamStart(AVSampleBufferDisplayLayer *layer);
extern void CloudPhotosDirectStreamStop(void);

static AVSampleBufferDisplayLayer *cpLayer=nil;
static id cpHost=nil;
static volatile BOOL cpRunning=NO;
static volatile unsigned cpGeneration=0;
static NSObject *cpWorker=nil;
static NSString * const cpBase=@"http://192.0.2.24:18793";

static void cpLog(NSString *message){
    FILE *out=fopen("/var/tmp/cloudphotos_direct_lifecycle.log","a");
    if(out){fprintf(out,"%.3f %s\n",[[NSDate date]timeIntervalSince1970],[message UTF8String]);fclose(out);}
}

@interface CPDirectService : NSObject
-(void)request:(NSDictionary*)details;
@end

@implementation CPDirectService
-(void)request:(NSDictionary*)details{
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    NSString *action=[details objectForKey:@"action"];
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"%@/%@",cpBase,action]];
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:url
       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [r setHTTPMethod:@"POST"];
    [r setValue:CloudPhotosClientSecret() forHTTPHeaderField:@"X-ATV-Photos-Key"];
    NSData *data=[NSData data];
    [r setHTTPBody:data];
    NSURLResponse *response=nil;
    NSError *error=nil;
    [NSURLConnection sendSynchronousRequest:r returningResponse:&response error:&error];
    long code=[response isKindOfClass:[NSHTTPURLResponse class]]
       ?(long)[(NSHTTPURLResponse *)response statusCode]:0;
    cpLog([NSString stringWithFormat:@"SERVER_%@ http=%ld err=%ld",
       action,code,error?(long)error.code:0L]);
    [pool drain];
}
@end

static void cpRequest(NSString *action){
    if(!cpWorker)cpWorker=[[CPDirectService alloc]init];
    [NSThread detachNewThreadSelector:@selector(request:)
       toTarget:cpWorker withObject:@{@"action":action}];
}

BOOL CloudPhotosDirectActive(void){return cpRunning;}
void CloudPhotosDirectActivated(id host){
    if(![NSThread isMainThread] || !host)return;
    if(cpRunning && cpHost==host)return;
    if(![host respondsToSelector:@selector(layer)]){
        cpLog(@"HOST_NO_UIVIEW_LAYER");
        return;
    }
    cpGeneration++;
    cpRunning=YES;
    cpHost=[host retain];
    AVSampleBufferDisplayLayer *layer=[AVSampleBufferDisplayLayer layer];
    if(!layer){
        cpLog(@"VIDEO_LAYER_INIT_FAILED");
        cpRunning=NO;
        [cpHost release];cpHost=nil;
        return;
    }
    UIView *view=(UIView *)host;
    layer.frame=view.bounds;
    layer.videoGravity=AVLayerVideoGravityResizeAspect;
    layer.backgroundColor=[UIColor blackColor].CGColor;
    [view.layer addSublayer:layer];
    cpLayer=[layer retain];
    // The only focus outline now lives inside the NAS browser image.
    // Do not draw a CALayer selection border on Apple TV.
    cpLog([NSString stringWithFormat:@"LIVE_LAYER_ATTACHED %.0fx%.0f NAS_FOCUS_ONLY",
       view.bounds.size.width,view.bounds.size.height]);
    CloudPhotosDirectStreamStart(layer);
    cpRequest(@"start");
}
void CloudPhotosDirectStop(void){
    if(!cpRunning && !cpLayer)return;
    cpRunning=NO;
    cpGeneration++;
    CloudPhotosDirectStreamStop();
    if(cpLayer){
        [cpLayer removeFromSuperlayer];
        [cpLayer release];
        cpLayer=nil;
    }
    [cpHost release];cpHost=nil;
    cpRequest(@"stop");
    cpLog(@"STOPPED");
}
void CloudPhotosDirectPopped(id host){
    (void)host;
    CloudPhotosDirectStop();
}
void CloudPhotosDirectExit(id host){
    if(!host || !cpRunning)return;
    cpLog(@"MENU_NATIVE_EXIT");
    CloudPhotosDirectStop();
    SEL selector=NSSelectorFromString(@"stack");
    id stack=[host respondsToSelector:selector]
      ?((id(*)(id,SEL))objc_msgSend)(host,selector):nil;
    if(stack && [stack respondsToSelector:NSSelectorFromString(@"popController")])
       ((void(*)(id,SEL))objc_msgSend)(stack,NSSelectorFromString(@"popController"));
    else cpLog(@"NO_NATIVE_STACK");
}
