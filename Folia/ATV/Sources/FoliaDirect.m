#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>

static NSString *FDPath=@"/Applications/FoliaDirect.frappliance";
// Set FoliaBridgeHost in the installed bundle's Info.plist before launching.
NSString *FDPublicBridgeHost(void) {
 NSString *value=[[NSBundle bundleWithPath:FDPath]
    objectForInfoDictionaryKey:@"FoliaBridgeHost"];
 if(![value isKindOfClass:[NSString class]])return @"";
 // IPv4 only: reject accidental URL / arbitrary URI injection.
 NSArray *parts=[value componentsSeparatedByString:@"."];
 if([parts count]!=4)return @"";
 for(NSString *part in parts){
   if(![part length]||[part length]>3)return @"";
   NSCharacterSet *bad=[[NSCharacterSet decimalDigitCharacterSet] invertedSet];
   if([part rangeOfCharacterFromSet:bad].location!=NSNotFound)return @"";
   NSInteger n=[part integerValue];
   if(n<0||n>255)return @"";
 }
 return value;
}

extern void FDRemoteSetActive(BOOL enabled);
extern BOOL FDRemoteHandle(id self,SEL sel,id event,IMP inherited);
extern void FDStreamStart(AVSampleBufferDisplayLayer *layer);
extern void FDStreamStop(void);
extern void FDAudioStart(void);
extern void FDAudioStop(void);
static void FDLog(NSString *s){
 FILE *f=fopen("/var/tmp/foliadirect_decode_display.log","a");
 if(!f)return;
 fprintf(f,"%.3f %s\n",[[NSDate date]timeIntervalSince1970],[s UTF8String]);
 fclose(f);
}
// v44: Folia stays resident but SIGSTOP-suspended on Home; the separate
// Mac supervisor alone may receive lifecycle requests, never the UI thread.
@interface FoliaDirectLifecycleWorker:NSObject
-(void)deliver:(NSDictionary*)task;
@end
@implementation FoliaDirectLifecycleWorker
-(void)deliver:(NSDictionary*)task {
 NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
 NSString *operation=[task objectForKey:@"op"];
 NSString *session=[task objectForKey:@"session"];
 NSString *host=FDPublicBridgeHost();
 if(![host length]){FDLog(@"FOLIA_BRIDGE_HOST_MISSING");[pool drain];return;}
 NSString *urlString=[NSString stringWithFormat:
   @"http://%@:18783/%@?session=%@",host,operation,session];
 NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:
   [NSURL URLWithString:urlString]
   cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
   timeoutInterval:[operation isEqualToString:@"start"]?35.0:6.0];
 // On leave, allow the video socket to close before freezing the sender.
 if([operation isEqualToString:@"suspend"])[NSThread sleepForTimeInterval:0.35];
 NSURLResponse *response=nil;
 NSError *error=nil;
 NSData *body=[NSURLConnection sendSynchronousRequest:request
   returningResponse:&response error:&error];
 NSInteger code=[response isKindOfClass:[NSHTTPURLResponse class]]
   ?[(NSHTTPURLResponse*)response statusCode]:0;
 FDLog([NSString stringWithFormat:
    @"LIFECYCLE_%@ session=%@ http=%ld bytes=%lu error=%@",
    operation,session,(long)code,(unsigned long)body.length,
    error?:@"none"]);
 [pool drain];
}
@end
static FoliaDirectLifecycleWorker *FDLifecycleWorker=nil;
static NSString *FDLifecycleSession=nil;
static BOOL FDLifecycleActive=NO;
static void FDCallLifecycle(NSString *operation,NSString *session){
 if(!session || !operation)return;
 if(!FDLifecycleWorker)FDLifecycleWorker=[[FoliaDirectLifecycleWorker alloc]init];
 [NSThread detachNewThreadSelector:@selector(deliver:)
   toTarget:FDLifecycleWorker
   withObject:[NSDictionary dictionaryWithObjectsAndKeys:
     operation,@"op",session,@"session",nil]];
}
static void FDLifecycleStart(void){
 // Monotonic across app opens in this live system: Unix microseconds.
 [FDLifecycleSession release];
 FDLifecycleSession=[[NSString alloc]initWithFormat:@"%.0f",
   [[NSDate date]timeIntervalSince1970]*1000000.0];
 FDLifecycleActive=YES;
 FDLog([NSString stringWithFormat:@"LIFECYCLE_OPEN %@",FDLifecycleSession]);
 FDCallLifecycle(@"start",FDLifecycleSession);
}
static void FDLifecycleSuspend(void){
 if(!FDLifecycleActive)return; // multiple deactivation callbacks are normal
 FDLifecycleActive=NO;
 FDLog([NSString stringWithFormat:@"LIFECYCLE_EXIT %@",FDLifecycleSession]);
 FDCallLifecycle(@"suspend",FDLifecycleSession);
}
static IMP FDControllerSuper(SEL sel){
 Class cls=objc_getClass("FoliaDirectController");
 return cls?class_getMethodImplementation(class_getSuperclass(cls),sel):NULL;
}
static IMP FDApplianceSuper(SEL sel){
 Class cls=objc_getClass("FoliaDirectAppliance");
 return cls?class_getMethodImplementation(class_getSuperclass(cls),sel):NULL;
}
static BOOL FDAdd(Class cls, NSString *name,IMP imp,const char *ret,NSArray *args){
 SEL sel=NSSelectorFromString(name);
 Method method=class_getInstanceMethod(class_getSuperclass(cls),sel);
 if(!method){FDLog([NSString stringWithFormat:@"MISSING_ABI %@",name]);return NO;}
 NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
 if(strcmp(signature.methodReturnType,ret) || signature.numberOfArguments!=args.count+2){
  FDLog([NSString stringWithFormat:@"ABI_MISMATCH %@",name]);return NO;
 }
 for(NSUInteger i=0;i<args.count;i++){
  if(strcmp([signature getArgumentTypeAtIndex:i+2],[[args objectAtIndex:i]UTF8String]))return NO;
 }
 return class_addMethod(cls,sel,imp,method_getTypeEncoding(method));
}
// AppleTV 3 (12H1006) home tile is rendered from the Beigelist merchant,
// not by reading FRApplianceIcon out of Info.plist. Match the verified
// Jellyfin/Clock 720/1080 URL dictionary contract.
static NSString *FDIconURL(void){
 return [[NSURL fileURLWithPath:[FDPath stringByAppendingPathComponent:@"AppIcon.png"]] absoluteString];
}
static id FDIconURLs(void){
 NSString *url=FDIconURL();
 return url ? @{
   @"720":url, @"1080":url,
   [NSNumber numberWithInteger:720]:url,
   [NSNumber numberWithInteger:1080]:url
 } : @{};
}
static id FDIconVersion(void){return @"0.0.2-folia-home-icon"; }
static id FDInfoIconURLs(id self,SEL cmd){return FDIconURLs();}
static id FDInfoIconVersion(id self,SEL cmd){return FDIconVersion();}
static Class FDInfoClass(void){
 Class existing=objc_getClass("FoliaDirectApplianceInfo");
 if(existing)return existing;
 Class base=objc_getClass("BRApplianceInfo");
 if(!base)return Nil;
 Method m1=class_getInstanceMethod(base,NSSelectorFromString(@"menuIconURLs"));
 Method m2=class_getInstanceMethod(base,NSSelectorFromString(@"menuIconURLVersion"));
 if(!m1||!m2){FDLog(@"HOME_ICON_INFO_MISSING_ABI");return Nil;}
 Class cls=objc_allocateClassPair(base,"FoliaDirectApplianceInfo",0);
 if(!cls)return Nil;
 BOOL ok=class_addMethod(cls,NSSelectorFromString(@"menuIconURLs"),
   (IMP)FDInfoIconURLs,method_getTypeEncoding(m1)) &&
   class_addMethod(cls,NSSelectorFromString(@"menuIconURLVersion"),
   (IMP)FDInfoIconVersion,method_getTypeEncoding(m2));
 if(!ok){objc_disposeClassPair(cls);return Nil;}
 objc_registerClassPair(cls);
 return cls;
}
static id FDSyntheticInfo(){
 Class cls=FDInfoClass();
 if(!cls)return nil;
 id i=[cls alloc];
 SEL sel=NSSelectorFromString(@"_initWithMutableDictionary:");
 if(![i respondsToSelector:sel]){[i release];return nil;}
 NSMutableDictionary *settings=[NSMutableDictionary dictionaryWithDictionary:@{
   @"FRApplianceIdentifier":@"foliadirect",
   @"FRApplianceName":@"Folia",
   @"FRAppliancePreferedOrderValue":@7,
   @"FRPrincipalClass":@"FoliaDirectAppliance",
   @"FRHideIfNoCategories":@NO,
   @"FRApplianceSupportedMediaTypes":@[],
   @"FRApplianceRequiredRemoteMediaTypes":@[]
 }];
 id ret=((id(*)(id,SEL,id))objc_msgSend)(i,sel,settings);
 return [ret autorelease];
}
static id FDApplianceInit(id self,SEL sel,id incoming){
 FDLog([NSString stringWithFormat:@"APPLIANCE_INIT incoming=%@",incoming?@"YES":@"NO"]);
 IMP imp=FDApplianceSuper(sel);
 if(!imp)return nil;
 id info=incoming?:FDSyntheticInfo();
 id result=((id(*)(id,SEL,id))imp)(self,sel,info);
 FDLog([NSString stringWithFormat:@"APPLIANCE_INIT_RETURN valid=%@",result?@"YES":@"NO"]);
 return result;
}
static id FDCategories(id self, SEL sel){
 Class cls=objc_getClass("BRApplianceCategory");
 SEL method=NSSelectorFromString(@"categoryWithName:identifier:preferredOrder:");
 if(!cls||![cls respondsToSelector:method])return @[];
 NSMethodSignature *sig=[cls methodSignatureForSelector:method];
 if(!sig||sig.numberOfArguments!=5 || strcmp([sig getArgumentTypeAtIndex:4],@encode(float)))return @[];
 NSInvocation *i=[NSInvocation invocationWithMethodSignature:sig];
 id name=@"Folia",identifier=@"foliadirect"; float order=7.0f;
 [i setTarget:cls];[i setSelector:method];
 [i setArgument:&name atIndex:2];[i setArgument:&identifier atIndex:3];[i setArgument:&order atIndex:4];
 [i invoke];
 id result=nil;[i getReturnValue:&result];
 return result?@[result]:@[];
}
static id FDControllerNew(){
 FDLog(@"CONTROLLER_NEW_ENTER");
 Class cls=objc_getClass("FoliaDirectController");
 id controller=cls?[[[cls alloc]init]autorelease]:nil;
 FDLog([NSString stringWithFormat:@"CONTROLLER_NEW_EXIT valid=%@",controller?@"YES":@"NO"]);
 return controller;
}
static id FDControllerForID(id self, SEL sel,id identifier,id args){
 return [identifier isEqual:@"foliadirect"]?FDControllerNew():nil;
}
static id FDApplianceController(id self, SEL sel){return FDControllerNew();}

