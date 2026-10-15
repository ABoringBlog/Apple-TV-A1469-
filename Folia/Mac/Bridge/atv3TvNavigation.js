// ATV3-only Folia TV navigation. Executed inside the hidden renderer.
(() => {
  if (window.__atv3TVNavigation) return;
  let target=null;
  let browse=true;
  let previousTrack=false;
  let ring=null;
  let hint=null;
  function ensure(){
    if(!document.getElementById('atv3-tv-css')){
      const style=document.createElement('style');
      style.id='atv3-tv-css';
      style.textContent='#atv3-focus{position:fixed;z-index:2147483000;pointer-events:none;border:4px solid #f6c24e;border-radius:12px;box-shadow:0 0 0 4px rgba(0,0,0,.65),0 0 30px rgba(246,194,78,.55)}#atv3-hint{position:fixed;z-index:2147483001;bottom:14px;left:16px;pointer-events:none;background:rgba(0,0,0,.8);color:white;font:600 16px system-ui;padding:8px 14px;border-radius:10px}';
      document.head.appendChild(style);
    }
    if(!ring){ring=document.createElement('div');ring.id='atv3-focus';document.body.appendChild(ring);}
    if(!hint){hint=document.createElement('div');hint.id='atv3-hint';document.body.appendChild(hint);}
  }
  function isVisible(el){
    if(!el||!el.isConnected||el.closest('[inert],[aria-hidden="true"]'))return false;
    const r=el.getBoundingClientRect(),s=getComputedStyle(el);
    return r.width>=8&&r.height>=8&&r.right>0&&r.bottom>0&&r.left<innerWidth&&r.top<innerHeight&&s.display!=='none'&&s.visibility!=='hidden'&&Number(s.opacity)!==0;
  }
  function options(){
    const dlg=[...document.querySelectorAll('[role="dialog"][aria-modal="true"]')].filter(isVisible).pop();
    const root=dlg||document;
    return [...root.querySelectorAll('button,[role="button"],a[href],input,select,textarea,[tabindex]:not([tabindex="-1"])')].filter(isVisible);
  }
  function caption(el){
    return String(el?.getAttribute('aria-label')||el?.getAttribute('title')||el?.textContent||el?.getAttribute('placeholder')||el?.tagName||'').trim().replace(/\s+/g,' ').slice(0,65);
  }
  function first(){
    const providers=[...document.querySelectorAll('[role="group"] button')].filter(isVisible);
    return providers.find(x=>!x.disabled)||providers[0]||options().find(x=>!x.disabled)||options()[0]||null;
  }
  function focus(el){
    ensure();target=el;
    if(!el||!isVisible(el)){ring.style.display='none';hint.textContent='方向键：浏览  ·  确定：选择  ·  Menu：退出';return;}
    const r=el.getBoundingClientRect();
    ring.style.display='block';
    ring.style.left=Math.max(0,r.left-5)+'px';ring.style.top=Math.max(0,r.top-5)+'px';
    ring.style.width=Math.max(0,Math.min(innerWidth-r.left+5,r.width+10))+'px';
    ring.style.height=Math.max(0,Math.min(innerHeight-r.top+5,r.height+10))+'px';
    hint.textContent='选择：'+caption(el)+(el.disabled?'（不可用）':'')+' · Menu 返回';
  }
  function move(direction){
    const opts=options();if(!opts.length){focus(null);return;}
    if(!target||!opts.includes(target)){focus(first());return;}
    const r=target.getBoundingClientRect(),cx=r.left+r.width/2,cy=r.top+r.height/2;
    const dx=direction==='left'?-1:direction==='right'?1:0;
    const dy=direction==='up'?-1:direction==='down'?1:0;
    const candidates=opts.filter(el=>el!==target).map(el=>{
      const rc=el.getBoundingClientRect(),x=rc.left+rc.width/2-cx,y=rc.top+rc.height/2-cy;
      const forward=x*dx+y*dy;
      return {el,forward,score:forward+2.2*Math.abs(dx?y:x)+(el.disabled?120:0)};
    }).filter(x=>x.forward>3).sort((a,b)=>a.score-b.score);
    if(candidates.length)focus(candidates[0].el);
  }
  function activate(){
    const opts=options();
    if(!target||!opts.includes(target)){focus(first());return;}
    if(target.disabled){focus(target);return;}
    try{
      target.focus({preventScroll:true});
      target.click();
      setTimeout(()=>focus(isVisible(target)?target:first()),260);
    }catch(e){console.warn('[ATV3-TV] activate failed',e);}
  }
  window.__atv3TVStatus=()=>({browse,hasTrack:!!window.__atv3HasTrack,focus:caption(target),enabled:!!target&&!target.disabled,options:options().length});
  window.__atv3TVNavigation=(command)=>{
    if(!['key-up','key-down','key-left','key-right','key-select','key-playback'].includes(command))return {ok:false};
    ensure();
    const track=!!window.__atv3HasTrack;
    if(track&&!previousTrack){browse=false;if(ring)ring.style.display='none';if(hint)hint.style.display='none';}
    if(!track)browse=true;
    previousTrack=track;
    if(command==='key-playback'){browse=false;if(ring)ring.style.display='none';if(hint)hint.style.display='none';return {ok:true,playback:true};}
    if(browse&&hint)hint.style.display='block';
    if(window.__atv3HasTrack&&!browse&&command!=='key-up')return {ok:true,playback:true};
    if(window.__atv3HasTrack&&!browse&&command==='key-up'){browse=true;focus(first());}
    else if(command==='key-select')activate();
    else move(command.slice(4));
    return {ok:true,playback:false,...window.__atv3TVStatus()};
  };
  window.addEventListener('resize',()=>{if(target)focus(target);});
  console.log('[ATV3-TV] directional focus adapter loaded');
})();