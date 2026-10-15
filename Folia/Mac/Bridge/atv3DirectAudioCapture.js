// Dedicated FoliaDirect PCM capture on the audio render thread.
// Preserve Folia's existing audio output; this worklet outputs silence only.
(function(){
 'use strict';
 if(!window.atv3AudioBridge||!window.AudioNode||!window.AudioDestinationNode)return;
 if(window.__foliaDirectAudioWorkletInstalled)return;
 window.__foliaDirectAudioWorkletInstalled=true;
 const connect=AudioNode.prototype.connect;
 const taps=new WeakMap();
 let sent=0,errors=0,attached=0,rate=0,state='initializing',lastError='';
 const processorSource=`
class FoliaATV3PCM extends AudioWorkletProcessor {
 constructor(){super();this.pcm=new Uint8Array(8192);this.view=new DataView(this.pcm.buffer);this.index=0;}
 process(inputs, outputs){
  const source=inputs[0]||[],out=outputs[0]||[];
  for(let i=0;i<out.length;i++)out[i].fill(0);
  if(!source.length)return true;
  const left=source[0],right=source[1]||source[0];
  for(let i=0;i<left.length;i++){
    const l=Math.max(-1,Math.min(1,left[i])),r=Math.max(-1,Math.min(1,right[i]));
    const p=this.index*4;
    this.view.setInt16(p,Math.round(l<0?l*32768:l*32767),true);
    this.view.setInt16(p+2,Math.round(r<0?r*32768:r*32767),true);
    if(++this.index===2048){
      const full=this.pcm;
      this.port.postMessage(full,[full.buffer]);
      this.pcm=new Uint8Array(8192);this.view=new DataView(this.pcm.buffer);this.index=0;
    }
  }
  return true;
 }
}
registerProcessor('foliadirect-pcm',FoliaATV3PCM);
`;
 function attach(context,source,destination){
  if(!context.audioWorklet){state='audioWorklet_missing';errors++;return;}
  let promise=taps.get(context);
  if(!promise){
   const blob=new Blob([processorSource],{type:'application/javascript'});
   const url=URL.createObjectURL(blob);
   promise=context.audioWorklet.addModule(url).then(()=>{
    URL.revokeObjectURL(url);
    const node=new AudioWorkletNode(context,'foliadirect-pcm',{
      numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[2]
    });
    node.port.onmessage=e=>{
      try{window.atv3AudioBridge.sendPCM(e.data,context.sampleRate);sent++;rate=context.sampleRate;}
      catch(err){errors++;lastError=String(err);}
    };
    connect.call(node,destination);state='active';
    return node;
   }).catch(err=>{errors++;state='failed';lastError=String(err);return null;});
   taps.set(context,promise);
  }
  promise.then(node=>{if(node){try{connect.call(source,node);attached++;}catch(err){errors++;lastError=String(err);}}});
 }
 AudioNode.prototype.connect=function(destination,...args){
  const value=connect.call(this,destination,...args);
  if(destination instanceof AudioDestinationNode)attach(this.context,this,destination);
  return value;
 };
 window.__foliaDirectAudioStatus=()=>({mode:'AudioWorklet',state,sent,errors,attached,rate,lastError});
})();
