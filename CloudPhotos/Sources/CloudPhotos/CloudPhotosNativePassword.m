// CloudPhotos private native ATV3 masked password input for Hidden album.
// Password is never written to logs or local storage.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <Security/SecRandom.h>

extern NSString *CloudPhotosClientSecret(void);
static id cpEditor=nil;
static id cpEditorHost=nil;
static id cpEditorStack=nil;
static NSObject *cpPasswordSender=nil;
static BOOL cpEditorSubmitting=NO;
static BOOL cpEditorSecure=YES;


static NSData *CPEncryptedInput(NSString *text) {
    if(![text isKindOfClass:[NSString class]])return nil;
    NSData *plaintext=[text dataUsingEncoding:NSUTF8StringEncoding];
    if(!plaintext || [plaintext length]>1536)return nil;
    extern NSString *CloudPhotosInputCryptoKey(void);
    NSString *base=CloudPhotosInputCryptoKey();
    NSData *aesMaterial=[[base stringByAppendingString:@":aes"] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *macMaterial=[[base stringByAppendingString:@":mac"] dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t key[CC_SHA256_DIGEST_LENGTH],macKey[CC_SHA256_DIGEST_LENGTH],iv[kCCBlockSizeAES128];
    CC_SHA256([aesMaterial bytes],(CC_LONG)[aesMaterial length],key);
    CC_SHA256([macMaterial bytes],(CC_LONG)[macMaterial length],macKey);
    if(SecRandomCopyBytes(kSecRandomDefault,sizeof(iv),iv)!=errSecSuccess)return nil;
    size_t capacity=[plaintext length]+kCCBlockSizeAES128;
    uint8_t *cipher=malloc(capacity);
    if(!cipher)return nil;
    size_t actual=0;
    CCCryptorStatus status=CCCrypt(kCCEncrypt,kCCAlgorithmAES128,kCCOptionPKCS7Padding,
                key,kCCKeySizeAES256,iv,[plaintext bytes],[plaintext length],
                cipher,capacity,&actual);
    NSData *payload=nil;
    if(status==kCCSuccess && actual && actual<2048){
        // HMAC-SHA256 over versioned IV and ciphertext.
        NSMutableData *tagged=[NSMutableData dataWithBytes:"CP_INPUT_V1" length:11];
        [tagged appendBytes:iv length:sizeof(iv)];
        [tagged appendBytes:cipher length:actual];
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CCHmac(kCCHmacAlgSHA256,macKey,sizeof(macKey),[tagged bytes],[tagged length],digest);
        NSDictionary *envelope=@{
            @"iv":[[NSData dataWithBytes:iv length:sizeof(iv)] base64EncodedStringWithOptions:0],
            @"ct":[[NSData dataWithBytes:cipher length:actual] base64EncodedStringWithOptions:0],
            @"mac":[[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0]
        };
        payload=[NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
        memset(digest,0,sizeof(digest));
    }
    memset(key,0,sizeof(key));memset(macKey,0,sizeof(macKey));
    memset(iv,0,sizeof(iv));memset(cipher,0,capacity);free(cipher);
    return payload;
}

@interface CPPhotosPasswordWorker : NSObject
-(void)send:(NSDictionary*)request;
@end
@implementation CPPhotosPasswordWorker
-(void)send:(NSDictionary*)request {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    @try {
        NSString *entry=[request objectForKey:@"text"];
        NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"http://192.0.2.24:18790/v1/photos/input"]
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
        [r setHTTPMethod:@"POST"];
        [r setValue:CloudPhotosClientSecret() forHTTPHeaderField:@"X-ATV-Photos-Key"];
        [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        NSData *body=CPEncryptedInput(entry);
        if(body && [body length]<4096){
            [r setHTTPBody:body];
            NSURLResponse *response=nil;
            [NSURLConnection sendSynchronousRequest:r returningResponse:&response error:NULL];
            NSInteger code=[response isKindOfClass:[NSHTTPURLResponse class]]?
                 [(NSHTTPURLResponse*)response statusCode]:0;
            // Never log the typed characters, hash, ciphertext or URL query.
            NSLog(@"CloudPhotos browser field entry response=%ld", (long)code);
        }
    }@catch(NSException *e) {
        NSLog(@"CloudPhotos browser text entry unavailable");
    }
    [pool drain];
}
@end

static void CPPasswordTextDidChange(id self,SEL cmd,id sender) {
    (void)self;(void)cmd;(void)sender;
}

static void CPPasswordTextDidEnd(id self,SEL cmd,id sender){
    (void)cmd;
    if(![NSThread isMainThread]||cpEditorHost!=self||!cpEditor||cpEditorSubmitting){
        NSLog(@"CloudPhotos input completion ignored: invalid editor state");
        return;
    }
    NSLog(@"CloudPhotos input completion callback received");
    id field=nil;
    if([cpEditor respondsToSelector:NSSelectorFromString(@"editor")]){
        id editorObj=((id(*)(id,SEL))objc_msgSend)(cpEditor,NSSelectorFromString(@"editor"));
        if([editorObj respondsToSelector:NSSelectorFromString(@"textField")])
            field=((id(*)(id,SEL))objc_msgSend)(editorObj,NSSelectorFromString(@"textField"));
    }
    if(![field respondsToSelector:NSSelectorFromString(@"stringValue")]){
        NSLog(@"CloudPhotos input completion ignored: text field unavailable");
        return;
    }
    if(sender!=field){
        NSLog(@"CloudPhotos input completion: delegate sender differs from editor field");
    }
    id entry=((id(*)(id,SEL))objc_msgSend)(field,NSSelectorFromString(@"stringValue"));
    if(![entry isKindOfClass:[NSString class]])return;
    NSString *password=[entry copy];
    cpEditorSubmitting=YES;
    if([cpEditor respondsToSelector:NSSelectorFromString(@"setTextFieldDelegate:")])
      ((void(*)(id,SEL,id))objc_msgSend)(cpEditor,NSSelectorFromString(@"setTextFieldDelegate:"),nil);
    if([cpEditor respondsToSelector:NSSelectorFromString(@"setInitialTextEntryText:")])
      ((void(*)(id,SEL,id))objc_msgSend)(cpEditor,NSSelectorFromString(@"setInitialTextEntryText:"),@"");
    [cpEditor release];cpEditor=nil;
    id stack=[cpEditorStack retain];
    [cpEditorStack release];cpEditorStack=nil;
    [cpEditorHost release];cpEditorHost=nil;
    if(stack && [stack respondsToSelector:NSSelectorFromString(@"popController")])
       ((void(*)(id,SEL))objc_msgSend)(stack,NSSelectorFromString(@"popController"));
    [stack release];
    if([password length]>0 && [password length]<=512){
        if(!cpPasswordSender)cpPasswordSender=[[CPPhotosPasswordWorker alloc]init];
        NSDictionary *request=[NSDictionary dictionaryWithObjectsAndKeys:
            password,@"text",nil];
        [NSThread detachNewThreadSelector:@selector(send:) toTarget:cpPasswordSender withObject:request];
    }
    [password release];
    cpEditorSubmitting=NO;
}

static void CPPasswordShow(id self,SEL cmd,id unused){
    (void)cmd;(void)unused;
    if(![NSThread isMainThread]||cpEditor || !self)return;
    Class cls=NSClassFromString(@"BRTextEntryController");
    SEL ctor=NSSelectorFromString(@"initWithTextEntryStyle:");
    NSMethodSignature *sig=[cls instanceMethodSignatureForSelector:ctor];
    if(!sig || [sig numberOfArguments]!=3 ||
       strcmp([sig methodReturnType],@encode(id))||
       strcmp([sig getArgumentTypeAtIndex:2],@encode(int))){
        NSLog(@"CloudPhotos Hidden input: BR editor style is unavailable");
        return;
    }
    id stack=nil;
    if([self respondsToSelector:NSSelectorFromString(@"stack")])
        stack=((id(*)(id,SEL))objc_msgSend)(self,NSSelectorFromString(@"stack"));
    if(!stack || ![stack respondsToSelector:NSSelectorFromString(@"pushController:")])return;
    id editor=((id(*)(id,SEL,int))objc_msgSend)([cls alloc],ctor,4);
    SEL delegate=NSSelectorFromString(@"setTextFieldDelegate:");
    SEL init=NSSelectorFromString(@"setInitialTextEntryText:");
    SEL title=NSSelectorFromString(@"setTextEntryTextFieldLabel:");
    SEL masked=NSSelectorFromString(@"setShowUserEnteredText:");
    if(!editor || ![editor respondsToSelector:delegate] ||
       ![editor respondsToSelector:init] ||
       ![editor respondsToSelector:title] ||
       ![editor respondsToSelector:masked]){
        [editor release];
        NSLog(@"CloudPhotos Hidden input: missing native editor methods");
        return;
    }
    BOOL secure=YES;
    NSString *label=@"iCloud input";
    if([unused isKindOfClass:[NSDictionary class]]){
        NSNumber *flag=[unused objectForKey:@"secure"];
        if([flag isKindOfClass:[NSNumber class]])secure=[flag boolValue];
        NSString *kind=[unused objectForKey:@"kind"];
        if([kind isKindOfClass:[NSString class]] && [kind length]<50)
            label=kind;
    }
    cpEditorSecure=secure;
    ((void(*)(id,SEL,BOOL))objc_msgSend)(editor,masked,!secure);
    ((void(*)(id,SEL,id))objc_msgSend)(editor,title,label);
    ((void(*)(id,SEL,id))objc_msgSend)(editor,init,@"");
    ((void(*)(id,SEL,id))objc_msgSend)(editor,delegate,self);
    cpEditorHost=[self retain];cpEditorStack=[stack retain];cpEditor=editor;
    NSLog(@"CloudPhotos Hidden native masked keyboard opened");
    ((void(*)(id,SEL,id))objc_msgSend)(stack,NSSelectorFromString(@"pushController:"),editor);
}

BOOL CloudPhotosPasswordActive(void){return cpEditor!=nil;}
void CloudPhotosPasswordResetOnReturn(void){
    // The user may dismiss the keyboard with Menu rather than submit.
    // Clear the old editor/delegate to permit opening it again.
    if(![NSThread isMainThread] || !cpEditor)return;
    if([cpEditor respondsToSelector:NSSelectorFromString(@"setTextFieldDelegate:")])
        ((void(*)(id,SEL,id))objc_msgSend)(cpEditor,
          NSSelectorFromString(@"setTextFieldDelegate:"),nil);
    [cpEditor release];cpEditor=nil;
    [cpEditorStack release];cpEditorStack=nil;
    [cpEditorHost release];cpEditorHost=nil;
    cpEditorSubmitting=NO;
}
void CloudPhotosPasswordRegister(Class cls){
    if(!cls)return;
    Protocol *proto=objc_getProtocol("BRTextFieldDelegate");
    if(proto)class_addProtocol(cls,proto);
    class_addMethod(cls,NSSelectorFromString(@"icloudphotosOpenPassword:"),
                    (IMP)CPPasswordShow,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"textDidChange:"),
                    (IMP)CPPasswordTextDidChange,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"textDidEndEditing:"),
                    (IMP)CPPasswordTextDidEnd,"v@:@");
}
