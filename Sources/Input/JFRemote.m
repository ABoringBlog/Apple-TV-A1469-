#import "JFRemote.h"
@implementation JFRemote
- (NSDictionary *)action:(NSInteger)a value:(NSInteger)v time:(NSTimeInterval)t {
    JFButton b = JFUnknown; BOOL explicitHold = NO;
    switch (a) { case 1:b=JFMenu;break; case 2:b=JFMenu;explicitHold=YES;break;
        case 3:b=JFUp;break; case 4:b=JFDown;break; case 5:b=JFSelect;break;
        case 6:b=JFLeft;break; case 7:b=JFRight;break;
        case 22:case 23:case 24:b=JFSelect;explicitHold=YES;break;
        case 8:b=JFLeft;explicitHold=YES;break; case 9:b=JFRight;explicitHold=YES;break;
        default:return nil; }
    if (v == 2) return @{@"button":@(b),@"phase":@"repeat"};
    if (v != 0 && v != 1) return nil;
    NSString *phase;
    if (!v) { if (_active != b) return nil; phase=@"release"; _active=0; _held=NO; }
    else if (explicitHold) { if (_active==b && _held) phase=@"repeat"; else phase=@"hold"; _active=b; _held=YES; }
    else if (_active != b) { _active=b; _started=t; _held=NO; phase=@"press"; }
    else if (!_held && t-_started >= 0.6) { _held=YES; phase=@"hold"; }
    else phase=@"repeat";
    return @{@"button":@(b),@"phase":phase};
}
@end
