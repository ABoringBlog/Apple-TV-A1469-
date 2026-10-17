#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>

extern NSString *CloudPhotosClientSecret(void);
extern void CloudPhotosVideoFallback(id controller);

static NSString * const CPVideoBase=@"http://192.0.2.24:18791";
static NSString * const CPVideoPlaylist=@"http://192.0.2.24:18791/stream.m3u8";
static BOOL cpVideoActive=NO, cpVideoStarting=NO, cpVideoPresented=NO, cpVideoExiting=NO;
static BOOL cpVideoHookActive=NO, cpVideoSelectPressed=NO;
static Class cpHookedSubclass=Nil;
static BOOL (*cpSubclassOriginalEvent)(id,SEL,id)=NULL;
static BOOL cpSubclassHooked=NO;
static NSTimeInterval cpVideoLastMenu=0;
static id cpVideoAsset=nil, cpVideoPlayer=nil, cpVideoController=nil;
static id cpVideoDisplayed=nil; // not retained, native manager owned
static id cpVideoHost=nil; // retained until stopped
static char cpVideoRequestKey;
static BOOL (*cpOriginalMediaEvent)(id,SEL,id)=NULL;

@interface CPVideoWorker : NSObject
- (void)start:(id)unused;
- (void)present:(NSNumber *)ready;
- (void)stop:(id)unused;
- (void)navigate:(NSString *)command;
- (void)playerPopped:(NSNotification *)notification;
- (void)popHost:(id)unused;
@end

static CPVideoWorker *cpWorker=nil;
static CPVideoWorker *CPWorker(void) {
    if(!cpWorker)cpWorker=[[CPVideoWorker alloc] init];
    return cpWorker;
}

static NSDictionary *CPRequest(NSString *path,NSString *method,NSDictionary *body,NSTimeInterval timeout) {
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[CPVideoBase stringByAppendingString:path]]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    [req setHTTPMethod:method];
    [req setValue:CloudPhotosClientSecret() forHTTPHeaderField:@"X-ATV-Photos-Key"];
    if(body) {
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        NSData *data=[NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
        [req setHTTPBody:data];
    }
    NSURLResponse *response=nil;
    NSData *data=[NSURLConnection sendSynchronousRequest:req returningResponse:&response error:NULL];
    if(!data || ![response isKindOfClass:[NSHTTPURLResponse class]] ||
       [(NSHTTPURLResponse *)response statusCode]!=200)return nil;
    id obj=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:[NSDictionary class]]?obj:nil;
}

