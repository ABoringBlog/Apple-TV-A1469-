// FoliaDirect exclusive low-latency audio receiver (FA01).
// Separate from FV01 H264 and other ATV3 applications.
#import <Foundation/Foundation.h>
extern NSString *FDPublicBridgeHost(void);
#import <AudioToolbox/AudioToolbox.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <pthread.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>

#define FD_AUDIO_PORT 18787
#define FD_RING_BYTES 262144u
#define FD_OUTPUT_BYTES 4096u
#define FD_PREFILL_BYTES (FD_OUTPUT_BYTES * 8)
static volatile BOOL faRunning=NO;
static volatile unsigned faGeneration=0;
static volatile int faSocket=-1;
static NSString *const FA_LOG=@"/var/tmp/foliadirect_audio.log";
static void faLog(NSString *s) {
 FILE *f=fopen([FA_LOG UTF8String],"a");
 if(f){fprintf(f,"%.3f %s\n",[[NSDate date]timeIntervalSince1970],[s UTF8String]);fclose(f);}
}
static BOOL faRead(int fd,void *dest,size_t n) {
 size_t offset=0;
 while(offset<n && faRunning){
  ssize_t r=recv(fd,(uint8_t*)dest+offset,n-offset,0);
  if(r>0){offset+=(size_t)r;continue;}
  if(r<0&&errno==EINTR)continue;
  return NO;
 }
 return offset==n;
}
@interface FoliaAudioWorker:NSObject {
 @public
  unsigned generation;
  pthread_mutex_t lock;
  unsigned char ring[FD_RING_BYTES];
  size_t rd,wr,used;
  AudioQueueRef queue;
  BOOL started;
  unsigned long received,underruns,overflowCount,queuedFrames;
}
-(id)initWithGeneration:(unsigned)g;
-(void)run:(id)unused;
-(void)playInto:(AudioQueueBufferRef)buffer;
@end
static void faCallback(void *data,AudioQueueRef q,AudioQueueBufferRef buffer) {
 FoliaAudioWorker *w=(FoliaAudioWorker*)data;
 [w playInto:buffer];
 if(faRunning && w->generation==faGeneration && w->started){
  OSStatus s=AudioQueueEnqueueBuffer(q,buffer,0,NULL);
  if(s!=noErr)faLog([NSString stringWithFormat:@"ENQUEUE_ERROR %d",(int)s]);
 }
}
@implementation FoliaAudioWorker
-(id)initWithGeneration:(unsigned)g {
 self=[super init];
 if(self){generation=g;pthread_mutex_init(&lock,NULL);rd=wr=used=0;
  queue=NULL;started=NO;received=underruns=overflowCount=queuedFrames=0;}
 return self;
}
-(void)dealloc{
 if(queue)AudioQueueDispose(queue,true);
 pthread_mutex_destroy(&lock);
 [super dealloc];
}
-(void)playInto:(AudioQueueBufferRef)b {
 size_t size=b->mAudioDataBytesCapacity;
 if(size>FD_OUTPUT_BYTES)size=FD_OUTPUT_BYTES;
 pthread_mutex_lock(&lock);
 size_t n=size<used?size:used;
 size_t a=n<FD_RING_BYTES-rd?n:FD_RING_BYTES-rd;
 memcpy(b->mAudioData,ring+rd,a);
 if(n>a)memcpy((char*)b->mAudioData+a,ring,n-a);
 rd=(rd+n)%FD_RING_BYTES;used-=n;
 if(n<size)underruns++;
 queuedFrames++;
 pthread_mutex_unlock(&lock);
 if(n<size)memset((char*)b->mAudioData+n,0,size-n);
 b->mAudioDataByteSize=(UInt32)size;
}
-(void)addPCM:(const unsigned char*)bytes length:(size_t)n {
 pthread_mutex_lock(&lock);
 const size_t maxUsed=44100; // at most 250 ms @ 44.1 kHz s16 stereo
 if(n>FD_RING_BYTES){bytes+=n-FD_RING_BYTES;n=FD_RING_BYTES;}
 while(used+n>maxUsed && used>=4) {
  size_t drop=used+n-maxUsed;
  drop=(drop+3)&~(size_t)3;
  if(drop>used)drop=used;
  rd=(rd+drop)%FD_RING_BYTES;used-=drop;overflowCount++;
 }
 size_t a=n<FD_RING_BYTES-wr?n:FD_RING_BYTES-wr;
 memcpy(ring+wr,bytes,a);
 if(n>a)memcpy(ring,bytes+a,n-a);
 wr=(wr+n)%FD_RING_BYTES;used+=n;
 received++;
 pthread_mutex_unlock(&lock);
}
-(void)run:(id)unused {
 NSAutoreleasePool *outer=[[NSAutoreleasePool alloc]init];
 faLog(@"AUDIO_WORKER_START");
 while(faRunning && generation==faGeneration){
  NSAutoreleasePool *cycle=[[NSAutoreleasePool alloc]init];
  int fd=socket(AF_INET,SOCK_STREAM,0);
  if(fd<0){[cycle drain];break;}
  struct timeval timeout={2,0};
  setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
  struct sockaddr_in address={0};
  address.sin_family=AF_INET;address.sin_port=htons(FD_AUDIO_PORT);
  inet_pton(AF_INET,[FDPublicBridgeHost() UTF8String],&address.sin_addr);
  faSocket=fd;
  if(connect(fd,(struct sockaddr*)&address,sizeof(address))!=0){
   faLog(@"AUDIO_CONNECT_RETRY");close(fd);faSocket=-1;
   [cycle drain];if(faRunning)[NSThread sleepForTimeInterval:1.0];continue;
  }
  unsigned char intro[12];
  if(!faRead(fd,intro,sizeof(intro))||memcmp(intro,"FA01",4)!=0){
   faLog(@"AUDIO_BAD_HANDSHAKE");close(fd);faSocket=-1;
   [cycle drain];if(faRunning)[NSThread sleepForTimeInterval:0.5];continue;
  }
  uint32_t netRate=0;memcpy(&netRate,intro+4,4);
  uint32_t rate=ntohl(netRate);
  uint16_t channels=(uint16_t)((intro[8]<<8)|intro[9]);
  uint16_t bits=(uint16_t)((intro[10]<<8)|intro[11]);
  if(!((rate==44100)||(rate==48000))||channels!=2||bits!=16){
   faLog([NSString stringWithFormat:@"AUDIO_BAD_FORMAT %u/%u/%u",rate,channels,bits]);
   close(fd);faSocket=-1;[cycle drain];break;
  }
  AudioStreamBasicDescription fmt={0};
  fmt.mSampleRate=rate;fmt.mFormatID=kAudioFormatLinearPCM;
  fmt.mFormatFlags=kLinearPCMFormatFlagIsSignedInteger|kLinearPCMFormatFlagIsPacked;
  fmt.mBitsPerChannel=16;fmt.mChannelsPerFrame=2;
  fmt.mBytesPerFrame=4;fmt.mFramesPerPacket=1;fmt.mBytesPerPacket=4;
  OSStatus err=AudioQueueNewOutput(&fmt,faCallback,self,NULL,NULL,0,&queue);
  if(err!=noErr||!queue){
   faLog([NSString stringWithFormat:@"AUDIOQUEUE_CREATE_ERROR %d",(int)err]);
   close(fd);faSocket=-1;[cycle drain];break;
  }
  faLog([NSString stringWithFormat:@"AUDIO_CONNECTED rate=%u channels=%u bits=%u",rate,channels,bits]);
  AudioQueueBufferRef buffers[4]={NULL,NULL,NULL,NULL};
  BOOL ok=YES;
  for(int i=0;i<4;i++){
   err=AudioQueueAllocateBuffer(queue,FD_OUTPUT_BYTES,&buffers[i]);
   if(err!=noErr||!buffers[i]){ok=NO;faLog([NSString stringWithFormat:@"AUDIO_ALLOC_ERROR %d",(int)err]);break;}
  }
  BOOL ready=NO;
  while(ok&&faRunning&&generation==faGeneration){
   unsigned char hdr[8];
   if(!faRead(fd,hdr,8))break;
   uint32_t n=0,seq=0;
   memcpy(&n,hdr,4);n=ntohl(n);
   memcpy(&seq,hdr+4,4);seq=ntohl(seq);
   if(n<4||n>65536||(n%4)!=0){faLog(@"AUDIO_BAD_PAYLOAD");break;}
   unsigned char *data=malloc(n);
   if(!data){faLog(@"AUDIO_ALLOC_PACKET_FAIL");break;}
   BOOL got=faRead(fd,data,n);
   if(got)[self addPCM:data length:n];
   free(data);
   if(!got)break;
   if(!ready){
    pthread_mutex_lock(&lock);size_t avail=used;pthread_mutex_unlock(&lock);
    if(avail>=FD_PREFILL_BYTES){
     for(int i=0;i<4;i++){
      [self playInto:buffers[i]];
      err=AudioQueueEnqueueBuffer(queue,buffers[i],0,NULL);
      if(err!=noErr){ok=NO;faLog([NSString stringWithFormat:@"AUDIO_PRIME_ERROR %d",(int)err]);break;}
     }
     if(ok){
      started=YES;err=AudioQueueStart(queue,NULL);
      if(err!=noErr){started=NO;ok=NO;faLog([NSString stringWithFormat:@"AUDIO_START_ERROR %d",(int)err]);}
      else {ready=YES;faLog(@"AUDIO_OUTPUT_STARTED");}
     }
    }
   }
   if(received%200==0) {
    pthread_mutex_lock(&lock);size_t avail=used;
    unsigned long under=underruns,over=overflowCount,played=queuedFrames;
    pthread_mutex_unlock(&lock);
    faLog([NSString stringWithFormat:@"AUDIO_STATS recv=%lu seq=%u ring=%lu queued=%lu underrun=%lu overflow=%lu",received,seq,(unsigned long)avail,played,under,over]);
   }
  }
  started=NO;
  if(queue){AudioQueueStop(queue,true);AudioQueueDispose(queue,true);queue=NULL;}
  shutdown(fd,SHUT_RDWR);close(fd);faSocket=-1;
  pthread_mutex_lock(&lock);rd=wr=used=0;pthread_mutex_unlock(&lock);
  faLog(@"AUDIO_SESSION_ENDED");
  [cycle drain];
  if(faRunning && generation==faGeneration)[NSThread sleepForTimeInterval:0.7];
 }
 faLog(@"AUDIO_WORKER_END");
 [outer drain];
}
@end
static FoliaAudioWorker *faWorker=nil;
void FDAudioStart(void) {
 if(![NSThread isMainThread]||faRunning)return;
 faRunning=YES;faGeneration++;
 faWorker=[[FoliaAudioWorker alloc]initWithGeneration:faGeneration];
 [NSThread detachNewThreadSelector:@selector(run:) toTarget:faWorker withObject:nil];
 faLog(@"AUDIO_START_REQUESTED");
}
void FDAudioStop(void){
 if(![NSThread isMainThread])return;
 faRunning=NO;faGeneration++;
 int fd=faSocket;if(fd>=0)shutdown(fd,SHUT_RDWR);
 // Worker is owned by detached thread until finished. Do not release it during callback.
 faWorker=nil;
 faLog(@"AUDIO_STOP_REQUESTED");
}
