'use strict';
// Folia runs in Mac Electron. Only a compressed H.264 elementary stream
// traverses the LAN to Apple TV 3. No AirPlay/HLS/JPEG transmission.
const http=require('http');
const net=require('net');
const {spawn}=require('child_process');
const {Worker}=require('worker_threads');
const path=require('path');
// Keep original Folia's proven 1280x720 compositor untouched.
 // Only the H.264 OUTPUT is 1920x1080: this avoids the previous offscreen gray clipping.
const AUDIO_PORT=18787;
let audioServer=null,audioClients=new Set(),audioRate=44100;
let audioPackets=0,audioBytes=0,audioSentPackets=0,audioDrops=0,audioLastAt=0;
const INPUT_WIDTH=1280,INPUT_HEIGHT=720;
const WIDTH=1920,HEIGHT=1080,FPS=30,VIDEO_PORT=18786,CONTROL_PORT=18782;
const TARGET_BITRATE='5200k', GOP=15;
const MAC_HOST=process.env.FOLIA_ATV3_MAC_HOST;
const ATV_IP=process.env.FOLIA_ATV3_ATV_IP;
if(!MAC_HOST || !ATV_IP)throw new Error('Set FOLIA_ATV3_MAC_HOST and FOLIA_ATV3_ATV_IP');
const ALLOW=new Set([ATV_IP,MAC_HOST,'127.0.0.1']);
const KEYS=new Set(['key-up','key-down','key-left','key-right','key-select','key-back','key-playback',
  'play','pause','play-pause','previous','next']);
let video=null,control=null,ffmpeg=null,pump=null;
let forcedPaintTimer=null,forcePaintCalls=0,forcePaintErrors=0;
// Offscreen RAF targets 45Hz while H264/HDMI stays 1080p30.
 // Measured on 2016 Iris 540: 45Hz eliminates >50ms RAF stalls without
 // saturating the video encoder as 60Hz does. Reversible by env or diag.
let renderFps=[30,45,60].includes(Number(process.env.FOLIA_ATV3_RENDER_FPS))
 ?Number(process.env.FOLIA_ATV3_RENDER_FPS):45;
