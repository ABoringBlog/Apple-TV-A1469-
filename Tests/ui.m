#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
#import "BackRow/JFBackRow.h"
#import "BackRow/JFBRMenu.h"
#import "BackRow/JFUIController.h"
#import "Input/JFRemote.h"
#import "JFDeviceABIFixture.h"
#import "Navigation/JFSession.h"
static NSUserDefaults *configurationDefaults;
static NSString *configurationSuite;
static BOOL submitPassword=YES;
static id TestConfigurationDefaults(id self, SEL cmd) { return configurationDefaults; }
static void CleanConfiguration(void) {
    [configurationDefaults removePersistentDomainForName:configurationSuite];
    [configurationDefaults synchronize];
}
static void ResetConfiguration(void) { [configurationDefaults removeObjectForKey:@"ServerConfiguration"]; [configurationDefaults removeObjectForKey:@"SessionCredential"]; }
static BOOL multiLibraries, unsupportedLibrary, badList, emptySeasons, emptyEpisodes, pagedMovies;

static CGSize TestImagePixelSize(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || !data.length) return CGSizeZero;
    CGImageSourceRef source=CGImageSourceCreateWithData((CFDataRef)data,NULL);
    if (!source) return CGSizeZero;
    NSDictionary *props=(NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source,0,NULL);
    CFRelease(source);
    NSNumber *w=props[(NSString *)kCGImagePropertyPixelWidth], *h=props[(NSString *)kCGImagePropertyPixelHeight];
    CGSize size=CGSizeMake([w doubleValue],[h doubleValue]);
    [props release]; return size;
}
static NSUInteger configurationRequests;
@interface JFFixtureProtocol : NSURLProtocol @end
@interface UIFixtureProtocol : JFFixtureProtocol @end
@implementation UIFixtureProtocol
- (void)startLoading {
    @synchronized([UIFixtureProtocol class]) { configurationRequests++; }
    // Simulate a 150-movie library served over two API pages.
    if (pagedMovies && [self.request.URL.path isEqual:@"/jellyfin/Items"] &&
        [[self.request.URL query] containsString:@"IncludeItemTypes=Movie"] &&
        [[self.request.URL query] containsString:@"ParentId=lib1"]) {
        NSURLComponents *components=[NSURLComponents componentsWithURL:self.request.URL
                                              resolvingAgainstBaseURL:NO];
        NSUInteger start=0,limit=101;
        for(NSURLQueryItem *q in components.queryItems) {
            if([q.name isEqual:@"StartIndex"])start=[q.value integerValue];
            if([q.name isEqual:@"Limit"])limit=[q.value integerValue];
        }
        NSUInteger count=start>=150?0:MIN(limit,150-start);
        NSMutableArray *items=[NSMutableArray array];
        for (NSUInteger i=start;i<start+count;i++)
            [items addObject:@{@"Id":[NSString stringWithFormat:@"movie%lu",(unsigned long)i],
                               @"Name":[NSString stringWithFormat:@"Film %lu",(unsigned long)i],
                               @"Type":@"Movie",@"ProductionYear":@2020}];
        NSData *payload=[NSJSONSerialization dataWithJSONObject:@{@"Items":items} options:0 error:NULL];
        NSHTTPURLResponse *reply=[[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}] autorelease];
        [self.client URLProtocol:self didReceiveResponse:reply cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:payload]; [self.client URLProtocolDidFinishLoading:self];
    } else if (multiLibraries && [self.request.URL.path isEqual:@"/jellyfin/Items"] &&
               [[self.request.URL query] containsString:@"ParentId=lib2"] &&
               [[self.request.URL query] containsString:@"IncludeItemTypes=Movie"]) {
        NSDictionary *replyObj=@{@"Items":@[@{@"Id":@"movie1",@"Name":@"Movie",@"Type":@"Movie"}]};
        NSData *data=[NSJSONSerialization dataWithJSONObject:replyObj options:0 error:NULL];
        NSHTTPURLResponse *reply=[[[NSHTTPURLResponse alloc] initWithURL:self.request.URL
            statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}] autorelease];
        [self.client URLProtocol:self didReceiveResponse:reply cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data];[self.client URLProtocolDidFinishLoading:self];
    } else if ((emptySeasons && [self.request.URL.path hasSuffix:@"/Shows/series1/Seasons"]) ||
        (emptyEpisodes && [self.request.URL.path hasSuffix:@"/Shows/series1/Episodes"])) {
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"Items":@[]} options:0 error:NULL];
        NSHTTPURLResponse *response=[[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}] autorelease];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data]; [self.client URLProtocolDidFinishLoading:self];
    } else if (unsupportedLibrary && [self.request.URL.path isEqual:@"/jellyfin/Users/user1/Views"]) {
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"Items":@[@{@"Id":@"music1",@"Name":@"Music",@"CollectionType":@"music"}]} options:0 error:NULL];
        NSHTTPURLResponse *response=[[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}] autorelease];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data]; [self.client URLProtocolDidFinishLoading:self];
    } else if (multiLibraries && [self.request.URL.path isEqual:@"/jellyfin/Users/user1/Views"]) {
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"Items":@[@{@"Id":@"lib1",@"Name":@"Shows",@"CollectionType":@"tvshows"},@{@"Id":@"lib2",@"Name":@"Movies",@"CollectionType":@"movies"}]} options:0 error:NULL];
        NSHTTPURLResponse *response=[[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}] autorelease];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data]; [self.client URLProtocolDidFinishLoading:self];
    } else [super startLoading];
}
@end
static int checks, activations, deactivations, pops, destroys, nativeEvents;
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { NSLog(@"FAIL line %d: %s",__LINE__,#__VA_ARGS__); exit(1); } } while(0)
@interface UIList : NSObject
@property(nonatomic, retain) id datasource;
@property(nonatomic) long selection;
@property(nonatomic) NSUInteger reloads;
- (void)reload;
@end
@implementation UIList
- (void)reload { _reloads++; }
- (void)dealloc { [_datasource release]; [super dealloc]; }
@end
@interface UIItem : NSObject
@property(nonatomic, copy) NSString *text;
- (void)setText:(id)text withAttributes:(id)attributes;
@end
@implementation UIItem
- (void)setText:(id)text withAttributes:(id)attributes { self.text=text; }
- (void)dealloc { [_text release]; [super dealloc]; }
@end
@interface UIImage : NSObject
@property(nonatomic, retain) NSData *data;
+ (id)imageWithData:(id)data;
@end
@implementation UIImage
+ (id)imageWithData:(id)data { UIImage *image=[[[self alloc] init] autorelease]; image.data=data; return image; }
- (void)dealloc { [_data release]; [super dealloc]; }
@end
@interface UIPreview : NSObject
@property(nonatomic, retain) id image;
@property(nonatomic, copy) NSString *statusMessage;
@property(nonatomic) BOOL cropAndFill;
- (void)setMessage:(id)message;
@end
@implementation UIPreview
- (void)setMessage:(id)message { self.statusMessage=message; }
- (void)dealloc { [_image release]; [_statusMessage release]; [super dealloc]; }
@end

@interface UITheme : NSObject
+ (id)sharedTheme;
- (id)menuTitleTextAttributes;
@end
@implementation UITheme
+ (id)sharedTheme { static id theme; if (!theme) theme=[self new]; return theme; }
- (id)menuTitleTextAttributes { return @{}; }
@end
@interface UIText : NSObject
@property(nonatomic, copy) NSString *stringValue;
@end
@implementation UIText
- (void)dealloc { [_stringValue release]; [super dealloc]; }
@end
@interface UIEntry : NSObject
@property(nonatomic, retain) UIText *textField;
@end
@implementation UIEntry
- (id)init { if ((self=[super init])) _textField=[UIText new]; return self; }
- (void)dealloc { [_textField release]; [super dealloc]; }
@end
@interface UIEditor : NSObject
@property(nonatomic, retain) UIEntry *editor;
@property(nonatomic, assign) id textFieldDelegate;
@property(nonatomic, copy) NSString *textEntryTextFieldLabel;
@property(nonatomic) BOOL showUserEnteredText;
- (void)setInitialTextEntryText:(id)text;
@end
@implementation UIEditor
- (id)init { if ((self=[super init])) { _editor=[UIEntry new]; _showUserEnteredText=YES; } return self; }
- (void)setInitialTextEntryText:(id)text { _editor.textField.stringValue=text; }
- (void)dealloc { [_editor release]; [_textEntryTextFieldLabel release]; [super dealloc]; }
@end
@protocol UILifecycle <NSObject>
- (void)controlWasActivated;
- (void)controlWasDeactivated;
@end
@interface UIStack : NSObject
@property(nonatomic, assign) id<UILifecycle> root;
@property(nonatomic, retain) UIEditor *pushed;
- (void)pushController:(id)controller;
- (void)popController;
@end
@implementation UIStack
- (void)pushController:(id)controller { self.pushed=controller; [_root controlWasDeactivated]; }
- (void)popController { pops++; if (_pushed) { [_root controlWasActivated]; self.pushed=nil; } }
- (void)dealloc { [_pushed release]; [super dealloc]; }
@end
// Exercise the production bridge and init ownership without private frameworks.
static int infoInitMode, infoDestroyed;
@interface UIFoundationInfo : NSObject
- (id)_initWithMutableDictionary:(id)values;
- (id)menuIconURLs;
- (id)menuIconURLVersion;
@end
@implementation UIFoundationInfo
- (id)_initWithMutableDictionary:(id)values {
    if (infoInitMode) { [self release]; return infoInitMode==1 ? nil : (id)[NSObject new]; }
    return [super init];
}
- (id)menuIconURLs { return nil; }
- (id)menuIconURLVersion { return nil; }
- (void)dealloc { infoDestroyed++; [super dealloc]; }
@end
@interface UIMerchantParent : NSObject
@end
@implementation UIMerchantParent
- (id)valueForKey:(id)key { return key ?: @"nil-key-fallback"; }
@end
@interface UIMerchant : UIMerchantParent
@property(nonatomic,copy) NSString *merchantID;
@property(nonatomic,retain) id menuIconURL;
@end
@implementation UIMerchant
- (void)dealloc { [_merchantID release]; [_menuIconURL release]; [super dealloc]; }
@end
static int legacyInfoReads, legacyIdentifierReads, legacyClassReads;
@interface UILegacyMerchant : NSObject {
    UIMerchant *_info;
    NSString *_identifier;
    Class _legacyApplianceClass;
}
@property(nonatomic,retain) UIMerchant *info;
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,assign) Class legacyApplianceClass;
- (id)rootController;
@end
@implementation UILegacyMerchant
- (UIMerchant *)info { legacyInfoReads++; return _info; }
- (void)setInfo:(UIMerchant *)value { if (_info!=value) { [value retain]; [_info release]; _info=value; } }
- (NSString *)identifier { legacyIdentifierReads++; return _identifier; }
- (void)setIdentifier:(NSString *)value { if (_identifier!=value) { [_identifier release]; _identifier=[value copy]; } }
- (Class)legacyApplianceClass { legacyClassReads++; return _legacyApplianceClass; }
- (void)setLegacyApplianceClass:(Class)value { _legacyApplianceClass=value; }
- (id)rootController { return @"legacy-root"; }
- (void)dealloc { [_info release]; [_identifier release]; [super dealloc]; }
@end
@interface UIBase : NSObject
- (id)initWithApplianceInfo:(id)info;
- (id)applianceCategories;
- (id)controllerForIdentifier:(id)identifier args:(id)args;
- (id)applianceController;
@end
@implementation UIBase
- (id)init { [self release]; return nil; }
- (id)initWithApplianceInfo:(id)info { return [super init]; }
- (id)applianceCategories { return nil; }
- (id)controllerForIdentifier:(id)identifier args:(id)args { return nil; }
- (id)applianceController { return nil; }
@end
@interface UIEvent : NSObject
@property int remoteAction, value;
@property unsigned int originator;
@end
@implementation UIEvent
@end
@interface UIMedia : NSObject <UILifecycle>
@property(nonatomic, retain) UIList *list;
@property(nonatomic, retain) UIStack *testStack;
@property(nonatomic, copy) NSString *listTitle;
- (BOOL)brEventAction:(id)event;
- (void)controlWasActivated;
- (void)controlWasDeactivated;
- (void)wasPopped;
- (void)itemSelected:(long)row;
- (id)previewControlForItem:(long)row;
- (id)stack;
@end
@implementation UIMedia
- (id)init { if ((self=[super init])) { _list=badList ? [[NSClassFromString(@"UIBadList") alloc] init] : [UIList new]; _testStack=[UIStack new]; _testStack.root=self; } return self; }
- (BOOL)brEventAction:(id)event {
    nativeEvents++;
    if ([event class]==[UIEvent class]) {
        UIEvent *remote=(UIEvent *)event;
        if (remote.originator==1 && remote.remoteAction==1 && remote.value==1) return YES;
    }
    return NO;
}
- (void)controlWasActivated { activations++; }
- (void)controlWasDeactivated { deactivations++; }
- (void)wasPopped { pops++; }
- (void)itemSelected:(long)row { }
- (id)previewControlForItem:(long)row { return @"unexpected preview"; }
- (id)stack { return _testStack; }
- (void)dealloc { destroys++; [_testStack release]; [_list release]; [_listTitle release]; [super dealloc]; }
@end
@interface BadSetter : NSObject
- (id)setDatasource:(id)value;
@end
@implementation BadSetter
- (id)setDatasource:(id)value { CHECK(NO); return nil; }
@end
static void WaitTitle(UIMedia *controller, NSString *fragment) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while ((![controller.listTitle containsString:fragment] || [controller.listTitle containsString:@"Loading"]) && deadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    if(![controller.listTitle containsString:fragment] || [controller.listTitle containsString:@"Loading"])
        NSLog(@"WAIT_TITLE_FAILED wanted=%@ saw=%@",fragment,controller.listTitle);
    CHECK([controller.listTitle containsString:fragment] && ![controller.listTitle containsString:@"Loading"]);
}
static void Choose(UIMedia *controller, long row) {
    JFBRMenu *menu=[controller.list.datasource isKindOfClass:[JFBRMenu class]] ? controller.list.datasource : nil;
    CHECK(menu!=nil);
    [menu selectRow:row];
}
static void Enter(UIMedia *controller, long row, NSString *text) {
    Choose(controller,row);
    UIEditor *editor=[controller.testStack.pushed retain]; CHECK(editor!=nil);
    if (row==2) CHECK(!editor.showUserEnteredText);
    editor.editor.textField.stringValue=text;
    CHECK([editor.textFieldDelegate respondsToSelector:@selector(textDidChange:)]);
    [editor.textFieldDelegate textDidChange:editor.editor.textField];
    CHECK(controller.testStack.pushed==editor && editor.textFieldDelegate!=nil);
    [editor.textFieldDelegate textDidEndEditing:editor.editor.textField];
    CHECK(!editor.textFieldDelegate && [editor.editor.textField.stringValue isEqual:@""]);
    CHECK(!controller.testStack.pushed);
    [editor release];
    if (row==2 && submitPassword) Choose(controller,3);
}
static void RejectStoredCredential(NSDictionary *config, id credential) {
    ResetConfiguration();
    [configurationDefaults setObject:config forKey:@"ServerConfiguration"];
    [configurationDefaults setObject:credential forKey:@"SessionCredential"];
    NSUInteger before=configurationRequests;
    UIMedia *candidate=[[objc_getClass("JellyfinController") alloc] init];
    [candidate controlWasActivated];
    CHECK([configurationDefaults objectForKey:@"SessionCredential"]==nil);
    CHECK(configurationRequests==before);
    [candidate wasPopped]; [candidate release];
}
static void Register(Class base, const char *name) { objc_registerClassPair(objc_allocateClassPair(base,name,0)); }
static id BadMethod(id self, SEL cmd) { return nil; }
static id BadBool(id self, SEL cmd, BOOL value) { return nil; }
static double BadEventValue(id self, SEL cmd) { CHECK(NO); return 1.0; }
static int BadInit(id self, SEL cmd) { CHECK(NO); return 0; }
static void BadIntSelection(id self, SEL cmd, int row) { CHECK(NO); }
static id BadCategory(id self, SEL cmd, id name, id identifier, int order) { CHECK(NO); return nil; }
static id BadSelection(id self, SEL cmd, long value) { return nil; }
static BOOL Send(UIMedia *controller, NSInteger action, NSInteger value) {
    UIEvent *event=[[[UIEvent alloc] init] autorelease]; event.remoteAction=action; event.value=value; event.originator=1;
    return [controller brEventAction:event];
}
static void Press(UIMedia *controller, NSInteger action) { CHECK(Send(controller,action,1)); Send(controller,action,0); }
int main(int argc, char **argv) { @autoreleasepool {
    NSString *mode=argc>1 ? [NSString stringWithUTF8String:argv[1]] : @"normal";
    configurationSuite=[[NSString stringWithFormat:@"org.jellyfin.atv3.tests.%@",[NSUUID UUID].UUIDString] copy];
    configurationDefaults=[[NSUserDefaults alloc] initWithSuiteName:configurationSuite];
    [configurationDefaults setObject:@"test-device" forKey:@"DeviceID"];
    method_setImplementation(class_getClassMethod([JFUIController class],NSSelectorFromString(@"configurationDefaults")),(IMP)TestConfigurationDefaults);
    atexit(CleanConfiguration);
    [NSURLProtocol registerClass:[UIFixtureProtocol class]];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"JFDeviceID":@"test-device"}];
    CHECK(!JFBRMenuClassAvailable([NSObject class]));
    CHECK(!JFBRMenuClassAvailable([UIMedia class])); // missing protocol rejects before invocation
    if (![mode isEqual:@"missing-protocol"] && ![mode isEqual:@"bad-protocol"])
        JFRegisterProtocolFixture("BRMenuListItemProvider",[JFBRMenu class],@[@"itemCount",@"heightForRow:",@"rowSelectable:",@"titleForRow:",@"itemForRow:"]);
    if (![mode isEqual:@"missing-text-protocol"])
        JFRegisterProtocolFixture("BRTextFieldDelegate",[JFUIController class],@[@"textDidChange:",@"textDidEndEditing:"]);
    Protocol *applianceProtocol=objc_allocateProtocol("BRAppliance"); objc_registerProtocol(applianceProtocol);
    CHECK(objc_getProtocol("BRAppliance")!=nil && objc_getClass("BRAppliance")==Nil);
    if (![mode isEqual:@"missing-category"] && ![mode isEqual:@"missing-category-selector"]) JFRegisterCategoryFixture();
    if ([mode isEqual:@"missing-category-selector"]) Register([NSObject class],"BRApplianceCategory");
    if ([mode isEqual:@"bad-category"]) class_addMethod(object_getClass(objc_getClass("BRApplianceCategory")),NSSelectorFromString(@"categoryWithName:identifier:preferredOrder:"),(IMP)BadCategory,"@@:@@i");
    BadSetter *bad=[BadSetter new]; CHECK(!JFBRCall(bad,@"setDatasource:",@[@1])); [bad release];
    Register([UIBase class],"BRBaseAppliance"); Register([UIMedia class],"BRController");
    Register(objc_getClass("BRController"),"BRMediaMenuController");
    Register([UIEditor class],"BRTextEntryController");
    Register([UIItem class],"BRMenuItem"); Register([UITheme class],"BRThemeInfo");
    Register([UIImage class],"ATVImage"); Register([UIPreview class],"BRAsyncImageControl");
    if ([mode isEqual:@"missing-category"] || [mode isEqual:@"missing-category-selector"] || [mode isEqual:@"bad-category"] || [mode isEqual:@"missing-protocol"]) {
        CHECK(!JFRegisterBackRowClasses()); CHECK(!objc_getClass("JellyfinAppliance")); CHECK(categoryCalls==0);
        printf("PASS: category/protocol rejection %s (%d assertions)\n",argv[1],checks); return 0;
    }
    if ([mode isEqual:@"missing-selector"]) {
        CHECK(!JFBRCall([NSObject new],@"setDatasource:",@[@1]));
        CHECK(!JFBRNew(Nil)); CHECK(JFBRObject([NSObject new],@"missingSelector")==nil);
        printf("PASS: absent selector rejection (%d assertions)\n",checks); return 0;
    }
    if ([mode isEqual:@"bad-menu"]) {
        class_addMethod(objc_getClass("BRMediaMenuController"),@selector(controlWasActivated),(IMP)BadMethod,"@@:");
        CHECK(!JFRegisterBackRowClasses()); CHECK(!objc_getClass("JellyfinController"));
        printf("PASS: incompatible menu ABI rejected\n"); return 0;
    }
    if ([mode isEqual:@"bad-protocol"]) {
        Protocol *provider=objc_allocateProtocol("BRMenuListItemProvider");
        protocol_addMethodDescription(provider,@selector(itemCount),"@@:",YES,YES); objc_registerProtocol(provider);
        CHECK(!JFRegisterBackRowClasses()); CHECK(!objc_getClass("JellyfinController"));
        printf("PASS: incompatible provider ABI rejected\n"); return 0;
    }
    if ([mode isEqual:@"bad-password"]) class_addMethod(objc_getClass("BRTextEntryController"),@selector(setShowUserEnteredText:),(IMP)BadBool,"@@:c");
    if ([mode isEqual:@"bad-list"]) {
        Register([UIList class],"UIBadList"); badList=YES;
        class_addMethod(objc_getClass("UIBadList"),@selector(setSelection:),(IMP)BadSelection,"@@:q");
    }
    if ([mode isEqual:@"bad-init"]) {
        Register([UIEditor class],"UIBadInit");
        class_addMethod(objc_getClass("UIBadInit"),@selector(init),(IMP)BadInit,"i@:");
        CHECK(JFBRNew(objc_getClass("UIBadInit"))==nil);
        printf("PASS: wrong init encoding rejected (%d assertions)\n",checks); return 0;
    }
    if ([mode isEqual:@"bad-int-selection"]) {
        Register([UIList class],"UIBadIntList");
        class_addMethod(objc_getClass("UIBadIntList"),@selector(setSelection:),(IMP)BadIntSelection,"v@:i");
        id list=[[objc_getClass("UIBadIntList") alloc] init];
        CHECK(!JFBRSetInteger(list,@"setSelection:",1)); [list release];
        printf("PASS: int instead of long rejected (%d assertions)\n",checks); return 0;
    }
    Register([UIFoundationInfo class],"BRApplianceInfo");
    Register([UIMerchant class],"BLAppMerchantInfo");
    Register([UILegacyMerchant class],"BLAppLegacyMerchant");
    CHECK(JFRegisterBackRowClasses());
    if ([mode isEqual:@"normal"]) {
        UIMerchant *merchant=[[objc_getClass("BLAppMerchantInfo") alloc] init];
        merchant.merchantID=@"org.jellyfin.atv3";
        merchant.menuIconURL=@"file:///Applications/Jellyfin.frappliance/AppIcon.png";
        NSDictionary *urls=[merchant valueForKey:@"menu-icon-url"];
        CHECK([urls isKindOfClass:[NSDictionary class]] && urls.count==4);
        for (id key in @[@"720",@"1080",@720,@1080]) CHECK([urls[key] isEqual:merchant.menuIconURL]);
        CHECK([[merchant valueForKey:@"menu-icon-url-version"] isKindOfClass:[NSString class]]);
        CHECK([[merchant valueForKey:@"unrelated"] isEqual:@"unrelated"]);
        IMP valueForKey=[merchant methodForSelector:@selector(valueForKey:)];
        CHECK([((id(*)(id,SEL,id))valueForKey)(merchant,@selector(valueForKey:),nil) isEqual:@"nil-key-fallback"]);
        UILegacyMerchant *legacy=[[objc_getClass("BLAppLegacyMerchant") alloc] init];
        legacy.info=merchant;
        legacy.identifier=@"merchant.org.jellyfin.atv3";
        legacyInfoReads=legacyIdentifierReads=legacyClassReads=0;
        // A foreign merchant must go straight back to Beigelist after the one
        // audited legacyApplianceClass read; info/identifier are never probed.
        CHECK([[legacy rootController] isEqual:@"legacy-root"]);
        CHECK(legacyInfoReads==0 && legacyIdentifierReads==0 && legacyClassReads==1);
        legacy.legacyApplianceClass=objc_getClass("JellyfinAppliance");
        id direct=[legacy rootController];
        CHECK([direct isKindOfClass:objc_getClass("JellyfinController")]);
        CHECK(legacyInfoReads==0 && legacyIdentifierReads==0 && legacyClassReads==2);
        merchant.merchantID=@"other.merchant";
        CHECK([[merchant valueForKey:@"menu-icon-url"] isEqual:@"menu-icon-url"]);
        CHECK([[merchant valueForKey:@"menu-icon-url-version"] isEqual:@"menu-icon-url-version"]);
        legacy.legacyApplianceClass=Nil;
        CHECK([[legacy rootController] isEqual:@"legacy-root"]);
        CHECK(legacyInfoReads==0 && legacyIdentifierReads==0 && legacyClassReads==3);
        [legacy release];
        [merchant release];
        for (int modeIndex=0; modeIndex<3; modeIndex++) {
            int before=infoDestroyed; infoInitMode=modeIndex;
            @autoreleasepool {
                id instance=[[objc_getClass("JellyfinAppliance") alloc] initWithApplianceInfo:nil];
                CHECK(instance!=nil); [instance release];
            }
            CHECK(infoDestroyed==before+1);
        }
        infoInitMode=0;
    }
    CHECK(class_getSuperclass(objc_getClass("JellyfinController"))==objc_getClass("BRMediaMenuController"));
    CHECK([[objc_getClass("JellyfinAppliance") alloc] init]==nil);
    UIBase *appliance=[[objc_getClass("JellyfinAppliance") alloc] initWithApplianceInfo:nil];
    CHECK(appliance!=nil);
    NSArray *categories=[appliance applianceCategories];
    CHECK(categories.count==1 && categoryCalls==1 && categoryOrder==0.0f);
    CHECK([categories[0][@"identifier"] isEqual:@"jellyfin"] && [categories[0][@"name"] isEqual:@"Jellyfin"]);
    if ([mode isEqual:@"normal"]) {
        UIMedia *direct=[[appliance applianceController] retain];
        CHECK(direct!=nil && [direct isKindOfClass:objc_getClass("JellyfinController")]);
        [direct release];
    }
    CHECK(![appliance controllerForIdentifier:@"other" args:nil]);
    UIMedia *controller=[[appliance controllerForIdentifier:@"jellyfin" args:nil] retain];
    if (badList) {
        CHECK(controller==nil); [appliance release];
        printf("PASS: incompatible list instance ABI rejected\n"); return 0;
    }
    if ([mode isEqual:@"bad-event"]) {
        Register([UIEvent class],"UIBadEvent");
        class_addMethod(objc_getClass("UIBadEvent"),@selector(value),(IMP)BadEventValue,"d@:");
        UIEvent *event=[[objc_getClass("UIBadEvent") alloc] init]; event.originator=1; event.remoteAction=1;
        CHECK(![controller brEventAction:event]); CHECK(pops==0); [event release]; [controller release]; [appliance release];
        printf("PASS: wrong event encoding rejected (%d assertions)\n",checks); return 0;
    }
    [controller controlWasActivated];
    CHECK(activations==1 && [controller.listTitle isEqual:@"Jellyfin"]);
    CHECK(controller.list.datasource && controller.list.reloads==1);
    JFBRMenu *menu=[controller.list.datasource retain];
    [menu displayTitle:@"Libraries" rows:@[@{@"title":@"Movies",@"enabled":@YES},@{@"title":@"Empty",@"enabled":@NO}] selection:1];
    CHECK([controller.listTitle isEqual:@"Libraries"] && controller.list.selection==1);
    CHECK([menu itemCount]==2 && [[menu titleForRow:0] isEqual:@"Movies"]);
    CHECK(![menu itemForRow:-1] && ![menu titleForRow:2] && ![menu rowSelectable:2]);
    CHECK([menu rowSelectable:0] && ![menu rowSelectable:1]);
    CHECK([[(UIItem *)[menu itemForRow:0] text] isEqual:@"Movies"]);
    CHECK([menu heightForRow:0]==0.0f && ![controller previewControlForItem:0]);
    [controller controlWasDeactivated]; CHECK(deactivations==1 && !controller.list.datasource);
    NSUInteger reloads=controller.list.reloads;
    [menu displayTitle:@"Paused" rows:@[] selection:0]; CHECK(controller.list.reloads==reloads);
    [controller controlWasActivated]; CHECK(activations==2 && [controller.listTitle isEqual:@"Jellyfin"]);
    [controller wasPopped]; CHECK(!controller.list.datasource && pops==1 && [menu itemCount]==0);
    [controller controlWasActivated]; CHECK(!controller.list.datasource);
    [menu release]; [controller release]; [appliance release];
    // Non-autoreleased allocation proves controller/list/data-source do not form a retain cycle.
    ResetConfiguration();
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    int before=destroys; [controller release]; CHECK(destroys==before+1);
    ResetConfiguration();
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    menu=[controller.list.datasource retain];
    CHECK([menu itemCount]==5 && ![menu rowSelectable:3]);
    if ([mode isEqual:@"missing-text-protocol"]) {
        Choose(controller,0); CHECK(!controller.testStack.pushed);
        CHECK([[menu titleForRow:5] isEqual:@"Text input is unavailable"]);
        [controller wasPopped]; [menu release]; [controller release];
        printf("PASS: missing text delegate protocol rejected (%d assertions)\n",checks); return 0;
    }
    Enter(controller,0,@"http://fixture.invalid/jellyfin"); Enter(controller,1,@"测试用户");
    CHECK([menu rowSelectable:2]);
    if ([mode isEqual:@"bad-password"]) {
        Choose(controller,2); CHECK(!controller.testStack.pushed);
        CHECK([[menu titleForRow:5] isEqual:@"Text input is unavailable"]);
        [controller wasPopped]; [menu release]; [controller release];
        printf("PASS: incompatible password masking ABI rejected\n"); return 0;
    }
    NSUInteger requestsBeforeHTTP=configurationRequests;
    Enter(controller,2,@"p\"ass"); // explicit HTTP gate, no request accepted
    CHECK(configurationRequests==requestsBeforeHTTP);
    CHECK([[menu titleForRow:5] containsString:@"HTTP"]);
    [controller itemSelected:4]; CHECK([[menu titleForRow:4] isEqual:@"Allow HTTP: Off"]);
    Choose(controller,4); CHECK([[menu titleForRow:4] isEqual:@"Allow HTTP: On"]);
    Enter(controller,2,@"p\"ass"); WaitTitle(controller,@"Libraries");
    CHECK([[menu titleForRow:0] isEqual:@"电影"] && [menu itemCount]==3);
    NSDictionary *credential=[configurationDefaults objectForKey:@"SessionCredential"];
    CHECK([credential[@"version"] integerValue]==1);
    CHECK([credential[@"server"] isEqual:@"http://fixture.invalid/jellyfin"]);
    CHECK([credential[@"deviceID"] isEqual:@"test-device"]);
    CHECK([credential[@"token"] isEqual:@"fixture-token"]);
    CHECK(![[credential description] containsString:@"p\"ass"]);
    UIMedia *restored=[[objc_getClass("JellyfinController") alloc] init];
    [restored controlWasActivated]; JFBRMenu *restoredMenu=[restored.list.datasource retain];
    JFMockPlaybackBackend *restoreBackend=[JFMockPlaybackBackend new];
    CHECK([(JFUIController *)restoredMenu configurePlaybackBackend:restoreBackend]);
    WaitTitle(restored,@"Libraries");
    CHECK([[restoredMenu titleForRow:0] isEqual:@"电影"]);
    CHECK([(JFUIController *)restoredMenu playback]!=nil);
    CHECK([[[configurationDefaults objectForKey:@"SessionCredential"] objectForKey:@"token"] isEqual:@"fixture-token"]);
    [restored wasPopped]; [restoredMenu release]; [restored release]; [restoreBackend release];
    CHECK([[[configurationDefaults objectForKey:@"SessionCredential"] objectForKey:@"token"] isEqual:@"fixture-token"]);
    Choose(controller,0); WaitTitle(controller,@"Media");
    CHECK([[menu titleForRow:0] isEqual:@"Movie  1999"]);
    __block id posterPreview=nil;
    NSDate *posterDeadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!(posterPreview=[controller previewControlForItem:0]) && posterDeadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK([posterPreview isKindOfClass:objc_getClass("BRAsyncImageControl")]);
    CHECK([[(UIPreview *)posterPreview image] isKindOfClass:objc_getClass("ATVImage")]);
    CHECK(![(UIPreview *)posterPreview cropAndFill]);
    CHECK([controller previewControlForItem:1]==nil);
    Choose(controller,0); WaitTitle(controller,@"Movie  1999");
    // Redesign: facts/genres/overview are rendered in a single non-action information pane.
    CHECK([[menu titleForRow:0] isEqual:@"Play"] && [menu rowSelectable:0]);
    CHECK([[[menu titleForRow:1] lowercaseString] containsString:@"watched"] && [menu rowSelectable:1]);
    CHECK([[menu titleForRow:2] containsString:@"Favorite"] && [menu rowSelectable:2]);
    CHECK([[menu titleForRow:[menu itemCount]-1] isEqual:@"Information"]);
    id movieDetailPreview=[controller previewControlForItem:0];
    CHECK([movieDetailPreview isKindOfClass:objc_getClass("BRAsyncImageControl")]);
    CHECK([[(UIPreview *)movieDetailPreview image] isKindOfClass:objc_getClass("ATVImage")]);
    Press(controller,1); WaitTitle(controller,@"Media");
    Choose(controller,1); WaitTitle(controller,@"Libraries");
    Choose(controller,2); WaitTitle(controller,@"Jellyfin");
    CHECK([configurationDefaults objectForKey:@"SessionCredential"]==nil);
    CHECK([menu itemCount]==5 && [[menu titleForRow:3] isEqual:@"Sign in"]);

    // Explicit authentication rejection removes the persisted token.
    NSDictionary *baseConfig=@{@"server":@"http://fixture.invalid/jellyfin",@"username":@"测试用户",@"allowHTTP":@YES};
    [configurationDefaults setObject:baseConfig forKey:@"ServerConfiguration"];
    [configurationDefaults setObject:@{@"version":@1,@"server":@"http://fixture.invalid/jellyfin",@"deviceID":@"test-device",@"token":@"expired"} forKey:@"SessionCredential"];
    UIMedia *expired=[[objc_getClass("JellyfinController") alloc] init]; [expired controlWasActivated];
    JFBRMenu *expiredMenu=[expired.list.datasource retain]; WaitTitle(expired,@"Jellyfin");
    CHECK([configurationDefaults objectForKey:@"SessionCredential"]==nil);
    CHECK([[expiredMenu titleForRow:5] containsString:@"authentication failed (401)"]);
    [expired wasPopped]; [expiredMenu release]; [expired release];

    // A transport failure keeps a structurally valid credential for a later retry.
    NSDictionary *offlineConfig=@{@"server":@"https://fixture.invalid/disconnect",@"username":@"测试用户",@"allowHTTP":@NO};
    [configurationDefaults setObject:offlineConfig forKey:@"ServerConfiguration"];
    [configurationDefaults setObject:@{@"version":@1,@"server":@"https://fixture.invalid/disconnect",@"deviceID":@"test-device",@"token":@"fixture-token"} forKey:@"SessionCredential"];
    UIMedia *offline=[[objc_getClass("JellyfinController") alloc] init]; [offline controlWasActivated];
    JFBRMenu *offlineMenu=[offline.list.datasource retain]; WaitTitle(offline,@"Jellyfin");
    CHECK([[[configurationDefaults objectForKey:@"SessionCredential"] objectForKey:@"token"] isEqual:@"fixture-token"]);
    CHECK([[offlineMenu titleForRow:5] containsString:@"network"]);
    [offline wasPopped]; [offlineMenu release]; [offline release];
    Enter(controller,1,@"bad"); Enter(controller,2,@"wrong"); WaitTitle(controller,@"Jellyfin");
    CHECK([[menu titleForRow:5] containsString:@"authentication failed (401)"]);
    Enter(controller,1,@"empty"); Enter(controller,2,@"x"); WaitTitle(controller,@"Libraries");
    CHECK([[menu titleForRow:0] isEqual:@"No libraries available"] && ![menu rowSelectable:0]);
    Choose(controller,1); WaitTitle(controller,@"Libraries");
    Choose(controller,2); WaitTitle(controller,@"Jellyfin");
    // Input cancellation resumes presentation without submitting credentials.
    Choose(controller,2); UIEditor *cancelled=[controller.testStack.pushed retain];
    CHECK(cancelled!=nil); [controller.testStack popController];
    CHECK(!cancelled.textFieldDelegate && [cancelled.editor.textField.stringValue isEqual:@""]);
    [cancelled release];
    [controller wasPopped]; [menu release]; [controller release];
    // Structurally invalid or mismatched persisted credentials are discarded locally.
    NSDictionary *secureConfig=@{@"server":@"https://fixture.invalid/jellyfin",@"username":@"user",@"allowHTTP":@NO};
    RejectStoredCredential(secureConfig,@{@"version":@2,@"server":@"https://fixture.invalid/jellyfin",@"deviceID":@"test-device",@"token":@"fixture-token"});
    RejectStoredCredential(secureConfig,@{@"version":@1,@"server":@"https://fixture.invalid/other",@"deviceID":@"test-device",@"token":@"fixture-token"});
    RejectStoredCredential(secureConfig,@{@"version":@1,@"server":@"https://fixture.invalid/jellyfin",@"deviceID":@"other-device",@"token":@"fixture-token"});
    RejectStoredCredential(secureConfig,@{@"version":@1,@"server":@"https://fixture.invalid/jellyfin",@"deviceID":@"test-device",@"token":[NSString stringWithFormat:@"bad%ctoken",10]});
    RejectStoredCredential(secureConfig,@"not-a-dictionary");
    NSDictionary *blockedHTTP=@{@"server":@"http://fixture.invalid/jellyfin",@"username":@"user",@"allowHTTP":@NO};
    RejectStoredCredential(blockedHTTP,@{@"version":@1,@"server":@"http://fixture.invalid/jellyfin",@"deviceID":@"test-device",@"token":@"fixture-token"});

    // Injected player path: existing native menu uses no private playback selector.
    ResetConfiguration();
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    menu=[controller.list.datasource retain];
    JFMockPlaybackBackend *mock=[JFMockPlaybackBackend new];
    CHECK([(JFUIController *)menu configurePlaybackBackend:mock]);
    Enter(controller,0,@"http://fixture.invalid/jellyfin"); Enter(controller,1,@"测试用户");
    Choose(controller,4); Enter(controller,2,@"p\"ass"); WaitTitle(controller,@"Libraries");
    Choose(controller,0); WaitTitle(controller,@"Media"); Choose(controller,0); WaitTitle(controller,@"Movie  1999");
    // Playback regression preserved with redesigned action positions.
    CHECK([[menu titleForRow:0] isEqual:@"Play"]); Choose(controller,0); WaitTitle(controller,@"setup");
    CHECK(controller.list.selection==0); // Async Play must not jump to Watched.
    CHECK([menu rowSelectable:0]);
    NSDate *ready=[NSDate dateWithTimeIntervalSinceNow:3];
    while (!mock.starts && ready.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(mock.starts==1); [mock emit:@"started" ticks:0]; WaitTitle(controller,@"playing");
    CHECK([[menu titleForRow:0] isEqual:@"Pause"]);
    Choose(controller,0); WaitTitle(controller,@"paused");
    NSUInteger resumeStarts=mock.starts, resumeStops=mock.stops;
    Choose(controller,0); WaitTitle(controller,@"playing");
    CHECK(mock.starts==resumeStarts && mock.stops==resumeStops);
    Press(controller,7); CHECK([(JFUIController *)menu playback].positionTicks==3000000000LL);
    Press(controller,6); CHECK([(JFUIController *)menu playback].positionTicks==0);
    Press(controller,7); CHECK([(JFUIController *)menu playback].positionTicks==3000000000LL);
    [mock emit:@"paused" ticks:3000000000LL]; WaitTitle(controller,@"paused");
    CHECK([[menu titleForRow:0] isEqual:@"Resume"]);
    Press(controller,1); WaitTitle(controller,@"Media");
    CHECK([[(JFUIController *)menu playback].currentState isEqual:@"stopped"]);
    Choose(controller,0); WaitTitle(controller,@"Movie  1999");
    CHECK([[menu titleForRow:0] containsString:@"Resume"]);
    Choose(controller,0); WaitTitle(controller,@"setup");
    CHECK([(JFUIController *)menu playback].positionTicks==3000000000LL);
    ready=[NSDate dateWithTimeIntervalSinceNow:3];
    while (mock.starts<2 && ready.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(mock.starts==2); [mock emit:@"failure" ticks:0]; WaitTitle(controller,@"Movie  1999");
    CHECK([[(JFUIController *)menu playback].currentState isEqual:@"failed"]);
    Choose(controller,0); WaitTitle(controller,@"setup");
    ready=[NSDate dateWithTimeIntervalSinceNow:3];
    while (mock.starts<3 && ready.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(mock.starts==3); [mock emit:@"started" ticks:3000000000LL]; WaitTitle(controller,@"playing");
    CHECK([[(JFUIController *)menu playback].currentState isEqual:@"playing"]);
    [controller wasPopped]; CHECK([[(JFUIController *)menu playback] currentState]==nil);
    [menu release]; [controller release]; [mock release];
    // Releasing an owner while its input page remains retained detaches and clears input.
    ResetConfiguration();
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    Choose(controller,0); UIEditor *orphan=[controller.testStack.pushed retain];
    orphan.editor.textField.stringValue=@"pending input";
    [controller release]; CHECK(!orphan.textFieldDelegate && [orphan.editor.textField.stringValue isEqual:@""]);
    [orphan release];
    // Configuration survives controller destruction and a fresh defaults instance.
    ResetConfiguration(); submitPassword=NO;
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    menu=[controller.list.datasource retain];
    Enter(controller,0,@" HTTPS://Fixture.Invalid:443/jellyfin/// ");
    CHECK([[menu titleForRow:0] isEqual:@"Server: https://fixture.invalid/jellyfin"]);
    Enter(controller,1,@"配置用户"); Enter(controller,2,@"never-store-this-password");
    CHECK([menu rowSelectable:3] && [[menu titleForRow:2] isEqual:@"Password: Entered"]);
    Choose(controller,4);
    NSDictionary *saved=[configurationDefaults objectForKey:@"ServerConfiguration"];
    CHECK(saved.count==3 && ![[saved description] containsString:@"never-store-this-password"]);
    Enter(controller,0,@"https://user:secret@example.com");
    CHECK([[menu titleForRow:0] isEqual:@"Server: https://fixture.invalid/jellyfin"]);
    CHECK([[menu titleForRow:5] containsString:@"valid HTTP"]);
    [controller wasPopped]; [menu release]; [controller release];
    [configurationDefaults synchronize]; [configurationDefaults release];
    configurationDefaults=[[NSUserDefaults alloc] initWithSuiteName:configurationSuite];
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    menu=[controller.list.datasource retain];
    CHECK([[menu titleForRow:0] isEqual:@"Server: https://fixture.invalid/jellyfin"]);
    CHECK([[menu titleForRow:1] isEqual:@"Username: 配置用户"]);
    CHECK([[menu titleForRow:4] isEqual:@"Allow HTTP: On"]);
    CHECK([[menu titleForRow:2] isEqual:@"Password"] && ![menu rowSelectable:3]);
    Enter(controller,2,@"temporary"); Enter(controller,0,@"https://fixture.invalid/other");
    CHECK(![menu rowSelectable:3] && [[menu titleForRow:2] isEqual:@"Password"]);
    [controller wasPopped]; [menu release]; [controller release]; submitPassword=YES;
    ResetConfiguration();
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    menu=[controller.list.datasource retain];
    Enter(controller,0,@"https://fixture.invalid/tls"); Enter(controller,1,@"user"); Enter(controller,2,@"secret");
    WaitTitle(controller,@"Jellyfin"); CHECK([[menu titleForRow:5] containsString:@"certificate"]);
    JFSession *oldSession=[[menu valueForKey:@"session"] retain]; CHECK(oldSession!=nil);
    Enter(controller,0,@"https://fixture.invalid/disconnect");
    CHECK(oldSession.closed && [menu valueForKey:@"session"]==nil); [oldSession release];
    Enter(controller,2,@"secret");
    WaitTitle(controller,@"Jellyfin"); CHECK([[menu titleForRow:5] containsString:@"network"]);
    [controller wasPopped]; [menu release]; [controller release];
    // Raw Apple Remote events exercise the actual runtime controller override.
    multiLibraries=YES;
    ResetConfiguration();
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    menu=[controller.list.datasource retain];
    int startPops=pops;
    Press(controller,4); CHECK(controller.list.selection==1);
    CHECK(Send(controller,4,1)); CHECK(Send(controller,4,1)); Send(controller,4,0);
    CHECK(controller.list.selection==4); // repeated Down skips disabled Sign in
    Press(controller,3); CHECK(controller.list.selection==2);
    Enter(controller,0,@"http://fixture.invalid/jellyfin"); Enter(controller,1,@"测试用户");
    Choose(controller,4); Enter(controller,2,@"p\"ass");
    int afterEditors=pops;
    Press(controller,1); CHECK(pops==afterEditors); // busy root Menu is consumed
    WaitTitle(controller,@"Libraries");
    CHECK([menu itemCount]==4);
    // Async selection must stay on the requested library while its rows
    // are disabled for loading; previous code reset it to item 0 (Archived).
    Press(controller,7);CHECK(controller.list.selection==1);
    CHECK(Send(controller,5,1));CHECK(controller.list.selection==1);
    WaitTitle(controller,@"Media");
    Press(controller,1);WaitTitle(controller,@"Libraries");
    Press(controller,6);CHECK(controller.list.selection==0);
    // Two-column Libraries: left card -> Refresh, right card -> Sign out.
    Press(controller,7); WaitTitle(controller,@"Libraries"); CHECK(controller.list.selection==1);
    Press(controller,3); CHECK(controller.list.selection==3); // Sign out
    Press(controller,6); CHECK(controller.list.selection==2); // Refresh
    Press(controller,7); CHECK(controller.list.selection==3); // Sign out
    Press(controller,4); CHECK(controller.list.selection==1); // Right card
    Press(controller,6); CHECK(controller.list.selection==0); // Shows
    // Reproduce 12H1006 dropping Select release across a page change: the
    // next physical press must still be treated as a fresh press.
    CHECK(Send(controller,5,1)); WaitTitle(controller,@"Media");
    CHECK([[menu titleForRow:0] isEqual:@"Series"]);
    __block id seriesPosterPreview=nil;
    NSDate *seriesPosterDeadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!(seriesPosterPreview=[controller previewControlForItem:0]) && seriesPosterDeadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK([seriesPosterPreview isKindOfClass:objc_getClass("BRAsyncImageControl")]);
    CHECK([[(UIPreview *)seriesPosterPreview image] isKindOfClass:objc_getClass("ATVImage")]);
    CHECK(![(UIPreview *)seriesPosterPreview cropAndFill]);
    CHECK(Send(controller,5,1)); WaitTitle(controller,@"Seasons");
    CHECK([[menu titleForRow:0] isEqual:@"Season 1"]);
    __block id seasonPosterPreview=nil;
    NSDate *seasonPosterDeadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!(seasonPosterPreview=[controller previewControlForItem:0]) && seasonPosterDeadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK([seasonPosterPreview isKindOfClass:objc_getClass("BRAsyncImageControl")]);
    CHECK([[(UIPreview *)seasonPosterPreview image] isKindOfClass:objc_getClass("ATVImage")]);
    CGSize seasonPosterSize=TestImagePixelSize([(UIImage *)[(UIPreview *)seasonPosterPreview image] data]);
    CHECK(seasonPosterSize.width==1 && seasonPosterSize.height==3);
    Press(controller,5); WaitTitle(controller,@"Episodes");
    CHECK([[menu titleForRow:0] isEqual:@"S01E01  Pilot"]);
    __block id episodePosterPreview=nil;
    NSDate *episodePosterDeadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!(episodePosterPreview=[controller previewControlForItem:0]) && episodePosterDeadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK([episodePosterPreview isKindOfClass:objc_getClass("BRAsyncImageControl")]);
    CHECK([[(UIPreview *)episodePosterPreview image] isKindOfClass:objc_getClass("ATVImage")]);
    CGSize episodePosterSize=TestImagePixelSize([(UIImage *)[(UIPreview *)episodePosterPreview image] data]);
    CHECK(episodePosterSize.width==3 && episodePosterSize.height==3);
    Press(controller,5); WaitTitle(controller,@"S01E02  Episode");
    CHECK([[menu titleForRow:0] isEqual:@"Play"]);
    CHECK([[menu titleForRow:1] containsString:@"watched"] ||
          [[menu titleForRow:1] containsString:@"Watched"]);
    CHECK([[menu titleForRow:[menu itemCount]-1] isEqual:@"Information"]);
    id episodeDetailPreview=[controller previewControlForItem:0];
    CHECK([episodeDetailPreview isKindOfClass:objc_getClass("BRAsyncImageControl")]);
    CHECK([[(UIPreview *)episodeDetailPreview image] isKindOfClass:objc_getClass("ATVImage")]);
    for (NSString *title in @[@"Episodes",@"Seasons",@"Media",@"Libraries"]) {
        Press(controller,1); WaitTitle(controller,title); CHECK(pops==afterEditors);
    }
    // Context-specific empty child lists remain navigable back to the stable parent page.
    emptySeasons=YES;
    Choose(controller,0); WaitTitle(controller,@"Media");
    Choose(controller,0); WaitTitle(controller,@"Seasons");
    CHECK([menu itemCount]==3 && [[menu titleForRow:0] isEqual:@"No seasons available"] && ![menu rowSelectable:0]);
    Choose(controller,1); WaitTitle(controller,@"Media");
    Choose(controller,1); WaitTitle(controller,@"Libraries");
    emptySeasons=NO; emptyEpisodes=YES;
    Choose(controller,0); WaitTitle(controller,@"Media");
    Choose(controller,0); WaitTitle(controller,@"Seasons");
    Choose(controller,0); WaitTitle(controller,@"Episodes");
    CHECK([menu itemCount]==3 && [[menu titleForRow:0] isEqual:@"No episodes available"] && ![menu rowSelectable:0]);
    Choose(controller,1); WaitTitle(controller,@"Seasons");
    Choose(controller,1); WaitTitle(controller,@"Media");
    Choose(controller,1); WaitTitle(controller,@"Libraries");
    emptyEpisodes=NO;
    CHECK(!Send(controller,999,1));
    UIEvent *foreign=[UIEvent new]; foreign.originator=2; foreign.remoteAction=1; foreign.value=1;
    CHECK(![controller brEventAction:foreign]); [foreign release]; CHECK(pops==afterEditors);
    // Root Menu is delegated to BackRow's native brEventAction:. Jellyfin must
    // not synchronously pop its controller stack or tear down the datasource.
    int beforeNative=nativeEvents;
    CHECK(Send(controller,1,1)); CHECK(nativeEvents==beforeNative+1);
    CHECK(pops==afterEditors && controller.list.datasource==menu);
    CHECK(Send(controller,1,0)); CHECK(pops==afterEditors && controller.list.datasource==menu);
    [controller wasPopped]; CHECK(!controller.list.datasource);
    [menu release]; [controller release]; CHECK(pops>startPops);
    multiLibraries=NO;
    // Explicit non-video collections are not misrepresented as Movies/TV shows.
    unsupportedLibrary=YES;
    ResetConfiguration();
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    menu=[controller.list.datasource retain];
    Enter(controller,0,@"http://fixture.invalid/jellyfin"); Enter(controller,1,@"测试用户");
    Choose(controller,4); Enter(controller,2,@"p\"ass"); WaitTitle(controller,@"Libraries");
    CHECK([[menu titleForRow:0] isEqual:@"Music"]);
    Choose(controller,0); WaitTitle(controller,@"Music");
    CHECK([menu itemCount]==2 && [[menu titleForRow:0] containsString:@"not supported"] && ![menu rowSelectable:0]);
    CHECK([[menu titleForRow:1] isEqual:@"Back"] && [menu rowSelectable:1]);
    Choose(controller,1); WaitTitle(controller,@"Libraries");
    [controller wasPopped]; [menu release]; [controller release];
    unsupportedLibrary=NO;
    // An in-flight request is closed on removal; no callback may reattach its list.
    ResetConfiguration();
    controller=[[objc_getClass("JellyfinController") alloc] init]; [controller controlWasActivated];
    menu=[controller.list.datasource retain];
    Enter(controller,0,@"http://fixture.invalid/slow"); Enter(controller,1,@"user");
    Choose(controller,4); Enter(controller,2,@"secret"); CHECK([controller.listTitle containsString:@"Loading"]);
    NSUInteger lastReload=controller.list.reloads; [controller wasPopped];
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.15];
    while (until.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
    CHECK(!controller.list.datasource && controller.list.reloads==lastReload);
    [menu release]; [controller release];
    // Regression: all 150 movies and Back are visible without a Load more row,
    // and cursor navigation crosses the old 100-item boundary.
    pagedMovies=YES; ResetConfiguration();
    controller=[[objc_getClass("JellyfinController") alloc] init];
    [controller controlWasActivated]; menu=[controller.list.datasource retain];
    Enter(controller,0,@"http://fixture.invalid/jellyfin");
    Enter(controller,1,@"测试用户");
    Choose(controller,4); Enter(controller,2,@"p\"ass"); WaitTitle(controller,@"Libraries");
    Choose(controller,0); WaitTitle(controller,@"Media");
    // First screen becomes usable before the rest of the 150-item directory.
    CHECK([menu itemCount]>=12 && [menu itemCount]<=152);
    NSDate *allMovies=[NSDate dateWithTimeIntervalSinceNow:6.0];
    while([menu itemCount]!=152 && allMovies.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK([menu itemCount]==152 && [[menu titleForRow:100] hasPrefix:@"Film 100"] &&
          [[menu titleForRow:150] isEqual:@"Back"] && [[menu titleForRow:151] isEqual:@"Search"]);
    // First-row UP targets the Back/Search header, not the last poster row.
    Press(controller,3); CHECK(controller.list.selection==150);
    Press(controller,7); CHECK(controller.list.selection==151);
    Press(controller,6); CHECK(controller.list.selection==150);
    Press(controller,4); CHECK(controller.list.selection==0);
    // 20 x Down = 100 media positions in the new five-column grid.
    for(int i=0;i<20;i++) CHECK([menu handleEvent:@{@"button":@(JFDown),@"phase":@"press"}]==JFHostEventConsumed);
    CHECK(controller.list.selection==100 && [menu rowSelectable:100]);
    CHECK([menu handleEvent:@{@"button":@(JFUp),@"phase":@"press"}]==JFHostEventConsumed);
    CHECK(controller.list.selection==95);
    for(int i=0;i<11;i++) CHECK([menu handleEvent:@{@"button":@(JFDown),@"phase":@"press"}]==JFHostEventConsumed);
    CHECK(controller.list.selection>=145 && controller.list.selection<150);
    // Header buttons are reachable from top row; Back continues to work.
    Choose(controller,150); WaitTitle(controller,@"Libraries");
    [controller wasPopped]; [menu release]; [controller release];
    printf("PASS: %d UI runtime assertions\n",checks);
} }
