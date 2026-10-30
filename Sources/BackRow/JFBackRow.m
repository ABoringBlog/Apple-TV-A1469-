#import "JFBackRow.h"
#import "JFBRMenu.h"
#import "JFPosterTrace.h"
#import "JFUIController.h"
#import "../Input/JFRemote.h"
#import "../Playback/JFATV3PlaybackBackend.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
static char remoteKey, menuKey, mobileGestureKey;
// The 12H1006 touch remote reports touch begin/move/end (32/33/34),
// then a directional gesture action and a terminal event (39..42).
// Model navigation must occur at most once per phone gesture. These are
// appliance-owned objects: do NOT modify BackRow or other applications.
@interface JFMobileGestureState : NSObject {
@public
    BOOL touching;
    NSTimeInterval lastTouchAt, lastNativeAt, lastGestureAt;
    NSInteger lastNativeButton, lastGestureButton;
    id selectController; // Assign: controller owns this state; cancelled on exit.
    BOOL selectPending;
    NSInteger seenPage, selectArmedOnPage;
    BOOL pageKnown, firstPhoneSelectGuard, nativeLibrarySelectArmed;
}
- (void)armSelectForController:(id)controller;
- (void)cancelPendingSelect;
@end
@implementation JFMobileGestureState
- (void)armSelectForController:(id)controller {
    // Phone touchpads can emit a Select just before a swipe. Do not activate
    // media content until we know the gesture did not follow.
    if (selectPending) return; // duplicate Select within a pending touch burst
    selectController=controller;
    JFUIController *ui=(JFUIController *)objc_getAssociatedObject(controller,&menuKey);
    selectArmedOnPage=ui ? [ui phoneRemotePage] : -1;
    selectPending=YES;
    [self performSelector:@selector(deliverPendingSelect) withObject:nil afterDelay:0.35];
}
- (void)cancelPendingSelect {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(deliverPendingSelect) object:nil];
    selectPending=NO;
    selectController=nil;
}
- (void)deliverPendingSelect {
    if (!selectPending || !selectController) return;
    id controller=selectController;
    NSInteger oldPage=selectArmedOnPage;
    selectPending=NO;selectController=nil;
    JFUIController *ui=(JFUIController *)objc_getAssociatedObject(controller,&menuKey);
    if (!ui || [ui phoneRemotePage]!=oldPage) {
        JFPosterTrace(@"PHONE_SELECT_DROPPED_PAGE_CHANGED");
        return;
    }
    JFBRMenu *menu=objc_getAssociatedObject(controller,&menuKey);
    if (menu) {
        JFPosterTrace(@"PHONE_SELECT_CONFIRMED");
        (void)[menu handleEvent:@{@"button":@(JFSelect),@"phase":@"press"}];
    }
}
@end

