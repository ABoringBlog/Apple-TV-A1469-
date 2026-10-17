// Private iCloud live PCM sink. No global audio changes; no media stored.
#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <math.h>
#include <time.h>
#include <stdlib.h>
#define RATE 44100
#define CAP 32768
#define TARGET 13230
#define MAX_BACKLOG 26460
#define CHUNK 441
static int16_t ring[CAP][2];
static _Atomic uint64_t written, consumed, callbacks, rendered, underflows, overruns;
static _Atomic int ended, stopping;
static int primed;
static float envelope;
static double phase;
static float last_sample[2];
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void *reader(void *unused){
 (void)unused;
 unsigned char bytes[4096];size_t held=0;
 for(;;){ssize_t n=read(0,bytes+held,sizeof(bytes)-held);if(n<=0)break;
  size_t size=held+n,frames=size/4;
  for(size_t i=0;i<frames;i++){
   uint64_t w=atomic_load_explicit(&written,memory_order_relaxed);
   uint64_t r=atomic_load_explicit(&consumed,memory_order_acquire);
   if(w-r>=CAP){atomic_fetch_add(&overruns,1);continue;}
   ring[w%CAP][0]=(int16_t)(bytes[i*4]|bytes[i*4+1]<<8);
   ring[w%CAP][1]=(int16_t)(bytes[i*4+2]|bytes[i*4+3]<<8);
   atomic_store_explicit(&written,w+1,memory_order_release);
  }
  held=size%4;for(size_t j=0;j<held;j++)bytes[j]=bytes[frames*4+j];
 }
 atomic_store(&ended,1);return NULL;
}
static void output(void *u,AudioQueueRef q,AudioQueueBufferRef b){
 (void)u; if(atomic_load(&stopping))return;
 int16_t *dst=b->mAudioData;
 uint64_t r=atomic_load_explicit(&consumed,memory_order_relaxed);
 uint64_t w=atomic_load_explicit(&written,memory_order_acquire);
 uint64_t available=w-r;
 // Callback alone advances consumer cursor. Discard only stale backlog.
 if(available>MAX_BACKLOG){r=w-TARGET;available=TARGET;envelope=0;phase=0;atomic_fetch_add(&overruns,1);}
 if(!primed && available>=TARGET)primed=1;
 double ratio=1.0;
 // Slow, bounded clock servo; never periodically restart the audio device.
 if(primed)ratio+=fmax(-.002,fmin(.002,((double)available-TARGET)/2205000.0));
 for(int i=0;i<CHUNK;i++){
  if(primed && w-r>1){
   envelope=fminf(1,envelope+1.0f/220);
   for(int c=0;c<2;c++){
    last_sample[c]=(ring[r%CAP][c]*(1-phase)+ring[(r+1)%CAP][c]*phase)*envelope;
    dst[i*2+c]=(int16_t)last_sample[c];
   }
   phase+=ratio;unsigned advance=(unsigned)phase;phase-=advance;r+=advance;
   atomic_fetch_add(&rendered,1);
  }else{
   for(int c=0;c<2;c++){last_sample[c]*=.97f;dst[i*2+c]=(int16_t)last_sample[c];}
   if(primed){primed=0;envelope=0;phase=0;atomic_fetch_add(&underflows,1);}
  }
 }
 atomic_store_explicit(&consumed,r,memory_order_release);
 atomic_fetch_add(&callbacks,1);
 b->mAudioDataByteSize=CHUNK*4;
 OSStatus err=AudioQueueEnqueueBuffer(q,b,0,NULL);
 if(err){fprintf(stderr,"{\"enqueue_error\":%d}\n",(int)err);atomic_store(&ended,1);}
}
int main(void){
 AudioStreamBasicDescription f={0};f.mSampleRate=RATE;f.mFormatID=kAudioFormatLinearPCM;
 f.mFormatFlags=kLinearPCMFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
 f.mBytesPerPacket=f.mBytesPerFrame=4;f.mFramesPerPacket=1;f.mChannelsPerFrame=2;f.mBitsPerChannel=16;
 AudioQueueRef q;OSStatus err=AudioQueueNewOutput(&f,output,NULL,NULL,NULL,0,&q);
 if(err){fprintf(stderr,"{\"init_error\":%d}\n",(int)err);return 2;}
 AudioQueueSetParameter(q,kAudioQueueParam_Volume,1);
 pthread_t thread;pthread_create(&thread,NULL,reader,NULL);
 for(int i=0;i<3;i++){AudioQueueBufferRef b;err=AudioQueueAllocateBuffer(q,CHUNK*4,&b);if(err)return 3;output(NULL,q,b);}
 err=AudioQueueStart(q,NULL);if(err){fprintf(stderr,"{\"start_error\":%d}\n",(int)err);return 4;}
 double start=now(),last=start,last_input=start;uint64_t prev=0,prev_w=0;
 while(!atomic_load(&ended)){
  usleep(100000);double t=now();
  if(t-last>=1){uint64_t w=atomic_load(&written),r=atomic_load(&consumed),cb=atomic_load(&callbacks);
   fprintf(stderr,"{\"seconds\":%.2f,\"input_frames\":%llu,\"rendered_frames\":%llu,\"queued_ms\":%.2f,\"callbacks\":%llu,\"underflows\":%llu,\"overruns\":%llu}\n",t-start,(unsigned long long)w,(unsigned long long)atomic_load(&rendered),(w-r)*1000.0/RATE,(unsigned long long)cb,(unsigned long long)atomic_load(&underflows),(unsigned long long)atomic_load(&overruns));
   if(cb==prev){fprintf(stderr,"{\"error\":\"callback_stalled\"}\n");break;}
   if(w!=prev_w){last_input=t;prev_w=w;}
   if(t-last_input>3){fprintf(stderr,"{\"error\":\"input_stalled\"}\n");break;}
   prev=cb;last=t;
  }
 }
 atomic_store(&stopping,1);AudioQueueStop(q,true);AudioQueueDispose(q,true);return 0;
}
