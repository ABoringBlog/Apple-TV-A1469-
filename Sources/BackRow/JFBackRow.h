#import <Foundation/Foundation.h>
// 12H1006/source 8163 static method encodings audited; runtime guards retained.
// Device execution remains pending; see docs/device-abi-12H1006.md.
BOOL JFRegisterBackRowClasses(void);
id JFBRObject(id target, NSString *selector);
id JFBRObjectWithObject(id target, NSString *selector, id argument);

void JFBRClearRemoteState(id controller);
void JFBRResetRemoteForPageChange(id controller);