let paintPeriodMs=33,activePaintWindow=null;
const USE_ENCODER_WORKER=process.env.FOLIA_ATV3_ENCODER_WORKER==='1';
const WORKER_OWNS_NETWORK=USE_ENCODER_WORKER&&process.env.FOLIA_ATV3_WORKER_NETWORK==='1';
const NATIVE_VT_ENCODER=USE_ENCODER_WORKER&&process.env.FOLIA_ATV3_NATIVE_VT==='1';
let workerNetworkReady=false,workerClientCount=0,workerClientFrames=[],workerClientDrops=[];
let encoderWorker=null,encoderWorkerReady=false,encoderWorkerStats={};
let sharedPixels=null,sharedHeader=null,lastWrittenSlot=0,workerCaptureDrops=0;
const FORCE_PAINT=process.env.FOLIA_ATV3_FORCE_PAINT==='1';
// Paint can fire >45 times/s but H264 is capped at 30fps on ATV3.
// Bitmap conversion of all paint events costs ~160 MB/s on the 2016 Mac.
// Don't synchronously copy bitmap data more often than encoding needs.
let captureThrottleMs=Number(process.env.FOLIA_ATV3_CAPTURE_THROTTLE_MS||0);
let captureSkipped=0,lastCaptureAt=0,encoderInputBackpressure=0;
let intervalHistory=[],lastEncodedAt=0;
let paintCount=0,sentCount=0,encodedFrames=0,frameLatest=null,lastPaintTime=0;
let controls=0,lastControl=null,encoderError=null,clients=new Set();
let accumulated=Buffer.alloc(0),accessUnit=[],sps=null,pps=null;
let encoderStarted=Date.now(),frameDebug=null;
function ip(socket){return String(socket.remoteAddress||'').replace(/^::ffff:/,'');}
function emitJSON(res,code,value) {
 const data=Buffer.from(JSON.stringify(value));
 res.writeHead(code,{'Content-Type':'application/json','Content-Length':data.length,'Cache-Control':'no-store'});
 res.end(data);
}
function findStart(buf,offset){
 for(let n=offset;n<buf.length-3;n++)if(buf[n]===0&&buf[n+1]===0){
   if(buf[n+2]===1)return {p:n,size:3};
   if(buf[n+2]===0&&buf[n+3]===1)return {p:n,size:4};
 }
 return null;
}
function packetFromNals(items) {
 const out=[];
 for(const nal of items){
   const hdr=Buffer.allocUnsafe(4);hdr.writeUInt32BE(nal.length,0);
   out.push(hdr,nal);
 }
 return Buffer.concat(out);
}
function onNAL(nal) {
 const type=nal[0]&31;
 if(type===9) {
   if(accessUnit.length)flushUnit(accessUnit);
   accessUnit=[];
 } else {
   accessUnit.push(nal);
   if(type===7)sps=nal;
   if(type===8)pps=nal;
 }
}
function flushUnit(nals) {
 const isSync=nals.some(n=>(n[0]&31)===5);
 const payload=packetFromNals(nals);
 if(!payload.length)return;
 encodedFrames++;
 const now=Date.now();
 if(lastEncodedAt){
   intervalHistory.push(now-lastEncodedAt);
   if(intervalHistory.length>120)intervalHistory.shift();
 }
 lastEncodedAt=now;
 frameDebug={encodedFrames,encodedAt:now,sync:isSync,len:payload.length};
 for(const peer of clients){
   if(peer.destroyed){clients.delete(peer);continue;}
   if(!peer.__ready && !isSync)continue;
   if(peer.writableLength>200000){
     peer.__ready=false;
     peer.__drops=(peer.__drops||0)+1;
     continue;
   }
   peer.__ready=true;
   const head=Buffer.allocUnsafe(16);
   head.writeUInt32BE(payload.length,0);
   head.writeUInt32BE(encodedFrames,4);
   head.writeBigUInt64BE(BigInt(Date.now()),8);
   peer.write(Buffer.concat([head,payload]));
   peer.__frames=(peer.__frames||0)+1;
 }
 if(encodedFrames%150===0)
   console.log('[FOLIA-DIRECT] H264',frameDebug,'clients',clients.size,
     'paint',paintCount,'pump',sentCount);
}
function pushNals(chunk) {
 if(accumulated.length>8*1024*1024){
   encoderError='AnnexB overlarge buffer';accumulated=Buffer.alloc(0);accessUnit=[];
 }
 accumulated=Buffer.concat([accumulated,chunk]);
 for(;;){
  const a=findStart(accumulated,0);if(!a)break;
  if(a.p>0){accumulated=accumulated.subarray(a.p);continue;}
  const b=findStart(accumulated,a.size);if(!b)break;
  const nal=accumulated.subarray(a.size,b.p);
  if(nal.length)onNAL(nal);
  accumulated=accumulated.subarray(b.p);
 }
}
function makeVideo(win){
 const argv=[
   '-hide_banner','-nostdin','-loglevel','warning',
   '-f','rawvideo','-pixel_format','bgra','-video_size',INPUT_WIDTH+'x'+INPUT_HEIGHT,
   '-framerate',String(FPS),'-i','pipe:0',
   '-vf','scale=1920:1080:flags=bicubic,format=yuv420p',
   '-an','-c:v','h264_videotoolbox','-pix_fmt','yuv420p',
   '-profile:v','main','-level','4.0','-realtime','true',
   '-b:v',TARGET_BITRATE,'-g',String(GOP),'-bf','0',
   '-bsf:v','h264_metadata=aud=insert',
   '-f','h264','pipe:1'
 ];
 if(USE_ENCODER_WORKER){
   // Frames are transferred via triple-buffered SharedArrayBuffer. The worker
   // paces stdin into VideoToolbox independently from Electron UI work.
   const frameSize=INPUT_WIDTH*INPUT_HEIGHT*4;
   const framesSAB=new SharedArrayBuffer(frameSize*3);
   const headerSAB=new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT*2);
   sharedPixels=new Uint8Array(framesSAB);
   sharedHeader=new Int32Array(headerSAB);
   Atomics.store(sharedHeader,0,-1);
   Atomics.store(sharedHeader,1,-1);
   encoderWorker=new Worker(path.join(__dirname,'atv3EncoderWorker.cjs'),{
     workerData:{foliaVideoWorker:true,width:INPUT_WIDTH,height:INPUT_HEIGHT,
                 fps:FPS,sharedFrames:framesSAB,sharedState:headerSAB,
                 bitrate:TARGET_BITRATE,gop:GOP,
                 videoTcp:WORKER_OWNS_NETWORK?'direct':null,videoPort:VIDEO_PORT,
                 nativeVT:NATIVE_VT_ENCODER}
   });
   encoderWorker.on('message',message=>{
     if(message.type==='h264')pushNals(Buffer.from(message.data));
     else if(message.type==='ready')encoderWorkerReady=true;
     else if(message.type==='video-ready')workerNetworkReady=true;
     else if(message.type==='clients'){
       workerClientCount=message.count;
       workerClientFrames=message.frames;
       workerClientDrops=message.drops;
     }else if(message.type==='stats'){
       encoderWorkerStats=message;
       if(WORKER_OWNS_NETWORK){
         encodedFrames=message.encodedFrames||0;
         workerClientCount=message.clients||0;
         workerClientFrames=message.clientFrames||[];
         workerClientDrops=message.clientDrops||[];
       }
     }
     else if(message.type==='encoder-error'){
       encoderError=message.error;
       console.error('[FOLIA-DIRECT] encoder worker:',encoderError);
     }
   });
   encoderWorker.on('error',e=>{encoderError='worker error '+e.message;encoderWorkerReady=false});
   encoderWorker.on('exit',code=>{
     if(code!==0)encoderError='worker exit '+code;
     encoderWorkerReady=false;
   });
 }else{
 ffmpeg=spawn('/usr/local/bin/ffmpeg',argv,{stdio:['pipe','pipe','pipe']});
 ffmpeg.stdout.on('data',pushNals);
 ffmpeg.stderr.on('data',b=>{let s=String(b);if(/error|fail/i.test(s)){
   encoderError=s.slice(0,240);console.warn('[FOLIA-DIRECT] ffmpeg',encoderError);
 }});
 ffmpeg.stdin.on('error',e=>{encoderError='stdin:'+e.message});
 ffmpeg.on('exit',(code)=>{encoderError='encoder stopped '+code;ffmpeg=null;});
 }
 win.webContents.setFrameRate(renderFps);
 win.webContents.on('paint',(_,rect,image)=>{
   try{
     const now=Date.now();
     if(captureThrottleMs>0 && now-lastCaptureAt<captureThrottleMs){
       captureSkipped++;return;
     }
     lastCaptureAt=now;
     const size=image.getSize();
     if(!size.width || !size.height)return;
     let frame=size.width===INPUT_WIDTH && size.height===INPUT_HEIGHT?image
       :image.resize({width:INPUT_WIDTH,height:INPUT_HEIGHT,quality:'good'});
     const pixels=frame.getBitmap();
     if(pixels.length!==INPUT_WIDTH*INPUT_HEIGHT*4){encoderError='pixel length '+pixels.length;return;}
     if(USE_ENCODER_WORKER){
       const selected=Atomics.load(sharedHeader,0);
       const reading=Atomics.load(sharedHeader,1);
       let slot=-1;
       for(let n=0;n<3;n++){
         const candidate=(lastWrittenSlot+1+n)%3;
         if(candidate!==selected && candidate!==reading){slot=candidate;break;}
       }
       if(slot<0)workerCaptureDrops++;
       else{
         sharedPixels.set(pixels,slot*INPUT_WIDTH*INPUT_HEIGHT*4);
         Atomics.store(sharedHeader,0,slot);
         lastWrittenSlot=slot;
       }
     }else frameLatest=pixels;
     lastPaintTime=Date.now();paintCount++;
   }catch(e){encoderError='paint '+e.message;}
 });
 activePaintWindow=win;
 restartPaintTimer(win);
 if(!USE_ENCODER_WORKER)pump=setInterval(()=>{
   if(!frameLatest || !ffmpeg || ffmpeg.stdin.destroyed)return;
   if(ffmpeg.stdin.writableLength>INPUT_WIDTH*INPUT_HEIGHT*4*2){
     encoderInputBackpressure++;return;
   }
   ffmpeg.stdin.write(frameLatest);sentCount++;
 },Math.floor(1000/FPS));
}
function restartPaintTimer(win){
 if(forcedPaintTimer){clearInterval(forcedPaintTimer);forcedPaintTimer=null;}
 if(!FORCE_PAINT||!win||win.isDestroyed()||win.webContents.isDestroyed())return;
 forcedPaintTimer=setInterval(()=>{
   if(win.isDestroyed()||win.webContents.isDestroyed())return;
   try{
     if(typeof win.webContents.invalidate==='function'){
       win.webContents.invalidate();
       forcePaintCalls++;
     }
   }catch(e){
     forcePaintErrors++;
     if(forcePaintErrors===1)console.error('[FOLIA-DIRECT] invalidate error',e);
   }
 },paintPeriodMs);
}
function health(){
 return {service:'folia-direct-h264',mode:'direct',
  running:!!ffmpeg || (USE_ENCODER_WORKER && encoderWorkerReady),
  videoPort:VIDEO_PORT,
  atvConnected:WORKER_OWNS_NETWORK?workerClientCount>0:clients.size>0,
  activeClients:WORKER_OWNS_NETWORK?workerClientCount:clients.size,
  clientReceivedFrames:WORKER_OWNS_NETWORK?workerClientFrames:
    [...clients].map(c=>c.__frames||0),
  clientSenderDrops:WORKER_OWNS_NETWORK?workerClientDrops:
    [...clients].map(c=>c.__drops||0),
  framesEncoded:encodedFrames,framesSubmitted:sentCount,
  paintEvents:paintCount,paintAgeMs:lastPaintTime?Date.now()-lastPaintTime:null,
  forcePaint:FORCE_PAINT,forcePaintCalls,forcePaintErrors,
  renderFps,paintPeriodMs,
  captureThrottleMs,captureSkipped,encoderInputBackpressure,
  encoderWorker:USE_ENCODER_WORKER,encoderWorkerReady,encoderWorkerStats,workerCaptureDrops,
  workerNetwork:WORKER_OWNS_NETWORK,workerNetworkReady,nativeVTEncoder:NATIVE_VT_ENCODER,
  encodedIntervalMs:intervalHistory.length?{
    avg:Math.round(10*intervalHistory.reduce((a,b)=>a+b,0)/intervalHistory.length)/10,
    p90:[...intervalHistory].sort((a,b)=>a-b)[Math.floor(intervalHistory.length*.9)],
    max:Math.max(...intervalHistory)
  }:null,
  frame:frameDebug,encoderError,videoCodec:'H264 Main L4.0 1920x1080@30 (upscaled from 1280x720 original UI)',
  inputResolution:[INPUT_WIDTH,INPUT_HEIGHT],outputResolution:[WIDTH,HEIGHT],targetFps:FPS,gopFrames:GOP,
  audioStatus:audioPackets>0?'PCM_SENDING':'WAITING_FOR_FOLIA_PCM',
  audioPort:AUDIO_PORT,audioRate,audioClients:audioClients.size,
  audioPackets,audioBytes,audioSentPackets,audioDrops,
  audioLastAgeMs:audioLastAt?Date.now()-audioLastAt:null,
  controlCount:controls,lastControl,startedAt:encoderStarted,
  transport:'TCP raw AVCC, no HLS/AirPlay/JPEG'};
}
function startBridge(win,app,ipcMain) {
 if(video)throw new Error('direct stream already started');
 makeVideo(win);
 // FA01 is separate from, and cannot modify, the verified FV01 H264 path.
 audioServer=net.createServer(s=>{
   if(!ALLOW.has(ip(s))){s.destroy();return;}
   s.setNoDelay(true);s.setKeepAlive(true,10000);
   const handshake=Buffer.alloc(12);
   handshake.write('FA01',0,'ascii');
   handshake.writeUInt32BE(audioRate,4);
   handshake.writeUInt16BE(2,8);
   handshake.writeUInt16BE(16,10);
   s.write(handshake);
   audioClients.add(s);
   s.on('error',e=>console.log('[FOLIA-AUDIO] client',e.message));
   s.on('close',()=>audioClients.delete(s));
   console.log('[FOLIA-AUDIO] connected',ip(s),'rate',audioRate);
 });
 audioServer.on('error',e=>console.error('[FOLIA-AUDIO] server',e.message));
 audioServer.listen(AUDIO_PORT,MAC_HOST,()=>console.log('[FOLIA-AUDIO] listening',AUDIO_PORT));
 ipcMain.on('atv3-audio-pcm',(event,payload,rate)=>{
   if(event.sender!==win.webContents) return;
   if(!Number.isInteger(rate)||![44100,48000].includes(rate))return;
   if(!(payload instanceof Uint8Array)&&!Buffer.isBuffer(payload))return;
   const bytes=Buffer.from(payload.buffer,payload.byteOffset,payload.byteLength);
   if(bytes.length<4||bytes.length>65536||bytes.length%4)return;
   if(rate!==audioRate){
     audioRate=rate;
     for(const s of audioClients)s.destroy(); // negotiated on reconnect
   }
   audioPackets++;audioBytes+=bytes.length;audioLastAt=Date.now();
   const header=Buffer.allocUnsafe(8);
   header.writeUInt32BE(bytes.length,0);
   header.writeUInt32BE(audioPackets>>>0,4);
   const packet=Buffer.concat([header,bytes]);
   for(const s of audioClients){
     if(s.destroyed)continue;
     // Never stall Folia animation on TCP backpressure.
     if(s.writableLength>65536){audioDrops++;continue;}
     s.write(packet);audioSentPackets++;
   }
 });
 if(!WORKER_OWNS_NETWORK)video=net.createServer(s=>{
   if(!ALLOW.has(ip(s))){s.destroy();return;}
   s.setNoDelay(true);
   s.__ready=false;
   s.__frames=0;
   clients.add(s);
   s.write(Buffer.from('FV01'));
   s.on('close',()=>{clients.delete(s);console.log('[FOLIA-DIRECT] client exit',ip(s),'frames',s.__frames);});
   s.on('error',e=>{console.log('[FOLIA-DIRECT] peer',e.message)});
   console.log('[FOLIA-DIRECT] client joined',ip(s));
 });
 if(!WORKER_OWNS_NETWORK)
   video.listen(VIDEO_PORT,MAC_HOST,()=>console.log('[FOLIA-DIRECT] listening TCP',VIDEO_PORT));
 control=http.createServer((req,res)=>{
  if(!ALLOW.has(ip(req.socket)))return emitJSON(res,403,{ok:false});
  let route=(req.url||'/').split('?')[0];
  if(req.method==='GET'&&(route==='/health'||route==='/live/status')){
    return emitJSON(res,200,health());
  }
  // Mac-only compositor quality snapshot, NOT a video transport.
  // Mac-only bounded viewport experiment for compositor clipping.
  if(req.method==='GET' && route==='/diag/resize'){
    if(ip(req.socket)!=='127.0.0.1'&&ip(req.socket)!==MAC_HOST)
      return emitJSON(res,403,{error:'mac_only'});
    const allowed=new Map([['480x270',[480,270]],['512x288',[512,288]],['560x315',[560,315]],['640x360',[640,360]],['800x450',[800,450]],
        ['960x540',[960,540]],['1280x720',[1280,720]]]);
    const size=new URL(req.url,'http://127.0.0.1').searchParams.get('size');
    const dims=allowed.get(size);
    if(!dims)return emitJSON(res,400,{error:'unsupported_size'});
    win.setSize(dims[0],dims[1]);
    return emitJSON(res,200,{size:dims,bounds:win.getBounds()});
  }
  if(req.method==='GET' && route==='/diag/zoom'){
    if(ip(req.socket)!=='127.0.0.1'&&ip(req.socket)!==MAC_HOST)
      return emitJSON(res,403,{error:'mac_only'});
    const factor=new URL(req.url,'http://127.0.0.1').searchParams.get('factor');
    const value=({'0.4':0.4,'0.5':0.5,'0.8':0.8,'1':1.0})[factor];
    if(!value)return emitJSON(res,400,{error:'unsupported_zoom'});
    win.webContents.setZoomFactor(value);
    return emitJSON(res,200,{factor:value});
  }
  // Mac-only reversible animation pacing experiment. The encoded video
  // continues at 30 FPS; controls, zoom, camera and user settings untouched.
  if(req.method==='GET' && route==='/diag/render-tune'){
    if(ip(req.socket)!=='127.0.0.1'&&ip(req.socket)!==MAC_HOST)
      return emitJSON(res,403,{error:'mac_only'});
    const params=new URL(req.url,'http://localhost').searchParams;
    const target=Number(params.get('fps')||30);
    const period=Number(params.get('paintMs')||33);
    const capture=params.has('captureMs')?Number(params.get('captureMs')):captureThrottleMs;
    if(![30,45,60].includes(target)||![16,22,33,40,50,66].includes(period)||
       ![24,30,33,34,40,50].includes(capture))
      return emitJSON(res,400,{error:'unsupported_render_tuning'});
    renderFps=target;paintPeriodMs=period;captureThrottleMs=capture;
    win.webContents.setFrameRate(renderFps);
    restartPaintTimer(win);
    return emitJSON(res,200,{ok:true,renderFps,paintPeriodMs,captureThrottleMs,videoFps:FPS});
  }
  // Read-only graphical animation diagnostics, not H264 encoded frame count.
  if(req.method==='GET' && route==='/diag/render-profile'){
    if(ip(req.socket)!=='127.0.0.1'&&ip(req.socket)!==MAC_HOST)
      return emitJSON(res,403,{error:'mac_only'});
    win.webContents.executeJavaScript(`(async()=>{
      const keys=['visualizer_mode','visualizer_frame_rate',
        'enable_player_page_native_blur','random_visualizer_mode_per_song'];
      const settings={};
      for(const k of keys)settings[k]=localStorage.getItem(k);
      const canvases=[...document.querySelectorAll('canvas')].slice(0,12)
        .map(e=>{
          let parent=e.parentElement;
          const ancestry=[];
          for(let i=0;i<4&&parent;i++,parent=parent.parentElement)
            ancestry.push(String(parent.className||'').slice(0,65));
          const css=getComputedStyle(e);
          return {width:e.width,height:e.height,
            screen:[Math.round(e.getBoundingClientRect().width),
                    Math.round(e.getBoundingClientRect().height)],
            visible:css.visibility,display:css.display,
            ancestry};
        });
      const gaps=[];
      let stopped=false,last=0;
      const start=performance.now();
      await new Promise(resolve=>{
        const watchdog=setTimeout(()=>{stopped=true;resolve()},3600);
        function tick(now){
          if(stopped)return;
          if(last)gaps.push(now-last);
          last=now;
          if(now-start>=3200){stopped=true;clearTimeout(watchdog);resolve();}
          else requestAnimationFrame(tick);
        }
        requestAnimationFrame(tick);
      });
      const sorted=[...gaps].sort((a,b)=>a-b);
      const at=p=>sorted.length?Math.round(sorted[Math.min(sorted.length-1,Math.floor(sorted.length*p))]*10)/10:null;
      return {elapsedMs:Math.round(performance.now()-start),
        samples:gaps.length,rafFps:Math.round(gaps.length/((performance.now()-start)/1000)*10)/10,
        p50Ms:at(.5),p90Ms:at(.9),p99Ms:at(.99),maxMs:at(.999),
        slowFramesOver50ms:gaps.filter(x=>x>50).length,
        visibility:document.visibilityState,canvases,settings,
        cssAnimations:document.getAnimations?.().length||0};
    })()`).then(data=>emitJSON(res,200,data))
       .catch(e=>emitJSON(res,503,{error:'render_profile_failed',
          detail:String(e&&e.message||e).slice(0,120)}));
    return;
  }
  if(req.method==='GET' && route==='/diag/audio'){
    if(ip(req.socket)!=='127.0.0.1'&&ip(req.socket)!==MAC_HOST)
      return emitJSON(res,403,{error:'mac_only'});
    return win.webContents.executeJavaScript(`(()=>({
      bridgeType:typeof window.atv3AudioBridge,
      capture:typeof window.__foliaDirectAudioStatus==='function'
        ?window.__foliaDirectAudioStatus():null,
      audioElements:document.querySelectorAll('audio').length
    }))()`).then(x=>emitJSON(res,200,x))
       .catch(e=>emitJSON(res,503,{error:String(e.message||e)}));
  }
  if(req.method==='GET' && route==='/diag/scene'){
    if(ip(req.socket)!=='127.0.0.1'&&ip(req.socket)!==MAC_HOST)
      return emitJSON(res,403,{error:'mac_only'});
    win.webContents.executeJavaScript(`(()=>{
      const pick=el=>el?{
        tag:el.tagName,cls:String(el.className||'').slice(0,70),
        role:el.getAttribute('role'),action:el.getAttribute('data-bravais-seam-action'),
        tab:el.getAttribute('data-bravais-tab'),section:el.getAttribute('data-bravais-section'),
        selected:el.getAttribute('aria-selected'),
        rect:['x','y','width','height'].map(k=>Math.round(el.getBoundingClientRect()[k]||0))
      }:null;
      const selectors=['[data-library-stage=bravais]','[data-bravais-seam]',
        '[data-bravais-seam] [data-bravais-tab]','[data-bravais-seam] [data-bravais-section]',
        '[data-bravais-seam] [data-bravais-account-toggle]',
        '[data-bravais-seam-action=back]',
        '[data-bravais-seam-action=close-list]',
        '[data-bravais-seam-action=close-directory]',
        '[data-bravais-slot][data-bravais-focused=true]'];
      const result={active:pick(document.activeElement),focusTitle:window.__atv3TVStatus?.().focus};
      for(const sel of selectors)result[sel]=[...document.querySelectorAll(sel)].slice(0,20).map(pick);
      return result;
    })()`).then(data=>emitJSON(res,200,data))
      .catch(e=>emitJSON(res,503,{error:'inspect_failed'}));
    return;
  }
  if(req.method==='GET' && route==='/diag/capture.jpg'){
    if(ip(req.socket)!=='127.0.0.1'&&ip(req.socket)!==MAC_HOST)
      return emitJSON(res,403,{error:'mac_only'});
    win.webContents.capturePage().then(img=>{
      const jpeg=img.toJPEG(75);
      res.writeHead(200,{'Content-Type':'image/jpeg','Content-Length':jpeg.length});
      res.end(jpeg);
    }).catch(()=>emitJSON(res,503,{error:'capture_failed'}));
    return;
  }
  if(req.method==='GET'&&route==='/control/status'){
    const q=health();
    win.webContents.executeJavaScript('window.__atv3TVStatus && window.__atv3TVStatus()')
      .then(f=>emitJSON(res,200,{ok:true,...q,focus:f}))
      .catch(()=>emitJSON(res,503,{ok:false}));
    return;
  }
  if(req.method==='POST'&&route==='/control'){
    if(req.headers.origin || req.headers['content-type']!=='application/json'){
      return emitJSON(res,403,{ok:false,error:'unauthorized origin/type'});
    }
    let body='';
    req.setEncoding('utf8');req.on('data',c=>{
      body+=c;
      if(body.length>256)req.destroy();
    });
    req.on('end',()=>{
      let action;
      try{let q=JSON.parse(body);if(Object.keys(q).length===1&&KEYS.has(q.command))action=q.command;}catch{}
      if(!action)return emitJSON(res,400,{ok:false});
      if(win.isDestroyed()||win.webContents.isDestroyed())return emitJSON(res,503,{ok:false});
      const finish=result=>{
        controls++;lastControl={action,at:Date.now(),result};
        emitJSON(res,200,{ok:true,command:action,result,sequence:controls});
      };
      if(action.startsWith('key-')){
        win.webContents.executeJavaScript('window.__atv3TVNavigation && window.__atv3TVNavigation('+JSON.stringify(action)+')')
        .then(r=>{
          if(r?.playback){
            const map={'key-left':'previous','key-right':'next','key-select':'play-pause'};
            if(map[action])win.webContents.send('remote-control-command',{type:map[action]});
          }
          finish(r||{ok:false,reason:'no_navigation'});
        }).catch(()=>emitJSON(res,503,{ok:false,error:'navigation'}));
      }else{
        win.webContents.send('remote-control-command',{type:action});
        finish({playback:true});
      }
    });
    return;
  }
  emitJSON(res,404,{error:'not_found'});
 });
 control.listen(CONTROL_PORT,MAC_HOST,()=>console.log('[FOLIA-DIRECT] control',CONTROL_PORT));
 app.on('before-quit',()=>{
   if(forcedPaintTimer)clearInterval(forcedPaintTimer);
   if(pump)clearInterval(pump);
   for(const peer of clients)peer.destroy();
   for(const peer of audioClients)peer.destroy();
   try{audioServer.close()}catch{}
   try{video.close()}catch{}
   try{control.close()}catch{}
   if(ffmpeg)ffmpeg.kill('SIGTERM');
   if(encoderWorker){try{encoderWorker.postMessage({type:'shutdown'})}catch{}}
 });
}
module.exports={startBridge};
