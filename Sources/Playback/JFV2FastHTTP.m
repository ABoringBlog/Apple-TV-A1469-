#import "JFV2FastHTTP.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

// Fixed IPv4-only private endpoint, never a user-controlled URL or proxy.
// The HMAC verifier lives in JFV2EventSender, NOT in this transport.
static BOOL JFReady(int fd, BOOL writable, NSTimeInterval deadline) {
    for (;;) {
        NSTimeInterval remaining=deadline-[NSProcessInfo processInfo].systemUptime;
        if (!(remaining>0))return NO;
        struct timeval tv;
        tv.tv_sec=(long)remaining;
        tv.tv_usec=(long)((remaining-tv.tv_sec)*1000000.0);
        fd_set rfds,wfds;FD_ZERO(&rfds);FD_ZERO(&wfds);
        if (writable) FD_SET(fd,&wfds); else FD_SET(fd,&rfds);
        int n=select(fd+1,writable?NULL:&rfds,writable?&wfds:NULL,NULL,&tv);
        if (n>0)return YES;
        if (n==0)return NO;
        if (errno!=EINTR)return NO;
    }
}
static BOOL JFWriteAll(int fd,const void *data,size_t length,NSTimeInterval deadline) {
    const uint8_t *p=data;
    size_t sent=0;
    while (sent<length) {
        if (!JFReady(fd,YES,deadline))return NO;
        ssize_t n=send(fd,p+sent,length-sent,0);
        if (n>0) {sent+=(size_t)n;continue;}
        if (n<0 && (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK))continue;
        return NO;
    }
    return YES;
}
@implementation JFV2FastHTTP
+ (NSDictionary *)request:(NSURLRequest *)request {
    NSURL *url=request.URL;
    if (!url || ![[url.scheme lowercaseString] isEqualToString:@"http"])return nil;
    NSString *host=url.host;
    // Only local/private IPv4 endpoints are supported (no arbitrary public hosts).
    struct in_addr configured;
    if (inet_pton(AF_INET,[host UTF8String],&configured)!=1)return nil;
    uint32_t address=ntohl(configured.s_addr);
    BOOL trusted=(address==0x7f000001U ||
                  (address&0xff000000U)==0x0a000000U ||
                  (address&0xfff00000U)==0xac100000U ||
                  (address&0xffff0000U)==0xc0a80000U);
    if (!trusted)return nil;
    NSInteger port=url.port?[url.port integerValue]:80;
    if (port<1 || port>65535)return nil;
    NSString *route=url.path;
    BOOL hello=[route isEqualToString:@"/v2/hello"] && url.query.length==38 && [url.query hasPrefix:@"nonce="];
    BOOL control=[route isEqualToString:@"/v2/control"] && url.query==nil;
    if (!hello && !control)return nil;
    NSString *method=request.HTTPMethod ?: @"GET";
    NSData *body=request.HTTPBody;
    if ((hello && (![method isEqualToString:@"GET"] || body.length)) ||
        (control && (![method isEqualToString:@"POST"] || body.length<1 || body.length>4096)))return nil;
    NSString *path=hello?[route stringByAppendingFormat:@"?%@",url.query]:route;
    if ([path rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location!=NSNotFound)return nil;
    NSTimeInterval allowed=MIN(4.0,MAX(0.1,request.timeoutInterval));
    NSTimeInterval deadline=[NSProcessInfo processInfo].systemUptime+allowed;
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if (fd<0)return nil;
    NSDictionary *answer=nil;
    do {
#ifdef SO_NOSIGPIPE
        int yes=1;(void)setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
#endif
        int flags=fcntl(fd,F_GETFL,0);
        if (flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0)break;
        struct sockaddr_in addr;memset(&addr,0,sizeof(addr));
        addr.sin_family=AF_INET;addr.sin_port=htons((uint16_t)port);
        if (inet_pton(AF_INET,[host UTF8String],&addr.sin_addr)!=1)break;
        int connected=connect(fd,(struct sockaddr *)&addr,sizeof(addr));
        if (connected<0 && errno!=EINPROGRESS)break;
        if (connected<0) {
            if (!JFReady(fd,YES,deadline))break;
            int err=0;socklen_t n=sizeof(err);
            if (getsockopt(fd,SOL_SOCKET,SO_ERROR,&err,&n)!=0 || err)break;
        }
        NSString *headers=[NSString stringWithFormat:
           @"%@ %@ HTTP/1.0\r\nHost: %@\r\nConnection: close\r\nContent-Length: %lu\r\nContent-Type: application/json\r\n\r\n",
           method,path,host,(unsigned long)(body?body.length:0)];
        NSData *headerBytes=[headers dataUsingEncoding:NSASCIIStringEncoding];
        if (!headerBytes || headerBytes.length>1024 || !JFWriteAll(fd,headerBytes.bytes,headerBytes.length,deadline))break;
        if (body.length && !JFWriteAll(fd,body.bytes,body.length,deadline))break;
        // No redirects, HTTP chunking, compressed bodies, or unread bytes.
        // Max 8 KiB including headers; reply JSON <=4 KiB.
        NSMutableData *reply=[NSMutableData data];
        uint8_t buffer[2048];
        while (reply.length<8192) {
            if (!JFReady(fd,NO,deadline))break;
            ssize_t n=recv(fd,buffer,sizeof(buffer),0);
            if (n>0) {[reply appendBytes:buffer length:(NSUInteger)n];continue;}
            if (n==0)break;
            if (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK)continue;
            break;
        }
        if (reply.length>8192 || reply.length<15)break;
        NSData *marker=[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        NSRange delimiter=[reply rangeOfData:marker options:0 range:NSMakeRange(0,reply.length)];
        if (delimiter.location==NSNotFound || delimiter.location>4096)break;
        NSData *headerPart=[reply subdataWithRange:NSMakeRange(0,delimiter.location)];
        NSString *headerText=[[[NSString alloc] initWithData:headerPart encoding:NSASCIIStringEncoding] autorelease];
        if (!headerText)break;
        NSArray *lines=[headerText componentsSeparatedByString:@"\r\n"];
        if (!lines.count || !([[lines objectAtIndex:0] hasPrefix:@"HTTP/1.0 200 "] ||
                               [[lines objectAtIndex:0] hasPrefix:@"HTTP/1.1 200 "]))break;
        NSInteger contentLength=-1;
        BOOL invalidHeader=NO;
        for (NSUInteger i=1;i<lines.count;i++) {
            NSString *line=[lines objectAtIndex:i];
            NSRange colon=[line rangeOfString:@":"];
            if (colon.location==NSNotFound){invalidHeader=YES;break;}
            NSString *key=[[line substringToIndex:colon.location] lowercaseString];
            if ([key isEqualToString:@"transfer-encoding"] || [key isEqualToString:@"content-encoding"]) {invalidHeader=YES;break;}
            if ([key isEqualToString:@"content-length"]) {
                if (contentLength>=0){invalidHeader=YES;break;}
                NSString *number=[[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSCharacterSet *nonDigit=[[NSCharacterSet decimalDigitCharacterSet] invertedSet];
                if (!number.length || [number rangeOfCharacterFromSet:nonDigit].location!=NSNotFound){invalidHeader=YES;break;}
                contentLength=[number integerValue];
            }
        }
        NSUInteger payload=NSMaxRange(delimiter);
        if (invalidHeader || contentLength<2 || contentLength>4096 || payload+contentLength!=reply.length)break;
        NSData *json=[reply subdataWithRange:NSMakeRange(payload,(NSUInteger)contentLength)];
        id obj=[NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]])answer=obj;
    } while (0);
    close(fd);
    return answer;
}
@end
