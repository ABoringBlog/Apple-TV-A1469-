'use strict';
// Dedicated Mac Folia video-encoder worker.
// UI/controls/capture remain in Electron main thread; raw BGRA shared frame
// buffer is read here at ~30fps and passed to VideoToolbox's H264 encoder.
// No AirPlay/HLS/JPEG. Worker never touches Mac Folia app account state.
const {parentPort,workerData}=require('worker_threads');
const {spawn}=require('child_process');
const net=require('net');
const path=require('path');
if(!parentPort || !workerData || !workerData.foliaVideoWorker)
  throw new Error('FoliaDirectEncoderWorker should only run as a Worker thread');
const {width,height,fps,sharedFrames,sharedState,bitrate,gop}=workerData;
const OWN_VIDEO_TCP=workerData.videoTcp==='direct';
const videoPort=workerData.videoPort||18786;
let server=null,clients=new Set();
let encodedFrames=0,wireDrops=0,frameIntervals=[],lastFrameAt=0;
let accumulated=Buffer.alloc(0),accessUnit=[];
const bytes=width*height*4;
const pixels=new Uint8Array(sharedFrames);
const state=new Int32Array(sharedState);
const videoArgs=[
 '-hide_banner','-nostdin','-loglevel','warning',
 '-f','rawvideo','-pixel_format','bgra','-video_size',width+'x'+height,
 '-framerate',String(fps),'-i','pipe:0',
 '-vf','scale=1920:1080:flags=bicubic,format=yuv420p',
 '-an','-c:v','h264_videotoolbox','-pix_fmt','yuv420p',
 '-profile:v','main','-level','4.0','-realtime','true',
 '-b:v',bitrate,'-g',String(gop),'-bf','0',
 '-bsf:v','h264_metadata=aud=insert',
 '-f','h264','pipe:1'
];
const nativeVT=workerData.nativeVT===true;
const nativePath=process.env.FOLIA_ATV3_NATIVE_ENCODER;
if(nativeVT && !nativePath)throw new Error('FOLIA_ATV3_NATIVE_ENCODER required');
const ffmpeg=spawn(nativeVT?nativePath:'/usr/local/bin/ffmpeg',
                   nativeVT?[]:videoArgs,{stdio:['pipe','pipe','pipe']});
