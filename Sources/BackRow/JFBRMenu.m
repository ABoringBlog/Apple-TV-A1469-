#import "JFBRMenu.h"
#import "JFBackRow.h"
#import "Input/JFRemote.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
static BOOL Matches(NSMethodSignature *s, const char *result, NSArray *args) {
    if (!s || strcmp(s.methodReturnType,result) || s.numberOfArguments!=args.count+2) return NO;
    for (NSUInteger i=0;i<args.count;i++) if (strcmp([s getArgumentTypeAtIndex:i+2],[args[i] UTF8String])) return NO;
    return YES;
}
BOOL JFBRHas(id target, NSString *name, const char *result, NSArray *args) {
    return [target respondsToSelector:NSSelectorFromString(name)] &&
        Matches([target methodSignatureForSelector:NSSelectorFromString(name)],result,args);
}
BOOL JFBRCall(id target, NSString *name, NSArray *objects) {
    NSMutableArray *types=[NSMutableArray array];
    for (id value in objects) { (void)value; [types addObject:@"@"]; }
    if (!JFBRHas(target,name,@encode(void),types)) return NO;
    NSInvocation *call=[NSInvocation invocationWithMethodSignature:[target methodSignatureForSelector:NSSelectorFromString(name)]];
    call.target=target; call.selector=NSSelectorFromString(name);
    for (NSUInteger i=0;i<objects.count;i++) { id arg=objects[i]==[NSNull null] ? nil : objects[i]; [call setArgument:&arg atIndex:i+2]; }
    [call invoke]; return YES;
}
BOOL JFBRSetInteger(id target, NSString *name, long value) {
    if (!JFBRHas(target,name,@encode(void),@[[NSString stringWithUTF8String:@encode(long)]])) return NO;
    NSInvocation *call=[NSInvocation invocationWithMethodSignature:[target methodSignatureForSelector:NSSelectorFromString(name)]];
    call.target=target; call.selector=NSSelectorFromString(name);
    [call setArgument:&value atIndex:2]; [call invoke]; return YES;
}
BOOL JFBRSetBool(id target, NSString *name, BOOL value) {
    if (!JFBRHas(target,name,@encode(void),@[[NSString stringWithUTF8String:@encode(BOOL)]])) return NO;
    ((void(*)(id,SEL,BOOL))objc_msgSend)(target,NSSelectorFromString(name),value); return YES;
}
id JFBRNew(Class cls) {
    if (!cls || !Matches([cls instanceMethodSignatureForSelector:@selector(init)],@encode(id),@[])) return nil;
    return [[cls alloc] init]; // caller owns the result
}
BOOL JFBRProtocolMatches(Class cls, NSString *name, NSArray *selectors) {
    Protocol *provider=objc_getProtocol([name UTF8String]);
    if (!cls || !provider) return NO;
    for (NSString *methodName in selectors) {
        SEL selector=NSSelectorFromString(methodName);
        struct objc_method_description method=protocol_getMethodDescription(provider,selector,YES,YES);
        if (!method.types) return NO;
        NSMethodSignature *actual=[NSMethodSignature signatureWithObjCTypes:method.types];
        NSMethodSignature *ours=[cls instanceMethodSignatureForSelector:selector];
        if (!ours || strcmp(actual.methodReturnType,ours.methodReturnType) || actual.numberOfArguments!=ours.numberOfArguments) return NO;
        for (NSUInteger i=2;i<actual.numberOfArguments;i++)
            if (strcmp([actual getArgumentTypeAtIndex:i],[ours getArgumentTypeAtIndex:i])) return NO;
    }
    class_addProtocol(cls,provider); return YES;
}
BOOL JFBRMenuClassAvailable(Class cls) {
    if (!cls || !JFBRProtocolMatches([JFBRMenu class],@"BRMenuListItemProvider",
        @[@"itemCount",@"itemForRow:",@"titleForRow:",@"rowSelectable:",@"heightForRow:"])) return NO;
    NSDictionary *methods=@{@"list":@[@"@"],@"setListTitle:":@[@"v",@"@"],
        @"controlWasActivated":@[@"v"],@"controlWasDeactivated":@[@"v"],@"wasPopped":@[@"v"],
        @"itemSelected:":@[@"v",[NSString stringWithUTF8String:@encode(long)]]};
    for (NSString *name in methods) {
        NSArray *types=methods[name];
        if (!Matches([cls instanceMethodSignatureForSelector:NSSelectorFromString(name)], [types[0] UTF8String], [types subarrayWithRange:NSMakeRange(1,types.count-1)])) return NO;
    }
    return YES;
}
@implementation JFBRMenu
- (id)initWithController:(id)controller {
    if ((self=[super init])) { _controller=controller; _rows=[@[@{@"title":@"Jellyfin",@"enabled":@NO}] copy]; _title=[@"Jellyfin" copy]; _needsReload=YES; }
    return self;
}
- (BOOL)canRender {
    if (_closed || !_controller) { return NO; }
    id list=JFBRObject(_controller,@"list"), theme=JFBRObject(NSClassFromString(@"BRThemeInfo"),@"sharedTheme");
    Class item=NSClassFromString(@"BRMenuItem");
    BOOL datasource=JFBRHas(list,@"setDatasource:",@encode(void),@[@"@"]);
    BOOL reload=JFBRHas(list,@"reload",@encode(void),@[]);
    BOOL attrs=JFBRHas(theme,@"menuTitleTextAttributes",@encode(id),@[]);
    BOOL itemText=Matches([item instanceMethodSignatureForSelector:NSSelectorFromString(@"setText:withAttributes:")],@encode(void),@[@"@",@"@"]);
    NSMethodSignature *selection=[list methodSignatureForSelector:NSSelectorFromString(@"setSelection:")];
    BOOL selectionBase=selection && selection.numberOfArguments==3 && !strcmp(selection.methodReturnType,"v");
    const char *t=selectionBase ? [selection getArgumentTypeAtIndex:2] : "";
    BOOL selectionLong=selectionBase && !strcmp(t,@encode(long));
    BOOL title=JFBRHas(_controller,@"setListTitle:",@encode(void),@[@"@"]);
    BOOL ok=datasource && reload && attrs && itemText && selectionLong && title;
    return ok;
}
- (BOOL)render {
    if (!_active || ![self canRender]) { return NO; }
    id list=JFBRObject(_controller,@"list");
    // On 12H1006 an unconditional BRList.reload can rebuild 200+ items.
    // This must happen on a data change, NOT on a focus-only/poster refresh.
    // Still validate the native ABI and update the selection every time.
    BOOL titleOK=YES,sourceOK=YES,reloadOK=YES;
    if(_needsReload) {
        titleOK=JFBRCall(_controller,@"setListTitle:",@[_title]);
        sourceOK=JFBRCall(list,@"setDatasource:",@[self]);
        reloadOK=JFBRCall(list,@"reload",@[]);
    }
    BOOL selectionOK=JFBRSetInteger(list,@"setSelection:",_selection);
    BOOL success=titleOK && sourceOK && reloadOK && selectionOK;
    if(success)_needsReload=NO;
    return success;
}
- (BOOL)activate {
    if (![NSThread isMainThread] || _closed) return NO;
    _active=YES;
    _needsReload=YES; // Datasource may have been cleared at deactivation.
    if (![self render]) { [self deactivate]; return NO; }
    return YES;
}
- (void)deactivate {
    _active=NO;
    _needsReload=YES;
    JFBRCall(JFBRObject(_controller,@"list"),@"setDatasource:",@[[NSNull null]]);
}
- (void)close {
    if (_closed) return;
    [self deactivate]; _closed=YES; _controller=nil;
    [_rows release]; _rows=[@[] copy]; [_title release]; _title=[@"Jellyfin" copy]; _selection=0;
}
- (void)displayTitle:(NSString *)title rows:(NSArray *)rows selection:(long)selection {
    if (_closed) return;
    // Matching visible rows do not require a native BackRow reload. Compare
    // actual dictionaries rather than just row count to avoid stale titles
    // after metadata/pagination changes.
    if(![_title isEqualToString:title] || ![_rows isEqualToArray:rows])
        _needsReload=YES;
    [_title release]; _title=[title copy]; [_rows release]; _rows=[rows copy];
    _selection=rows.count ? MAX(0,MIN(selection,(long)rows.count-1)) : 0;
    if (_active && ![self render]) [self deactivate];
}
- (JFHostEventResult)handleEvent:(NSDictionary *)event {
    if (!_active || _closed) return JFHostEventUnhandled;
    if ([event[@"button"] integerValue]==JFMenu && [event[@"phase"] isEqual:@"press"]) return JFHostEventExitRequested;
    return JFHostEventConsumed;
}
- (void)selectRow:(long)row { (void)row; }
- (long)itemCount { return (long)_rows.count; }
- (id)titleForRow:(long)row { return row>=0 && (NSUInteger)row<_rows.count ? _rows[row][@"title"] : nil; }
- (BOOL)rowSelectable:(long)row { return row>=0 && (NSUInteger)row<_rows.count && [_rows[row][@"enabled"] boolValue]; }
- (float)heightForRow:(long)row { return 0.0f; }
- (id)itemForRow:(long)row {
    NSString *title=[self titleForRow:row]; if (!title) { return nil; }
    id item=[JFBRNew(NSClassFromString(@"BRMenuItem")) autorelease];
    id theme=JFBRObject(NSClassFromString(@"BRThemeInfo"),@"sharedTheme");
    id attrs=JFBRObject(theme,@"menuTitleTextAttributes");
    BOOL textOK=JFBRCall(item,@"setText:withAttributes:",@[title,attrs ?: @{}]);
    return textOK ? item : nil;
}
- (void)dealloc { [self close]; [_rows release]; [_title release]; [super dealloc]; }
@end