static id FDLayer=nil;static NSTimer *FDStatusTimer=nil;
static void FDStatus(id self,SEL sel,id timer){
 AVSampleBufferDisplayLayer *layer=FDLayer;
 if(layer)FDLog([NSString stringWithFormat:@"LAYER_STATE status=%ld error=%@ bounds=%@",
   (long)layer.status,layer.error,NSStringFromCGRect(layer.bounds)]);
}
@interface FDStatusMonitor:NSObject
-(void)tick:(NSTimer*)timer;
@end
@implementation FDStatusMonitor
-(void)tick:(NSTimer*)timer {FDStatus(self,_cmd,timer);}
@end
static FDStatusMonitor *FDMonitor=nil;

static void FDRemove(){
 FDRemoteSetActive(NO);
 FDStreamStop();
 FDAudioStop();
 if(FDStatusTimer){[FDStatusTimer invalidate];[FDStatusTimer release];FDStatusTimer=nil;}
 if(FDLayer){[FDLayer removeFromSuperlayer];[FDLayer release];FDLayer=nil;}
 FDLog(@"STOPPED_VIDEO_LAYER");
}
static void FDStart(id controller){
 FDRemove();
 FDLifecycleStart();
 FDLog(@"CONTROLLER_ACTIVATED_HDMI_TEST");
 UIView *view=(UIView*)controller;
 if(![view respondsToSelector:@selector(layer)]){
  FDLog(@"NO_UIVIEW_LAYER");return;
 }
 // Continuous 720p30 FV01 compressed frames. No static fallback frame;
 // a missing server leaves an empty layer and background worker retries.
 AVSampleBufferDisplayLayer *layer=[AVSampleBufferDisplayLayer layer];
 if(layer){
  layer.frame=view.bounds;
  layer.videoGravity=AVLayerVideoGravityResizeAspect;
  [view.layer addSublayer:layer];
  FDLayer=[layer retain];
  FDLog([NSString stringWithFormat:@"LIVE_LAYER_ATTACHED bounds=%@",
    NSStringFromCGRect(view.bounds)]);
  FDStreamStart(layer);
  FDAudioStart();
  FDRemoteSetActive(YES);
  if(!FDMonitor)FDMonitor=[[FDStatusMonitor alloc]init];
  FDStatusTimer=[[NSTimer scheduledTimerWithTimeInterval:1.0
           target:FDMonitor selector:@selector(tick:)
           userInfo:nil repeats:YES]retain];
 }else FDLog(@"LIVE_LAYER_ALLOCATION_FAILED");
}
static id FDControllerInit(id self,SEL sel){
 FDLog(@"CONTROLLER_INIT_BEGIN");
 IMP imp=FDControllerSuper(sel);
 if(!imp){FDLog(@"CONTROLLER_INIT_MISSING_SUPER");return nil;}
 id result=((id(*)(id,SEL))imp)(self,sel);
 FDLog([NSString stringWithFormat:@"CONTROLLER_INIT_END valid=%@",result?@"YES":@"NO"]);
 return result;
}
static void FDActivated(id self,SEL sel){
 FDLog(@"CONTROLLER_ACTIVATE_ENTER");
 IMP imp=FDControllerSuper(sel);
 if(imp)((void(*)(id,SEL))imp)(self,sel);
 FDLog(@"CONTROLLER_ACTIVATE_SUPER_RETURN");
 FDStart(self);
}
static void FDDeactivated(id self,SEL sel){
 FDRemove();
 FDLifecycleSuspend();
 IMP imp=FDControllerSuper(sel);
 if(imp)((void(*)(id,SEL))imp)(self,sel);
}
static void FDPopped(id self,SEL sel){
 FDRemove();
 FDLifecycleSuspend();
 IMP imp=FDControllerSuper(sel);
 if(imp)((void(*)(id,SEL))imp)(self,sel);
}
static void FDDealloc(id self,SEL sel){
 FDRemove();
 FDLifecycleSuspend();
 IMP imp=FDControllerSuper(sel);
 if(imp)((void(*)(id,SEL))imp)(self,sel);
}
static BOOL FDRemoteEvent(id self,SEL sel,id event){
 return FDRemoteHandle(self,sel,event,FDControllerSuper(sel));
}
/* The AppleTV3 Beigelist entry is BLAppLegacyMerchant rootController, NOT
 * BRBaseAppliance.controllerForIdentifier:args: on this OS. Without the
 * targeted bridge the merchant routes to the legacy fallback and can abort.
 * Same mechanism verified in user's Jellyfin, Display, MusicVideo plugins.
 * Never affect any other bundle: forward unrelated invocations unchanged.
 */
