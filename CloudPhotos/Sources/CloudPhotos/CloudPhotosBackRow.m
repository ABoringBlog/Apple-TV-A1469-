#include "CloudPhotosPublicConfig.h"
#import "CloudPhotosBackRow.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>
#include <string.h>

static char internetcloudphotosTimerKey;
static NSMutableArray *cloudphotosRows;
static NSData *cloudPhotosRemoteJPEG=nil;
static NSString *cloudPhotosRemoteEtag=nil;
static BOOL cloudPhotosRemoteActive=NO;
static BOOL cloudPhotosPollInFlight=NO;
static NSTimeInterval cloudPhotosLastMenu=0;
static BOOL cloudPhotosSelectPressed=NO;
static char cloudPhotosPollTimerKey;
extern void CloudPhotosPasswordRegister(Class cls);
extern void CloudPhotosPasswordResetOnReturn(void);
extern BOOL CloudPhotosPasswordActive(void);
extern BOOL CloudPhotosDirectActive(void);
extern void CloudPhotosDirectActivated(id controller);
extern void CloudPhotosDirectPopped(id controller);
extern void CloudPhotosDirectStop(void);
extern void CloudPhotosDirectExit(id controller);
extern BOOL CloudPhotosVideoHostSelect(id event);
extern void CloudPhotosVideoActivated(id controller);
extern void CloudPhotosVideoPopped(id controller);
static NSString *CloudPhotosNASBase=@"http://192.0.2.24:18790";
static NSString *CloudPhotosPrivateKey=CP_API_KEY_NS;
NSString *CloudPhotosClientSecret(void) {return CloudPhotosPrivateKey;}
// Separate from the HTTP authorization token; NEVER sent over the network.
NSString *CloudPhotosInputCryptoKey(void){return CP_INPUT_KEY_NS;}
static void CloudPhotosBeginFramePoll(id controller);
static void CloudPhotosFetchRemoteFrame(id controller,SEL cmd,id unused);
static void CloudPhotosApplyRemoteFrame(id controller,SEL cmd,id unused);
static void CloudPhotosSendNavigation(id controller,SEL cmd,id action);
// 0=controls, 1=grid, 2=OneUp filmstrip, 3=immersive photo.
static volatile NSInteger cloudPhotosNavTier=0;
static volatile BOOL cloudPhotosPhotoLayer=NO;
static BOOL cpSelectDown=NO,cpSelectDidHold=NO;
static NSTimeInterval cpSelectLastAccepted=0,cpSelectStart=0;
static NSTimer *cpSelectHoldTimer=nil;
static NSTimeInterval cpPhoneSelectAt=0;
static BOOL cpPhoneSelectHeld=NO;
static NSOperationQueue *cloudPhotosNavQueue=nil;
static void CloudPhotosQueueNav(id controller,NSString *action) {
    if(!controller || ![action length])return;
    @synchronized([NSObject class]){
        if(!cloudPhotosNavQueue){
            cloudPhotosNavQueue=[[NSOperationQueue alloc]init];
            [cloudPhotosNavQueue setMaxConcurrentOperationCount:1];
        }
    }
    // Prevent held iPhone or IR direction keys from accumulating seconds
    // of stale navigation requests while the page performs a grid scroll.
    if([cloudPhotosNavQueue operationCount]>=5 &&
       ([action isEqualToString:@"up"]||[action isEqualToString:@"down"]||
        [action isEqualToString:@"left"]||[action isEqualToString:@"right"]))return;
    NSInvocationOperation *task=[[NSInvocationOperation alloc]
        initWithTarget:controller
        selector:NSSelectorFromString(@"icloudphotosNav:") object:action];
    [cloudPhotosNavQueue addOperation:task];
    [task release];
}
static void CloudPhotosPollTimer(id controller,SEL cmd,id timer);

