#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
extern NSString *FDPublicBridgeHost(void);
static volatile BOOL fdRemoteActive=NO;
static BOOL fdOKPressed=NO;
static NSTimeInterval fdOKAt=0;
static NSTimeInterval fdLastAt[32]={0};
static NSTimeInterval fdLastMenuAt=0;
static const NSTimeInterval FDMenuDoubleTapSeconds=0.65;
static void fdLog(NSString *s){
 FILE *f=fopen("/var/tmp/foliadirect_remote.log","a");
 if(!f)return;
 fprintf(f,"%.3f %s\n",[[NSDate date]timeIntervalSince1970],[s UTF8String]);
 fclose(f);
}
@interface FoliaDirectRemoteWorker:NSObject
-(void)deliver:(NSString*)command;
@end
@implementation FoliaDirectRemoteWorker
-(void)deliver:(NSString*)command {
 NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
 NSString *host=FDPublicBridgeHost();
 if(![host length]){[pool drain];return;}
 NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"http://%@:18782/control",host]];
 NSData *body=[NSJSONSerialization dataWithJSONObject:@{@"command":command}
           options:0 error:NULL];
 NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:url
    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1];
 [r setHTTPMethod:@"POST"];
 [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
 [r setHTTPBody:body];
 NSTimeInterval start=[NSDate timeIntervalSinceReferenceDate];
 NSURLResponse *res=nil;
 NSError *err=nil;
 NSData *data=[NSURLConnection sendSynchronousRequest:r returningResponse:&res error:&err];
 NSInteger status=[res isKindOfClass:NSHTTPURLResponse.class]
   ?[(NSHTTPURLResponse*)res statusCode]:0;
 fdLog([NSString stringWithFormat:@"DELIVER command=%@ HTTP=%ld ms=%.1f len=%lu error=%@",
   command,(long)status,([NSDate timeIntervalSinceReferenceDate]-start)*1000,
   (unsigned long)data.length,err?:@"none"]);
 [pool drain];
}
@end
static FoliaDirectRemoteWorker *worker=nil;
void FDRemoteSetActive(BOOL enabled){
 fdRemoteActive=enabled;
 if(!enabled){fdOKPressed=NO;fdOKAt=0;}
 else fdLog(@"REMOTE_CONTROLLER_ACTIVE");
}
static BOOL eventInt(id event,NSString *name,int *output){
 if(!event || !output)return NO;
 SEL sel=NSSelectorFromString(name);
 NSMethodSignature *sig=[event methodSignatureForSelector:sel];
 if(!sig || sig.numberOfArguments!=2)return NO;
 const char *t=sig.methodReturnType;
 BOOL isLong=t && !strcmp(t,@encode(NSInteger));
 BOOL isInt=t && !strcmp(t,@encode(int));
 if(!isLong&&!isInt)return NO;
 NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];
 [inv setTarget:event];[inv setSelector:sel];[inv invoke];
 if(isLong){NSInteger v=0;[inv getReturnValue:&v];*output=(int)v;}
 else {int v=0;[inv getReturnValue:&v];*output=v;}
 return YES;
}
BOOL FDRemoteHandle(id self,SEL sel,id event,IMP inherited) {
 if(!fdRemoteActive){
   return inherited?((BOOL(*)(id,SEL,id))inherited)(self,sel,event):NO;
 }
 int action=-1,value=-1,origin=-1;
 BOOL known=eventInt(event,@"remoteAction",&action);
 BOOL haveValue=eventInt(event,@"value",&value);
 BOOL haveOrigin=eventInt(event,@"originator",&origin);
 if(!known || (haveOrigin && origin!=1 && origin!=3)){
   return inherited?((BOOL(*)(id,SEL,id))inherited)(self,sel,event):NO;
 }
 BOOL down=(!haveValue||value==1);
 NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
 // Single Menu goes BACK inside original Mac Folia (real Escape behavior).
 // Two deliberate rapid Menu presses retain the OS's return-to-home path.
 // Action 1 is documented by this ATV's previous real event logs:
 // remoteAction=1 value=1. Action 2 is release/alternate Menu and must not
 // trigger another back request.
 if(action==1||action==2){
   if(action==1 && down){
     BOOL doubleTap=fdLastMenuAt>0 && now-fdLastMenuAt<FDMenuDoubleTapSeconds;
     fdLastMenuAt=doubleTap?0:now;
     if(doubleTap){
       fdLog(@"MENU_DOUBLE_TAP native AppleTV home");
       return inherited?((BOOL(*)(id,SEL,id))inherited)(self,sel,event):NO;
     }
     if(!worker)worker=[[FoliaDirectRemoteWorker alloc]init];
     [NSThread detachNewThreadSelector:@selector(deliver:)
       toTarget:worker withObject:@"key-back"];
     fdLog(@"MENU_SINGLE_FOLIA_BACK command=key-back");
   }
   return YES;  // NEVER let one Menu press pop BRController to ATV Home
 }
 NSString *command=nil;
 switch(action){
  case 3:if(down)command=@"key-up";break;
  case 4:if(down)command=@"key-down";break;
  case 6:if(down)command=@"key-left";break;
  case 7:if(down)command=@"key-right";break;
  case 5:if(down)command=@"key-select";break;
  case 9:if(down)command=@"previous";break;
  case 10:if(down)command=@"play-pause";break;
  case 12:if(down)command=@"next";break;
  case 22:if(down){fdOKPressed=YES;fdOKAt=now;}break;
  case 23:
   if(fdOKPressed && now-fdOKAt<0.8)command=@"key-select";
   fdOKPressed=NO;break;
  default:break;
 }
 if(command){
   if(action<0 || action>=32 || now-fdLastAt[action]>0.09){
     if(action>=0&&action<32)fdLastAt[action]=now;
     if(!worker)worker=[[FoliaDirectRemoteWorker alloc]init];
     [NSThread detachNewThreadSelector:@selector(deliver:)
       toTarget:worker withObject:command];
     fdLog([NSString stringWithFormat:@"LOCAL_REMOTE action=%d value=%d key=%@",action,value,command]);
   }
 }
 switch(action){
  case 3:case 4:case 5:case 6:case 7:
  case 9:case 10:case 11:case 12:case 22:case 23:case 24:
   return YES;
  default:break;
 }
 return inherited?((BOOL(*)(id,SEL,id))inherited)(self,sel,event):NO;
}