static IMP fdOriginalLegacyRoot=NULL;
static id FDQueryObject(id obj,NSString *name) {
 if(!obj)return nil;
 SEL sel=NSSelectorFromString(name);
 NSMethodSignature *s=[obj methodSignatureForSelector:sel];
 if(!s || s.numberOfArguments!=2 || strcmp(s.methodReturnType,@encode(id)))return nil;
 return ((id(*)(id,SEL))objc_msgSend)(obj,sel);
}
// BLAppMerchantInfo's KVC is consumed by ATVMerchantAppliance. The
// valueForKey: hook is scoped to THIS merchant only and calls the previous
// implementation for every other app, preserving Jellyfin/Clock hooks.
static IMP fdPriorMerchantValueForKey=NULL;
static BOOL FDIsOurMerchantInfo(id info){
 id key=FDQueryObject(info,@"merchantID");
 return [key isKindOfClass:[NSString class]] &&
   [key isEqualToString:@"org.atv3.foliadirect"];
}
static id FDMerchantValueForKey(id self,SEL cmd,id key){
 if(FDIsOurMerchantInfo(self) && [key isKindOfClass:[NSString class]]){
  if([key isEqualToString:@"menu-icon-url"])return FDIconURLs();
  if([key isEqualToString:@"menu-icon-url-version"])return FDIconVersion();
  if([key isEqualToString:@"menu-title"])return @"Folia";
 }
 return fdPriorMerchantValueForKey
   ?((id(*)(id,SEL,id))fdPriorMerchantValueForKey)(self,cmd,key):nil;
}
static BOOL FDInstallMerchantIconBridge(void){
 Class cls=objc_getClass("BLAppMerchantInfo");
 if(!cls){FDLog(@"HOME_ICON_MERCHANT_CLASS_MISSING");return NO;}
 SEL sel=NSSelectorFromString(@"valueForKey:");
 Method m=class_getInstanceMethod(cls,sel);
 if(!m){FDLog(@"HOME_ICON_KVC_MISSING");return NO;}
 NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
 if(strcmp(sig.methodReturnType,@encode(id)) || sig.numberOfArguments!=3 ||
    strcmp([sig getArgumentTypeAtIndex:2],@encode(id))){
    FDLog(@"HOME_ICON_KVC_ABI_MISMATCH");return NO;
 }
 IMP current=method_getImplementation(m);
 if(!current)return NO;
 if(current==(IMP)FDMerchantValueForKey)return YES;
 fdPriorMerchantValueForKey=current;
 if(class_addMethod(cls,sel,(IMP)FDMerchantValueForKey,method_getTypeEncoding(m))){
   FDLog(@"HOME_ICON_KVC_OVERRIDE_ADDED");return YES;
 }
 Method local=class_getInstanceMethod(cls,sel);
 if(!local || method_getImplementation(local)!=current)return NO;
 IMP previous=method_setImplementation(local,(IMP)FDMerchantValueForKey);
 BOOL ok=previous==current;
 FDLog(ok?@"HOME_ICON_KVC_CHAINED":@"HOME_ICON_KVC_CHAIN_FAILED");
 return ok;
}
static BOOL FDIsOurLegacyMerchant(id merchant){
 id info=FDQueryObject(merchant,@"info");
 id mid=FDQueryObject(info,@"merchantID");
 if([mid isKindOfClass:[NSString class]] && [mid isEqual:@"org.atv3.foliadirect"])return YES;
 id identifier=FDQueryObject(merchant,@"identifier");
 if([identifier isKindOfClass:[NSString class]] &&
    ([identifier isEqual:@"org.atv3.foliadirect"] ||
     [identifier isEqual:@"merchant.org.atv3.foliadirect"]))return YES;
 SEL method=NSSelectorFromString(@"legacyApplianceClass");
 NSMethodSignature *signature=[merchant methodSignatureForSelector:method];
 if(signature && signature.numberOfArguments==2 &&
    !strcmp(signature.methodReturnType,@encode(Class)))
   return ((Class(*)(id,SEL))objc_msgSend)(merchant,method)==objc_getClass("FoliaDirectAppliance");
 return NO;
}
static id FDLegacyRoot(id self,SEL cmd){
 if(FDIsOurLegacyMerchant(self)){
  FDLog(@"LEGACY_ROOT_MATCH_FOLIADIRECT");
  return FDControllerNew();
 }
 return fdOriginalLegacyRoot
    ? ((id(*)(id,SEL))fdOriginalLegacyRoot)(self,cmd) : nil;
}
static BOOL FDInstallLegacyRoot(){
 Class cls=objc_getClass("BLAppLegacyMerchant");
 SEL sel=NSSelectorFromString(@"rootController");
 if(!cls){FDLog(@"LEGACY_MERCHANT_CLASS_NOT_FOUND");return NO;}
 Method m=class_getInstanceMethod(cls,sel);
 if(!m)return NO;
 const char *types=method_getTypeEncoding(m);
 NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:types];
 if(strcmp(sig.methodReturnType,@encode(id)) || sig.numberOfArguments!=2)return NO;
 IMP current=method_getImplementation(m);
 if(!current)return NO;
 if(current==(IMP)FDLegacyRoot)return YES;
 Class super=class_getSuperclass(cls);
 IMP inherited=super?class_getMethodImplementation(super,sel):NULL;
 if(inherited && current==inherited){
  if(class_addMethod(cls,sel,(IMP)FDLegacyRoot,types)){
   fdOriginalLegacyRoot=current;
   FDLog(@"LEGACY_ROOT_BRIDGE_ADDED");return YES;
  }
  return NO;
 }
 fdOriginalLegacyRoot=method_setImplementation(m,(IMP)FDLegacyRoot);
 BOOL ok=fdOriginalLegacyRoot!=NULL;
 FDLog(ok?@"LEGACY_ROOT_BRIDGE_INSTALLED":@"LEGACY_ROOT_BRIDGE_FAILED");
 return ok;
}
static BOOL FDRegister(void){
 if(objc_getClass("FoliaDirectAppliance")){
  BOOL icon=FDInstallMerchantIconBridge();
  BOOL root=FDInstallLegacyRoot();
  FDLog([NSString stringWithFormat:@"EXISTING_FOLIA_BRIDGES icon=%@ root=%@",icon?@"YES":@"NO",root?@"YES":@"NO"]);
  return root;
 }
 Class aBase=objc_getClass("BRBaseAppliance"),cBase=objc_getClass("BRController");
 if(!aBase||!cBase){FDLog(@"BASE_CLASSES_UNAVAILABLE");return NO;}
 Class a=objc_allocateClassPair(aBase,"FoliaDirectAppliance",0);
 Class c=objc_allocateClassPair(cBase,"FoliaDirectController",0);
 if(!a||!c)return NO;
 BOOL ok=FDAdd(a,@"initWithApplianceInfo:",(IMP)FDApplianceInit,@encode(id),@[@"@"]) &&
   FDAdd(a,@"applianceCategories",(IMP)FDCategories,@encode(id),@[]) &&
   FDAdd(a,@"controllerForIdentifier:args:",(IMP)FDControllerForID,@encode(id),@[@"@",@"@"]) &&
   FDAdd(a,@"applianceController",(IMP)FDApplianceController,@encode(id),@[]) &&
   FDAdd(c,@"brEventAction:",(IMP)FDRemoteEvent,@encode(BOOL),@[@"@"]) &&
   FDAdd(c,@"init",(IMP)FDControllerInit,@encode(id),@[]) &&
   FDAdd(c,@"controlWasActivated",(IMP)FDActivated,@encode(void),@[]) &&
   FDAdd(c,@"controlWasDeactivated",(IMP)FDDeactivated,@encode(void),@[]) &&
   FDAdd(c,@"wasPopped",(IMP)FDPopped,@encode(void),@[]) &&
   FDAdd(c,@"dealloc",(IMP)FDDealloc,@encode(void),@[]);
 if(!ok){
  FDLog(@"ABI_INCOMPATIBLE_NOT_REGISTERING");
  objc_disposeClassPair(c);objc_disposeClassPair(a);
  return NO;
 }
 objc_registerClassPair(c);objc_registerClassPair(a);
 BOOL icon=FDInstallMerchantIconBridge();
 BOOL linked=FDInstallLegacyRoot();
 FDLog([NSString stringWithFormat:@"FOLIADIRECT_BACKROW_CLASSES_REGISTERED root=%@ icon=%@",
  linked?@"YES":@"NO",icon?@"YES":@"NO"]);
 return linked;
}
__attribute__((constructor))static void FDEntry(void){
 @autoreleasepool{FDRegister();}
}