static BOOL CPEventInteger(id event,NSString *selector,NSInteger *out) {
    SEL s=NSSelectorFromString(selector);
    if(!event || ![event respondsToSelector:s])return NO;
    NSMethodSignature *sig=[event methodSignatureForSelector:s];
    if(!sig || [sig numberOfArguments]!=2)return NO;
    const char *type=[sig methodReturnType];
    BOOL isLong=type && !strcmp(type,@encode(NSInteger));
    BOOL isInt=type && !strcmp(type,@encode(int));
    if(!isLong && !isInt)return NO;
    NSInvocation *call=[NSInvocation invocationWithMethodSignature:sig];
    [call setTarget:event];[call setSelector:s];[call invoke];
    if(isLong){NSInteger v=0;[call getReturnValue:&v];*out=v;}
    else {int v=0;[call getReturnValue:&v];*out=v;}
    return YES;
}
static void CPRemoteLog(NSInteger action,NSInteger value,NSInteger origin,BOOL known,BOOL ours) {
    FILE *out=fopen("/var/tmp/cloudphotos_video_remote.log","a");
    if(out) {
        fprintf(out,"%.3f action=%ld value=%ld origin=%ld known=%d ours=%d active=%d presented=%d\n",
            [NSDate timeIntervalSinceReferenceDate],(long)action,(long)value,(long)origin,
            known,ours,cpVideoActive,cpVideoPresented);
        fclose(out);
    }
}
static BOOL CPIsOurPlayerController(id target) {
    if(!target || !cpVideoPlayer || !cpVideoPresented)return NO;
    if(target==cpVideoController || target==cpVideoDisplayed)return YES;
    SEL sel=NSSelectorFromString(@"player");
    if([target respondsToSelector:sel]){
        NSMethodSignature *sig=[target methodSignatureForSelector:sel];
        if(sig && [sig numberOfArguments]==2 &&
           !strcmp([sig methodReturnType],@encode(id)))
            return ((id(*)(id,SEL))objc_msgSend)(target,sel)==cpVideoPlayer;
    }
    // Only one native BRMediaPlayerController is presented at a time.
    // Some 12H1006 media controller subclasses don't expose -player;
    // they still belong to our active presentation.
    return cpVideoActive && [target isKindOfClass:objc_getClass("BRMediaPlayerController")];
}
// Some system Select events are routed to the underlying appliance controller
// while the HLS player owns directional events. Capture only Select in that
// alternate path, leaving native Menu handling and other apps untouched.
BOOL CloudPhotosVideoHostSelect(id event){
    if(!cpVideoActive || !cpVideoPresented)return NO;
    NSInteger action=-1,value=-1,origin=-1;
    BOOL known=CPEventInteger(event,@"remoteAction",&action);
    BOOL haveValue=CPEventInteger(event,@"value",&value);
    BOOL haveOrigin=CPEventInteger(event,@"originator",&origin);
    if(!known || (haveOrigin && origin!=1 && origin!=3))return NO;
    BOOL down=!haveValue || value==1;
    if((action==5 || action==22) && down){
        CPRemoteLog(action,value,origin,YES,YES);
        [NSThread detachNewThreadSelector:@selector(navigate:)
                                toTarget:CPWorker() withObject:@"select"];
        return YES;
    }
    return action==23;
}
static BOOL CPMediaEvent(id self,SEL selector,id event){
    BOOL ours=CPIsOurPlayerController(self);
    if(cpVideoPresented){
        NSInteger action=-1,value=-1,origin=-1;
        BOOL known=CPEventInteger(event,@"remoteAction",&action);
        BOOL haveValue=CPEventInteger(event,@"value",&value);
        BOOL haveOrigin=CPEventInteger(event,@"originator",&origin);
        CPRemoteLog(action,value,origin,known,ours);
        if(!ours)goto originalEvent;
        if(known && (!haveOrigin || origin==1 || origin==3)){
            BOOL down=!haveValue || value==1;
            NSString *command=nil;
            if(action==22 && down){
                // Some ATV3 remotes don't dispatch the separate 23 release
                // event to a streaming BRMediaPlayerController.
                cpVideoSelectPressed=YES;
                command=@"select";
            }
            else if(action==23){
                cpVideoSelectPressed=NO;
                return YES;
            }
            else if(down){
                if(action==3)command=@"up";
                else if(action==4)command=@"down";
                else if(action==6)command=@"left";
                else if(action==7)command=@"right";
                else if(action==5)command=@"select";
            }
            if(command){
                [NSThread detachNewThreadSelector:@selector(navigate:) toTarget:CPWorker() withObject:command];
                return YES;
            }
            if(action==1 || action==2){
                // First Menu exits the native player and the Photos appliance.
                // Do not require two presses or send Escape to the web page.
                if(down && !cpVideoExiting){
                    cpVideoExiting=YES;
                    [CPWorker() performSelectorOnMainThread:@selector(popHost:)
                                              withObject:nil waitUntilDone:NO];
                }
                return YES;
            }else if(action==22||action==23||action==24||action==9||action==10||action==11||action==12){
                return YES;
            }
        }
    }
originalEvent:
    if(cpSubclassHooked && cpHookedSubclass &&
       [self isMemberOfClass:cpHookedSubclass] && cpSubclassOriginalEvent)
       return cpSubclassOriginalEvent(self,selector,event);
    return cpOriginalMediaEvent ? cpOriginalMediaEvent(self,selector,event):NO;
}
static void CPInstallPresentedSubclassGuard(id presented){
    if(!presented || cpSubclassHooked)return;
    Class cls=object_getClass(presented), base=objc_getClass("BRMediaPlayerController");
    if(!cls || cls==base)return;
    unsigned int count=0;
    Method *methods=class_copyMethodList(cls,&count);
    for(unsigned int i=0;i<count;i++){
        if(sel_isEqual(method_getName(methods[i]),NSSelectorFromString(@"brEventAction:"))){
            IMP previous=method_setImplementation(methods[i],(IMP)CPMediaEvent);
            if(previous!=(IMP)CPMediaEvent){
                cpSubclassOriginalEvent=(BOOL(*)(id,SEL,id))previous;
                cpHookedSubclass=cls;cpSubclassHooked=YES;
            }
            break;
        }
    }
    if(methods)free(methods);
    NSLog(@"CloudPhotos Video: native subclass guard=%d",cpSubclassHooked);
}
static BOOL CPInstallEventGuard(void) {
    if(cpVideoHookActive)return YES;
    Class cls=objc_getClass("BRMediaPlayerController");
    Method m=cls?class_getInstanceMethod(cls,NSSelectorFromString(@"brEventAction:")):NULL;
    if(!m)return NO;
    const char *type=method_getTypeEncoding(m);
    NSMethodSignature *sig=type?[NSMethodSignature signatureWithObjCTypes:type]:nil;
    if(!sig || [sig numberOfArguments]!=3 ||
       strcmp([sig methodReturnType],@encode(BOOL)) ||
       strcmp([sig getArgumentTypeAtIndex:2],@encode(id)))return NO;
    cpOriginalMediaEvent=(BOOL(*)(id,SEL,id))method_setImplementation(m,(IMP)CPMediaEvent);
    cpVideoHookActive=cpOriginalMediaEvent && cpOriginalMediaEvent!=(BOOL(*)(id,SEL,id))CPMediaEvent;
    return cpVideoHookActive;
}
static void CPRemoveEventGuard(void) {
    if(!cpVideoHookActive)return;
    Class cls=objc_getClass("BRMediaPlayerController");
    Method m=cls?class_getInstanceMethod(cls,NSSelectorFromString(@"brEventAction:")):NULL;
    if(m && method_getImplementation(m)==(IMP)CPMediaEvent)
        method_setImplementation(m,(IMP)cpOriginalMediaEvent);
    cpOriginalMediaEvent=NULL;
    cpVideoHookActive=NO;
    if(cpSubclassHooked && cpHookedSubclass){
        Method method=class_getInstanceMethod(cpHookedSubclass,NSSelectorFromString(@"brEventAction:"));
        if(method && method_getImplementation(method)==(IMP)CPMediaEvent)
            method_setImplementation(method,(IMP)cpSubclassOriginalEvent);
    }
    cpSubclassHooked=NO;cpHookedSubclass=Nil;cpSubclassOriginalEvent=NULL;
}

