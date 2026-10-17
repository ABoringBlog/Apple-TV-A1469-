// Isolated CloudPhotosDirect live raw H.264 receiver: macOS Mac -> AppleTV3
// No HLS, AirPlay, JPEG or changes to Folia application's UI.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#import <objc/runtime.h>
static volatile BOOL streamRun=NO;
static volatile unsigned streamGeneration=0;
static volatile int streamFD=-1;
static volatile int inflight=0;
static volatile unsigned frameRead=0,frameSubmitted=0,frameDropped=0;
static volatile unsigned decodeErrors=0;
static NSString *const LOGPATH=@"/var/tmp/cloudphotos_direct_tcp_video.log";
static void trace(NSString *s){
  FILE *f=fopen([LOGPATH UTF8String],"a");
  if(f){fprintf(f,"%.3f %s\n",[[NSDate date]timeIntervalSince1970],[s UTF8String]);fclose(f);}
}
static int recvExactly(int fd,uint8_t *b,size_t total){
  size_t got=0;
  while(got<total && streamRun){
    ssize_t n=recv(fd,b+got,total-got,0);
    if(n==0)return -1;
    if(n<0){
      if(errno==EINTR)continue;
      return -1;
    }
    got+=(size_t)n;
  }
  return got==total?0:-1;
}
@interface CloudPhotosDirectStreamWorker:NSObject {
  AVSampleBufferDisplayLayer *_display;
  unsigned _generation;
}
-(void)run:(id)unused;
-(void)showSample:(NSValue*)value;
-(id)initWithDisplay:(AVSampleBufferDisplayLayer *)d generation:(unsigned)gen;
@end
@implementation CloudPhotosDirectStreamWorker
-(id)initWithDisplay:(AVSampleBufferDisplayLayer*)d generation:(unsigned)gen {
  self=[super init];
  if(self){_display=[d retain];_generation=gen;}
  return self;
}
-(void)dealloc{
  [_display release];
  [super dealloc];
}
-(void)showSample:(NSValue*)value{
  // The sample is CFRetained by producer and must be released regardless
  // of current stream state. Display layer is updated ONLY on main thread.
  CMSampleBufferRef sample=(CMSampleBufferRef)[value pointerValue];
  if(streamRun && _generation==streamGeneration && sample && _display){
    @try {
      if(_display.status==AVQueuedSampleBufferRenderingStatusFailed){
        // The known old static-frame test reported AVFoundation -11847
        // after minutes with no new packets. Only recover on a new IDR
        // to rebuild decoder state without presenting stale P frames.
        CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
        BOOL sync=NO;
        if(attachments&&CFArrayGetCount(attachments)){
          CFDictionaryRef a=(CFDictionaryRef)CFArrayGetValueAtIndex(attachments,0);
          sync=CFDictionaryGetValue(a,kCMSampleAttachmentKey_NotSync)==kCFBooleanFalse;
        }
        if(sync){
          [_display flushAndRemoveImage];
          trace([NSString stringWithFormat:@"LAYER_RESET_AT_IDR status=%ld error=%@",
            (long)_display.status,_display.error]);
        }
      }
      if(_display.status!=AVQueuedSampleBufferRenderingStatusFailed)
        [_display enqueueSampleBuffer:sample];
      frameSubmitted++;
      if(frameSubmitted%30==0)
        trace([NSString stringWithFormat:@"SUBMITTED %u received=%u dropped=%u outstanding=%d status=%ld error=%@",
          frameSubmitted,frameRead,frameDropped,inflight,(long)_display.status,_display.error]);
    }@catch(NSException *e) {
      decodeErrors++;
      trace([NSString stringWithFormat:@"ENQUEUE_EXCEPTION %@",e]);
    }
  }
  if(sample)CFRelease(sample);
  @synchronized(self){if(inflight>0)inflight--;}
}
-(void)run:(id)unused{
  NSAutoreleasePool *outer=[[NSAutoreleasePool alloc]init];
  trace(@"FV01_STREAM_CONNECT_START");
  struct sockaddr_in address={0};
  address.sin_family=AF_INET;
  address.sin_port=htons(18792);
  inet_pton(AF_INET,"192.0.2.24",&address.sin_addr);
  while(streamRun && _generation==streamGeneration){
    NSAutoreleasePool *attemptPool=[[NSAutoreleasePool alloc]init];
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if(fd<0){[attemptPool drain];break;}
    struct timeval to={2,0};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&to,sizeof(to));
    streamFD=fd;
    if(connect(fd,(struct sockaddr*)&address,sizeof(address))!=0){
      trace(@"CONNECT_FAILED_RETRY");
      close(fd);streamFD=-1;
      [attemptPool drain];
      if(streamRun)[NSThread sleepForTimeInterval:1.0];
      continue;
    }
    trace(@"FV01_CONNECTED");
    uint8_t magic[4];
    NSData *sps=nil,*pps=nil;
    CMVideoFormatDescriptionRef format=NULL;
    if(!recvExactly(fd,magic,4) && memcmp(magic,"FV01",4)==0){
      BOOL waitForSync=YES;
      while(streamRun && _generation==streamGeneration){
        uint8_t head[16];
        if(recvExactly(fd,head,16))break;
        uint32_t length=0,seq=0;
        memcpy(&length,head,4);length=ntohl(length);
        memcpy(&seq,head+4,4);seq=ntohl(seq);
        if(length<5 || length>700000){trace(@"BAD_PAYLOAD_LENGTH");break;}
        uint8_t *buffer=malloc(length),*accessUnit=malloc(length);
        if(!buffer||!accessUnit){free(buffer);free(accessUnit);trace(@"ALLOC_FAIL");break;}
        if(recvExactly(fd,buffer,length)){free(buffer);free(accessUnit);break;}
        size_t in=0,out=0;
        BOOL sync=NO;
        while(in+4<=length){
          uint32_t nalLength=0;
          memcpy(&nalLength,buffer+in,4);nalLength=ntohl(nalLength);in+=4;
          if(!nalLength || nalLength>length-in){out=0;break;}
          uint8_t typ=buffer[in]&31;
          if(typ==7){[sps release];sps=[[NSData alloc]initWithBytes:buffer+in length:nalLength];}
          else if(typ==8){[pps release];pps=[[NSData alloc]initWithBytes:buffer+in length:nalLength];}
          else if(typ==5||typ==1||typ==6){
            uint32_t n=htonl(nalLength);
            memcpy(accessUnit+out,&n,4);out+=4;
            memcpy(accessUnit+out,buffer+in,nalLength);out+=nalLength;
            if(typ==5)sync=YES;
          }
          in+=nalLength;
        }
        free(buffer);
        frameRead++;
        if(sync&&sps&&pps&&!format){
          const uint8_t *params[]={sps.bytes,pps.bytes};
          size_t sizes[]={sps.length,pps.length};
          OSStatus status=CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL,2,params,sizes,4,&format);
          trace([NSString stringWithFormat:@"VIDEO_FORMAT status=%d sps=%lu pps=%lu",
            (int)status,(unsigned long)sps.length,(unsigned long)pps.length]);
        }
        if(!out||!format){free(accessUnit);continue;}
        if(waitForSync&&!sync){frameDropped++;free(accessUnit);continue;}
        if(sync)waitForSync=NO;
        // Allow a very short main-thread jitter burst without breaking a
        // whole H264 P-frame chain. Worst-case pending main-thread samples <= 2/15=133ms.
        // The v18 sender emits a fresh IDR every 15 frames (0.5sec) so
        // true backpressure recovers sooner than v17 GOP30.
        // Do not queue unlimited frames and build latency.
        BOOL accepted=NO;
        @synchronized(self){
          if(inflight<2){inflight++;accepted=YES;}
        }
        if(!accepted){
          frameDropped++;
          waitForSync=YES;  // P frame chain must restart at next IDR
          free(accessUnit);
          continue;
        }
        CMBlockBufferRef block=NULL;
        OSStatus status=CMBlockBufferCreateWithMemoryBlock(NULL,NULL,out,NULL,NULL,0,out,0,&block);
        if(!status)status=CMBlockBufferReplaceDataBytes(accessUnit,block,0,out);
        free(accessUnit);
        CMSampleBufferRef sample=NULL;
        size_t sampleSize=out;
        // DisplayImmediately keeps AVSampleBufferDisplayLayer from introducing
        // the old AVPlayer/HLS multi-second buffering timeline.
        CMSampleTimingInfo timing={CMTimeMake(1,15),CMTimeMake(seq,15),kCMTimeInvalid};
        if(!status)status=CMSampleBufferCreateReady(NULL,block,format,1,1,&timing,1,&sampleSize,&sample);
        if(block)CFRelease(block);
        if(status||!sample){
          decodeErrors++;
          @synchronized(self){inflight--;}
          if(sample)CFRelease(sample);
          continue;
        }
        CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,YES);
        if(attachments&&CFArrayGetCount(attachments)){
          CFMutableDictionaryRef a=(CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments,0);
          CFDictionarySetValue(a,kCMSampleAttachmentKey_DisplayImmediately,kCFBooleanTrue);
          CFDictionarySetValue(a,kCMSampleAttachmentKey_NotSync,sync?kCFBooleanFalse:kCFBooleanTrue);
        }
        // +1 CF retain belongs to the main-thread delivery method.
        [self performSelectorOnMainThread:@selector(showSample:)
           withObject:[NSValue valueWithPointer:sample] waitUntilDone:NO];
      }
    }
    if(format)CFRelease(format);
    [sps release];[pps release];
    shutdown(fd,SHUT_RDWR);
    close(fd);streamFD=-1;
    [attemptPool drain];
    if(streamRun){trace(@"STREAM_ENDED_RECONNECT");[NSThread sleepForTimeInterval:0.8];}
  }
  trace([NSString stringWithFormat:@"STREAM_STOPPED read=%u shown=%u drop=%u errors=%u",
    frameRead,frameSubmitted,frameDropped,decodeErrors]);
  [outer drain];
}
@end
static CloudPhotosDirectStreamWorker *activeWorker=nil;
void CloudPhotosDirectStreamStart(AVSampleBufferDisplayLayer *layer){
  if(!layer || ![NSThread isMainThread] || streamRun)return;
  streamRun=YES;
  streamGeneration++;
  frameRead=frameSubmitted=frameDropped=decodeErrors=0;
  inflight=0;
  activeWorker=[[CloudPhotosDirectStreamWorker alloc]initWithDisplay:layer generation:streamGeneration];
  trace(@"STREAM_START");
  [NSThread detachNewThreadSelector:@selector(run:) toTarget:activeWorker withObject:nil];
}
void CloudPhotosDirectStreamStop(void){
  if(![NSThread isMainThread])return;
  streamRun=NO;
  streamGeneration++;
  int fd=streamFD;
  if(fd>=0)shutdown(fd,SHUT_RDWR);
  // Don't free worker during pending main-thread callbacks. Next launch
  // may retain it, bounded test leaks one temporary object per open.
  activeWorker=nil;
  trace(@"STREAM_STOP_REQUESTED");
}