let running=true,shuttingDown=false,written=0,backpressure=0,lastWrite=0;
let nativeFirstOutputMs=null;
let intervals=[],errors=0;
const emit=(type,more)=>parentPort.postMessage({type,...more});
function nalStart(buf,offset){
 for(let i=offset;i<buf.length-3;i++)if(buf[i]===0&&buf[i+1]===0){
  if(buf[i+2]===1)return {p:i,n:3};
  if(buf[i+2]===0&&buf[i+3]===1)return {p:i,n:4};
 }
 return null;
}
function flushUnit(nals){
 const idr=nals.some(n=>(n[0]&31)===5);
 const packets=[];
 for(const nal of nals){
  const h=Buffer.allocUnsafe(4);h.writeUInt32BE(nal.length,0);
  packets.push(h,nal);
 }
 const payload=Buffer.concat(packets);
 if(!payload.length)return;
 forwardAVCC(payload,idr);
}
function forwardAVCC(payload,idr){
 encodedFrames++;
 const now=Date.now();
 if(lastFrameAt){
  frameIntervals.push(now-lastFrameAt);
  if(frameIntervals.length>120)frameIntervals.shift();
 }
 lastFrameAt=now;
 for(const socket of clients){
  if(socket.destroyed){clients.delete(socket);continue;}
  if(!socket.__ready && !idr)continue;
  if(socket.writableLength>200000){
   socket.__ready=false;socket.__drops++;wireDrops++;
   continue;
  }
  socket.__ready=true;
  const hdr=Buffer.allocUnsafe(16);
  hdr.writeUInt32BE(payload.length,0);
  hdr.writeUInt32BE(encodedFrames,4);
  hdr.writeBigUInt64BE(BigInt(now),8);
  socket.write(Buffer.concat([hdr,payload]));
  socket.__frames++;
 }
}
function pushNals(chunk){
 accumulated=Buffer.concat([accumulated,chunk]);
 if(accumulated.length>8*1024*1024){
  accumulated=Buffer.alloc(0);accessUnit=[];
  emit('encoder-error',{error:'worker AnnexB input overlarge'});
  return;
 }
 for(;;){
  const a=nalStart(accumulated,0);
  if(!a)break;
  if(a.p){accumulated=accumulated.subarray(a.p);continue;}
  const b=nalStart(accumulated,a.n);
  if(!b)break;
  const nal=accumulated.subarray(a.n,b.p);
  if(nal.length){
   if((nal[0]&31)===9){
    if(accessUnit.length)flushUnit(accessUnit);
    accessUnit=[];
   }else accessUnit.push(nal);
  }
  accumulated=accumulated.subarray(b.p);
 }
}
// Native VT outputs EXACT one AU per callback with BE32 length, followed
// by ready-to-forward AVCC NALs. No 1-frame lookahead from AnnexB AUD parser.
let nativeChunks=Buffer.alloc(0);
function pushNativeFrames(chunk){
 nativeChunks=Buffer.concat([nativeChunks,chunk]);
 if(nativeChunks.length>8*1024*1024){
  nativeChunks=Buffer.alloc(0);emit('encoder-error',{error:'native AVCC excessive backlog'});return;
 }
 while(nativeChunks.length>=4){
  const n=nativeChunks.readUInt32BE(0);
  if(n<5||n>700000){emit('encoder-error',{error:'native AVCC malformed packet len='+n});nativeChunks=Buffer.alloc(0);return;}
  if(nativeChunks.length<4+n)return;
  const payload=nativeChunks.subarray(4,4+n);
  let p=0,sync=false,valid=true,hasVcl=false;
  while(p+4<=n){
   const len=payload.readUInt32BE(p);p+=4;
   if(!len || p+len>n){valid=false;break;}
   const type=payload[p]&31;
   if(type===5){sync=true;hasVcl=true;}
   if(type===1)hasVcl=true;
   p+=len;
  }
  if(!valid||p!==n||!hasVcl){
   emit('encoder-error',{error:'native AVCC bad NAL boundaries'});
   nativeChunks=Buffer.alloc(0);return;
  }
  forwardAVCC(payload,sync);
  nativeChunks=nativeChunks.subarray(4+n);
 }
}
if(OWN_VIDEO_TCP){
 server=net.createServer(socket=>{
  const ip=String(socket.remoteAddress||'').replace(/^::ffff:/,'');
  if(![process.env.FOLIA_ATV3_ATV_IP,process.env.FOLIA_ATV3_MAC_HOST,'127.0.0.1'].includes(ip)){
    socket.destroy();return;
  }
  socket.setNoDelay(true);
  socket.__ready=false;socket.__frames=0;socket.__drops=0;
  clients.add(socket);
  socket.write('FV01','ascii');
  emit('clients',{count:clients.size,frames:[...clients].map(s=>s.__frames),
    drops:[...clients].map(s=>s.__drops)});
  socket.on('close',()=>{
   clients.delete(socket);
   emit('clients',{count:clients.size,frames:[...clients].map(s=>s.__frames),
     drops:[...clients].map(s=>s.__drops)});
  });
  socket.on('error',()=>{});
 });
 server.on('error',e=>emit('encoder-error',{error:'worker TCP '+e.message}));
 server.listen(videoPort,process.env.FOLIA_ATV3_MAC_HOST,()=>emit('video-ready',{port:videoPort}));
}
ffmpeg.stdout.on('data',b=>{
 if(nativeVT)pushNativeFrames(b);
 else if(OWN_VIDEO_TCP)pushNals(b);
 else emit('h264',{data:b});
});
ffmpeg.stderr.on('data',b=>{
 const msg=String(b);
 const match=msg.match(/NATIVE_VT_FIRST_OUTPUT_MS\s+(\d+)/);
 if(match)nativeFirstOutputMs=Number(match[1]);
 if(/error|fail/i.test(msg))emit('encoder-error',{error:msg.slice(0,250)});
});
ffmpeg.stdin.on('error',e=>emit('encoder-error',{error:'stdin:'+e.message}));
ffmpeg.on('error',e=>emit('encoder-error',{error:'spawn:'+e.message}));
ffmpeg.on('exit',(code,signal)=>{
 running=false;clearInterval(pump);clearInterval(monitor);
 if(!shuttingDown || (code!==0 && signal!=='SIGTERM'))emit('encoder-error',{error:'encoder stopped '+code+' / '+signal});
});
ffmpeg.on('spawn',()=>emit('ready',{}));
// Keep frame data OWNED by worker while ffmpeg's stdin queues asynchronous
// writes: copy from shared triple buffering to independent Buffer.
function submit(){
 if(!running||ffmpeg.stdin.destroyed)return;
 const slot=Atomics.load(state,0);
 if(slot<0)return;
 if(ffmpeg.stdin.writableLength>bytes*(nativeVT?1:2)){backpressure++;return;}
 Atomics.store(state,1,slot);
 const bgra=Buffer.allocUnsafe(bytes);
 bgra.set(pixels.subarray(slot*bytes,(slot+1)*bytes));
 Atomics.store(state,1,-1);
 ffmpeg.stdin.write(bgra);
 written++;
 const now=Date.now();
 if(lastWrite){
   intervals.push(now-lastWrite);
   if(intervals.length>120)intervals.shift();
 }
 lastWrite=now;
}
const pump=setInterval(submit,1000/fps);
const monitor=setInterval(()=>{
 const list=[...intervals].sort((a,b)=>a-b);
 const timings=[...frameIntervals].sort((a,b)=>a-b);
 emit('stats',{written,backpressure,encodedFrames,wireDrops,
    encoder:nativeVT?'nativeVT':'ffmpeg',nativeFirstOutputMs,lagFrames:written-encodedFrames,
    clients:clients.size,
    clientFrames:[...clients].map(s=>s.__frames),
    clientDrops:[...clients].map(s=>s.__drops),
    networkFrameP90:timings.length?timings[Math.floor(timings.length*.9)]:null,
    networkFrameMax:timings.length?timings[timings.length-1]:null,
    intervalMean:list.length?list.reduce((a,b)=>a+b,0)/list.length:null,
    intervalP90:list.length?list[Math.floor(list.length*.9)]:null,
    intervalMax:list.length?list[list.length-1]:null});
},2000);
parentPort.on('message',message=>{
 if(message&&message.type==='shutdown'){
   shuttingDown=true;running=false;clearInterval(pump);clearInterval(monitor);
   for(const client of clients)client.destroy();
   if(server)try{server.close()}catch{}
   try{ffmpeg.stdin.end()}catch{}
   setTimeout(()=>{try{ffmpeg.kill('SIGTERM')}catch{}},400).unref();
 }
});