static id CPAssetValue(id self) {return objc_getAssociatedObject(self,&cpVideoRequestKey);}
static id CPAssetURL(id self,SEL cmd) {return [[CPAssetValue(self) URL] absoluteString];}
static id CPAssetID(id self,SEL cmd) {return @"icloud-photos-nas-live";}
static id CPAssetTitle(id self,SEL cmd) {return @"iCloud Photos";}
static id CPAssetType(id self,SEL cmd){
    Class c=objc_getClass("BRMediaType");SEL s=NSSelectorFromString(@"streamingVideo");
    return (c && [c respondsToSelector:s])?((id(*)(id,SEL))objc_msgSend)(c,s):nil;
}
static id CPAssetMetadata(id self,SEL cmd){
    return @{@"BRMediaAssetMetadataHTTPHeaders":@{@"User-Agent":@"CloudPhotosNASATV3"},
             @"kBRMediaAssetReferenceRestrictions":@5};
}
static BOOL CPYes(id self,SEL cmd){return YES;}
static BOOL CPNo(id self,SEL cmd){return NO;}
static long CPDuration(id self,SEL cmd){return 0;}

static Class CPAssetClass(void){
    Class existing=objc_getClass("CPPhotosLiveMediaAsset");
    if(existing)return existing;
    Class base=objc_getClass("BRBaseMediaAsset");
    if(!base || !objc_getClass("BRMediaPlayerManager"))return Nil;
    Class cls=objc_allocateClassPair(base,"CPPhotosLiveMediaAsset",0);
    if(!cls)return Nil;
    struct {const char *name;IMP imp;} fields[]={
        {"mediaURL",(IMP)CPAssetURL},{"assetID",(IMP)CPAssetID},
        {"title",(IMP)CPAssetTitle},{"mediaType",(IMP)CPAssetType},
        {"playbackMetadata",(IMP)CPAssetMetadata},
        {"isValid",(IMP)CPYes},{"playable",(IMP)CPYes},
        {"hasVideoContent",(IMP)CPYes},{"isScrubbable",(IMP)CPNo},
        {"duration",(IMP)CPDuration}
    };
    for(NSUInteger i=0;i<sizeof(fields)/sizeof(fields[0]);i++){
        SEL s=sel_registerName(fields[i].name);
        Method parent=class_getInstanceMethod(base,s);
        if(!parent || !class_addMethod(cls,s,fields[i].imp,method_getTypeEncoding(parent))){
            objc_disposeClassPair(cls);return Nil;
        }
    }
    objc_registerClassPair(cls);
    return cls;
}

