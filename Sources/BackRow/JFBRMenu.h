#import <Foundation/Foundation.h>
#import "JFSessionHost.h"
// Runtime calls use only evidenced selectors and validate their full signature.
BOOL JFBRHas(id target, NSString *name, const char *result, NSArray *arguments);
BOOL JFBRCall(id target, NSString *name, NSArray *objects);
BOOL JFBRSetInteger(id target, NSString *name, long value);
BOOL JFBRSetBool(id target, NSString *name, BOOL value);
BOOL JFBRMenuClassAvailable(Class cls);
id JFBRNew(Class cls); // retained result, or nil on unsupported init ABI
BOOL JFBRProtocolMatches(Class cls, NSString *name, NSArray *selectors);
@interface JFBRMenu : NSObject {
@protected
    id _controller; // non-owning; controller explicitly closes before its dealloc
    NSArray *_rows;
    NSString *_title;
    long _selection;
    BOOL _active, _closed, _needsReload;
}
- (id)initWithController:(id)controller;
- (BOOL)canRender;
- (BOOL)activate;
- (void)deactivate;
- (void)close;
- (void)displayTitle:(NSString *)title rows:(NSArray *)rows selection:(long)selection;
- (JFHostEventResult)handleEvent:(NSDictionary *)event;
- (void)selectRow:(long)row;
// Evidenced BRMenuListItemProvider callbacks; no private header dependency.
- (long)itemCount;
- (id)itemForRow:(long)row;
- (id)titleForRow:(long)row;
- (BOOL)rowSelectable:(long)row;
- (float)heightForRow:(long)row;
@end