static NSString *cloudphotosPage=@"Home";
static NSInteger cloudphotosSelected=0;
static AVPlayer *cloudphotosPlayer=nil;
static NSString *cloudphotosNowPlaying=nil;
static BOOL cloudphotosLoading=NO;
static NSString *cloudphotosStatus=@"请选择分类";
static NSString *cloudphotosQuery=nil;
static NSMutableString *cloudphotosSearchText=nil;
static NSInteger cloudphotosLetterIndex=0;
static NSString *cloudphotosAlphabet=@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ";
static NSString *cloudphotosCountry=nil;
static NSString *cloudphotosTag=nil;
static NSDictionary *cloudphotosPlayingStation=nil;
static BOOL cloudphotosPaused=NO;
static NSInteger cloudphotosRetryCount=0;
static NSString *cloudphotosLastError=nil;
static NSString *cloudphotosLastStationPage=nil;
static NSInteger cloudphotosLastStationIndex=0;
static id cloudphotosObserver=nil;
static NSTimeInterval cloudphotosNextRetry=0;
static NSTimeInterval cloudphotosStartedAt=0;
static BOOL cloudphotosReady=NO;
static void CloudPhotosRefresh(id self, SEL cmd);
static void CloudPhotosPlayStation(id controller,NSDictionary *item);
@interface CloudPhotosPlaybackMonitor : NSObject
- (void)playerFailed:(NSNotification *)note;
- (void)playerStatus:(NSNotification *)note;
@end
@implementation CloudPhotosPlaybackMonitor
- (void)playerFailed:(NSNotification *)note {
    NSError *error=[[note userInfo] objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey];
    cloudphotosStatus=[NSString stringWithFormat:@"播放失败：%@",error.localizedDescription?:@"未知错误"];
    NSLog(@"CloudPhotos: playback failed %@",error);
}
- (void)playerStatus:(NSNotification *)note {
    if (cloudphotosPlayer.currentItem.status==AVPlayerItemStatusFailed) {
        cloudphotosStatus=[NSString stringWithFormat:@"播放失败：%@",cloudphotosPlayer.currentItem.error.localizedDescription?:@"格式不受支持"];
        NSLog(@"CloudPhotos: player item failed %@",cloudphotosPlayer.currentItem.error);
    }
}
@end
static void CloudPhotosStopPlayback(void) {
    if (cloudphotosPlayer.currentItem && cloudphotosObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:cloudphotosObserver name:AVPlayerItemFailedToPlayToEndTimeNotification object:cloudphotosPlayer.currentItem];
        /* Status is polled on the main run loop; do not register KVO without observeValueForKeyPath:. */
    }
    [cloudphotosPlayer pause];[cloudphotosPlayer release];cloudphotosPlayer=nil;cloudphotosPaused=NO;cloudphotosReady=NO;
}
static void CloudPhotosPlayStation(id controller,NSDictionary *item) {
    NSString *stream=[item objectForKey:@"url_resolved"];
    NSURL *url=[stream isKindOfClass:[NSString class]]?[NSURL URLWithString:stream]:nil;
    if (!url || ![@[@"http",@"https"] containsObject:[url.scheme lowercaseString]]) {cloudphotosStatus=@"该电台无法播放";return;}
    CloudPhotosStopPlayback();
    AVPlayerItem *playerItem=[AVPlayerItem playerItemWithURL:url];
    cloudphotosPlayer=[[AVPlayer playerWithPlayerItem:playerItem] retain];
    if (!cloudphotosObserver)cloudphotosObserver=[[CloudPhotosPlaybackMonitor alloc]init];
    [[NSNotificationCenter defaultCenter] addObserver:cloudphotosObserver selector:@selector(playerFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    /* Status polling avoids KVO crashes on legacy ATV3 AVFoundation. */
    [cloudphotosPlayer play];
    cloudphotosStartedAt=[NSDate timeIntervalSinceReferenceDate];cloudphotosReady=NO;
    [cloudphotosPlayingStation release];cloudphotosPlayingStation=[item copy];
    [cloudphotosNowPlaying release];cloudphotosNowPlaying=[[item objectForKey:@"name"] copy];
    cloudphotosStatus=@"正在连接电台…";cloudphotosPaused=NO;
    [NSThread detachNewThreadSelector:NSSelectorFromString(@"internetcloudphotosRecordPlayed:") toTarget:controller withObject:item];
}

static NSString *CloudPhotosEscape(NSString *s) { return [[s stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"]; }
static NSDictionary *CloudPhotosAPI(NSString *path) {
    NSURL *url=[NSURL URLWithString:[@"http://192.0.2.15:8100" stringByAppendingString:path]];
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    NSData *data=[NSURLConnection sendSynchronousRequest:req returningResponse:NULL error:NULL];
    if (!data) return nil;
    id result=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [result isKindOfClass:[NSDictionary class]] ? result : nil;
}
static void CloudPhotosLoadBackground(id controller) {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    NSString *page=nil,*country=nil,*tag=nil,*query=nil;
    @synchronized([NSObject class]) { page=[cloudphotosPage copy]; country=[cloudphotosCountry copy]; tag=[cloudphotosTag copy]; query=[cloudphotosQuery copy]; }
    NSString *path=nil; NSString *key=nil;
    if ([page isEqual:@"Stations"]) {
        NSMutableArray *parts=[NSMutableArray arrayWithObject:@"limit=100"];
        if (country.length) [parts addObject:[@"countrycode=" stringByAppendingString:CloudPhotosEscape(country)]];
        if (tag.length) [parts addObject:[@"tag=" stringByAppendingString:CloudPhotosEscape(tag)]];
        if (query.length) [parts addObject:[@"name=" stringByAppendingString:CloudPhotosEscape(query)]];
        path=[@"/v1/cloudphotos/stations?" stringByAppendingString:[parts componentsJoinedByString:@"&"]];key=@"stations";
    } else if ([page isEqual:@"Countries"]) {path=@"/v1/cloudphotos/countries";key=@"countries";}
    else if ([page isEqual:@"Genres"]) {path=@"/v1/cloudphotos/tags";key=@"tags";}
    else if ([page isEqual:@"Favorites"]) {path=@"/v1/cloudphotos/favorites";key=@"favorites";}
    else if ([page isEqual:@"Recent"]) {path=@"/v1/cloudphotos/recent";key=@"recent";}
    NSDictionary *result=path?CloudPhotosAPI(path):nil;
    @synchronized([NSObject class]) {
        if ([cloudphotosPage isEqual:page]) {
            [cloudphotosRows release]; cloudphotosRows=[[NSMutableArray alloc]initWithArray:[result objectForKey:key]?:@[]];
            cloudphotosSelected=0;cloudphotosStatus=result?@"加载完成":@"无法连接桥接服务";cloudphotosLoading=NO;
        }
    }
    [controller performSelectorOnMainThread:NSSelectorFromString(@"internetcloudphotosApplyFreshData") withObject:nil waitUntilDone:NO];
    [page release];[country release];[tag release];[query release];[pool drain];
}
static void CloudPhotosLoad(id controller) {
    cloudphotosLoading=YES;cloudphotosStatus=@"正在加载…";
    [NSThread detachNewThreadSelector:NSSelectorFromString(@"internetcloudphotosLoadPage:") toTarget:controller withObject:nil];
}
static void CloudPhotosRecord(NSString *action,NSDictionary *station) {
    if (!station)return;
    NSDictionary *payload=@{@"station":station};
    NSData *body=[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSURL *url=[NSURL URLWithString:[@"http://192.0.2.15:8100/v1/cloudphotos/" stringByAppendingString:action]];
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3];
    [req setHTTPMethod:@"POST"];[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];[req setHTTPBody:body];
    [NSURLConnection sendSynchronousRequest:req returningResponse:NULL error:NULL];
}


/* ---------------------------------------------------------
   Generic ABI helpers
   --------------------------------------------------------- */

static BOOL CloudPhotosSignature(id target, SEL sel, const char *result, NSArray *args)
{
    if (!target || ![target respondsToSelector:sel])
        return NO;

    NSMethodSignature *s = [target methodSignatureForSelector:sel];

    if (!s ||
        strcmp([s methodReturnType], result) ||
        [s numberOfArguments] != [args count] + 2)
        return NO;

    for (NSUInteger i = 0; i < [args count]; i++) {
        if (strcmp([s getArgumentTypeAtIndex:i + 2],
                   [[args objectAtIndex:i] UTF8String]))
            return NO;
    }

    return YES;
}

static id CloudPhotosObject(id target, NSString *name)
{
    SEL sel = NSSelectorFromString(name);

    if (!CloudPhotosSignature(target, sel, @encode(id), @[]))
        return nil;

    return ((id(*)(id,SEL))objc_msgSend)(target, sel);
}

static id CloudPhotosNew(Class cls)
{
    if (!cls)
        return nil;

    return [[cls alloc] init];
}

static IMP CloudPhotosControllerSuper(SEL selector)
{
    Class cls = objc_getClass("CloudPhotosController");

    if (!cls)
        return NULL;

    Class base = class_getSuperclass(cls);

    return base ? class_getMethodImplementation(base, selector) : NULL;
}

static IMP CloudPhotosApplianceSuper(SEL selector)
{
    Class cls = objc_getClass("CloudPhotosAppliance");

    if (!cls)
        return NULL;

    Class base = class_getSuperclass(cls);

    return base ? class_getMethodImplementation(base, selector) : NULL;
}

/* ---------------------------------------------------------
   CloudPhotos display
   --------------------------------------------------------- */

static NSDictionary *CloudPhotosBridgeData(void)
{
    NSURL *url = [NSURL URLWithString:@"http://192.0.2.15:8099/v1/internetcloudphotos"];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (![data length]) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static NSDictionary *internetcloudphotosCachedSnapshot = nil;
static NSTimeInterval internetcloudphotosCachedAt = 0;
static BOOL internetcloudphotosFetchInFlight = NO;

static NSString *CloudPhotosCachePath(void)
{
    return @"/var/mobile/Library/Caches/org.atv3.cloudphotos.snapshot.json";
}

static void CloudPhotosStoreSnapshot(NSDictionary *fresh)
{
    if (![fresh isKindOfClass:[NSDictionary class]]) return;
    @synchronized([NSObject class]) {
        [internetcloudphotosCachedSnapshot release];
        internetcloudphotosCachedSnapshot=[fresh retain];
        internetcloudphotosCachedAt=[NSDate timeIntervalSinceReferenceDate];
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:fresh options:0 error:NULL];
    if ([data length]) [data writeToFile:CloudPhotosCachePath() atomically:YES];
}

static NSDictionary *CloudPhotosSnapshot(void)
{
    @synchronized([NSObject class]) {
        if (!internetcloudphotosCachedSnapshot) {
            NSData *data=[NSData dataWithContentsOfFile:CloudPhotosCachePath()];
            if ([data length]) {
                id obj=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([obj isKindOfClass:[NSDictionary class]]) internetcloudphotosCachedSnapshot=[obj retain];
            }
        }
        return internetcloudphotosCachedSnapshot;
    }
}

static void CloudPhotosFetchAsync(id controller)
{
    @synchronized([NSObject class]) {
        if (internetcloudphotosFetchInFlight) return;
        internetcloudphotosFetchInFlight=YES;
    }
    [NSThread detachNewThreadSelector:NSSelectorFromString(@"internetcloudphotosBackgroundFetch:")
                             toTarget:controller withObject:nil];
}

static NSString *CloudPhotosConditionMark(NSNumber *code, NSNumber *isDay)
{
    NSInteger c=[code integerValue]; BOOL day=!isDay || [isDay boolValue];
    if (c==0) return day ? @"SUN" : @"MOON";
    if (c==1 || c==2) return @"SUN/CLOUD";
    if (c==3) return @"CLOUD";
    if (c==45 || c==48) return @"FOG";
    if ((c>=51 && c<=67) || (c>=80 && c<=82)) return @"RAIN";
    if ((c>=71 && c<=77) || c==85 || c==86) return @"SNOW";
    if (c>=95) return @"STORM";
    return @"WEATHER";
}

static NSString *CloudPhotosChineseCondition(NSInteger code);

static NSString *CloudPhotosCurrentTime(void)
{
    NSDictionary *w = CloudPhotosSnapshot();
    NSNumber *temp = [w objectForKey:@"temperature_c"];
    if (!w || !temp) return @"天气不可用";
    NSInteger code=[[w objectForKey:@"internetcloudphotos_code"] integerValue];
    NSString *condition=CloudPhotosChineseCondition(code);
    return [NSString stringWithFormat:@"%.0f C   %@", [temp doubleValue], condition ?: @""];
}

static NSString *CloudPhotosCurrentDate(void)
{
    NSDictionary *w = CloudPhotosSnapshot();
    if (!w) return @"ATV3Bridge offline";
    NSString *location = [w objectForKey:@"location"] ?: @"CloudPhotos";
    NSNumber *feels = [w objectForKey:@"feels_like_c"];
    NSNumber *humidity = [w objectForKey:@"humidity"];
    NSNumber *wind = [w objectForKey:@"wind_kmh"];
    return [NSString stringWithFormat:@"%@   体感 %.0f C   湿度 %.0f%%   风速 %.0f km/h", location, [feels doubleValue], [humidity doubleValue], [wind doubleValue]];
}

static NSString *CloudPhotosHourLabel(NSString *iso)
{
    if (![iso isKindOfClass:[NSString class]] || [iso length] < 13) return @"--";
    NSInteger h = [[iso substringWithRange:NSMakeRange(11,2)] integerValue];
    return [NSString stringWithFormat:@"%ld时", (long)h];
}

static NSString *CloudPhotosDayLabel(NSString *iso)
{
    if (![iso isKindOfClass:[NSString class]] || [iso length] < 10) return @"---";
    NSInteger y=[[iso substringWithRange:NSMakeRange(0,4)] integerValue];
    NSInteger m=[[iso substringWithRange:NSMakeRange(5,2)] integerValue];
    NSInteger d=[[iso substringWithRange:NSMakeRange(8,2)] integerValue];
    if (m<3) { m+=12; y-=1; }
    NSInteger k=y%100, j=y/100;
    NSInteger h=(d+(13*(m+1))/5+k+k/4+j/4+5*j)%7;
    static NSString *days[]={@"周六",@"周日",@"周一",@"周二",@"周三",@"周四",@"周五"};
    if (h<0 || h>6) return @"---";
    return days[h];
}

static NSString *CloudPhotosChineseCondition(NSInteger code)
{
    if (code==0) return @"晴";
    if (code==1) return @"大致晴朗";
    if (code==2) return @"局部多云";
    if (code==3) return @"多云";
    if (code==45 || code==48) return @"有雾";
    if (code>=51 && code<=57) return @"毛毛雨";
    if (code>=61 && code<=67) return @"有雨";
    if (code>=71 && code<=77) return @"有雪";
    if (code>=80 && code<=82) return @"阵雨";
    if (code==85 || code==86) return @"阵雪";
    if (code>=95) return @"雷暴";
    return @"天气";
}

static NSString *CloudPhotosHourlySummary(void)
{
    NSDictionary *w=CloudPhotosSnapshot(); NSArray *a=[w objectForKey:@"hourly"];
    if (![a isKindOfClass:[NSArray class]] || ![a count]) return @"";
    NSString *updated=[w objectForKey:@"updated"];
    NSUInteger start=0;
    if ([updated isKindOfClass:[NSString class]] && [updated length]>=13) {
        NSString *hour=[updated substringToIndex:13];
        for (NSUInteger i=0;i<[a count];i++) { NSString *t=[[a objectAtIndex:i] objectForKey:@"time"]; if ([t hasPrefix:hour]) { start=i; break; } }
    }
    NSMutableArray *parts=[NSMutableArray array];
    for (NSUInteger j=0;j<5 && start+j<[a count];j++) {
        NSDictionary *x=[a objectAtIndex:start+j]; NSNumber *t=[x objectForKey:@"temperature_2m"]; NSNumber *rain=[x objectForKey:@"precipitation_probability"];
        NSString *m=CloudPhotosConditionMark([x objectForKey:@"internetcloudphotos_code"], nil);
        [parts addObject:[NSString stringWithFormat:@"%@ %@ %.0fC %.0f%%",CloudPhotosHourLabel([x objectForKey:@"time"]),m,[t doubleValue],[rain doubleValue]]];
    }
    return [parts componentsJoinedByString:@"     "];
}

static NSString *CloudPhotosDailySummary(void)
{
    NSDictionary *w=CloudPhotosSnapshot(); NSArray *a=[w objectForKey:@"daily"];
    if (![a isKindOfClass:[NSArray class]] || ![a count]) return @"";
    NSMutableArray *parts=[NSMutableArray array];
    for (NSUInteger i=0;i<5 && i<[a count];i++) {
        NSDictionary *x=[a objectAtIndex:i]; NSNumber *hi=[x objectForKey:@"temperature_2m_max"]; NSNumber *lo=[x objectForKey:@"temperature_2m_min"];
        NSString *m=CloudPhotosConditionMark([x objectForKey:@"internetcloudphotos_code"], nil);
        [parts addObject:[NSString stringWithFormat:@"%@ %@ %.0f/%.0f",CloudPhotosDayLabel([x objectForKey:@"time"]),m,[hi doubleValue],[lo doubleValue]]];
    }
    return [parts componentsJoinedByString:@"     "];
}

static void CloudPhotosRoundedRect(CGContextRef c, CGRect r, CGFloat radius)
{
    CGFloat x=CGRectGetMinX(r), y=CGRectGetMinY(r), w=CGRectGetWidth(r), h=CGRectGetHeight(r);
    CGContextBeginPath(c);
    CGContextMoveToPoint(c,x+radius,y);
    CGContextAddLineToPoint(c,x+w-radius,y);
    CGContextAddArc(c,x+w-radius,y+radius,radius,-M_PI_2,0,0);
    CGContextAddLineToPoint(c,x+w,y+h-radius);
    CGContextAddArc(c,x+w-radius,y+h-radius,radius,0,M_PI_2,0);
    CGContextAddLineToPoint(c,x+radius,y+h);
    CGContextAddArc(c,x+radius,y+h-radius,radius,M_PI_2,M_PI,0);
    CGContextAddLineToPoint(c,x,y+radius);
    CGContextAddArc(c,x+radius,y+radius,radius,M_PI,3*M_PI_2,0);
    CGContextClosePath(c);
}

static CTFontRef CloudPhotosCTFont(CGFloat size)
{
    CTFontRef font=CTFontCreateWithName(CFSTR("STHeitiSC-Light"),size,NULL);
    if (!font) font=CTFontCreateWithName(CFSTR("STHeiti-Light"),size,NULL);
    if (!font) font=CTFontCreateWithName(CFSTR("STHeitiSC-Medium"),size,NULL);
    if (!font) font=CTFontCreateWithName(CFSTR("STHeiti-Medium"),size,NULL);
    if (!font) font=CTFontCreateWithName(CFSTR("HelveticaNeue"),size,NULL);
    return font;
}

static CTLineRef CloudPhotosCTLine(NSString *text, CGFloat size, CGFloat gray)
{
    if (![text length]) return NULL;
    CTFontRef font=CloudPhotosCTFont(size);
    if (!font) return NULL;
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGFloat comps[4]={gray,gray,gray,1.0f};
    CGColorRef color=CGColorCreate(cs,comps);
    NSDictionary *attrs=[NSDictionary dictionaryWithObjectsAndKeys:
        (id)font,(id)kCTFontAttributeName,
        (id)color,(id)kCTForegroundColorAttributeName,nil];
    NSAttributedString *as=[[[NSAttributedString alloc] initWithString:text attributes:attrs] autorelease];
    CTLineRef line=CTLineCreateWithAttributedString((CFAttributedStringRef)as);
    CGColorRelease(color); CGColorSpaceRelease(cs); CFRelease(font);
    return line;
}

static void CloudPhotosText(CGContextRef c, NSString *text, CGFloat x, CGFloat y, CGFloat size, CGFloat gray)
{
    CTLineRef line=CloudPhotosCTLine(text,size,gray);
    if (!line) return;
    CGContextSaveGState(c);
    CGContextSetTextMatrix(c,CGAffineTransformIdentity);
    CGContextSetTextPosition(c,x,y);
    CTLineDraw(line,c);
    CGContextRestoreGState(c);
    CFRelease(line);
}

static CGFloat CloudPhotosTextWidth(NSString *text, CGFloat size)
{
    CTLineRef line=CloudPhotosCTLine(text,size,1.0f);
    if (!line) return 0.0f;
    double width=CTLineGetTypographicBounds(line,NULL,NULL,NULL);
    CFRelease(line);
    return (CGFloat)width;
}

static void CloudPhotosCenteredText(CGContextRef c, NSString *text, CGFloat centerX,
                                CGFloat y, CGFloat size, CGFloat gray)
{
    CloudPhotosText(c,text,centerX-CloudPhotosTextWidth(text,size)*0.5f,y,size,gray);
}

static CGFloat CloudPhotosIconVisualCenter(NSInteger code, CGFloat scale)
{
    BOOL rain=((code>=51&&code<=67)||(code>=80&&code<=82));
    BOOL snow=((code>=71&&code<=77)||code==85||code==86);
    BOOL storm=(code>=95);
    BOOL fog=(code==45||code==48);
    BOOL cloudy=(code>=1&&code<=3)||rain||snow||storm||fog;
    if (cloudy) return 75.0f*scale;
    return 37.0f*scale;
}

static void CloudPhotosIcon(CGContextRef c, NSInteger code, BOOL day, CGFloat x, CGFloat y, CGFloat scale)
{
    BOOL rain=((code>=51&&code<=67)||(code>=80&&code<=82));
    BOOL snow=((code>=71&&code<=77)||code==85||code==86);
    BOOL storm=(code>=95);
    BOOL fog=(code==45||code==48);
    BOOL cloudy=(code>=1&&code<=3)||rain||snow||storm||fog;

    if (code==0 || code==1 || code==2) {
        CGContextSetRGBFillColor(c,1.0,0.78,0.12,1.0);
        if (day) {
            CGContextFillEllipseInRect(c,CGRectMake(x+15*scale,y+28*scale,42*scale,42*scale));
            CGContextSetLineWidth(c,4*scale); CGContextSetRGBStrokeColor(c,1.0,0.78,0.12,1.0);
            for(int i=0;i<8;i++){ CGFloat a=i*M_PI/4.0; CGContextMoveToPoint(c,x+(36+29*cos(a))*scale,y+(49+29*sin(a))*scale); CGContextAddLineToPoint(c,x+(36+39*cos(a))*scale,y+(49+39*sin(a))*scale); }
            CGContextStrokePath(c);
        } else {
            CGContextFillEllipseInRect(c,CGRectMake(x+16*scale,y+27*scale,44*scale,44*scale));
            CGContextSetRGBFillColor(c,0.12,0.24,0.43,1.0);
            CGContextFillEllipseInRect(c,CGRectMake(x+29*scale,y+36*scale,40*scale,40*scale));
        }
    }
    if (cloudy) {
        CGContextSetRGBFillColor(c,0.88,0.92,0.97,1.0);
        CGContextFillEllipseInRect(c,CGRectMake(x+34*scale,y+37*scale,42*scale,32*scale));
        CGContextFillEllipseInRect(c,CGRectMake(x+55*scale,y+27*scale,46*scale,43*scale));
        CGContextFillEllipseInRect(c,CGRectMake(x+78*scale,y+40*scale,38*scale,29*scale));
        CGContextFillRect(c,CGRectMake(x+45*scale,y+48*scale,60*scale,22*scale));
    }
    if (rain || storm) {
        CGContextSetRGBStrokeColor(c,0.32,0.70,1.0,1.0); CGContextSetLineWidth(c,4*scale);
        for(int i=0;i<3;i++){ CGFloat dx=(55+i*20)*scale; CGContextMoveToPoint(c,x+dx,y+78*scale); CGContextAddLineToPoint(c,x+(dx-7*scale),y+94*scale); } CGContextStrokePath(c);
    }
    if (snow) {
        CGContextSetRGBFillColor(c,0.85,0.94,1.0,1.0);
        for(int i=0;i<3;i++) CGContextFillEllipseInRect(c,CGRectMake(x+(50+i*23)*scale,y+82*scale,7*scale,7*scale));
    }
    if (fog) {
        CGContextSetRGBStrokeColor(c,0.75,0.80,0.86,1.0); CGContextSetLineWidth(c,3*scale);
        for(int i=0;i<3;i++){ CGContextMoveToPoint(c,x+35*scale,y+(78+i*9)*scale); CGContextAddLineToPoint(c,x+110*scale,y+(78+i*9)*scale); } CGContextStrokePath(c);
    }
    if (storm) {
        CGContextSetRGBFillColor(c,1.0,0.78,0.12,1.0);
        CGContextBeginPath(c); CGContextMoveToPoint(c,x+76*scale,y+70*scale); CGContextAddLineToPoint(c,x+60*scale,y+94*scale); CGContextAddLineToPoint(c,x+73*scale,y+92*scale); CGContextAddLineToPoint(c,x+64*scale,y+110*scale); CGContextAddLineToPoint(c,x+91*scale,y+82*scale); CGContextAddLineToPoint(c,x+77*scale,y+84*scale); CGContextClosePath(c); CGContextFillPath(c);
    }
}

static NSString *CloudPhotosDisplayPage(NSString *page) {
    NSDictionary *names=@{@"Home":@"首页",@"Stations":@"全球电台",@"Countries":@"国家与地区",@"Genres":@"电台类型",@"Search":@"搜索",@"Favorites":@"我的收藏",@"Recent":@"最近播放"};
    return [names objectForKey:page]?:page;
}
static NSData *CloudPhotosRenderImage(void)
{
    NSData *cached=nil;
    @synchronized([NSObject class]) {
        cached=[cloudPhotosRemoteJPEG retain];
    }
    if(cached) return [cached autorelease];
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(NULL,1280,720,8,1280*4,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);if(!ctx)return nil;
    CGContextSetRGBFillColor(ctx,0.045,0.052,0.086,1);CGContextFillRect(ctx,CGRectMake(0,0,1280,720));
    CGContextSetRGBFillColor(ctx,0.19,0.27,0.51,1);CloudPhotosRoundedRect(ctx,CGRectMake(105,135,1070,450),32);CGContextFillPath(ctx);
    CloudPhotosText(ctx,@"iCloud Photos",160,465,57,1);
    CloudPhotosText(ctx,@"iCloud Photos · Apple TV 3",162,381,37,0.9);
    CloudPhotosText(ctx,@"正在连接 NAS 上的 iCloud Photos 浏览器…",162,278,27,0.8);
    CloudPhotosText(ctx,@"方向键：选择  ·  Select：打开  ·  Menu：返回",162,190,23,0.7);
    CGImageRef image=CGBitmapContextCreateImage(ctx);CGContextRelease(ctx);if(!image)return nil;
    NSMutableData *data=[NSMutableData data];CGImageDestinationRef dest=CGImageDestinationCreateWithData((CFMutableDataRef)data,CFSTR("public.jpeg"),1,NULL);
    CGImageDestinationAddImage(dest,image,NULL);BOOL ok=CGImageDestinationFinalize(dest);
    CFRelease(dest);CGImageRelease(image);return ok?data:nil;
}

static id CloudPhotosCreateImageControl(void)
{
    NSData *data = CloudPhotosRenderImage();

    if (![data length])
        return nil;

    Class imageClass = NSClassFromString(@"ATVImage");
    Class controlClass = NSClassFromString(@"BRAsyncImageControl");

    if (!imageClass || !controlClass)
        return nil;

    SEL imageSel = NSSelectorFromString(@"imageWithData:");

    if (!CloudPhotosSignature(imageClass,
                        imageSel,
                        @encode(id),
                        @[@"@"]))
        return nil;

    id image =
        ((id(*)(id,SEL,id))objc_msgSend)(imageClass,
                                         imageSel,
                                         data);

    if (!image)
        return nil;

    id control = CloudPhotosNew(controlClass);

    if (!control)
        return nil;

    SEL cropSel = NSSelectorFromString(@"setCropAndFill:");

    if (CloudPhotosSignature(control,
                       cropSel,
                       @encode(void),
                       @[[NSString stringWithUTF8String:@encode(BOOL)]])) {

        ((void(*)(id,SEL,BOOL))objc_msgSend)(control,
                                             cropSel,
                                             NO);
    }

    SEL setImageSel = NSSelectorFromString(@"setImage:");

    if (!CloudPhotosSignature(control,
                        setImageSel,
                        @encode(void),
                        @[@"@"])) {
        [control release];
        return nil;
    }

    ((void(*)(id,SEL,id))objc_msgSend)(control,
                                       setImageSel,
                                       image);

    return [control autorelease];
}


static char CloudPhotosImageControlKey;

static id CloudPhotosMakeATVImage(void)
{
    NSData *data = CloudPhotosRenderImage();

    if (![data length])
        return nil;

    Class imageClass = NSClassFromString(@"ATVImage");

    if (!imageClass)
        return nil;

    SEL sel = NSSelectorFromString(@"imageWithData:");

    if (!CloudPhotosSignature(imageClass,
                        sel,
                        @encode(id),
                        @[@"@"]))
        return nil;

    return ((id(*)(id,SEL,id))objc_msgSend)(
        imageClass,
        sel,
        data);
}

/*
 * Shared ATV3 layout rule:
 * BackRow owns the display geometry.  Never query UIScreen and never encode
 * monitor-specific pixel compensation in an appliance.  CGRect is a struct
 * return on armv7, so use NSInvocation rather than a guessed objc_msgSend ABI.
 */
static BOOL CloudPhotosBackRowBounds(id host, CGRect *outBounds)
{
    if (!host || !outBounds) return NO;

    SEL sel = NSSelectorFromString(@"bounds");
    NSMethodSignature *sig = [host methodSignatureForSelector:sel];
    if (!sig || strcmp([sig methodReturnType], @encode(CGRect)) ||
        [sig numberOfArguments] != 2) return NO;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:host];
    [inv setSelector:sel];
    [inv invoke];

    CGRect bounds = CGRectZero;
    [inv getReturnValue:&bounds];
    if (bounds.size.width <= 0.0f || bounds.size.height <= 0.0f) return NO;

    *outBounds = bounds;
    return YES;
}

static BOOL CloudPhotosBackRowSetFrame(id control, CGRect frame)
{
    if (!control) return NO;

    SEL sel = NSSelectorFromString(@"setFrame:");
    NSMethodSignature *sig = [control methodSignatureForSelector:sel];
    if (!sig || strcmp([sig methodReturnType], @encode(void)) ||
        [sig numberOfArguments] != 3 ||
        strcmp([sig getArgumentTypeAtIndex:2], @encode(CGRect))) return NO;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:control];
    [inv setSelector:sel];
    [inv setArgument:&frame atIndex:2];
    [inv invoke];
    return YES;
}

static id CloudPhotosCreateFullscreenControl(id host)
{
    Class controlClass = NSClassFromString(@"BRImageControl");
    if (!controlClass) return nil;

    id control = CloudPhotosNew(controlClass);
    if (!control) return nil;

    CGRect frame = CGRectZero;
    if (!CloudPhotosBackRowBounds(host, &frame) ||
        !CloudPhotosBackRowSetFrame(control, frame)) {
        [control release];
        return nil;
    }

    NSLog(@"CloudPhotos: BackRow-owned bounds %.0fx%.0f at %.0f,%.0f",
          frame.size.width, frame.size.height, frame.origin.x, frame.origin.y);

    return [control autorelease];
}

static void CloudPhotosInstallFullscreenControl(id self)
{
    id control =
        objc_getAssociatedObject(
            self,
            &CloudPhotosImageControlKey);

    if (control)
        return;

    control = CloudPhotosCreateFullscreenControl(self);

    if (!control)
        return;

    objc_setAssociatedObject(
        self,
        &CloudPhotosImageControlKey,
        control,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL addSubviewSel =
        NSSelectorFromString(@"addSubview:");

    if ([self respondsToSelector:addSubviewSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(
            self,
            addSubviewSel,
            control);
    }
}

static void CloudPhotosUpdateFullscreenControl(id self)
{
    CloudPhotosInstallFullscreenControl(self);

    id control =
        objc_getAssociatedObject(
            self,
            &CloudPhotosImageControlKey);

    if (!control)
        return;

    id image = CloudPhotosMakeATVImage();

    if (!image)
        return;

    SEL setImageSel =
        NSSelectorFromString(@"setImage:");

    if ([control respondsToSelector:setImageSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(
            control,
            setImageSel,
            image);
    }
}


static char CloudPhotosTimeTextKey;
static char CloudPhotosDateTextKey;
static char CloudPhotosHourlyTextKey;
static char CloudPhotosDailyTextKey;
static char CloudPhotosHourlyLabelKey;
static char CloudPhotosDailyLabelKey;

static id CloudPhotosObjectCall(id target, NSString *name)
{
    if (!target)
        return nil;

    SEL sel = NSSelectorFromString(name);

    if (![target respondsToSelector:sel])
        return nil;

    return ((id(*)(id,SEL))objc_msgSend)(target, sel);
}

static BOOL CloudPhotosSetFrame(id control, CGRect frame)
{
    if (!control)
        return NO;

    SEL sel = NSSelectorFromString(@"setFrame:");

    if (![control respondsToSelector:sel])
        return NO;

    ((void(*)(id,SEL,CGRect))objc_msgSend)(
        control, sel, frame);

    return YES;
}

static BOOL CloudPhotosSetText(id control,
                         NSString *text,
                         id attrs)
{
    if (!control || !text)
        return NO;

    SEL sel =
        NSSelectorFromString(@"setText:withAttributes:");

    if (!CloudPhotosSignature(control,
                        sel,
                        @encode(void),
                        @[@"@", @"@"]))
        return NO;

    ((void(*)(id,SEL,id,id))objc_msgSend)(
        control,
        sel,
        text,
        attrs ?: @{});

    return YES;
}

static id CloudPhotosThemeTextAttributes(void)
{
    Class themeClass =
        NSClassFromString(@"BRThemeInfo");

    if (!themeClass)
        return @{};

    id theme =
        CloudPhotosObjectCall(themeClass, @"sharedTheme");

    if (!theme)
        return @{};

    id attrs =
        CloudPhotosObjectCall(theme,
                        @"menuTitleTextAttributes");

    static BOOL dumped = NO;

    if (!dumped) {
        dumped = YES;

        NSString *dump =
            [NSString stringWithFormat:
                @"class=%@\nattrs=%@\n",
                attrs ? NSStringFromClass([attrs class]) : @"nil",
                attrs ?: @"nil"];

        [dump writeToFile:@"/var/tmp/internetcloudphotos_text_attrs.txt"
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:NULL];
    }

    return attrs ?: @{};
}

static id CloudPhotosCreateTextControl(void)
{
    Class cls =
        NSClassFromString(@"BRTextControl");

    if (!cls)
        return nil;

    return [CloudPhotosNew(cls) autorelease];
}

static void CloudPhotosInstallTextControls(id self)
{
    id timeControl =
        objc_getAssociatedObject(
            self,
            &CloudPhotosTimeTextKey);

    if (timeControl)
        return;

    timeControl = CloudPhotosCreateTextControl();
    id dateControl = CloudPhotosCreateTextControl();
    id hourlyControl = CloudPhotosCreateTextControl();
    id dailyControl = CloudPhotosCreateTextControl();
    id hourlyLabel = CloudPhotosCreateTextControl();
    id dailyLabel = CloudPhotosCreateTextControl();

    if (!timeControl || !dateControl || !hourlyControl || !dailyControl || !hourlyLabel || !dailyLabel)
        return;

    /*
     * First validation layout.
     * Once BRTextControl is confirmed on-device,
     * we'll replace these temporary frames with
     * measured final internetcloudphotos geometry.
     */
    CloudPhotosSetFrame(
        timeControl,
        CGRectMake(190.0f,
                   440.0f,
                   900.0f,
                   180.0f));

    CloudPhotosSetFrame(
        dateControl,
        CGRectMake(190.0f,
                   365.0f,
                   900.0f,
                   60.0f));

    CloudPhotosSetFrame(hourlyLabel, CGRectMake(190.0f, 320.0f, 900.0f, 30.0f));
    CloudPhotosSetFrame(hourlyControl, CGRectMake(190.0f, 275.0f, 900.0f, 48.0f));
    CloudPhotosSetFrame(dailyLabel, CGRectMake(190.0f, 225.0f, 900.0f, 30.0f));
    CloudPhotosSetFrame(dailyControl, CGRectMake(190.0f, 180.0f, 900.0f, 48.0f));

    SEL addSubviewSel =
        NSSelectorFromString(@"addSubview:");

    if (![self respondsToSelector:addSubviewSel])
        return;

    ((void(*)(id,SEL,id))objc_msgSend)(
        self,
        addSubviewSel,
        timeControl);

    ((void(*)(id,SEL,id))objc_msgSend)(
        self,
        addSubviewSel,
        dateControl);

    ((void(*)(id,SEL,id))objc_msgSend)(self, addSubviewSel, hourlyLabel);
    ((void(*)(id,SEL,id))objc_msgSend)(self, addSubviewSel, hourlyControl);
    ((void(*)(id,SEL,id))objc_msgSend)(self, addSubviewSel, dailyLabel);
    ((void(*)(id,SEL,id))objc_msgSend)(self, addSubviewSel, dailyControl);

    objc_setAssociatedObject(
        self,
        &CloudPhotosTimeTextKey,
        timeControl,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    objc_setAssociatedObject(
        self,
        &CloudPhotosDateTextKey,
        dateControl,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    objc_setAssociatedObject(self, &CloudPhotosHourlyLabelKey, hourlyLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &CloudPhotosHourlyTextKey, hourlyControl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &CloudPhotosDailyLabelKey, dailyLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &CloudPhotosDailyTextKey, dailyControl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void CloudPhotosUpdateTextControls(id self)
{
    CloudPhotosInstallTextControls(self);

    id timeControl =
        objc_getAssociatedObject(
            self,
            &CloudPhotosTimeTextKey);

    id dateControl =
        objc_getAssociatedObject(
            self,
            &CloudPhotosDateTextKey);

    id hourlyLabel = objc_getAssociatedObject(self, &CloudPhotosHourlyLabelKey);
    id hourlyControl = objc_getAssociatedObject(self, &CloudPhotosHourlyTextKey);
    id dailyLabel = objc_getAssociatedObject(self, &CloudPhotosDailyLabelKey);
    id dailyControl = objc_getAssociatedObject(self, &CloudPhotosDailyTextKey);

    if (!timeControl || !dateControl || !hourlyLabel || !hourlyControl || !dailyLabel || !dailyControl)
        return;

    NSDictionary *baseAttrs =
        CloudPhotosThemeTextAttributes();

    NSMutableDictionary *timeAttrs =
        [NSMutableDictionary dictionaryWithDictionary:
            baseAttrs ?: @{}];

    NSMutableDictionary *dateAttrs =
        [NSMutableDictionary dictionaryWithDictionary:
            baseAttrs ?: @{}];

    [timeAttrs setObject:@82
                  forKey:@"BRFontPointSize"];

    [dateAttrs setObject:@30
                  forKey:@"BRFontPointSize"];

    NSMutableDictionary *forecastAttrs=[NSMutableDictionary dictionaryWithDictionary:baseAttrs ?: @{}];
    [forecastAttrs setObject:@24 forKey:@"BRFontPointSize"];
    [forecastAttrs setObject:@1 forKey:@"BRTextAlignmentKey"];
    NSMutableDictionary *labelAttrs=[NSMutableDictionary dictionaryWithDictionary:baseAttrs ?: @{}];
    [labelAttrs setObject:@19 forKey:@"BRFontPointSize"];
    [labelAttrs setObject:@1 forKey:@"BRTextAlignmentKey"];

    /*
     * Keep the native BackRow alignment value discovered
     * from the real Apple TV theme.
     */
    [timeAttrs setObject:@1
                  forKey:@"BRTextAlignmentKey"];

    [dateAttrs setObject:@1
                  forKey:@"BRTextAlignmentKey"];

    CloudPhotosSetText(
        timeControl,
        CloudPhotosCurrentTime(),
        timeAttrs);

    CloudPhotosSetText(
        dateControl,
        CloudPhotosCurrentDate(),
        dateAttrs);

    CloudPhotosSetText(hourlyLabel, @"每小时天气", labelAttrs);
    CloudPhotosSetText(hourlyControl, CloudPhotosHourlySummary(), forecastAttrs);
    CloudPhotosSetText(dailyLabel, @"7天天气预报", labelAttrs);
    CloudPhotosSetText(dailyControl, CloudPhotosDailySummary(), forecastAttrs);

    /*
     * BRTextControl owns part of its BackRow layout.
     * Give it an explicit text-layout area instead of
     * trying to reposition the glyphs with UIView frame.x.
     */
    SEL maxSizeSel =
        NSSelectorFromString(@"setMaxSize:");

    if ([timeControl respondsToSelector:maxSizeSel]) {
        ((void(*)(id,SEL,CGSize))objc_msgSend)(
            timeControl,
            maxSizeSel,
            CGSizeMake(900.0f, 180.0f));
    }

    if ([dateControl respondsToSelector:maxSizeSel]) {
        ((void(*)(id,SEL,CGSize))objc_msgSend)(
            dateControl,
            maxSizeSel,
            CGSizeMake(900.0f, 60.0f));
    }

    if ([hourlyControl respondsToSelector:maxSizeSel]) ((void(*)(id,SEL,CGSize))objc_msgSend)(hourlyControl,maxSizeSel,CGSizeMake(900.0f,55.0f));
    if ([dailyControl respondsToSelector:maxSizeSel]) ((void(*)(id,SEL,CGSize))objc_msgSend)(dailyControl,maxSizeSel,CGSizeMake(900.0f,55.0f));

    SEL verticalSel =
        NSSelectorFromString(@"setVerticallyCenterAdjustedText:");

    if ([timeControl respondsToSelector:verticalSel]) {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(
            timeControl,
            verticalSel,
            YES);
    }

    if ([dateControl respondsToSelector:verticalSel]) {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(
            dateControl,
            verticalSel,
            YES);
    }
}

static void CloudPhotosRefresh(id self, SEL cmd)
{
    (void)cmd;

    CloudPhotosUpdateFullscreenControl(self);

    NSString *time = CloudPhotosCurrentTime();
    NSString *date = CloudPhotosCurrentDate();

    /*
     * Keep the proven menu controller alive for 0.2.
     * The generated internetcloudphotos image is used through the preview-control path.
     */
    NSString *title =
        [NSString stringWithFormat:@"%@     %@", time, date];

    NSArray *selectors = @[@"setListTitle:", @"setTitle:"];

    for (NSString *name in selectors) {

        SEL sel = NSSelectorFromString(name);

        if (CloudPhotosSignature(self, sel, @encode(void), @[@"@"])) {
            ((void(*)(id,SEL,id))objc_msgSend)(self, sel, title);
            break;
        }
    }

    SEL reloadSel = NSSelectorFromString(@"reload");

    SEL listSel = NSSelectorFromString(@"list");

    if (CloudPhotosSignature(self, listSel, @encode(id), @[])) {

        id list =
            ((id(*)(id,SEL))objc_msgSend)(self, listSel);

        if (list &&
            CloudPhotosSignature(list,
                           reloadSel,
                           @encode(void),
                           @[])) {

            ((void(*)(id,SEL))objc_msgSend)(list,
                                            reloadSel);
        }
    }

    NSLog(@"CloudPhotos: refresh %@ %@", time, date);
}

static id CloudPhotosPreview(id self, SEL cmd, long item)
{
    (void)self;
    (void)cmd;
    (void)item;

    return CloudPhotosCreateImageControl();
}

static void CloudPhotosTimerFire(id self, SEL cmd, id timer)
{
    (void)cmd;
    (void)timer;

    NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
    if (cloudphotosPlayer && !cloudphotosPaused) {
        AVPlayerItem *item=cloudphotosPlayer.currentItem;
        if (item.status==AVPlayerItemStatusReadyToPlay && cloudphotosPlayer.rate>0.0f) {
            cloudphotosReady=YES;cloudphotosRetryCount=0;cloudphotosStatus=@"正在播放";
        } else if (item.status==AVPlayerItemStatusFailed || (now-cloudphotosStartedAt>25.0 && !cloudphotosReady)) {
            if (cloudphotosRetryCount<3 && now>=cloudphotosNextRetry && cloudphotosPlayingStation) {
                NSDictionary *station=[cloudphotosPlayingStation retain];
                cloudphotosRetryCount++;cloudphotosNextRetry=now+5.0*cloudphotosRetryCount;
                CloudPhotosPlayStation(self,station);[station release];
                cloudphotosStatus=[NSString stringWithFormat:@"连接失败，正在重试（%ld/3）",(long)cloudphotosRetryCount];
            } else if (cloudphotosRetryCount>=3)cloudphotosStatus=@"播放失败，请重新选择电台";
        }
    }
    CloudPhotosRefresh(self,NULL);
}

static void CloudPhotosBackgroundFetch(id self, SEL cmd, id unused)
{
    (void)cmd; (void)unused;
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    NSDictionary *fresh=CloudPhotosBridgeData();
    if (fresh) CloudPhotosStoreSnapshot(fresh);
    @synchronized([NSObject class]) { internetcloudphotosFetchInFlight=NO; }
    if (fresh) [self performSelectorOnMainThread:NSSelectorFromString(@"internetcloudphotosApplyFreshData") withObject:nil waitUntilDone:NO];
    [pool drain];
}

static void CloudPhotosApplyFreshData(id self, SEL cmd)
{
    (void)cmd;
    CloudPhotosRefresh(self,NULL);
}

static void CloudPhotosBeginFramePoll(id controller);
// No still-image panel before the video decoder is ready. Keeping the old
// BRImageControl active under the new BRMediaPlayer caused a distorted frame
// flash when the hardware-video surface took over.
void CloudPhotosVideoFallback(id controller) {
    if(!controller || cloudPhotosRemoteActive)return;
    cloudPhotosRemoteActive=YES;
    CloudPhotosUpdateFullscreenControl(controller);
    NSTimer *old=(NSTimer *)objc_getAssociatedObject(controller,&cloudPhotosPollTimerKey);
    if(old)[old invalidate];
    NSTimer *timer=[NSTimer scheduledTimerWithTimeInterval:1.7 target:controller
                 selector:NSSelectorFromString(@"icloudphotosPollTimer:")
                 userInfo:nil repeats:YES];
    objc_setAssociatedObject(controller,&cloudPhotosPollTimerKey,timer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CloudPhotosBeginFramePoll(controller);
    NSLog(@"CloudPhotos: video unavailable, enabling 1080p still-image fallback");
}
static void CloudPhotosBeginFramePoll(id controller) {
    if(!cloudPhotosRemoteActive || cloudPhotosPollInFlight)return;
    cloudPhotosPollInFlight=YES;
    [NSThread detachNewThreadSelector:NSSelectorFromString(@"icloudphotosFetchRemote:") toTarget:controller withObject:nil];
}

static void CloudPhotosFetchRemoteFrame(id controller,SEL cmd,id unused) {
    (void)cmd;(void)unused;
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    NSURL *url=[NSURL URLWithString:[CloudPhotosNASBase stringByAppendingString:@"/v1/photos/frame.jpg"]];
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
    [req setValue:CloudPhotosPrivateKey forHTTPHeaderField:@"X-ATV-Photos-Key"];
    NSString *etag=nil;
    @synchronized([NSObject class]) { etag=[cloudPhotosRemoteEtag retain]; }
    if([etag length])[req setValue:etag forHTTPHeaderField:@"If-None-Match"];
    [etag release];
    NSURLResponse *raw=nil;
    NSData *data=[NSURLConnection sendSynchronousRequest:req returningResponse:&raw error:NULL];
    NSInteger status=[raw isKindOfClass:[NSHTTPURLResponse class]]?[(NSHTTPURLResponse*)raw statusCode]:0;
    BOOL changed=NO;
    if(status==200 && [data length]>2000 && [data length]<3500000) {
        const unsigned char *bytes=(const unsigned char*)[data bytes];
        if(bytes[0]==0xff && bytes[1]==0xd8) {
            NSString *newEtag=[(NSHTTPURLResponse*)raw allHeaderFields][@"ETag"];
            @synchronized([NSObject class]) {
                BOOL same=(newEtag && [cloudPhotosRemoteEtag isEqualToString:newEtag]);
                if(!same) {
                    [cloudPhotosRemoteJPEG release];
                    cloudPhotosRemoteJPEG=[data copy];
                    changed=YES;
                }
                [cloudPhotosRemoteEtag release];
                cloudPhotosRemoteEtag=[newEtag copy];
            }
        }
    }
    @synchronized([NSObject class]) {cloudPhotosPollInFlight=NO;}
    if(changed && cloudPhotosRemoteActive)
        [controller performSelectorOnMainThread:NSSelectorFromString(@"icloudphotosApplyRemote:") withObject:nil waitUntilDone:NO];
    [pool drain];
}
static void CloudPhotosApplyRemoteFrame(id controller,SEL cmd,id unused) {
    (void)cmd;(void)unused;
    if(cloudPhotosRemoteActive)CloudPhotosUpdateFullscreenControl(controller);
}
static void CloudPhotosPollTimer(id controller,SEL cmd,id timer) {
    (void)cmd;(void)timer;
    CloudPhotosBeginFramePoll(controller);
}
static void CloudPhotosSendNavigation(id controller,SEL cmd,id action) {
    (void)controller;(void)cmd;
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    if(![action isKindOfClass:[NSString class]]){[pool drain];return;}
    NSURL *url=[NSURL URLWithString:[CloudPhotosNASBase stringByAppendingString:@"/v1/photos/nav"]];
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:CloudPhotosPrivateKey forHTTPHeaderField:@"X-ATV-Photos-Key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSData *body=[NSJSONSerialization dataWithJSONObject:@{@"action":action} options:0 error:NULL];
    [req setHTTPBody:body];
    NSURLResponse *response=nil;
    NSData *reply=[NSURLConnection sendSynchronousRequest:req returningResponse:&response error:NULL];
    NSInteger code=[response isKindOfClass:[NSHTTPURLResponse class]]
       ?[(NSHTTPURLResponse *)response statusCode]:0;
    NSDictionary *result=nil;
    if(code==200 && reply)
       result=[NSJSONSerialization JSONObjectWithData:reply options:0 error:NULL];
    // A dead NAS/CDP must never trap the user inside the appliance.
    if([action isEqualToString:@"back"] && (code!=200 || ![result isKindOfClass:[NSDictionary class]])) {
        if(cloudPhotosRemoteActive)
            [controller performSelectorOnMainThread:NSSelectorFromString(@"icloudphotosConfirmedExit:") withObject:nil waitUntilDone:NO];
    }
    if([result isKindOfClass:[NSDictionary class]]){
        id tier=[result objectForKey:@"tier"];
        if([tier isKindOfClass:[NSString class]]){
            if([tier isEqualToString:@"controls"])cloudPhotosNavTier=0;
            else if([tier isEqualToString:@"photos"])cloudPhotosNavTier=1;
            else if([tier isEqualToString:@"viewer"])cloudPhotosNavTier=2;
            else if([tier isEqualToString:@"immersive"])cloudPhotosNavTier=3;
            else if([tier isEqualToString:@"popup"])cloudPhotosNavTier=4;
            cloudPhotosPhotoLayer=(cloudPhotosNavTier!=0);
        }
        id mode=[result objectForKey:@"mode"];
        if([mode isEqual:@"exit"] && cloudPhotosRemoteActive) {
            [controller performSelectorOnMainThread:NSSelectorFromString(@"icloudphotosConfirmedExit:") withObject:nil waitUntilDone:NO];
        }
        if(([mode isEqual:@"password"] || [mode isEqual:@"text_input"]) &&
           cloudPhotosRemoteActive){
            id args=@{@"secure":[result objectForKey:@"secure"]?:@YES,
                       @"kind":[result objectForKey:@"kind"]?:@"iCloud input"};
            [controller performSelectorOnMainThread:
                 NSSelectorFromString(@"icloudphotosOpenPassword:")
                 withObject:args waitUntilDone:NO];
        }
    }
    FILE *log=fopen("/var/tmp/cloudphotos_direct_remote.log","a");
    if(log){
        fprintf(log,"%.3f action=%s http=%ld mode=%s\n",
             [NSDate timeIntervalSinceReferenceDate],[action UTF8String],(long)code,
             [[result objectForKey:@"mode"] UTF8String]?: "none");
        fclose(log);
    }
    [pool drain];
}
static void CloudPhotosEnsureTimerSelector(void);

/* ---------------------------------------------------------
   Controller lifecycle
   --------------------------------------------------------- */

static id CloudPhotosControllerInit(id self, SEL cmd)
{
    IMP superIMP = CloudPhotosControllerSuper(cmd);

    if (!superIMP)
        return nil;

    self = ((id(*)(id,SEL))superIMP)(self, cmd);

    if (!self)
        return nil;

    CloudPhotosEnsureTimerSelector();
    cloudphotosPage=@"Home";cloudphotosSelected=0;

    NSLog(@"CloudPhotos: controller initialized (NAS browser enabled)");

    return self;
}

static void CloudPhotosActivated(id self, SEL cmd)
{
    IMP superIMP = CloudPhotosControllerSuper(cmd);

    if (superIMP)
        ((void(*)(id,SEL))superIMP)(self, cmd);

    CloudPhotosPasswordResetOnReturn();
    cloudPhotosRemoteActive=YES;
    cloudPhotosSelectPressed=NO;
    cloudPhotosPhotoLayer=NO;cloudPhotosNavTier=0;
    cpSelectDown=NO;cpSelectDidHold=NO;cpPhoneSelectAt=0;cpPhoneSelectHeld=NO;
    [cpSelectHoldTimer invalidate];cpSelectHoldTimer=nil;
    // H.264 FV01 direct decoder: no HLS, no AVPlayer prebuffering.
    CloudPhotosDirectActivated(self);
    if(!CloudPhotosDirectActive()) {
        // Fallback to the previous functional HLS path if the system layer
        // is unavailable, without changing other ATV video applications.
        cloudPhotosRemoteActive=NO;
        CloudPhotosVideoActivated(self);
    }
    NSLog(@"CloudPhotos: activated direct H.264 video");
}

static void CloudPhotosDeactivated(id self, SEL cmd)
{
    cloudPhotosRemoteActive=NO;
    cloudPhotosSelectPressed=NO;
    cloudPhotosPhotoLayer=NO;cloudPhotosNavTier=0;
    cpSelectDown=NO;cpSelectDidHold=NO;cpPhoneSelectAt=0;cpPhoneSelectHeld=NO;
    [cpSelectHoldTimer invalidate];cpSelectHoldTimer=nil;
    CloudPhotosDirectStop();
    NSTimer *timer=(NSTimer *)objc_getAssociatedObject(self,&cloudPhotosPollTimerKey);
    if(timer)[timer invalidate];
    objc_setAssociatedObject(self,&cloudPhotosPollTimerKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"CloudPhotos: deactivated NAS browser");

    IMP superIMP = CloudPhotosControllerSuper(cmd);

    if (superIMP)
        ((void(*)(id,SEL))superIMP)(self, cmd);
}

static void CloudPhotosPopped(id self, SEL cmd)
{
    NSTimer *timer =
        (NSTimer *)objc_getAssociatedObject(self, &internetcloudphotosTimerKey);

    if (timer)
        [timer invalidate];

    objc_setAssociatedObject(self,
                             &internetcloudphotosTimerKey,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    cloudPhotosRemoteActive=NO;
    NSTimer *poll=(NSTimer *)objc_getAssociatedObject(self,&cloudPhotosPollTimerKey);
    if(poll)[poll invalidate];
    objc_setAssociatedObject(self,&cloudPhotosPollTimerKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized([NSObject class]) {
        [cloudPhotosRemoteJPEG release];cloudPhotosRemoteJPEG=nil;
        [cloudPhotosRemoteEtag release];cloudPhotosRemoteEtag=nil;
    }
    CloudPhotosDirectPopped(self);
    CloudPhotosVideoPopped(self);
    NSLog(@"CloudPhotos: popped");

    IMP superIMP = CloudPhotosControllerSuper(cmd);

    if (superIMP)
        ((void(*)(id,SEL))superIMP)(self, cmd);
}

static void CloudPhotosControllerDealloc(id self, SEL cmd)
{
    NSTimer *timer =
        (NSTimer *)objc_getAssociatedObject(self, &internetcloudphotosTimerKey);

    if (timer)
        [timer invalidate];

    objc_setAssociatedObject(self,
                             &internetcloudphotosTimerKey,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    IMP superIMP = CloudPhotosControllerSuper(cmd);

    if (superIMP)
        ((void(*)(id,SEL))superIMP)(self, cmd);
}

static void CloudPhotosPageLoader(id self,SEL cmd,id unused) {(void)cmd;(void)unused;CloudPhotosLoadBackground(self);}
static BOOL CloudPhotosEventInteger(id event,NSString *selector,NSInteger *out) {
    SEL sel=NSSelectorFromString(selector);
    if (![event respondsToSelector:sel])return NO;
    NSMethodSignature *sig=[event methodSignatureForSelector:sel];
    if (!sig || [sig numberOfArguments]!=2)return NO;
    NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:event];[inv setSelector:sel];[inv invoke];
    int value=0;[inv getReturnValue:&value];*out=value;return YES;
}
static void CloudPhotosChoose(id controller) {
    if ([cloudphotosPage isEqual:@"Home"]) {
        NSArray *pages=@[@"Stations",@"Countries",@"Genres",@"Search",@"Favorites",@"Recent"];
        NSInteger i=cloudphotosSelected;if (i<0||i>5)return;
        cloudphotosPage=[pages objectAtIndex:i];cloudphotosSelected=0;
        if (i==3) {cloudphotosPage=@"Search";cloudphotosSearchText=[NSMutableString new];cloudphotosLetterIndex=0;cloudphotosStatus=@"请选择字母";}
        else CloudPhotosLoad(controller);
    } else if ([cloudphotosPage isEqual:@"Search"]) {
        if (!cloudphotosSearchText)cloudphotosSearchText=[NSMutableString new];
        [cloudphotosSearchText appendString:[cloudphotosAlphabet substringWithRange:NSMakeRange(cloudphotosLetterIndex,1)]];
    } else if ([cloudphotosPage isEqual:@"Countries"] || [cloudphotosPage isEqual:@"Genres"]) {
        if (cloudphotosSelected>=(NSInteger)[cloudphotosRows count])return;
        NSDictionary *item=[cloudphotosRows objectAtIndex:cloudphotosSelected];
        if ([cloudphotosPage isEqual:@"Countries"])cloudphotosCountry=[[item objectForKey:@"iso_3166_1"] copy];
        else cloudphotosTag=[[item objectForKey:@"name"] copy];
        cloudphotosPage=@"Stations";CloudPhotosLoad(controller);
    } else if ([cloudphotosPage isEqual:@"Stations"]||[cloudphotosPage isEqual:@"Favorites"]||[cloudphotosPage isEqual:@"Recent"]) {
        if (cloudphotosSelected>=(NSInteger)[cloudphotosRows count])return;
        NSDictionary *item=[cloudphotosRows objectAtIndex:cloudphotosSelected];
        cloudphotosLastStationPage=cloudphotosPage;cloudphotosLastStationIndex=cloudphotosSelected;
        cloudphotosRetryCount=0;cloudphotosNextRetry=0;
        CloudPhotosPlayStation(controller,item);
    }
}
static void CloudPhotosRecordPlayed(id self,SEL cmd,id station) {(void)self;(void)cmd;NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];CloudPhotosRecord(@"played",station);[pool drain];}
static void CloudPhotosRecordFavorite(id self,SEL cmd,id station) {(void)self;(void)cmd;NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];CloudPhotosRecord(@"favorite",station);[pool drain];}
/* Let native BackRow own Menu/navigation. */

static void CPPhotosSelectHold(id self,SEL cmd,id unused){
    (void)self;(void)cmd;(void)unused;
    cpSelectHoldTimer=nil;
    if(!cloudPhotosRemoteActive || !cpSelectDown || cpSelectDidHold)return;
    cpSelectDidHold=YES;
    // Only the OneUp thumbstrip supports immersive long-Select.
    if(cloudPhotosNavTier==2)
        CloudPhotosQueueNav(self,@"hold");
}
static void CPPhotosSelectPress(id controller){
    if(![NSThread isMainThread]){
        [controller performSelectorOnMainThread:NSSelectorFromString(@"icloudphotosSelectPress:")
                                   withObject:nil waitUntilDone:NO];
        return;
    }
    NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
    // Do not turn duplicate press events or legacy phone repeats into clicks.
    if(cpSelectDown || now-cpSelectLastAccepted<0.19)return;
    cpSelectDown=YES;cpSelectDidHold=NO;
    cpSelectStart=now;
    [cpSelectHoldTimer invalidate];
    cpSelectHoldTimer=[NSTimer scheduledTimerWithTimeInterval:0.68
       target:controller selector:NSSelectorFromString(@"icloudphotosSelectHold:")
       userInfo:nil repeats:NO];
}
static void CPPhotosSelectRelease(id controller){
    if(![NSThread isMainThread]){
        [controller performSelectorOnMainThread:NSSelectorFromString(@"icloudphotosSelectRelease:")
                                   withObject:nil waitUntilDone:NO];
        return;
    }
    if(!cpSelectDown)return;
    cpSelectDown=NO;
    [cpSelectHoldTimer invalidate];cpSelectHoldTimer=nil;
    if(!cpSelectDidHold){
        NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
        if(now-cpSelectLastAccepted>=0.19){
            cpSelectLastAccepted=now;
            CloudPhotosQueueNav(controller,@"select");
        }
    }
    cpSelectDidHold=NO;
}
static void CPPhotosSelectPressSelector(id self,SEL cmd,id unused){
    (void)cmd;(void)unused;CPPhotosSelectPress(self);
}
static void CPPhotosSelectReleaseSelector(id self,SEL cmd,id unused){
    (void)cmd;(void)unused;CPPhotosSelectRelease(self);
}
static BOOL CloudPhotosEvent(id self, SEL cmd, id event)
{
    if(CloudPhotosVideoHostSelect(event))return YES;
    NSInteger action=-1,value=-1,origin=-1;
    BOOL known=CloudPhotosEventInteger(event,@"remoteAction",&action);
    BOOL haveValue=CloudPhotosEventInteger(event,@"value",&value);
    BOOL haveOrigin=CloudPhotosEventInteger(event,@"originator",&origin);
    // Accept legacy physical IR and DMAP/TouchRemote phone events. This
    // event method only belongs to the active Photos appliance controller;
    // never install a global remote hook.
    BOOL validOrigin=YES;
    // iPhone Companion IR tunnel uses phase 2 for held direction keys.
    BOOL down=!haveValue || value==1 || value==2;
    if(cloudPhotosRemoteActive && known && validOrigin && !CloudPhotosPasswordActive()) {
        // Direct physical IR and iPhone Companion both deliver a
        // press/release pair; only release becomes a short Select.
        // A lone anomalous press is never enough to open a photo.
        if(action==22){
            // Apple IR Select DOWN (22) and UP (23) support true holds.
            if(down && (!haveValue || value==1))
                CPPhotosSelectPress(self);
            else if(haveValue && value==0)
                CPPhotosSelectRelease(self);
            return YES;
        }
        if(action==23){
            CPPhotosSelectRelease(self);
            return YES;
        }
        if(action==5){
            // iPhone Companion / legacy remote Select often supplies only
            // remoteAction=5 value=1, without a matching release. Treat that
            // as a short press immediately, like the working Folia client.
            // Long iPhone holds may emit repeated phase=2 events.
            NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
            if(down && (!haveValue || value==1)){
                if(now-cpSelectLastAccepted>=0.28){
                    cpSelectLastAccepted=now;
                    cpPhoneSelectAt=now;
                    cpPhoneSelectHeld=NO;
                    CloudPhotosQueueNav(self,@"select");
                }
            }else if(haveValue && value==2){
                if(!cpPhoneSelectHeld && cpPhoneSelectAt>0 &&
                   now-cpPhoneSelectAt>=0.68 && cloudPhotosNavTier==2){
                    cpPhoneSelectHeld=YES;
                    CloudPhotosQueueNav(self,@"hold");
                }
            }else if(haveValue && value==0){
                cpPhoneSelectAt=0;
                cpPhoneSelectHeld=NO;
            }
            return YES;
        }
        if(action==1 || action==2) {
            // ATV3 action=2 is Menu release/alternate notification.
            // Treat only action=1 press as navigation, never both.
            if(action==2 || !down)return YES;
            [cpSelectHoldTimer invalidate];cpSelectHoldTimer=nil;
            cpSelectDown=NO;
            if(cloudPhotosNavQueue)[cloudPhotosNavQueue cancelAllOperations];
            // Menu navigates one level back first. The NAS nav handler
            // returns mode=exit only at the root; network failure retains
            // the existing local emergency-exit fallback.
            CloudPhotosQueueNav(self,@"back");
            return YES;
        }
        if(down){
            NSString *navigation=nil;
            if(action==3)navigation=@"up";
            else if(action==4)navigation=@"down";
            else if(action==6)navigation=@"left";
            else if(action==7)navigation=@"right";
            if(navigation){
                CloudPhotosQueueNav(self,navigation);
                return YES;
            }
        }
    }
    Class cls=objc_getClass("CloudPhotosController");
    Class base=cls?class_getSuperclass(cls):Nil;
    Method method=base?class_getInstanceMethod(base,cmd):NULL;
    return method?((BOOL(*)(id,SEL,id))method_getImplementation(method))(self,cmd,event):NO;
}

/* ---------------------------------------------------------
   Appliance information
   --------------------------------------------------------- */

static NSString *CloudPhotosMenuIconURLForResolution(NSInteger resolution)
{
    NSBundle *bundle = [NSBundle bundleWithIdentifier:@"org.atv3.cloudphotos"];
    NSString *name = (resolution >= 1080) ? @"AppIcon@1080" : @"AppIcon";
    NSString *path = [bundle pathForResource:name ofType:@"png"];
    if (![path length])
        path = (resolution >= 1080) ? @"/Applications/CloudPhotos.frappliance/AppIcon@1080.png" : @"/Applications/CloudPhotos.frappliance/AppIcon.png";
    return [[NSURL fileURLWithPath:path] absoluteString];
}

static NSString *CloudPhotosMenuIconURL(void)
{
    return CloudPhotosMenuIconURLForResolution(1080);
}

static id CloudPhotosInfoMenuIconURLs(id self, SEL cmd)
{
    (void)self;
    (void)cmd;

    static unsigned long callCount = 0;
    callCount++;

    NSString *probeLine =
        [NSString stringWithFormat:
            @"menuIconURLs call=%lu time=%@\n",
            callCount, [NSDate date]];

    NSFileHandle *probe =
        [NSFileHandle fileHandleForWritingAtPath:
            @"/var/tmp/internetcloudphotos_icon_probe.log"];

    if (!probe) {
        [[NSData data] writeToFile:
            @"/var/tmp/internetcloudphotos_icon_probe.log"
            atomically:YES];

        probe =
            [NSFileHandle fileHandleForWritingAtPath:
                @"/var/tmp/internetcloudphotos_icon_probe.log"];
    }

    if (probe) {
        [probe seekToEndOfFile];
        [probe writeData:
            [probeLine dataUsingEncoding:NSUTF8StringEncoding]];
        [probe closeFile];
    }

    NSString *url = CloudPhotosMenuIconURLForResolution(720);
    if (![url length]) return @{};
    return @{
        @"720": url, @"1080": url,
        [NSNumber numberWithInteger:720]: url,
        [NSNumber numberWithInteger:1080]: url
    };
}

static id CloudPhotosInfoMenuIconURLVersion(id self, SEL cmd)
{
    (void)self;
    (void)cmd;

    static unsigned long callCount = 0;
    callCount++;

    NSString *probeLine =
        [NSString stringWithFormat:
            @"menuIconURLVersion call=%lu time=%@\n",
            callCount, [NSDate date]];

    NSFileHandle *probe =
        [NSFileHandle fileHandleForWritingAtPath:
            @"/var/tmp/internetcloudphotos_icon_probe.log"];

    if (!probe) {
        [[NSData data] writeToFile:
            @"/var/tmp/internetcloudphotos_icon_probe.log"
            atomically:YES];

        probe =
            [NSFileHandle fileHandleForWritingAtPath:
                @"/var/tmp/internetcloudphotos_icon_probe.log"];
    }

    if (probe) {
        [probe seekToEndOfFile];
        [probe writeData:
            [probeLine dataUsingEncoding:NSUTF8StringEncoding]];
        [probe closeFile];
    }

    NSBundle *bundle =
        [NSBundle bundleWithIdentifier:@"org.atv3.cloudphotos"];

    id version =
        [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];

    return [version isKindOfClass:[NSString class]] &&
           [version length] ? version : @"1";
}

static Class CloudPhotosApplianceInfoClass(void)
{
    Class existing =
        objc_getClass("CloudPhotosApplianceInfo");

    if (existing)
        return existing;

    Class base =
        objc_getClass("BRApplianceInfo");

    if (!base)
        return Nil;

    Method urlsMethod =
        class_getInstanceMethod(
            base,
            NSSelectorFromString(@"menuIconURLs"));

    Method versionMethod =
        class_getInstanceMethod(
            base,
            NSSelectorFromString(@"menuIconURLVersion"));

    if (!urlsMethod || !versionMethod)
        return Nil;

    Class cls =
        objc_allocateClassPair(
            base,
            "CloudPhotosApplianceInfo",
            0);

    if (!cls)
        return Nil;

    BOOL ok =
        class_addMethod(
            cls,
            NSSelectorFromString(@"menuIconURLs"),
            (IMP)CloudPhotosInfoMenuIconURLs,
            method_getTypeEncoding(urlsMethod))
        &&
        class_addMethod(
            cls,
            NSSelectorFromString(@"menuIconURLVersion"),
            (IMP)CloudPhotosInfoMenuIconURLVersion,
            method_getTypeEncoding(versionMethod));

    if (!ok) {
        objc_disposeClassPair(cls);
        return Nil;
    }

    objc_registerClassPair(cls);

    return cls;
}

static id CloudPhotosSyntheticApplianceInfo(void)
{
    Class infoClass =
        CloudPhotosApplianceInfoClass();

    if (!infoClass)
        return nil;

    id info = [infoClass alloc];

    SEL init =
        NSSelectorFromString(@"_initWithMutableDictionary:");

    if (!CloudPhotosSignature(info,
                        init,
                        @encode(id),
                        @[@"@"])) {
        [info release];
        return nil;
    }

    NSMutableDictionary *values =
        [NSMutableDictionary dictionary];

    [values setObject:@"cloudphotos"
               forKey:@"FRApplianceIdentifier"];

    [values setObject:@"iCloud Photos"
               forKey:@"FRApplianceName"];

    [values setObject:@11
               forKey:@"FRAppliancePreferedOrderValue"];

    [values setObject:@"CloudPhotosAppliance"
               forKey:@"FRPrincipalClass"];

    [values setObject:@NO
               forKey:@"FRHideIfNoCategories"];

    [values setObject:@[]
               forKey:@"FRApplianceSupportedMediaTypes"];

    [values setObject:@[]
               forKey:@"FRApplianceRequiredRemoteMediaTypes"];

    info =
        ((id(*)(id,SEL,id))objc_msgSend)(
            info,
            init,
            values);

    return [info autorelease];
}

static id CloudPhotosApplianceInit(id self,
                             SEL cmd,
                             id incoming)
{
    id info =
        incoming ?: CloudPhotosSyntheticApplianceInfo();

    IMP superIMP =
        CloudPhotosApplianceSuper(cmd);

    if (!superIMP)
        return nil;

    return ((id(*)(id,SEL,id))superIMP)(
        self,
        cmd,
        info);
}

/* ---------------------------------------------------------
   Categories / controller
   --------------------------------------------------------- */

static BOOL CloudPhotosCategoryAvailable(void)
{
    return CloudPhotosSignature(
        objc_getClass("BRApplianceCategory"),
        NSSelectorFromString(
            @"categoryWithName:identifier:preferredOrder:"),
        @encode(id),
        @[@"@", @"@", @"f"]);
}

static id CloudPhotosCategories(id self, SEL cmd)
{
    (void)self;
    (void)cmd;

    if (!CloudPhotosCategoryAvailable()) {
        NSLog(@"CloudPhotos: category ABI unavailable");
        return @[];
    }

    Class cls =
        objc_getClass("BRApplianceCategory");

    SEL sel =
        NSSelectorFromString(
            @"categoryWithName:identifier:preferredOrder:");

    NSInvocation *invocation =
        [NSInvocation invocationWithMethodSignature:
            [cls methodSignatureForSelector:sel]];

    [invocation setTarget:cls];
    [invocation setSelector:sel];

    id name = @"iCloud Photos";
    id identifier = @"cloudphotos";
    float order = 0.0f;

    [invocation setArgument:&name atIndex:2];
    [invocation setArgument:&identifier atIndex:3];
    [invocation setArgument:&order atIndex:4];

    [invocation invoke];

    id result = nil;

    [invocation getReturnValue:&result];

    return result ? @[result] : @[];
}

static id CloudPhotosControllerForIdentifier(id self,
                                       SEL cmd,
                                       id identifier,
                                       id args)
{
    (void)self;
    (void)cmd;
    (void)args;

    if (![identifier isEqual:@"cloudphotos"])
        return nil;

    return [CloudPhotosNew(
        objc_getClass("CloudPhotosController"))
        autorelease];
}

static id CloudPhotosApplianceController(id self,
                                   SEL cmd)
{
    (void)self;
    (void)cmd;

    return [CloudPhotosNew(
        objc_getClass("CloudPhotosController"))
        autorelease];
}

/* ---------------------------------------------------------
   Beigelist legacy root bridge
   --------------------------------------------------------- */

static IMP internetcloudphotosOriginalLegacyRootController = NULL;

static BOOL CloudPhotosIsLegacyMerchant(id self)
{
    id info =
        CloudPhotosObject(self, @"info");

    id merchantID =
        CloudPhotosObject(info, @"merchantID");

    if ([merchantID isKindOfClass:[NSString class]] &&
        [merchantID isEqualToString:@"org.atv3.cloudphotos"])
        return YES;

    id identifier =
        CloudPhotosObject(self, @"identifier");

    if ([identifier isKindOfClass:[NSString class]] &&
        ([identifier isEqualToString:@"org.atv3.cloudphotos"] ||
         [identifier isEqualToString:
             @"merchant.org.atv3.cloudphotos"]))
        return YES;

    id legacyClass =
        CloudPhotosObject(self, @"legacyApplianceClass");

    return legacyClass ==
        objc_getClass("CloudPhotosAppliance");
}

static id CloudPhotosLegacyRootController(id self,
                                    SEL cmd)
{
    if (CloudPhotosIsLegacyMerchant(self)) {

        id controller =
            [CloudPhotosNew(
                objc_getClass("CloudPhotosController"))
                autorelease];

        if (controller)
            return controller;
    }

    return internetcloudphotosOriginalLegacyRootController
        ? ((id(*)(id,SEL))
            internetcloudphotosOriginalLegacyRootController)(
                self,
                cmd)
        : nil;
}

static BOOL CloudPhotosInstallLegacyRootBridge(void)
{
    Class cls =
        objc_getClass("BLAppLegacyMerchant");

    if (!cls)
        return NO;

    SEL sel =
        NSSelectorFromString(@"rootController");

    Method method =
        class_getInstanceMethod(cls, sel);

    if (!method)
        return NO;

    const char *encoding =
        method_getTypeEncoding(method);

    NSMethodSignature *sig =
        [NSMethodSignature
            signatureWithObjCTypes:encoding];

    if (strcmp([sig methodReturnType],
               @encode(id)) ||
        [sig numberOfArguments] != 2)
        return NO;

    IMP current =
        method_getImplementation(method);

    if (!current)
        return NO;

    if (current ==
        (IMP)CloudPhotosLegacyRootController)
        return YES;

    internetcloudphotosOriginalLegacyRootController =
        current;

    if (class_addMethod(
            cls,
            sel,
            (IMP)CloudPhotosLegacyRootController,
            encoding))
        return YES;

    Class super =
        class_getSuperclass(cls);

    IMP superIMP =
        super
        ? class_getMethodImplementation(
            super,
            sel)
        : NULL;

    method =
        class_getInstanceMethod(cls, sel);

    if (!method ||
        method_getImplementation(method) ==
            superIMP) {

        internetcloudphotosOriginalLegacyRootController =
            NULL;

        return NO;
    }

    internetcloudphotosOriginalLegacyRootController =
        method_setImplementation(
            method,
            (IMP)CloudPhotosLegacyRootController);

    return
        internetcloudphotosOriginalLegacyRootController != NULL;
}

/* ---------------------------------------------------------
   BLAppMerchantInfo icon compatibility bridge
   --------------------------------------------------------- */


/* ---------------------------------------------------------
   Dynamic Home Screen CloudPhotos Icon
   188x108 canvas, centered 92x92 internetcloudphotos face
   --------------------------------------------------------- */

static NSString *CloudPhotosDynamicIconPath(void)
{
    NSDateFormatter *formatter =
        [[[NSDateFormatter alloc] init] autorelease];

    [formatter setDateFormat:@"yyyyMMddHHmmss"];

    NSString *stamp =
        [formatter stringFromDate:[NSDate date]];

    return [NSString stringWithFormat:
        @"/var/tmp/CloudPhotosDynamicIcon-%@.png",
        stamp];
}

static BOOL CloudPhotosRenderDynamicHomeIcon(void)
{
    const size_t width = 188;
    const size_t height = 108;

    CGColorSpaceRef cs =
        CGColorSpaceCreateDeviceRGB();

    if (!cs)
        return NO;

    CGContextRef ctx =
        CGBitmapContextCreate(NULL,
                             width,
                             height,
                             8,
                             width * 4,
                             cs,
                             kCGImageAlphaPremultipliedLast |
                             kCGBitmapByteOrder32Big);

    CGColorSpaceRelease(cs);

    if (!ctx)
        return NO;

    /* Transparent 188x108 canvas. */
    CGContextClearRect(ctx, CGRectMake(0, 0, width, height));

    const CGFloat cx = 94.0f;
    const CGFloat cy = 54.0f;
    const CGFloat radius = 46.0f;

    /* Light internetcloudphotos face. */
    CGContextSetRGBFillColor(ctx, 0.97, 0.97, 0.97, 1.0);
    CGContextFillEllipseInRect(
        ctx,
        CGRectMake(cx - radius,
                   cy - radius,
                   radius * 2.0f,
                   radius * 2.0f));

    /* Outer rim. */
    CGContextSetRGBStrokeColor(ctx, 0.12, 0.12, 0.12, 1.0);
    CGContextSetLineWidth(ctx, 1.5f);
    CGContextStrokeEllipseInRect(
        ctx,
        CGRectMake(cx - radius,
                   cy - radius,
                   radius * 2.0f,
                   radius * 2.0f));

    const CGFloat pi = 3.14159265358979323846f;

    /* 60 tick marks. */
    for (int i = 0; i < 60; i++) {

        CGFloat angle =
            ((CGFloat)i / 60.0f) *
            2.0f * pi -
            pi / 2.0f;

        BOOL major = ((i % 5) == 0);

        CGFloat outer = radius - 4.0f;
        CGFloat inner =
            outer - (major ? 8.0f : 3.5f);

        CGFloat x1 =
            cx + cosf(angle) * inner;
        CGFloat y1 =
            cy + sinf(angle) * inner;

        CGFloat x2 =
            cx + cosf(angle) * outer;
        CGFloat y2 =
            cy + sinf(angle) * outer;

        CGContextSetRGBStrokeColor(
            ctx, 0.10, 0.10, 0.10, 1.0);

        CGContextSetLineWidth(
            ctx, major ? 1.8f : 0.7f);

        CGContextMoveToPoint(ctx, x1, y1);
        CGContextAddLineToPoint(ctx, x2, y2);
        CGContextStrokePath(ctx);
    }

    NSDate *now = [NSDate date];

    NSCalendar *calendar =
        [NSCalendar currentCalendar];

    NSDateComponents *parts =
        [calendar components:
            (NSCalendarUnitHour |
             NSCalendarUnitMinute |
             NSCalendarUnitSecond)
                    fromDate:now];

    NSInteger hour = [parts hour] % 12;
    NSInteger minute = [parts minute];
    NSInteger second = [parts second];

    NSString *debug =
        [NSString stringWithFormat:
            @"date=%@ timezone=%@ hour=%ld minute=%ld second=%ld\\n",
            now,
            [[NSTimeZone localTimeZone] name],
            (long)hour,
            (long)minute,
            (long)second];

    [debug writeToFile:
        @"/var/tmp/internetcloudphotos_dynamic_time.log"
        atomically:YES
        encoding:NSUTF8StringEncoding
        error:NULL];

    CGFloat secondAngle =
        ((CGFloat)second / 60.0f) *
        2.0f * pi -
        pi / 2.0f;

    CGFloat minuteAngle =
        (((CGFloat)minute +
          (CGFloat)second / 60.0f) /
         60.0f) *
        2.0f * pi -
        pi / 2.0f;

    CGFloat hourAngle =
        (((CGFloat)hour +
          (CGFloat)minute / 60.0f) /
         12.0f) *
        2.0f * pi -
        pi / 2.0f;

    /* Hour hand. */
    CGContextSetRGBStrokeColor(
        ctx, 0.08, 0.08, 0.08, 1.0);

    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineWidth(ctx, 4.2f);

    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(
        ctx,
        cx + cosf(hourAngle) * 21.0f,
        cy + sinf(hourAngle) * 21.0f);

    CGContextStrokePath(ctx);

    /* Minute hand. */
    CGContextSetLineWidth(ctx, 3.0f);

    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(
        ctx,
        cx + cosf(minuteAngle) * 34.0f,
        cy + sinf(minuteAngle) * 34.0f);

    CGContextStrokePath(ctx);

    /* Red second hand. */
    CGContextSetRGBStrokeColor(
        ctx, 0.90, 0.05, 0.05, 1.0);

    CGContextSetLineWidth(ctx, 1.3f);

    CGContextMoveToPoint(
        ctx,
        cx - cosf(secondAngle) * 40.0f,
        cy - sinf(secondAngle) * 40.0f);

    CGContextAddLineToPoint(
        ctx,
        cx + cosf(secondAngle) * 37.0f,
        cy + sinf(secondAngle) * 37.0f);

    CGContextStrokePath(ctx);

    /* Center pin. */
    CGContextSetRGBFillColor(
        ctx, 0.90, 0.05, 0.05, 1.0);

    CGContextFillEllipseInRect(
        ctx,
        CGRectMake(cx - 2.5f,
                   cy - 2.5f,
                   5.0f,
                   5.0f));

    CGImageRef image =
        CGBitmapContextCreateImage(ctx);

    CGContextRelease(ctx);

    if (!image)
        return NO;

    NSMutableData *png =
        [NSMutableData data];

    CGImageDestinationRef dest =
        CGImageDestinationCreateWithData(
            (CFMutableDataRef)png,
            CFSTR("public.png"),
            1,
            NULL);

    if (!dest) {
        CGImageRelease(image);
        return NO;
    }

    CGImageDestinationAddImage(dest,
                               image,
                               NULL);

    BOOL ok =
        CGImageDestinationFinalize(dest);

    CFRelease(dest);
    CGImageRelease(image);

    if (!ok || ![png length])
        return NO;

    NSString *path =
        CloudPhotosDynamicIconPath();

    NSString *tmp =
        [path stringByAppendingString:@".tmp"];

    if (![png writeToFile:tmp atomically:YES])
        return NO;

    NSFileManager *fm =
        [NSFileManager defaultManager];

    [fm removeItemAtPath:path error:NULL];

    if (![fm moveItemAtPath:tmp
                     toPath:path
                      error:NULL])
        return NO;

    return YES;
}

static NSString *CloudPhotosDynamicIconURL(void)
{
    if (CloudPhotosRenderDynamicHomeIcon()) {
        return [[NSURL fileURLWithPath:
            CloudPhotosDynamicIconPath()]
            absoluteString];
    }

    /* Stable 0.1.3 icon is always the fallback. */
    return CloudPhotosMenuIconURL();
}

static NSString *CloudPhotosDynamicIconVersion(void)
{
    NSDateFormatter *formatter =
        [[[NSDateFormatter alloc] init]
            autorelease];

    [formatter setDateFormat:
        @"yyyyMMddHHmmss"];

    return [formatter stringFromDate:
        [NSDate date]];
}


static void CloudPhotosProbeMerchantCoordinatorClass(void)
{
    Class cls = objc_getClass("ATVMerchantCoordinator");
    FILE *fp = fopen("/var/tmp/internetcloudphotos_coordinator_class.txt", "w");
    if (!fp) return;
    if (!cls) { fprintf(fp, "NOT FOUND\n"); fclose(fp); return; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(object_getClass(cls), &n);
    for (unsigned int i=0; i<n; i++)
        fprintf(fp, "%s | %s\n", sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]));
    if (ms) free(ms);
    fclose(fp);
}


static void CloudPhotosPulseMerchantCoordinator(void)
{
    Class cls = objc_getClass("ATVMerchantCoordinator");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:sharedSel]) return;
    id coordinator = ((id(*)(id,SEL))objc_msgSend)(cls, sharedSel);
    if (!coordinator) return;
    SEL merchantSel = NSSelectorFromString(@"merchantWithIdentifier:");
    SEL changedSel = NSSelectorFromString(@"merchantChanged:");
    if (![coordinator respondsToSelector:merchantSel] ||
        ![coordinator respondsToSelector:changedSel]) return;
    id merchant = ((id(*)(id,SEL,id))objc_msgSend)(coordinator, merchantSel, @"org.atv3.cloudphotos");
    if (merchant)
        ((void(*)(id,SEL,id))objc_msgSend)(coordinator, changedSel, merchant);
}

static void CloudPhotosHomeIconTimerFire(id self, SEL cmd, NSTimer *timer)
{
    (void)self; (void)cmd; (void)timer;
    CloudPhotosPulseMerchantCoordinator();
}

static void CloudPhotosStartHomeIconTimer(void)
{
    static NSTimer *timer = nil;
    if (timer) return;
    Class timerClass = objc_getClass("CloudPhotosHomeIconTimerTarget");
    if (!timerClass) {
        timerClass = objc_allocateClassPair([NSObject class], "CloudPhotosHomeIconTimerTarget", 0);
        if (!timerClass) return;
        class_addMethod(timerClass, NSSelectorFromString(@"fire:"), (IMP)CloudPhotosHomeIconTimerFire, "v@:@");
        objc_registerClassPair(timerClass);
    }
    static id target = nil;
    if (!target) target = [[timerClass alloc] init];
    timer = [[NSTimer scheduledTimerWithTimeInterval:5.0
                                              target:target
                                            selector:NSSelectorFromString(@"fire:")
                                            userInfo:nil
                                             repeats:YES] retain];
}

static IMP internetcloudphotosSuperMerchantInfoValueForKey = NULL;

static BOOL CloudPhotosIsMerchantInfo(id self)
{
    id merchantID =
        CloudPhotosObject(self, @"merchantID");

    return
        [merchantID isKindOfClass:[NSString class]] &&
        [merchantID isEqualToString:@"org.atv3.cloudphotos"];
}

static id CloudPhotosMerchantInfoValueForKey(id self, SEL cmd, id key)
{
    if ([key isKindOfClass:[NSString class]] && CloudPhotosIsMerchantInfo(self)) {
        if ([key isEqualToString:@"menu-icon-url"]) {
            NSString *url = CloudPhotosMenuIconURLForResolution(720);
            if (![url length]) return nil;
            return @{
                @"720": url, @"1080": url,
                [NSNumber numberWithInteger:720]: url,
                [NSNumber numberWithInteger:1080]: url
            };
        }
        if ([key isEqualToString:@"menu-icon-url-version"]) {
            NSBundle *bundle = [NSBundle bundleWithIdentifier:@"org.atv3.cloudphotos"];
            id version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
            return ([version isKindOfClass:[NSString class]] && [version length]) ? version : @"1";
        }
    }
    return internetcloudphotosSuperMerchantInfoValueForKey
        ? ((id(*)(id,SEL,id))internetcloudphotosSuperMerchantInfoValueForKey)(self,cmd,key)
        : nil;
}

static BOOL CloudPhotosInstallMerchantInfoBridge(void)
{
    Class cls =
        objc_getClass("BLAppMerchantInfo");

    if (!cls)
        return NO;

    Class super =
        class_getSuperclass(cls);

    SEL sel =
        NSSelectorFromString(@"valueForKey:");

    Method inherited =
        class_getInstanceMethod(cls, sel);

    Method superMethod =
        super
        ? class_getInstanceMethod(super, sel)
        : NULL;

    if (!inherited || !superMethod)
        return NO;

    const char *encoding =
        method_getTypeEncoding(inherited);

    NSMethodSignature *sig =
        [NSMethodSignature
            signatureWithObjCTypes:encoding];

    if (strcmp([sig methodReturnType],
               @encode(id)) ||
        [sig numberOfArguments] != 3 ||
        strcmp([sig getArgumentTypeAtIndex:2],
               @encode(id)))
        return NO;

    /* Multiple third-party appliances share BLAppMerchantInfo in the same
       AppleTV process. Chain the implementation that is active right now
       instead of assuming we are the first appliance to install a bridge. */
    IMP current = method_getImplementation(inherited);
    if (!current || current == (IMP)CloudPhotosMerchantInfoValueForKey)
        return current == (IMP)CloudPhotosMerchantInfoValueForKey;

    internetcloudphotosSuperMerchantInfoValueForKey = current;
    method_setImplementation(inherited, (IMP)CloudPhotosMerchantInfoValueForKey);
    return YES;
}

/* ---------------------------------------------------------
   Runtime class registration
   --------------------------------------------------------- */

static BOOL CloudPhotosAddOverride(Class cls,
                             NSString *name,
                             IMP imp,
                             const char *result,
                             NSArray *args)
{
    SEL sel =
        NSSelectorFromString(name);

    Method method =
        class_getInstanceMethod(
            class_getSuperclass(cls),
            sel);

    if (!method) {
        NSLog(@"CloudPhotos: missing %@", name);
        return NO;
    }

    NSMethodSignature *sig =
        [NSMethodSignature
            signatureWithObjCTypes:
                method_getTypeEncoding(method)];

    if (strcmp([sig methodReturnType],
               result) ||
        [sig numberOfArguments] !=
            [args count] + 2)
        return NO;

    for (NSUInteger i = 0;
         i < [args count];
         i++) {

        if (strcmp(
            [sig getArgumentTypeAtIndex:i + 2],
            [[args objectAtIndex:i] UTF8String]))
            return NO;
    }

    return class_addMethod(
        cls,
        sel,
        imp,
        method_getTypeEncoding(method));
}


static void CloudPhotosDumpRuntimeClass(FILE *fp, const char *name)
{
    Class cls = objc_getClass(name);

    fprintf(fp, "\n========== %s ==========\n", name);

    if (!cls) {
        fprintf(fp, "NOT FOUND\n");
        return;
    }

    Class super = class_getSuperclass(cls);

    fprintf(fp,
            "class=%s superclass=%s\n",
            class_getName(cls),
            super ? class_getName(super) : "(none)");

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);

    fprintf(fp, "method_count=%u\n", count);

    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);

        fprintf(fp,
                "%s | %s\n",
                sel_getName(sel),
                types ? types : "");
    }

    if (methods)
        free(methods);
}

static void CloudPhotosDumpRuntime(void)
{
    FILE *fp = fopen("/var/tmp/internetcloudphotos_runtime.txt", "w");

    if (!fp)
        return;

    const char *classes[] = {
        "BRController",
        "BRMediaMenuController",
        "BRControl",
        "BRImageControl",
        "BRAsyncImageControl",
        "BRTextControl",
        "BRWindow",
        "BRView",
        "ATVMerchantCoordinator",
        "ATVMerchant",
        "BRMerchant",
        "BRMerchantInfo",
        "BLAppMerchantInfo",
        "BLAppLegacyMerchant"
    };

    unsigned int count =
        sizeof(classes) / sizeof(classes[0]);

    for (unsigned int i = 0; i < count; i++)
        CloudPhotosDumpRuntimeClass(fp, classes[i]);

    fflush(fp);
    fclose(fp);
}


static void CloudPhotosDumpHomeIconRuntime(void)
{
    FILE *fp =
        fopen("/var/tmp/internetcloudphotos_home_icon_runtime.txt", "w");

    if (!fp)
        return;

    int count = objc_getClassList(NULL, 0);

    if (count <= 0) {
        fclose(fp);
        return;
    }

    Class *classes =
        (Class *)malloc(sizeof(Class) * count);

    if (!classes) {
        fclose(fp);
        return;
    }

    count = objc_getClassList(classes, count);

    const char *words[] = {
        "Icon",
        "Shelf",
        "Merchant",
        "Appliance",
        "MenuItem",
        "Image"
    };

    unsigned int wordCount =
        sizeof(words) / sizeof(words[0]);

    for (int i = 0; i < count; i++) {

        Class cls = classes[i];

        if (!cls)
            continue;

        const char *name = class_getName(cls);

        if (!name)
            continue;

        BOOL interesting = NO;

        for (unsigned int w = 0;
             w < wordCount;
             w++) {

            if (strstr(name, words[w])) {
                interesting = YES;
                break;
            }
        }

        if (!interesting)
            continue;

        fprintf(fp,
                "\n===== %s =====\n",
                name);

        Class super = class_getSuperclass(cls);

        fprintf(fp,
                "super=%s\n",
                super
                    ? class_getName(super)
                    : "(none)");

        unsigned int methodCount = 0;

        Method *methods =
            class_copyMethodList(
                cls,
                &methodCount);

        for (unsigned int m = 0;
             m < methodCount;
             m++) {

            SEL sel =
                method_getName(methods[m]);

            const char *selName =
                sel_getName(sel);

            if (!selName)
                continue;

            if (strstr(selName, "icon") ||
                strstr(selName, "Icon") ||
                strstr(selName, "image") ||
                strstr(selName, "Image") ||
                strstr(selName, "reload") ||
                strstr(selName, "Reload") ||
                strstr(selName, "refresh") ||
                strstr(selName, "Refresh") ||
                strstr(selName, "update") ||
                strstr(selName, "Update") ||
                strstr(selName, "merchant") ||
                strstr(selName, "Merchant") ||
                strstr(selName, "appliance") ||
                strstr(selName, "Appliance") ||
                strstr(selName, "control") ||
                strstr(selName, "Control")) {

                fprintf(fp,
                        "%s | %s\n",
                        selName,
                        method_getTypeEncoding(
                            methods[m]));
            }
        }

        if (methods)
            free(methods);
    }

    free(classes);

    fflush(fp);
    fclose(fp);
}


BOOL CloudPhotosRegisterBackRowClasses(void)
{
    CloudPhotosProbeMerchantCoordinatorClass();
    CloudPhotosDumpHomeIconRuntime();
    CloudPhotosDumpRuntime();
    if (objc_getClass("CloudPhotosAppliance")) {
        CloudPhotosInstallLegacyRootBridge();
        return YES;
    }

    if (!CloudPhotosCategoryAvailable()) {
        NSLog(@"CloudPhotos: category ABI unavailable");
        return NO;
    }

    Class applianceBase =
        objc_getClass("BRBaseAppliance");

    Class controllerBase =
        objc_getClass("BRController");

    if (!applianceBase ||
        !controllerBase) {

        NSLog(@"CloudPhotos: BackRow unavailable");
        return NO;
    }

    Class appliance =
        objc_allocateClassPair(
            applianceBase,
            "CloudPhotosAppliance",
            0);

    Class controller =
        objc_allocateClassPair(
            controllerBase,
            "CloudPhotosController",
            0);

    if (!appliance || !controller) {

        if (appliance)
            objc_disposeClassPair(appliance);

        if (controller)
            objc_disposeClassPair(controller);

        return NO;
    }

    BOOL ok =
        CloudPhotosAddOverride(
            appliance,
            @"initWithApplianceInfo:",
            (IMP)CloudPhotosApplianceInit,
            @encode(id),
            @[@"@"])
        &&
        CloudPhotosAddOverride(
            appliance,
            @"applianceCategories",
            (IMP)CloudPhotosCategories,
            @encode(id),
            @[])
        &&
        CloudPhotosAddOverride(
            appliance,
            @"controllerForIdentifier:args:",
            (IMP)CloudPhotosControllerForIdentifier,
            @encode(id),
            @[@"@", @"@"])
        &&
        CloudPhotosAddOverride(
            appliance,
            @"applianceController",
            (IMP)CloudPhotosApplianceController,
            @encode(id),
            @[])
        &&
        CloudPhotosAddOverride(
            controller,
            @"brEventAction:",
            (IMP)CloudPhotosEvent,
            @encode(BOOL),
            @[@"@"]);

    if (ok) {

        ok =
            CloudPhotosAddOverride(
                controller,
                @"init",
                (IMP)CloudPhotosControllerInit,
                @encode(id),
                @[])
            &&
            CloudPhotosAddOverride(
                controller,
                @"controlWasActivated",
                (IMP)CloudPhotosActivated,
                @encode(void),
                @[])
            &&
            CloudPhotosAddOverride(
                controller,
                @"controlWasDeactivated",
                (IMP)CloudPhotosDeactivated,
                @encode(void),
                @[])
            &&
            CloudPhotosAddOverride(
                controller,
                @"wasPopped",
                (IMP)CloudPhotosPopped,
                @encode(void),
                @[])
            &&
            CloudPhotosAddOverride(
                controller,
                @"dealloc",
                (IMP)CloudPhotosControllerDealloc,
                @encode(void),
                @[]);

    }

    if (!ok) {

        objc_disposeClassPair(appliance);
        objc_disposeClassPair(controller);

        NSLog(@"CloudPhotos: incompatible BackRow ABI");

        return NO;
    }

    /* Register controller first, same proven order as Jellyfin. */
    objc_registerClassPair(controller);
    objc_registerClassPair(appliance);

    CloudPhotosInstallMerchantInfoBridge();
    CloudPhotosInstallLegacyRootBridge();

    NSLog(@"CloudPhotos: BackRow classes registered");

    return YES;
}

/* Dynamic NSTimer target selector */
__attribute__((constructor))
static void CloudPhotosInstallTimerSelector(void)
{
    /* Installed after CloudPhotosController is dynamically created,
       so actual selector installation occurs lazily below. */
}

static void CloudPhotosEnsureTimerSelector(void)
{
    Class cls =
        objc_getClass("CloudPhotosController");

    if (!cls)
        return;

    SEL sel =
        NSSelectorFromString(@"internetcloudphotosTimerFire:");

    if (!class_getInstanceMethod(cls, sel)) {
        class_addMethod(cls,sel,(IMP)CloudPhotosTimerFire,"v@:@");
    }
    SEL fetchSel=NSSelectorFromString(@"internetcloudphotosBackgroundFetch:");
    if (!class_getInstanceMethod(cls,fetchSel)) {
        class_addMethod(cls,fetchSel,(IMP)CloudPhotosBackgroundFetch,"v@:@");
    }
    class_addMethod(cls,NSSelectorFromString(@"internetcloudphotosLoadPage:"),(IMP)CloudPhotosPageLoader,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"internetcloudphotosRecordPlayed:"),(IMP)CloudPhotosRecordPlayed,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"internetcloudphotosRecordFavorite:"),(IMP)CloudPhotosRecordFavorite,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"icloudphotosFetchRemote:"),(IMP)CloudPhotosFetchRemoteFrame,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"icloudphotosApplyRemote:"),(IMP)CloudPhotosApplyRemoteFrame,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"icloudphotosNav:"),(IMP)CloudPhotosSendNavigation,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"icloudphotosConfirmedExit:"),(IMP)CloudPhotosDirectExit,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"icloudphotosSelectHold:"),(IMP)CPPhotosSelectHold,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"icloudphotosSelectPress:"),(IMP)CPPhotosSelectPressSelector,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"icloudphotosSelectRelease:"),(IMP)CPPhotosSelectReleaseSelector,"v@:@");
    CloudPhotosPasswordRegister(cls);
    class_addMethod(cls,NSSelectorFromString(@"icloudphotosPollTimer:"),(IMP)CloudPhotosPollTimer,"v@:@");
    SEL applySel=NSSelectorFromString(@"internetcloudphotosApplyFreshData");
    if (!class_getInstanceMethod(cls,applySel)) {
        class_addMethod(cls,applySel,(IMP)CloudPhotosApplyFreshData,"v@:");
    }
}