static void CPSetTransportDisabled(id object,BOOL value){
    SEL selector=NSSelectorFromString(@"setTransportControlDisabled:");
    NSMethodSignature *sig=object?[object methodSignatureForSelector:selector]:nil;
    if(sig && [sig numberOfArguments]==3 && !strcmp([sig methodReturnType],@encode(void)) &&
       !strcmp([sig getArgumentTypeAtIndex:2],@encode(BOOL)))
        ((void(*)(id,SEL,BOOL))objc_msgSend)(object,selector,value);
}

static void CPStopPlayer(void) {
    @try {
        if(cpVideoPlayer)
            ((BOOL(*)(id,SEL,int,NSError**))objc_msgSend)(cpVideoPlayer,
                NSSelectorFromString(@"setState:error:"),0,NULL);
        if(cpVideoPresented){
            Class cls=objc_getClass("BRMediaPlayerManager");
            id manager=cls?((id(*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"sharedInstance")):nil;
            if(manager) {
                ((void(*)(id,SEL))objc_msgSend)(manager,NSSelectorFromString(@"endPresentation"));
                CPSetTransportDisabled(manager,NO);
            }
        }
    }@catch(NSException *e){NSLog(@"CloudPhotos Video stop exception %@",e);}
    [[NSNotificationCenter defaultCenter] removeObserver:CPWorker()
       name:@"BRMediaPlayerControllerWasPopped" object:nil];
    CPRemoveEventGuard();
    cpVideoPresented=NO;
    cpVideoDisplayed=nil;
    cpVideoSelectPressed=NO;
    [cpVideoController release];cpVideoController=nil;
    [cpVideoPlayer release];cpVideoPlayer=nil;
    [cpVideoAsset release];cpVideoAsset=nil;
}
static BOOL CPPlay(void) {
    if(![NSThread isMainThread] || !cpVideoActive)return NO;
    Class cls=CPAssetClass();
    if(!cls)return NO;
    id asset=[[cls alloc] init];
    if(!asset)return NO;
    NSURLRequest *req=[NSURLRequest requestWithURL:[NSURL URLWithString:CPVideoPlaylist]];
    objc_setAssociatedObject(asset,&cpVideoRequestKey,req,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL ok=NO;
    @try {
        Class managerClass=objc_getClass("BRMediaPlayerManager");
        id manager=((id(*)(id,SEL))objc_msgSend)(managerClass,NSSelectorFromString(@"sharedInstance"));
        NSError *error=nil;
        id player=((id(*)(id,SEL,id,NSError**))objc_msgSend)(manager,NSSelectorFromString(@"playerForMediaAsset:error:"),asset,&error);
        id controller=player?((id(*)(id,SEL,id))objc_msgSend)(
            objc_getClass("BRMediaPlayerController"),NSSelectorFromString(@"controllerForPlayer:"),player):nil;
        if(player && controller){
            cpVideoAsset=[asset retain];
            cpVideoPlayer=[player retain];
            cpVideoController=[controller retain];
            CPSetTransportDisabled(controller,YES);
            CPInstallEventGuard();
            BOOL cued=((BOOL(*)(id,SEL,NSError**))objc_msgSend)(player,
                NSSelectorFromString(@"cueMediaWithError:"),&error);
            NSLog(@"CloudPhotos Video cue=%d error=%@",cued,error);
            if(cued){
                ((void(*)(id,SEL,id,id))objc_msgSend)(manager,
                    NSSelectorFromString(@"presentPlayer:options:"),player,nil);
                cpVideoPresented=YES;
                if([manager respondsToSelector:NSSelectorFromString(@"_presentedPlayerController")])
                    cpVideoDisplayed=((id(*)(id,SEL))objc_msgSend)(manager,
                        NSSelectorFromString(@"_presentedPlayerController"));
                CPInstallPresentedSubclassGuard(cpVideoDisplayed);
                CPSetTransportDisabled(cpVideoDisplayed,YES);
                CPSetTransportDisabled(manager,YES);
                error=nil;
                ok=((BOOL(*)(id,SEL,int,NSError**))objc_msgSend)(player,
                    NSSelectorFromString(@"setState:error:"),3,&error);
                NSLog(@"CloudPhotos Video playback=%d error=%@",ok,error);
                if(ok){
                    [[NSNotificationCenter defaultCenter] addObserver:CPWorker()
                        selector:@selector(playerPopped:)
                        name:@"BRMediaPlayerControllerWasPopped" object:nil];
                }
            }
        }
    }@catch(NSException *e){NSLog(@"CloudPhotos Video exception %@",e);}
    [asset release];
    if(!ok)CPStopPlayer();
    return ok;
}

void CloudPhotosVideoActivated(id host){
    if(![NSThread isMainThread] || !host || cpVideoExiting)return;
    if(cpVideoHost!=host){
        [cpVideoHost release];cpVideoHost=[host retain];
    }
    if(cpVideoPresented || cpVideoStarting)return;
    cpVideoActive=YES;cpVideoStarting=YES;
    [NSThread detachNewThreadSelector:@selector(start:) toTarget:CPWorker() withObject:nil];
}
void CloudPhotosVideoStop(void) {
    cpVideoActive=NO;
    cpVideoStarting=NO;
    CPStopPlayer();
    [NSThread detachNewThreadSelector:@selector(stop:) toTarget:CPWorker() withObject:nil];
}
void CloudPhotosVideoPopped(id host) {
    CloudPhotosVideoStop();
    if(cpVideoHost==host){[cpVideoHost release];cpVideoHost=nil;}
    cpVideoExiting=NO;
    cpVideoLastMenu=0;
}

@implementation CPVideoWorker
- (void)start:(id)unused {
    (void)unused;NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    NSDictionary *status=CPRequest(@"/v1/video/start",@"POST",nil,22);
    BOOL ok=[[status objectForKey:@"ready"] boolValue];
    NSLog(@"CloudPhotos Video NAS encoder ready=%d",ok);
    [self performSelectorOnMainThread:@selector(present:)
                          withObject:[NSNumber numberWithBool:ok] waitUntilDone:NO];
    [pool drain];
}
- (void)present:(NSNumber *)ready {
    cpVideoStarting=NO;
    if(!cpVideoActive){
        [NSThread detachNewThreadSelector:@selector(stop:) toTarget:self withObject:nil];
        return;
    }
    if(![ready boolValue]){
        NSLog(@"CloudPhotos Video: encoder unavailable; enabling JPEG fallback");
        CloudPhotosVideoFallback(cpVideoHost);
        return;
    }
    if(!CPPlay()){
        CloudPhotosVideoFallback(cpVideoHost);
        [NSThread detachNewThreadSelector:@selector(stop:) toTarget:self withObject:nil];
    }
}
- (void)stop:(id)unused {
    (void)unused;NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    CPRequest(@"/v1/video/stop",@"POST",nil,6);
    [pool drain];
}
- (void)navigate:(NSString *)command {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    if([command isEqualToString:@"select"]){
        static NSTimeInterval lastSelect=0;
        @synchronized(self){
            NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
            if(now-lastSelect<0.25){[pool drain];return;}
            lastSelect=now;
        }
    }
    NSURL *url=[NSURL URLWithString:@"http://192.0.2.24:18790/v1/photos/nav"];
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url
       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];
    [req setHTTPMethod:@"POST"];
    [req setValue:CloudPhotosClientSecret() forHTTPHeaderField:@"X-ATV-Photos-Key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSData *payload=[NSJSONSerialization dataWithJSONObject:@{@"action":command}
                                                   options:0 error:NULL];
    [req setHTTPBody:payload];
    NSURLResponse *reply=nil;
    NSError *networkError=nil;
    [NSURLConnection sendSynchronousRequest:req returningResponse:&reply error:&networkError];
    NSInteger status=[reply isKindOfClass:[NSHTTPURLResponse class]]
        ? [(NSHTTPURLResponse *)reply statusCode] : 0;
    FILE *log=fopen("/var/tmp/cloudphotos_video_remote.log","a");
    if(log){
        fprintf(log,"NAS_CONTROL action=%s http=%ld error=%ld\n",
           [command UTF8String],(long)status,
           networkError?(long)[networkError code]:0L);
        fclose(log);
    }
    [pool drain];
}
- (void)playerPopped:(NSNotification *)notification {
    (void)notification;
    if(![NSThread isMainThread]){
        [self performSelectorOnMainThread:@selector(playerPopped:)
             withObject:notification waitUntilDone:NO];
        return;
    }
    if(!cpVideoPresented || cpVideoExiting)return;
    cpVideoExiting=YES;
    [self performSelector:@selector(popHost:) withObject:nil afterDelay:0.12];
}
- (void)popHost:(id)unused {
    (void)unused;
    if(!cpVideoExiting || !cpVideoHost)return;
    id host=[cpVideoHost retain];
    CloudPhotosVideoStop();
    id stack=nil;
    SEL s=NSSelectorFromString(@"stack");
    if([host respondsToSelector:s])
        stack=((id(*)(id,SEL))objc_msgSend)(host,s);
    if(stack && [stack respondsToSelector:NSSelectorFromString(@"popController")])
        ((void(*)(id,SEL))objc_msgSend)(stack,NSSelectorFromString(@"popController"));
    [host release];
}
@end