static NSInteger JFMobileSwipeButton(NSInteger action) {
    switch(action) {
        case 39:return JFLeft;
        case 40:return JFRight;
        case 41:return JFUp;
        case 42:return JFDown;
        default:return JFUnknown;
    }
}
static JFMobileGestureState *JFMobileState(id controller) {
    JFMobileGestureState *state=objc_getAssociatedObject(controller,&mobileGestureKey);
    if (!state) {
        state=[[[JFMobileGestureState alloc] init] autorelease];
        objc_setAssociatedObject(controller,&mobileGestureKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}
void JFBRResetRemoteForPageChange(id controller) {
    if (!controller) return;
    objc_setAssociatedObject(controller,&remoteKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    JFMobileGestureState *state=objc_getAssociatedObject(controller,&mobileGestureKey);
    // Clear only held buttons and postponed activation, not the origin of
    // the event which navigated from Libraries to Media. That origin is needed
    // to discard the 12H1006 late origin3 Select echo on the next page.
    if (state) {
        [state cancelPendingSelect];
        state->touching=NO;
        state->lastNativeAt=0;
        state->lastGestureAt=0;
        state->lastNativeButton=0;
        state->lastGestureButton=0;
    }
}
void JFBRClearRemoteState(id controller) {
    if (controller) {
        JFBRResetRemoteForPageChange(controller);
        objc_setAssociatedObject(controller,&mobileGestureKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
static BOOL menuEnabled;
static BOOL Signature(id target, SEL sel, const char *result, NSArray *args) {
    if (![target respondsToSelector:sel]) return NO;
    NSMethodSignature *s = [target methodSignatureForSelector:sel];
    if (!s || strcmp([s methodReturnType],result) || [s numberOfArguments] != [args count]+2) return NO;
    for (NSUInteger i=0;i<[args count];i++) if (strcmp([s getArgumentTypeAtIndex:i+2],[[args objectAtIndex:i] UTF8String])) return NO;
    return YES;
}
id JFBRObject(id target, NSString *name) {
    SEL sel=NSSelectorFromString(name);
    if (!Signature(target,sel,@encode(id),@[])) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(target,sel);
}
id JFBRObjectWithObject(id target, NSString *name, id argument) {
    SEL sel=NSSelectorFromString(name);
    if (!Signature(target,sel,@encode(id),@[@"@"])) return nil;
    return ((id(*)(id,SEL,id))objc_msgSend)(target,sel,argument);
}
// 12H1006 BREvent: action/value int32, originator uint32.
// Phone swipes produce many touch-move events. The old path allocated an
// NSInvocation and verified all three signatures MULTIPLE TIMES per event.
// Verify the exact firmware ABI once for each concrete event class, then read
// its three integer getters once. Do not weaken the incompatible-ABI guard.
static BOOL JFDecodeEvent(id event,NSInteger *origin,NSInteger *action,NSInteger *value) {
    static Class lastClass=Nil;
    static BOOL lastValid=NO;
    Class cls=object_getClass(event);
    if (!cls || !event) return NO;
    if (cls!=lastClass) {
        lastValid=Signature(event,NSSelectorFromString(@"originator"),@encode(unsigned),@[]) &&
                  Signature(event,NSSelectorFromString(@"remoteAction"),@encode(int),@[]) &&
                  Signature(event,NSSelectorFromString(@"value"),@encode(int),@[]);
        lastClass=cls;
    }
    if(!lastValid)return NO;
    *origin=((unsigned(*)(id,SEL))objc_msgSend)(event,NSSelectorFromString(@"originator"));
    *action=((int(*)(id,SEL))objc_msgSend)(event,NSSelectorFromString(@"remoteAction"));
    *value=((int(*)(id,SEL))objc_msgSend)(event,NSSelectorFromString(@"value"));
    return YES;
}
// Keep source event timestamps for first touch/completed swipes. This is
// logging only: BREvent.timeStamp can use a different clock on some firmware.
static void JFTraceSourceTime(id event,NSInteger origin,NSInteger action) {
    // Modern phone remotes can synthesize origin=1 traditional key events,
    // so capture their BREvent producer timestamps too. Skip high-rate moves.
    if((origin!=1 && origin!=3) ||
       !(action==1 || action==3 || action==4 || action==5 ||
         action==6 || action==7 || action==32 || action==34 ||
         action==39 || action==40 || action==41 || action==42))return;
    SEL sel=NSSelectorFromString(@"timeStamp");
    static Class timestampClass=Nil;
    static BOOL timestampValid=NO;
    Class cls=object_getClass(event);
    if(cls!=timestampClass) {
        timestampValid=Signature(event,sel,@encode(double),@[]);
        timestampClass=cls;
    }
    if(!timestampValid)return;
    double stamp=((double(*)(id,SEL))objc_msgSend)(event,sel);
    JFPosterTrace([NSString stringWithFormat:
        @"REMOTE_SOURCE_TIME origin=%ld action=%ld source=%.3f received_uptime=%.3f",
        (long)origin,(long)action,stamp,[NSProcessInfo processInfo].systemUptime]);
}static IMP ControllerSuper(SEL selector) {
    Class base=class_getSuperclass(objc_getClass("JellyfinController"));
    return class_getMethodImplementation(base,selector);
}
static IMP ApplianceSuper(SEL selector) {
    Class base=class_getSuperclass(objc_getClass("JellyfinAppliance"));
    return class_getMethodImplementation(base,selector);
}
static NSString *JFMenuIconURL(void) {
    NSBundle *bundle=[NSBundle bundleWithIdentifier:@"org.jellyfin.atv3"];
    NSString *path=[bundle pathForResource:@"AppIcon" ofType:@"png"];
    if (!path.length) path=@"/Applications/Jellyfin.frappliance/AppIcon.png";
    return [[NSURL fileURLWithPath:path] absoluteString];
}
static id InfoMenuIconURLs(id self, SEL cmd) {
    NSString *url=JFMenuIconURL();
    if (!url.length) return @{};
    return @{
        @"720":url, @"1080":url,
        [NSNumber numberWithInteger:720]:url,
        [NSNumber numberWithInteger:1080]:url
    };
}
static id InfoMenuIconURLVersion(id self, SEL cmd) {
    NSBundle *bundle=[NSBundle bundleWithIdentifier:@"org.jellyfin.atv3"];
    id version=[bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    return [version isKindOfClass:[NSString class]] && [version length] ? version : @"1";
}
static Class JellyfinApplianceInfoClass(void) {
    Class existing=objc_getClass("JellyfinApplianceInfo");
    if (existing) return existing;
    Class base=objc_getClass("BRApplianceInfo");
    if (!base) return Nil;
    Method urlsMethod=class_getInstanceMethod(base,NSSelectorFromString(@"menuIconURLs"));
    Method versionMethod=class_getInstanceMethod(base,NSSelectorFromString(@"menuIconURLVersion"));
    if (!urlsMethod || !versionMethod) return Nil;
    Class cls=objc_allocateClassPair(base,"JellyfinApplianceInfo",0);
    if (!cls) return Nil;
    BOOL ok=class_addMethod(cls,NSSelectorFromString(@"menuIconURLs"),(IMP)InfoMenuIconURLs,method_getTypeEncoding(urlsMethod)) &&
        class_addMethod(cls,NSSelectorFromString(@"menuIconURLVersion"),(IMP)InfoMenuIconURLVersion,method_getTypeEncoding(versionMethod));
    if (!ok) { objc_disposeClassPair(cls); return Nil; }
    objc_registerClassPair(cls);
    return cls;
}
static id SyntheticApplianceInfo(void) {
    Class infoClass=JellyfinApplianceInfoClass();
    if (!infoClass) return nil;
    id info=[infoClass alloc];
    SEL init=NSSelectorFromString(@"_initWithMutableDictionary:");
    if (!Signature(info,init,@encode(id),@[@"@"])) { [info release]; return nil; }
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    [values setObject:@"jellyfin" forKey:@"FRApplianceIdentifier"];
    [values setObject:@"Jellyfin" forKey:@"FRApplianceName"];
    [values setObject:@5 forKey:@"FRAppliancePreferedOrderValue"];
    [values setObject:@"JellyfinAppliance" forKey:@"FRPrincipalClass"];
    [values setObject:@NO forKey:@"FRHideIfNoCategories"];
    [values setObject:@[] forKey:@"FRApplianceSupportedMediaTypes"];
    [values setObject:@[] forKey:@"FRApplianceRequiredRemoteMediaTypes"];
    // init may return nil or a replacement; autorelease only its returned object.
    info=((id(*)(id,SEL,id))objc_msgSend)(info,init,values);
    return [info autorelease];
}
static id ApplianceInitWithInfo(id self, SEL cmd, id incoming) {
    id info=incoming ?: SyntheticApplianceInfo();
    self=((id(*)(id,SEL,id))ApplianceSuper(cmd))(self,cmd,info);
    return self;
}
static id MenuInit(id self, SEL cmd) {
    self=((id(*)(id,SEL))ControllerSuper(cmd))(self,cmd);
    if (self) {
        JFUIController *menu=[[[JFUIController alloc] initWithController:self] autorelease];
        BOOL canRender=[menu canRender];
        if (!canRender) { [menu close]; [self release]; return nil; }

        // Playback stays absent on unknown firmware. On verified 12H1006 ABI,
        // configure the native adapter before the controller becomes visible.
        if ([JFATV3PlaybackBackend runtimeCompatible]) {
            JFATV3PlaybackBackend *backend=[[JFATV3PlaybackBackend alloc] initWithHostController:self];
            (void)[menu configurePlaybackBackend:backend];
            [backend release];
        }
        objc_setAssociatedObject(self,&menuKey,menu,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}
// Scoped BackRow screensaver suppression, based on the ATVSettingsFacade ABI.
static BOOL appSaverHeld=NO;
static NSInteger appSaverOriginal=0;
static id AppSaverFacade(void) {
    Class cls=objc_getClass("ATVSettingsFacade");
    if(!cls || ![cls respondsToSelector:NSSelectorFromString(@"singleton")])return nil;
    id settings=((id(*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"singleton"));
    if(![settings respondsToSelector:NSSelectorFromString(@"screenSaverTimeout")] ||
       ![settings respondsToSelector:NSSelectorFromString(@"setScreenSaverTimeout:")])return nil;
    return settings;
}
static void AppSaverSet(BOOL inhibit) {
    id settings=AppSaverFacade();if(!settings)return;
    if(inhibit && !appSaverHeld) {
        appSaverOriginal=((int(*)(id,SEL))objc_msgSend)(settings,NSSelectorFromString(@"screenSaverTimeout"));
        appSaverHeld=YES;
        ((void(*)(id,SEL,int))objc_msgSend)(settings,NSSelectorFromString(@"setScreenSaverTimeout:"),-1);
    } else if(!inhibit && appSaverHeld) {
        ((void(*)(id,SEL,int))objc_msgSend)(settings,NSSelectorFromString(@"setScreenSaverTimeout:"),(int)appSaverOriginal);
        appSaverHeld=NO;
    }
    if([settings respondsToSelector:NSSelectorFromString(@"flushDiskChanges")])
        ((void(*)(id,SEL))objc_msgSend)(settings,NSSelectorFromString(@"flushDiskChanges"));
}

static void Activated(id self, SEL cmd) {
    AppSaverSet(YES);
    ((void(*)(id,SEL))ControllerSuper(cmd))(self,cmd);
    JFBRMenu *menu=(JFBRMenu *)objc_getAssociatedObject(self,&menuKey);
    [menu activate];
}
static void Deactivated(id self, SEL cmd) {
    AppSaverSet(NO);
    [objc_getAssociatedObject(self,&menuKey) deactivate];
    JFBRClearRemoteState(self);
    ((void(*)(id,SEL))ControllerSuper(cmd))(self,cmd);
}
static void Popped(id self, SEL cmd) {
    JFBRClearRemoteState(self);
    [objc_getAssociatedObject(self,&menuKey) close];
    ((void(*)(id,SEL))ControllerSuper(cmd))(self,cmd);
}
static void ControllerDealloc(id self, SEL cmd) {
    [objc_getAssociatedObject(self,&menuKey) close];
    objc_setAssociatedObject(self,&menuKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    JFBRClearRemoteState(self);
    ((void(*)(id,SEL))ControllerSuper(cmd))(self,cmd);
}
static void ItemSelected(id self, SEL cmd, long row) { (void)self; (void)cmd; (void)row; }
static id Preview(id self, SEL cmd, long row) {
    JFPosterTrace([NSString stringWithFormat:@"BR_PREVIEW_CALL row=%ld",row]);
    id result=[objc_getAssociatedObject(self,&menuKey) previewControlForRow:row];
    JFPosterTrace([NSString stringWithFormat:@"BR_PREVIEW_RETURN row=%ld control=%d",row,result!=nil]);
    return result;
}
static BOOL Event(id self,SEL cmd,id event) {
    if (![NSThread isMainThread]) return NO;
    NSInteger action=0,value=0,origin=0;
    BOOL decoded=JFDecodeEvent(event,&origin,&action,&value);
    if (decoded) {
        // Action 33 is unbounded touch-motion telemetry, never a discrete key.
        // Synchronous logging of every 33 slowed the Apple A5 phone path.
        if(!(origin==3 && action==33))
            JFPosterTrace([NSString stringWithFormat:
                @"REMOTE_PROBE origin=%ld action=%ld value=%ld uptime_ms=%lld",
                (long)origin,(long)action,(long)value,
                (long long)([NSProcessInfo processInfo].systemUptime*1000.0)]);
        JFTraceSourceTime(event,origin,action);
    }
    // Never apply an input Select from the previous model page to a new page.
    // In particular, the first phone Select after Libraries -> Media is not a
    // reliable deliberate click: 12H1006 delivers it before a swipe burst, even
    // after the old 350ms timer has already fired. Treat that *one* Select as
    // untrusted until we see a fresh direction gesture or another explicit tap.
    if (decoded && (origin==1 || origin==3)) {
        JFMobileGestureState *state=JFMobileState(self);
        JFUIController *ui=(JFUIController *)objc_getAssociatedObject(self,&menuKey);
        NSInteger page=ui ? [ui phoneRemotePage] : -1;
        if (!state->pageKnown || page!=state->seenPage) {
            NSInteger previous=state->pageKnown ? state->seenPage : -1;
            if (state->selectPending) {
                [state cancelPendingSelect];
                JFPosterTrace(@"PHONE_SELECT_DROPPED_PAGE_TRANSITION");
            }
            state->pageKnown=YES;
            state->seenPage=page;
            state->firstPhoneSelectGuard=(page==3 && previous==1 &&
                state->nativeLibrarySelectArmed);
            state->nativeLibrarySelectArmed=NO;
            JFPosterTrace([NSString stringWithFormat:
                @"REMOTE_PAGE_CHANGED from=%ld to=%ld guard=%d uptime_ms=%lld",
                (long)previous,(long)page,state->firstPhoneSelectGuard,
                (long long)([NSProcessInfo processInfo].systemUptime*1000.0)]);
        }
        // A native Select on Libraries may leave a delayed origin3 echo on Media.
        // A pure phone-origin library entry must not disable the first real tap.
        if (decoded && action==5 &&
            decoded && value==1 &&
            origin==1 && page==1)
            state->nativeLibrarySelectArmed=YES;
    }
    // Phone touch DMAP action 32/33/34 = contact tracking; 35..38 = directional
    // intermediate events; 39..42 are completed directional gestures.
    // Previously these fell through to native BackRow: its list focus moved,
    // but our Jellyfin model focus stayed behind. Other apps are never touched.
    if (decoded && origin==3 &&
        decoded &&
        action>=30 && action<=42) {
        JFMobileGestureState *state=JFMobileState(self);
        NSTimeInterval now=[NSProcessInfo processInfo].systemUptime;
        // A new contact proves intent to navigate on this grid.
        if (state->firstPhoneSelectGuard) {
            state->firstPhoneSelectGuard=NO;
            JFPosterTrace(@"PHONE_MEDIA_GUARD_RELEASED_BY_TOUCH");
        }
        // Any touch/gesture after a Select is proof the user meant to swipe.
        if (state->selectPending) {
            [state cancelPendingSelect];
            JFPosterTrace(@"PHONE_SELECT_CANCELLED_BY_GESTURE");
        }
        if (action==32) { state->touching=YES;state->lastTouchAt=now; }
        if (action==34) state->touching=NO;
        NSInteger swipe=JFMobileSwipeButton(action);
        if (swipe!=JFUnknown && value==1) {
            BOOL duplicate=(state->lastGestureButton==swipe && now-state->lastGestureAt<0.18) ||
                           (state->lastNativeButton==swipe &&
                            now-state->lastNativeAt>=0 && now-state->lastNativeAt<0.45);
            if (!duplicate) {
                JFBRMenu *menu=objc_getAssociatedObject(self,&menuKey);
                if (menu) (void)[menu handleEvent:@{@"button":@(swipe),@"phase":@"press"}];
                state->lastGestureAt=now;state->lastGestureButton=swipe;
                JFPosterTrace([NSString stringWithFormat:@"PHONE_GESTURE_NAV action=%ld button=%ld",
                               (long)action,(long)swipe]);
            } else JFPosterTrace(@"PHONE_GESTURE_DEDUP");
        }
        return YES; // Do not let native list focus drift independently.
    }
    // A standalone phone click produces action 5 without necessarily sending
    // a release. Schedule one Select after a short gesture-identification
    // window; a following touch begin/move/swipe cancels it.
    if (decoded && origin==3 &&
        decoded && action==5 &&
        decoded) {
        if (value==1) {
            JFMobileGestureState *state=JFMobileState(self);
            if (state->firstPhoneSelectGuard) {
                state->firstPhoneSelectGuard=NO;
                JFPosterTrace(@"PHONE_FIRST_MEDIA_SELECT_SUPPRESSED");
            } else {
                [state armSelectForController:self];
                JFPosterTrace(@"PHONE_SELECT_PENDING");
            }
        }
        return YES;
    }
    // Native-origin directional events remain authoritative for the physical
    // remote. Some firmware also emits them as a phone swipe's duplicate.
    if (decoded && origin==1 &&
        decoded &&
        value==1 && (action==3 || action==4 || action==6 || action==7)) {
        NSInteger b=action==3?JFUp:action==4?JFDown:action==6?JFLeft:JFRight;
        JFMobileGestureState *state=objc_getAssociatedObject(self,&mobileGestureKey);
        NSTimeInterval now=[NSProcessInfo processInfo].systemUptime;
        if (state) {
            if (state->selectPending) {
                [state cancelPendingSelect];
                JFPosterTrace(@"PHONE_SELECT_CANCELLED_BY_DIRECTION");
            }
            BOOL duplicate=(state->touching && state->lastGestureButton==b &&
                            now-state->lastGestureAt>=0 && now-state->lastGestureAt<0.45);
            if (duplicate) {
                JFPosterTrace(@"PHONE_NATIVE_DIRECTION_DEDUP");
                return YES;
            }
            // Track an early synthesized directional event while a phone touch
            // is in flight; its later terminal gesture must not repeat movement.
            if (state->touching && now-state->lastTouchAt>=0 && now-state->lastTouchAt<1.5) {
                state->lastNativeAt=now;state->lastNativeButton=b;
            }
        }
    }
    // Network DMAP sends synthesized clicks. Route to Jellyfin's model-owned
    // focus and selection; BackRow's native visual focus is not the model index.
    if (decoded && (origin==1 || origin==3) &&
        decoded) {
        NSInteger b=0;
        switch(action) { case 1:b=JFMenu;break; case 3:b=JFUp;break;
            case 4:b=JFDown;break; case 5:b=JFSelect;break;
            case 6:b=JFLeft;break; case 7:b=JFRight;break; default:break; }
        if (origin==1 && action==5 && value==1) {
            JFMobileGestureState *state=objc_getAssociatedObject(self,&mobileGestureKey);
            if (state && state->selectPending) [state cancelPendingSelect];
            id list=JFBRObject(self,@"list");
            for (NSString *method in @[@"selection",@"selectedIndex",@"selectedRow"]) {
                NSMethodSignature *sig=[list methodSignatureForSelector:NSSelectorFromString(method)];
                if (!sig || sig.numberOfArguments!=2) continue;
                const char *type=sig.methodReturnType;
                if (strcmp(type,@encode(long)) && strcmp(type,@encode(int)) && strcmp(type,@encode(NSInteger))) continue;
                NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];
                inv.target=list; inv.selector=NSSelectorFromString(method); [inv invoke];
                long index=0;
                if (!strcmp(type,@encode(int))) {int v=0; [inv getReturnValue:&v];index=v;}
                else [inv getReturnValue:&index];
                JFPosterTrace([NSString stringWithFormat:@"NATIVE_FOCUS method=%@ index=%ld",method,index]);
                if ([method isEqualToString:@"selection"] && index>=0) {
                    JFUIController *ui=(JFUIController *)objc_getAssociatedObject(self,&menuKey);
                    [ui synchronizeNativeSelection:index];
                    break;
                }
            }
        }
        if (b && (value==1 || (value==2 && (b==JFUp || b==JFDown)))) {
            JFBRMenu *menu=objc_getAssociatedObject(self,&menuKey);
            NSTimeInterval modelStart=[NSProcessInfo processInfo].systemUptime;
            JFHostEventResult result=menu ? [menu handleEvent:@{@"button":@(b),@"phase":value==2 ? @"repeat" : @"press"}] : JFHostEventUnhandled;
            NSTimeInterval modelMS=([NSProcessInfo processInfo].systemUptime-modelStart)*1000.0;
            if(modelMS>30.0)
                JFPosterTrace([NSString stringWithFormat:
                    @"REMOTE_MODEL_SLOW origin=%ld action=%ld value=%ld duration_ms=%lld",
                    (long)origin,(long)action,(long)value,(long long)modelMS]);
            if (result==JFHostEventConsumed) return YES;
            if (result==JFHostEventExitRequested && b==JFMenu) {
                Method native=class_getInstanceMethod(class_getSuperclass(objc_getClass("JellyfinController")),cmd);
                return native ? ((BOOL(*)(id,SEL,id))method_getImplementation(native))(self,cmd,event) : NO;
            }
        }
        if (b) return YES;
    }
    if (decoded && (origin==1 || origin==3) && decoded) {
        JFRemote *remote=objc_getAssociatedObject(self,&remoteKey);
        if (!remote) { remote=[[[JFRemote alloc] init] autorelease]; objc_setAssociatedObject(self,&remoteKey,remote,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        NSDictionary *e=[remote action:action value:value time:[NSProcessInfo processInfo].systemUptime];
        if (e) {
            JFBRMenu *menu=objc_getAssociatedObject(self,&menuKey);
            if (menu) {
                JFHostEventResult result=[menu handleEvent:e];
                if (result==JFHostEventConsumed) return YES;
                if (result==JFHostEventUnhandled) return NO;
            } else [[NSNotificationCenter defaultCenter] postNotificationName:@"JFRemoteEvent" object:self userInfo:e];
            if ([[e objectForKey:@"button"] integerValue]==JFMenu && [[e objectForKey:@"phase"] isEqual:@"press"]) {
                // At the appliance root, let BackRow's native controller/navigation
                // chain own Menu dismissal. A direct synchronous stack pop from inside
                // brEventAction: is not reliable after list focus has changed on 12H1006.
                Method native=class_getInstanceMethod(class_getSuperclass(objc_getClass("JellyfinController")),cmd);
                return native ? ((BOOL(*)(id,SEL,id))method_getImplementation(native))(self,cmd,event) : NO;
            } else return YES;
        }
    }
    Method m=class_getInstanceMethod(class_getSuperclass(objc_getClass("JellyfinController")),cmd);
    return m ? ((BOOL(*)(id,SEL,id))method_getImplementation(m))(self,cmd,event) : NO;
}
static BOOL CategoryAvailable(void) {
    return Signature(objc_getClass("BRApplianceCategory"),
        NSSelectorFromString(@"categoryWithName:identifier:preferredOrder:"),@encode(id),@[@"@",@"@",@"f"]);
}
static id Categories(id self,SEL cmd) {
    if (!CategoryAvailable()) { NSLog(@"Jellyfin: category float ABI unavailable"); return @[]; }
    Class c=objc_getClass("BRApplianceCategory"); SEL s=NSSelectorFromString(@"categoryWithName:identifier:preferredOrder:");
    NSInvocation *v=[NSInvocation invocationWithMethodSignature:[c methodSignatureForSelector:s]];
    [v setTarget:c]; [v setSelector:s];
    id name=@"Jellyfin",identifier=@"jellyfin"; float order=0.0f;
    [v setArgument:&name atIndex:2]; [v setArgument:&identifier atIndex:3]; [v setArgument:&order atIndex:4];
    [v invoke]; id result=nil; [v getReturnValue:&result];
    return result ? @[result] : @[];
}
static id Controller(id self,SEL cmd,id identifier,id args) {
    if (![identifier isEqual:@"jellyfin"]) return nil;
    id controller=[JFBRNew(objc_getClass("JellyfinController")) autorelease];
    return controller;
}
static id ApplianceController(id self, SEL cmd) {
    id controller=[JFBRNew(objc_getClass("JellyfinController")) autorelease];
    return controller;
}
static IMP jfOriginalLegacyRootController;
static IMP jfLegacyApplianceClass;
static SEL jfLegacyApplianceClassSelector;
static id JFOriginalLegacyRootController(id self, SEL cmd) {
    return jfOriginalLegacyRootController ?
        ((id(*)(id,SEL))jfOriginalLegacyRootController)(self,cmd) : nil;
}
static id JFLegacyRootController(id self, SEL cmd) {
    // BLAppLegacyMerchant is shared by every legacy appliance. Keep the
    // non-Jellyfin path to one ABI-verified class getter and immediately tail
    // back into Beigelist's original IMP; do not inspect info/identifier or
    // invoke any appliance-owned selectors on foreign merchants.
    if (!jfLegacyApplianceClass || !jfLegacyApplianceClassSelector) return JFOriginalLegacyRootController(self,cmd);
    id legacyClass=((id(*)(id,SEL))jfLegacyApplianceClass)(self,jfLegacyApplianceClassSelector);
    if (legacyClass!=(id)objc_getClass("JellyfinAppliance")) return JFOriginalLegacyRootController(self,cmd);
    id controller=[JFBRNew(objc_getClass("JellyfinController")) autorelease];
    return controller ?: JFOriginalLegacyRootController(self,cmd);
}
static BOOL JFInstallLegacyRootBridge(void) {
    Class cls=objc_getClass("BLAppLegacyMerchant");
    if (!cls) return NO;

    // 12H1006 Beigelist's loader uses -legacyApplianceClass before constructing
    // the appliance. Gate and cache that exact getter once; if its ABI is not
    // the audited object/Class-returning no-argument form, do not install the
    // global rootController bridge.
    SEL legacySel=NSSelectorFromString(@"legacyApplianceClass");
    Method legacyMethod=class_getInstanceMethod(cls,legacySel);
    if (!legacyMethod) return NO;
    NSMethodSignature *legacySig=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(legacyMethod)];
    const char *legacyReturn=[legacySig methodReturnType];
    if ([legacySig numberOfArguments]!=2 ||
        (strcmp(legacyReturn,@encode(id)) && strcmp(legacyReturn,@encode(Class)))) return NO;
    IMP legacyIMP=method_getImplementation(legacyMethod);
    if (!legacyIMP) return NO;
    jfLegacyApplianceClass=legacyIMP;
    jfLegacyApplianceClassSelector=legacySel;

    SEL sel=NSSelectorFromString(@"rootController");
    Method method=class_getInstanceMethod(cls,sel);
    if (!method) return NO;
    const char *encoding=method_getTypeEncoding(method);
    NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:encoding];
    if (strcmp([sig methodReturnType],@encode(id)) || [sig numberOfArguments]!=2) return NO;
    IMP current=method_getImplementation(method);
    if (!current) return NO;
    if (current==(IMP)JFLegacyRootController) return YES;

    // If rootController is inherited, add a subclass override so no superclass
    // or non-Jellyfin merchant behavior is modified.
    jfOriginalLegacyRootController=current;
    if (class_addMethod(cls,sel,(IMP)JFLegacyRootController,encoding)) return YES;

    // Beigelist 7 owns rootController on BLAppLegacyMerchant. Only replace that
    // class-local implementation; all non-Jellyfin instances call the saved IMP.
    IMP superIMP=class_getSuperclass(cls) ?
        class_getMethodImplementation(class_getSuperclass(cls),sel) : NULL;
    method=class_getInstanceMethod(cls,sel);
    if (!method || method_getImplementation(method)==superIMP) {
        jfOriginalLegacyRootController=NULL;
        return NO;
    }
    jfOriginalLegacyRootController=method_setImplementation(method,(IMP)JFLegacyRootController);
    return jfOriginalLegacyRootController!=NULL;
}
static IMP jfSuperMerchantInfoValueForKey;
static BOOL JFIsJellyfinMerchantInfo(id self) {
    id merchantID=JFBRObject(self,@"merchantID");
    return [merchantID isKindOfClass:[NSString class]] && [merchantID isEqualToString:@"org.jellyfin.atv3"];
}
static id JFMerchantInfoValueForKey(id self, SEL cmd, id key) {
    // Only these two icon keys belong to this compatibility bridge.
    if ([key isKindOfClass:[NSString class]] &&
        ([key isEqualToString:@"menu-icon-url"] || [key isEqualToString:@"menu-icon-url-version"]) &&
        JFIsJellyfinMerchantInfo(self)) {
        if ([key isEqualToString:@"menu-icon-url"]) {
            NSString *url=JFMenuIconURL();
            if (!url.length) return nil;
            return @{
                @"720":url, @"1080":url,
                [NSNumber numberWithInteger:720]:url,
                [NSNumber numberWithInteger:1080]:url
            };
        }
        if ([key isEqualToString:@"menu-icon-url-version"]) {
            NSBundle *bundle=[NSBundle bundleWithIdentifier:@"org.jellyfin.atv3"];
            id version=[bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
            if (![version isKindOfClass:[NSString class]] || ![version length]) version=@"1";
            return version;
        }
    }
    return ((id(*)(id,SEL,id))jfSuperMerchantInfoValueForKey)(self,cmd,key);
}
static BOOL JFInstallMerchantInfoKVCBridge(void) {
    Class cls=objc_getClass("BLAppMerchantInfo");
    if (!cls) { return NO; }

    SEL sel=NSSelectorFromString(@"valueForKey:");
    Method inherited=class_getInstanceMethod(cls,sel);
    if (!inherited) { return NO; }

    const char *encoding=method_getTypeEncoding(inherited);
    NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:encoding];
    if (strcmp([sig methodReturnType],@encode(id)) || [sig numberOfArguments]!=3 ||
        strcmp([sig getArgumentTypeAtIndex:2],@encode(id))) {
        return NO;
    }

    IMP current=method_getImplementation(inherited);
    if (!current) { return NO; }

    if (current==(IMP)JFMerchantInfoValueForKey)
        return YES;

    jfSuperMerchantInfoValueForKey=current;
    method_setImplementation(inherited,(IMP)JFMerchantInfoValueForKey);
    return YES;
}
static BOOL AddOverride(Class cls,NSString *name,IMP imp,const char *result,NSArray *args) {
    SEL sel=NSSelectorFromString(name); Method m=class_getInstanceMethod(class_getSuperclass(cls),sel);
    if (!m) { NSLog(@"Jellyfin: missing %@; awaiting device verification",name); return NO; }
    NSMethodSignature *s=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
    if (strcmp([s methodReturnType],result) || [s numberOfArguments]!=[args count]+2) return NO;
    for(NSUInteger i=0;i<[args count];i++) if(strcmp([s getArgumentTypeAtIndex:i+2],[[args objectAtIndex:i] UTF8String])) return NO;
    return class_addMethod(cls,sel,imp,method_getTypeEncoding(m));
}
BOOL JFRegisterBackRowClasses(void) {
    if (objc_getClass("JellyfinAppliance")) {
        JFInstallMerchantInfoKVCBridge();
        JFInstallLegacyRootBridge();
        return YES;
    }
    if (!CategoryAvailable()) { NSLog(@"Jellyfin: category float ABI unavailable; registration refused"); return NO; }
    Class base=objc_getClass("BRBaseAppliance"),controller=objc_getClass("BRController");
    Class media=objc_getClass("BRMediaMenuController");
    BOOL menuCompatible=media ? JFBRMenuClassAvailable(media) : NO;
    if (media && !menuCompatible) return NO;
    menuEnabled=media!=Nil;
    if (menuEnabled) controller=media;
    if (!base || !controller) { NSLog(@"Jellyfin: BackRow unavailable; registration deferred (12H1006 static ABI audited; device execution pending)"); return NO; }
    Class a=objc_allocateClassPair(base,"JellyfinAppliance",0),c=objc_allocateClassPair(controller,"JellyfinController",0);
    if (!a || !c) { if(a)objc_disposeClassPair(a); if(c)objc_disposeClassPair(c); return NO; }
    BOOL ok=
        AddOverride(a,@"initWithApplianceInfo:",(IMP)ApplianceInitWithInfo,@encode(id),@[@"@"]) &&
        AddOverride(a,@"applianceCategories",(IMP)Categories,@encode(id),@[]) &&
        AddOverride(a,@"controllerForIdentifier:args:",(IMP)Controller,@encode(id),@[@"@",@"@"]) &&
        AddOverride(a,@"applianceController",(IMP)ApplianceController,@encode(id),@[]) &&
        AddOverride(c,@"brEventAction:",(IMP)Event,@encode(BOOL),@[@"@"]);
    if (ok && menuEnabled) {
        ok=AddOverride(c,@"init",(IMP)MenuInit,@encode(id),@[]) &&
           AddOverride(c,@"controlWasActivated",(IMP)Activated,@encode(void),@[]) &&
           AddOverride(c,@"controlWasDeactivated",(IMP)Deactivated,@encode(void),@[]) &&
           AddOverride(c,@"wasPopped",(IMP)Popped,@encode(void),@[]) &&
           AddOverride(c,@"dealloc",(IMP)ControllerDealloc,@encode(void),@[]) &&
           AddOverride(c,@"itemSelected:",(IMP)ItemSelected,@encode(void),@[[NSString stringWithUTF8String:@encode(long)]]);
        if (class_getInstanceMethod(media,NSSelectorFromString(@"previewControlForItem:")))
            ok=ok && AddOverride(c,@"previewControlForItem:",(IMP)Preview,@encode(id),@[[NSString stringWithUTF8String:@encode(long)]]);
    }
    if (!ok) { objc_disposeClassPair(a); objc_disposeClassPair(c); NSLog(@"Jellyfin: incompatible BackRow signatures; registration refused"); return NO; }
    objc_registerClassPair(c); objc_registerClassPair(a);
    JFInstallMerchantInfoKVCBridge();
    JFInstallLegacyRootBridge();
    return YES;
}
