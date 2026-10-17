#!/usr/bin/env python3
"""Private ATV3 iCloud Photos bridge: CDP screenshot + remote navigation.

The Chromium desktop lives in a separate persistent NAS Docker container.
No passwords, photos, cookies or screenshots are stored by this bridge.
ATV/authorized Mac only, with a random token embedded in the private ATV build.
"""
import base64
import ctypes
import ctypes.util
import hashlib
import hmac
import json
import os
import socket
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

import websocket

HOST = os.environ.get("ATV_PHOTOS_BIND", "192.0.2.24")
PORT = int(os.environ.get("ATV_PHOTOS_PORT", "18790"))
CDP_ENDPOINT = os.environ.get("ATV_PHOTOS_CDP", "http://127.0.0.1:39222")
SECRET = open(os.environ["ATV_PHOTOS_SECRET_FILE"], encoding="ascii").read().strip()
ALLOWED = {"192.0.2.41", "192.0.2.15", "192.0.2.24", "127.0.0.1"}
VIEW_W, VIEW_H = 1280, 720
SCREEN_DPR = 1.5   # 1920x1080 pixels, browser layout and input remain 1280x720 CSS

# Coordinate-space navigation focuses visible actionable controls, rather than
# relying on Tab order for iCloud's React UI.
# Application-layer encryption for native ATV text entry. Never send Apple ID
# credentials as unencrypted HTTP JSON over the local network. The credential
# is decrypted only in this private NAS process and inserted into the already
# selected, visible iCloud browser field; not logged or persisted.
_native_input_secret=open(os.environ.get("ATV_PHOTOS_INPUT_SECRET_FILE",
    "/etc/atv3-icloud-photos/input_crypto.key"),encoding="ascii").read().strip()
if len(_native_input_secret)!=64:raise RuntimeError("invalid_native_input_crypto_config")
_aes_key=hashlib.sha256((_native_input_secret+":aes").encode("ascii")).digest()
_mac_key=hashlib.sha256((_native_input_secret+":mac").encode("ascii")).digest()
_libcrypto=ctypes.CDLL(ctypes.util.find_library("crypto"))
_libcrypto.EVP_CIPHER_CTX_new.restype=ctypes.c_void_p
_libcrypto.EVP_aes_256_cbc.restype=ctypes.c_void_p
_libcrypto.EVP_DecryptInit_ex.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p]
_libcrypto.EVP_DecryptUpdate.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.POINTER(ctypes.c_int),ctypes.c_void_p,ctypes.c_int]
_libcrypto.EVP_DecryptFinal_ex.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.POINTER(ctypes.c_int)]
_libcrypto.EVP_CIPHER_CTX_free.argtypes=[ctypes.c_void_p]
_recent_ivs=set()
_recent_lock=threading.Lock()

def _decrypt_native_input(envelope):
    try:
        iv=base64.b64decode(envelope["iv"],validate=True)
        cipher=base64.b64decode(envelope["ct"],validate=True)
        tag=base64.b64decode(envelope["mac"],validate=True)
        if len(iv)!=16 or len(cipher)<16 or len(cipher)>2048 or len(cipher)%16 or len(tag)!=32:
            raise ValueError("invalid_envelope")
        expected=hmac.new(_mac_key,b"CP_INPUT_V1"+iv+cipher,hashlib.sha256).digest()
        if not hmac.compare_digest(expected,tag):
            raise ValueError("invalid_auth_tag")
        with _recent_lock:
            if iv in _recent_ivs:
                raise ValueError("replay")
            _recent_ivs.add(iv)
            if len(_recent_ivs)>512:_recent_ivs.clear()
        ctx=_libcrypto.EVP_CIPHER_CTX_new()
        if not ctx:raise ValueError("cipher_context_error")
        try:
            ivb=ctypes.create_string_buffer(iv)
            kb=ctypes.create_string_buffer(_aes_key)
            inp=ctypes.create_string_buffer(cipher)
            out=ctypes.create_string_buffer(len(cipher)+16)
            produced=ctypes.c_int(0)
            done=ctypes.c_int(0)
            if _libcrypto.EVP_DecryptInit_ex(ctx,_libcrypto.EVP_aes_256_cbc(),None,kb,ivb)!=1:
                raise ValueError("decrypt_init_failed")
            if _libcrypto.EVP_DecryptUpdate(ctx,out,ctypes.byref(produced),inp,len(cipher))!=1:
                raise ValueError("decrypt_update_failed")
            address=ctypes.c_void_p(ctypes.addressof(out)+produced.value)
            if _libcrypto.EVP_DecryptFinal_ex(ctx,address,ctypes.byref(done))!=1:
                raise ValueError("decrypt_final_failed")
            value=out.raw[:produced.value+done.value].decode("utf-8")
            if not 1<=len(value)<=512:
                raise ValueError("invalid_length")
            return value
        finally:
            _libcrypto.EVP_CIPHER_CTX_free(ctx)
    except (KeyError,TypeError,UnicodeError,ValueError,base64.binascii.Error) as ex:
        raise ValueError("encrypted_input_rejected") from None

# Coordinate-space navigation focuses visible actionable controls, rather than
# relying on Tab order for iCloud's React UI.
SPATIAL_JS = r"""
(async()=>{
const action=__ACTION__;
let doc=document, dx=0,dy=0,depth=0;
const sels='[role="treeitem"],[role="tab"],ui-button[role="button"],ui-slider[tabindex],button:not(:disabled),a[href]:not([role="treeitem"]),input:not([type="hidden"]):not(:disabled),.grid-item';
while(depth++<3) {
  // Prefer a visible Apple authentication frame to the background photo
  // app, even when the photo app has far more controls.
  const authSelector='input[type="password"],input[type="email"],input[autocomplete="one-time-code"],input[autocomplete="username"],input[name*="account" i],input[name*="email" i]';
  if([...doc.querySelectorAll(authSelector)].some(e=>e.getBoundingClientRect().width>7))break;
  let best=null, count=0;
  for(const frame of doc.querySelectorAll('iframe')){
    let d;try{d=frame.contentDocument}catch(e){continue}
    const r=frame.getBoundingClientRect();
    if(!d||r.width<100||r.height<100)continue;
    const auth=!!d.querySelector(authSelector);
    const n=d.querySelectorAll(sels).length+(auth?100000:0);
    if(n>count){count=n;best=frame}
  }
  if(!best||!count)break;
  const r=best.getBoundingClientRect();
  dx+=r.left+best.clientLeft;dy+=r.top+best.clientTop;
  doc=best.contentDocument;
}
const view=doc.defaultView;
for(const d of [document,doc]){
  if(!d.getElementById('__atv3_no_tooltip')){
    const st=d.createElement('style');st.id='__atv3_no_tooltip';
    st.textContent='ui-tooltip,[role="tooltip"],.tooltip,.Tooltip{display:none!important}';
    d.documentElement.appendChild(st);
  }
  // Chromium renders native black hover labels from HTML title attributes.
  // CSS cannot suppress those browser-owned tooltips. Remove only 'title',
  // retaining aria-label for accessibility, focus, and menu interaction.
  if(!d.__atv3NativeTooltipGuard){
    const stripTitles=node=>{
      if(!node||node.nodeType!==1)return;
      if(node.hasAttribute('title'))node.removeAttribute('title');
      for(const e of node.querySelectorAll('[title]'))e.removeAttribute('title');
    };
    stripTitles(d.documentElement);
    const observer=new d.defaultView.MutationObserver(changes=>{
      for(const change of changes){
        if(change.type==='attributes')stripTitles(change.target);
        else for(const node of change.addedNodes)stripTitles(node);
      }
    });
    observer.observe(d.documentElement,{
      subtree:true,childList:true,attributes:true,attributeFilter:['title']
    });
    d.__atv3NativeTooltipGuard=observer;
  }
}
const state=window.__atv3NavState||(window.__atv3NavState={tier:'controls',control:null,photo:null,photoX:0});
const label=e=>(e?.getAttribute('aria-label')||e?.textContent||'').trim();
const coords=e=>{const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}};
const absolute=e=>{const r=e.getBoundingClientRect();return {x:r.x+dx,y:r.y+dy,w:r.width,h:r.height}};
const shown=e=>{
  if(!e||!e.isConnected)return false;
  let r=e.getBoundingClientRect(),cs=e.ownerDocument.defaultView.getComputedStyle(e);
  const sw=Math.max(0,Math.min(r.right,view.innerWidth)-Math.max(0,r.left));
  const sh=Math.max(0,Math.min(r.bottom,view.innerHeight)-Math.max(0,r.top));
  return r.width>9&&r.height>9&&sw/r.width>=.70&&sh/r.height>=.70&&
     cs.display!=='none'&&cs.visibility!=='hidden'&&cs.pointerEvents!=='none'&&e.getAttribute('aria-hidden')!=='true';
};
const isBrandLogo=e=>{
  const r=e.getBoundingClientRect();
  if(r.top>65||r.left>230)return false;
  const name=((e.getAttribute('aria-label')||'')+' '+(e.textContent||'')).trim();
  const href=e.getAttribute('href')||'';
  return /^(iCloud|iCloud Photos)$/i.test(name)||/icloud-logo|icloudlogo|icloud-brand/i.test(e.className?.baseVal||e.className||'')||
    (e.querySelector('svg,img')&&/icloud/i.test(name+' '+href)&&!/account|photos|library/i.test(name));
};
const controls=[...new Set(doc.querySelectorAll(sels))]
    .filter(e=>!e.matches('.grid-item')&&shown(e)&&!isBrandLogo(e))
    .filter(e=>(!e.matches('button')||!e.closest('ui-button')) &&
               (!e.closest('[role="treeitem"]') || e.matches('[role="treeitem"]')) &&
               !e.matches('.Sidebar')); 
const isSidebar=e=>!!e?.matches('[role="treeitem"]');
const sidebar=controls.filter(isSidebar);
const library=sidebar.find(e=>/^library$/i.test(label(e)))||sidebar[0];
const buttons=controls.filter(e=>!isSidebar(e));
const grid=()=>[...doc.querySelectorAll('.grid-item')].filter(e=>!e.closest('.Thumbstrip')&&shown(e));
const firstGrid=()=>grid().find(e=>{const r=e.getBoundingClientRect();return r.top>=100&&r.bottom<=view.innerHeight-4})||grid()[0];
function overlay(el){
  let ring=document.getElementById('__atv3_photos_focus_ring');
  if(!ring){
    ring=document.createElement('div');ring.id='__atv3_photos_focus_ring';
    ring.setAttribute('aria-hidden','true');
    Object.assign(ring.style,{position:'fixed',boxSizing:'border-box',pointerEvents:'none',
       zIndex:'2147483647',border:'4px solid #08b7ff',borderRadius:'7px',
       boxShadow:'0 0 0 2px rgba(255,255,255,.95),0 0 18px 4px rgba(0,125,255,.85)',
       background:'rgba(0,128,255,.045)'});
    document.documentElement.appendChild(ring);
  }
  const r=absolute(el);
  Object.assign(ring.style,{display:'block',left:Math.round(r.x)+'px',top:Math.round(r.y)+'px',
     width:Math.round(r.w)+'px',height:Math.round(r.h)+'px'});
  return {x:Math.round(r.x),y:Math.round(r.y),w:Math.round(r.w),h:Math.round(r.h)};
}
function focus(el,tier){
  if(!el||!el.isConnected)return {mode:'none',tier:state.tier};
  state.tier=tier;
  if(tier==='photos'){
    state.photo=el;state.photoX=coords(el).x;
  }else if(tier==='login')state.loginEl=el;
  else if(tier==='controls')state.control=el;
  try{el.focus({preventScroll:true})}catch(e){}
  window.__atvCloudFocus=el;
  const r=overlay(el);
  return {mode:'focus',tier,type:tier==='photos'?'photo':'control',...r};
}
function nearest(from,candidates,dir){
  if(!from || !candidates.length)return null;
  const u=coords(from),d={up:[0,-1],down:[0,1],left:[-1,0],right:[1,0]}[dir];
  if(!d)return null;
  let best=null,score=Infinity;
  for(const e of candidates){
    if(e===from)continue;
    const v=coords(e),vx=v.x-u.x,vy=v.y-u.y,forward=vx*d[0]+vy*d[1];
    if(forward<7)continue;
    const perp=Math.abs(vx*d[1]-vy*d[0]);
    const cost=forward+2.7*perp+(perp>130?240:0);
    if(cost<score){score=cost;best=e;}
  }
  return best;
}
function scrollContainer(el){
  for(let e=el?.parentElement;e&&e!==doc.body;e=e.parentElement){
    if(e.scrollHeight>e.clientHeight+50&&e.clientHeight>50){
      const overflow=view.getComputedStyle(e).overflowY;
      if(/auto|scroll|overlay/.test(overflow)||e.scrollHeight>e.clientHeight+400)return e;
    }
  }
  const all=[...doc.querySelectorAll('*')].filter(e=>
    e.scrollHeight>e.clientHeight+100&&e.clientHeight>180&&e.getBoundingClientRect().width>220&&
    e.getBoundingClientRect().x>=240);
  return all.sort((a,b)=>a.clientHeight-b.clientHeight)[0]||doc.scrollingElement;
}
// Popover menu navigation, independent of the two top toolbars. The
// Account menu may be mounted in a React portal after the first click.
const popupSelector='[role="menuitem"],[role="option"],ui-menu-item,ui-button[role="button"],button,a[href],[tabindex="0"],[class*="MenuItem"],[class*="menu-item"],[class*="menuItem"],li';
function popupCandidates(){
  const anchor=state.popupAnchor;
  if(!anchor || !anchor.isConnected)return [];
  const ar=anchor.getBoundingClientRect();
  const before=state.popupKnown||new Set();
  // Apple renders Account's UI-POPOVER in the OUTER document, not
  // in the Photos iframe. These are the actual menu items.
  const portal=[...document.querySelectorAll('ui-popover')].find(e=>{
    const r=e.getBoundingClientRect();
    return r.width>80&&r.height>40&&r.left>=ar.left-650 &&
           !!e.querySelector('ui-menu-item[role="menuitem"]');
  });
  if(portal){
    return [...portal.querySelectorAll('ui-menu-item[role="menuitem"]')]
      .filter(e=>!e.classList.contains('header')&&shown(e));
  }
  const matches=[...new Set(doc.querySelectorAll(popupSelector))]
    .filter(e=>shown(e)&&!before.has(e))
    .filter(e=>{
      const r=e.getBoundingClientRect();
      return r.left>=Math.max(0,ar.left-610) && r.top>=ar.bottom-5 &&
             r.top<=Math.min(view.innerHeight-8,650) &&
             r.width>=16 && r.height>=13;
    });
  return matches.filter(e=>!matches.some(parent=>parent!==e&&parent.contains(e) &&
    (parent.matches('[role="menuitem"],ui-menu-item,[class*="MenuItem"],[class*="menu-item"]'))))
    .sort((a,b)=>{const x=a.getBoundingClientRect(),y=b.getBoundingClientRect();
      return x.top-y.top || x.left-y.left});
}
// The active Account popup lives in the parent document. Recover its
// tier even if a prior asynchronous click response still said controls.
const accountButton=doc.querySelector('ui-button[aria-label="Account"]');
const accountPopup=[...document.querySelectorAll('ui-popover')].find(e=>{
  const r=e.getBoundingClientRect();
  return r.width>100&&r.height>40&&
    !!e.querySelector('ui-menu.account-menu');
});
if(accountPopup&&accountButton){
  state.popupAnchor=accountButton;
  if(state.tier!=='popup')state.popupEl=null;
  state.tier='popup';
}
if(action==='popup_probe')
  return {mode:accountPopup||popupCandidates().length?'popup_open':'popup_closed',tier:state.tier};
if(action==='popup_return'){
  const old=state.popupAnchor;
  state.popupAnchor=null;state.popupEl=null;state.popupKnown=null;
  state.tier='controls';
  return old&&shown(old)?focus(old,'controls'):focus(library||buttons[0],'controls');
}
if(action==='popup_sync' || state.tier==='popup'){
  const items=popupCandidates();
  const old=state.popupEl;
  if(!items.length){
    if(action==='popup_sync' && state.popupAnchor)
      return {mode:'popup_wait',tier:'controls'};
    const anchor=state.popupAnchor;
    state.popupAnchor=null;state.popupEl=null;state.popupKnown=null;
    state.tier='controls';
    return anchor&&shown(anchor)?focus(anchor,'controls'):
      {mode:'none',tier:'controls'};
  }
  if(action==='back'){
    const anchor=state.popupAnchor;
    const p=anchor?coords(anchor):null;
    state.tier='controls';
    return {mode:'popup_close',tier:'controls',
      ax:p?Math.round(p.x+dx):null,ay:p?Math.round(p.y+dy):null};
  }
  let current=old&&items.includes(old)?old:items[0];
  if(action==='select'){
    const pt=coords(current);
    return {mode:'click',tier:'popup',type:'menu_item',x:Math.round(pt.x+dx),
      y:Math.round(pt.y+dy),...absolute(current)};
  }
  if(['up','down','left','right'].includes(action)){
    current=nearest(current,items,action)||current;
  }
  state.popupEl=current;
  return focus(current,'popup');
}
// Authentication controls have priority over the photo grid whenever
// iCloud opens a visible sign-in/verification form in the active page.
const loginInputs=[...doc.querySelectorAll('input,textarea,[contenteditable="true"]')]
    .filter(e=>shown(e)&&!e.matches('[type="hidden"]')&&
      !e.matches('[role="searchbox"],input[type="checkbox"],input[type="radio"]'));
const loginIsActive=loginInputs.some(e=>
      e.matches('input[type="password"],input[type="email"],input[autocomplete="one-time-code"],input[autocomplete="username"],input[name*="account" i],input[name*="email" i]'))
    || (!!doc.querySelector('[role="dialog"],[aria-modal="true"]')&&
       loginInputs.length>0)
    || (!doc.querySelector('.Sidebar')&&loginInputs.length>0);
if(loginIsActive){
  const candidates=[
    ...loginInputs,
    ...doc.querySelectorAll('button:not(:disabled),ui-button[role="button"],[role="button"],input[type="checkbox"],[role="checkbox"],label[for]')
  ].filter(shown).filter(e=>!isBrandLogo(e));
  // Apple's custom "Keep me signed in" can be a styled span with a hidden input.
  // Expose the visible label as a single focus target, never the hidden input.
  const keepText=[...doc.querySelectorAll('label,span,div,p')].filter(e=>
    e.children.length<4 && /keep me signed in/i.test((e.textContent||'').trim()) &&
    (e.textContent||'').trim().length<75 && shown(e));
  const keep=keepText.sort((a,b)=>a.getBoundingClientRect().width-b.getBoundingClientRect().width)[0];
  if(keep&&!candidates.some(e=>e===keep||e.contains(keep)))candidates.push(keep);
  const remember=doc.querySelector('#remember-me-label')||doc.querySelector('#remember-me');
  if(remember&&shown(remember)&&!candidates.includes(remember))candidates.push(remember);
  const first=loginInputs[0]||candidates[0];
  let currentLogin=state.loginEl?.isConnected&&shown(state.loginEl)&&candidates.includes(state.loginEl)?state.loginEl:first;
  if(action==='init'||action==='resume'||action==='viewer_sync'){
    state.loginEl=currentLogin; return focus(currentLogin,'login');
  }
  if(action==='back')return {mode:'exit',tier:'login'};
  if(action==='select'){
    state.loginEl=currentLogin;
    if(currentLogin?.matches('input:not([type="checkbox"]):not([type="radio"]),textarea,[contenteditable="true"]')){
      currentLogin.focus();
      window.__atv3AuthInput=currentLogin;
      return {mode:'text_input',tier:'login',type:'input',
       secure:currentLogin.type==='password',
       kind:currentLogin.type==='password'?'Password':
         (currentLogin.type==='email'?'Apple ID':
         (currentLogin.autocomplete==='one-time-code'?'Verification code':'Text')),
       ...overlay(currentLogin)};
    }
    if(currentLogin.matches('input[type="checkbox"],[role="checkbox"]')){
      currentLogin.click();return {mode:'login_dom_click',tier:'login',type:'control',...overlay(currentLogin)};
    }
    if(currentLogin.matches('label[for]')){
      const linked=doc.getElementById(currentLogin.getAttribute('for'));
      if(linked?.matches('input[type="checkbox"]')){linked.click();return {mode:'login_dom_click',tier:'login',type:'control',...overlay(currentLogin)};}
    }
    if(/keep me signed in/i.test((currentLogin.textContent||'').trim())){
      const parent=currentLogin.closest('label,[role="checkbox"],button')||currentLogin.parentElement;
      const input=parent?.querySelector('input[type="checkbox"]')||
        (currentLogin.closest('form')||doc).querySelector('input[type="checkbox"]');
      if(input){input.click();return {mode:'login_dom_click',tier:'login',type:'control',...overlay(currentLogin)};}
      (parent||currentLogin).click();return {mode:'login_dom_click',tier:'login',type:'control',...overlay(currentLogin)};
    }
    const target=currentLogin.closest('button,[role="button"],ui-button,a[href]')||currentLogin;
    if(target.matches(':disabled,[aria-disabled="true"]'))
      return {mode:'disabled',tier:'login',type:'control',...overlay(currentLogin)};
    target.click();
    return {mode:'login_dom_click',tier:'login',type:'control',...overlay(currentLogin)};
  }
  if(['up','down','left','right'].includes(action)){
    let next=nearest(currentLogin,candidates,action);
    if(action==='down'&&remember&&shown(remember)&&currentLogin!==remember){
      const cr=currentLogin.getBoundingClientRect(),rr=remember.getBoundingClientRect();
      if(rr.top>cr.top&&rr.top-cr.top<250&&(!next||next.getBoundingClientRect().top>rr.top+12))next=remember;
    }
    state.loginEl=next||currentLogin;
    return focus(state.loginEl,'login');
  }
  return focus(currentLogin,'login');
}
if(state.tier==='login')state.tier='controls';
// OneUp is a separate photo viewer over the virtual photo grid. The grid
// still exists under it, but must never receive the visible ATV focus.
const oneup=doc.querySelector('.OneUp-mainViewerContainer');
const viewerOpen=!!oneup&&shown(oneup);
const strip=viewerOpen?doc.querySelector('.Thumbstrip .grid-scroll'):null;
function viewerItems(){
  if(!strip)return [];
  const bound=strip.getBoundingClientRect();
  return [...strip.querySelectorAll('.grid-item')].filter(e=>{
    const r=e.getBoundingClientRect();
    return e.isConnected && r.width>9 && r.height>9 && 
      r.left>=bound.left+2 && r.right<=bound.right-2 &&
      r.top>=bound.top-2 && r.bottom<=bound.bottom+2;
  }).sort((a,b)=>a.getBoundingClientRect().left-b.getBoundingClientRect().left);
}
function centerThumb(){
  const items=viewerItems();
  if(!items.length)return null;
  const box=strip.getBoundingClientRect();
  const midpoint=box.left+box.width/2;
  return items.reduce((best,e)=>!best||
      Math.abs(coords(e).x-midpoint)<Math.abs(coords(best).x-midpoint)?e:best,null);
}
function viewerFocus(e){
  // Keep focus at the visual CENTER of the filmstrip. iCloud itself scrolls
  // the thumbnail ribbon when the selected image changes. The ATV outline
  // must not follow individual thumbnail element positions.
  const bar=doc.querySelector('.Thumbstrip');
  if(!bar)return {mode:'none',tier:'viewer'};
  state.viewerThumb=e||centerThumb();
  state.tier='viewer';
  const region=bar.getBoundingClientRect();
  const active=centerThumb()||state.viewerThumb;
  state.viewerThumb=active;
  const image=active?.querySelector('img')||active;
  const thumb=image?.getBoundingClientRect();
  const w=Math.max(12,(thumb?.width||40)+6);
  const h=Math.max(12,(thumb?.height||45)+6);
  const x=region.left+region.width/2-w/2;
  const y=(thumb?thumb.top+thumb.height/2:region.top+region.height/2)-h/2;
  let ring=document.getElementById('__atv3_photos_focus_ring');
  if(!ring){
    // overlay() owns the only NAS-drawn border and creates it if missing.
    overlay(bar);
    ring=document.getElementById('__atv3_photos_focus_ring');
  }
  Object.assign(ring.style,{display:'block',left:Math.round(dx+x)+'px',
       top:Math.round(dy+y)+'px',width:Math.round(w)+'px',
       height:Math.round(h)+'px'});
  return {mode:'focus',tier:'viewer',type:'thumbnail',
     x:Math.round(dx+x),y:Math.round(dy+y),
     w:Math.round(w),h:Math.round(h),
     stepPending:!!state.pendingViewerStep};
}
function immersiveExit(){
  const img=state.immersiveImage, marker=state.immersiveMarker;
  if(img && marker?.parentNode){
    marker.parentNode.insertBefore(img,marker);
    if(state.immersiveOriginalStyle===null)img.removeAttribute('style');
    else img.setAttribute('style',state.immersiveOriginalStyle);
    marker.remove();
  }
  state.immersiveImage=null;state.immersiveMarker=null;
  state.immersiveOriginalStyle=null;
  const cover=doc.getElementById('__atv3_immersive_photo');
  if(cover)cover.remove();
  state.immersive=false;
}
function immersiveEnter(){
  // Reuse the already decoded photo. Cloning an iCloud image creates a
  // separate load that can fail and display a broken-image icon.
  const video=doc.querySelector('.OneUpCarouselItem.is-center video')||
    doc.querySelector('.OneUp-mainViewerContainer video');
  const img=video||[...doc.querySelectorAll('.OneUpCarouselItem.is-center img')]
    .filter(e=>e.complete&&e.naturalWidth>0&&e.naturalHeight>0)
    .sort((a,b)=>{const x=a.getBoundingClientRect(),y=b.getBoundingClientRect();
      return y.width*y.height-x.width*x.height})[0];
  if(!img||!img.parentNode)
    return {mode:'not_ready',tier:'viewer',reason:'photo_not_loaded'};
  immersiveExit();
  const marker=doc.createComment('ATV3 restored photo position');
  img.parentNode.insertBefore(marker,img);
  const oldStyle=img.getAttribute('style');
  const panel=doc.createElement('div');
  panel.id='__atv3_immersive_photo';
  Object.assign(panel.style,{position:'fixed',inset:'0',background:'#000',
      zIndex:'2147483600',display:'flex',alignItems:'center',
      justifyContent:'center',pointerEvents:'none'});
  Object.assign(img.style,{display:'block',position:'static',width:'100%',
      height:'100%',maxWidth:'100%',maxHeight:'100%',objectFit:'contain',
      transform:'none',opacity:'1',margin:'0',padding:'0',border:'0'});
  panel.appendChild(img);
  doc.documentElement.appendChild(panel);
  state.immersiveImage=img;state.immersiveMarker=marker;
  state.immersiveOriginalStyle=oldStyle;
  const ring=document.getElementById('__atv3_photos_focus_ring');
  if(ring)ring.style.display='none';
  state.immersive=true;state.tier='immersive';
  return {mode:'immersive',tier:'immersive',type:'photo'};
}
if(state.immersive && !viewerOpen)immersiveExit();
if(state.immersive){
  if(action==='select'){
    const v=state.immersiveImage?.tagName==='VIDEO'?state.immersiveImage:
      doc.querySelector('.OneUpCarouselItem.is-center video');
    if(v){if(v.paused){v.muted=false;v.volume=1;
      v.play().catch(()=>{});}else v.pause();
      return {mode:'video_toggle',tier:'immersive'};}
  }
  if(action==='back'||action==='hold'){
    immersiveExit();
    return viewerFocus(state.viewerThumb?.isConnected?state.viewerThumb:centerThumb());
  }
  return {mode:'immersive',tier:'immersive'};
}
if(viewerOpen){
  if(action==='back'){
    immersiveExit();
    // iCloud OneUp has a dedicated Navigate back control; Escape does not
    // reliably close the viewer on every iCloud web release.
    const tiles=[...doc.querySelectorAll('.grid-item')]
      .filter(e=>!e.closest('.Thumbstrip'));
    const origin=tiles.indexOf(state.viewerOrigin||state.photo);
    const offset=state.viewerOffset||0;
    state.returnPhoto=(origin>=0?tiles[Math.max(0,Math.min(tiles.length-1,origin+offset))]:null)
       ||doc.querySelector('.grid-item .PhotoItemView.is-selected')?.closest('.grid-item')
       ||state.photo||firstGrid();
    const close=doc.querySelector('ui-button[aria-label="Navigate back"]');
    if(!close)return {mode:'viewer_back',tier:'photos'};
    const p=coords(close);
    state.viewerThumb=null;state.tier='photos';
    return {mode:'viewer_back',tier:'photos',type:'photo',
      x:Math.round(p.x+dx),y:Math.round(p.y+dy)};
  }
  if(action==='hold')return immersiveEnter();
  if(action==='init'||action==='resume'||action==='viewer_sync'){
    if(action==='viewer_sync' && state.pendingViewerStep){
      const img=doc.querySelector('.OneUpCarouselItem.is-center img');
      const src=img?.currentSrc||img?.src||null;
      if(src && state.beforeStepImage && src!==state.beforeStepImage){
        state.viewerOffset=(state.viewerOffset||0)+state.pendingViewerStep;
        state.pendingViewerStep=0;
      }
    }
    return viewerFocus(centerThumb());
  }
  if(action==='left'||action==='right'){
    const img=doc.querySelector('.OneUpCarouselItem.is-center img');
    state.beforeStepImage=img?.currentSrc||img?.src||null;
    state.pendingViewerStep=action==='right'?1:-1;
    return {mode:'viewer_step',tier:'viewer',key:action,
            type:'thumbnail'};
  }
  if(action==='select'){
    const v=doc.querySelector('.OneUpCarouselItem.is-center video')||
      doc.querySelector('.OneUp-mainViewerContainer video');
    if(v){
      if(v.paused||v.ended){if(v.ended)v.currentTime=0;
        v.muted=false;v.volume=1;
        v.play().catch(()=>{});}
      else v.pause();
      return {mode:'video_toggle',tier:'viewer'};
    }
    const play=[...doc.querySelectorAll('button,ui-button')].find(e=>
      e.closest('.OneUp-mainViewerContainer')&&shown(e)&&
      /^(play|pause)( video)?$/i.test(label(e)));
    if(play){const q=coords(play);return {mode:'click',tier:'viewer',
      type:'video_button',x:Math.round(q.x+dx),y:Math.round(q.y+dy)};}
    return viewerFocus(centerThumb());
  }
  if(action==='up'||action==='down')
    return viewerFocus(state.viewerThumb?.isConnected?state.viewerThumb:centerThumb());
}
if(action==='viewer_return'){
  state.tier='photos';
  let t=state.returnPhoto?.isConnected?state.returnPhoto:null;
  if(t&&!shown(t))try{t.scrollIntoView({block:'nearest'})}catch(e){}
  if(!t||!shown(t))
    t=doc.querySelector('.grid-item .PhotoItemView.is-selected')?.closest('.grid-item');
  if(!t||!shown(t))t=state.photo?.isConnected&&shown(state.photo)?state.photo:firstGrid();
  state.returnPhoto=null;state.viewerOrigin=null;state.viewerOffset=0;
  return t?focus(t,'photos'):{mode:'focus',tier:'photos'};
}
if(action==='back' && state.tier==='viewer' && !viewerOpen){
  state.tier='photos';
  const t=state.returnPhoto?.isConnected&&shown(state.returnPhoto)?state.returnPhoto:
     (doc.querySelector('.grid-item .PhotoItemView.is-selected')?.closest('.grid-item')
      ||state.photo||firstGrid());
  state.returnPhoto=null;
  return t?focus(t,'photos'):{mode:'focus',tier:'photos'};
}
if(action==='init'){
  state.tier='controls';state.photo=null;state.returnPhoto=null;
  state.viewerOffset=0;state.viewerOrigin=null;
  // A fresh app launch starts at Library, not the last private album or a
  // stale virtual-grid scroll offset left by a previous browser session.
  if(library){
    const selected=library.classList.contains('is-selected')||library.classList.contains('selected');
    if(!selected){
      try{library.click()}catch(e){}
      await new Promise(resolve=>view.setTimeout(resolve,140));
    }
  }
  const gridScroll=doc.querySelector('.grid-scroll');
  if(gridScroll&&gridScroll.scrollTop>0)gridScroll.scrollTop=0;
  const freshLibrary=[...doc.querySelectorAll('[role="treeitem"]')].find(e=>/^library$/i.test(label(e))&&shown(e));
  return focus(freshLibrary||library||buttons[0],'controls');
}
if(action==='resume'){
  window.__atv3ResumeForUnlock=false;
  const e=state.tier==='photos'?state.photo:state.control;
  return focus(e&&shown(e)?e:(library||buttons[0]),state.tier==='photos'&&shown(e)?'photos':'controls');
}
if(action==='back'){
  if(state.tier==='photos'){
    return focus(state.control&&shown(state.control)?state.control:(library||buttons[0]),'controls');
  }
  return {mode:'exit',tier:'controls'};
}
let tier=state.tier;
let current=tier==='photos'?state.photo:state.control;
if(!current||!shown(current)){
  if(tier==='photos'&&grid().length)current=firstGrid();
  else {tier='controls';current=library||buttons[0]}
}
if(!current)return {mode:'none',tier};
if(action==='select'){
  if(tier==='controls' && /^view album$/i.test(label(current))){
    // Click iCloud's actual View Album button first; only prompt for text
    // after the resulting real authentication field becomes visible.
    window.__atv3ResumeForUnlock=true;
  }
  if(tier==='photos'){
    state.viewerOrigin=current;state.viewerOffset=0;
    state.pendingViewerStep=0;state.beforeStepImage=null;state.returnPhoto=null;
  }
  if(tier==='controls' && coords(current).y<45 &&
     /^(Account|Create|Quick Access)$/i.test(label(current))){
    state.popupAnchor=current;state.popupEl=null;
    state.popupKnown=new Set([...doc.querySelectorAll(popupSelector)].filter(shown));
  }
  const popupCheck=!!(tier==='controls' && state.popupAnchor===current);
  const r=focus(current,tier),p=coords(current);
  return {mode:'click',tier,type:r.type,popupCheck,
          x:Math.round(p.x+dx),y:Math.round(p.y+dy),w:r.w,h:r.h};
}
if(!['left','right','up','down'].includes(action))return {mode:'none',tier};
if(tier==='controls'){
  // Both horizontal top bars are genuine first-tier controls:
  // row 0 (iCloud logo / Create / Quick Access / Account), and
  // row 1 (Photos toolbar / search) above the library sidebar.
  const cy=coords(current).y;
  const top0=controls.filter(e=>coords(e).y<45)
     .sort((a,b)=>coords(a).x-coords(b).x);
  const top1=controls.filter(e=>coords(e).y>=45&&coords(e).y<88)
     .sort((a,b)=>coords(a).x-coords(b).x);
  const closestByX=(items,x)=>items.reduce((best,e)=>
     (!best||Math.abs(coords(e).x-x)<Math.abs(coords(best).x-x))?e:best,null);
  if(action==='up' && isSidebar(current) &&
     !nearest(current,sidebar,'up') && top1.length)
    return focus(closestByX(top1,coords(current).x),'controls');
  if(action==='up' && cy>=45 && cy<88 && top0.length)
    return focus(closestByX(top0,coords(current).x),'controls');
  if(action==='down' && cy<45 && top1.length)
    return focus(closestByX(top1,coords(current).x),'controls');
  if(action==='down' && cy>=45 && cy<88){
    const below=controls.filter(e=>coords(e).y>=88);
    if(below.length)return focus(closestByX(below,coords(current).x),'controls');
  }
  if(action==='left'||action==='right'){
    const sameRow=cy<45?top0:(cy<88?top1:null);
    if(sameRow&&sameRow.length){
      const idx=sameRow.indexOf(current);
      const sorted=idx>=0?sameRow: sameRow;
      if(idx>=0){
        const pos=idx+(action==='right'?1:-1);
        if(pos>=0&&pos<sorted.length)return focus(sorted[pos],'controls');
      }
    }
  }
  if(action==='right'&&isSidebar(current)){
    let available=grid();
    if(!available.length){
      await new Promise(resolve=>view.setTimeout(resolve,150));
      available=grid();
    }
    if(available.length)return focus(firstGrid(),'photos');
    const mainBtns=buttons.filter(e=>coords(e).x>250);
    if(mainBtns.length){
      const unlock=mainBtns.find(e=>/^view album$/i.test(label(e)));
      return focus(unlock||nearest(current,mainBtns,'right')||mainBtns[0],'controls');
    }
  }
  let options=controls.filter(e=>{
    if(isSidebar(current)&&['up','down'].includes(action))return isSidebar(e);
    if(coords(current).y<90 && ['left','right'].includes(action))return coords(e).y<95;
    return true;
  });
  return focus(nearest(current,options,action)||current,'controls');
}
if(action==='left'){
  const a=nearest(current,grid(),'left');
  if(!a)return focus(state.control&&shown(state.control)?state.control:(library||buttons[0]),'controls');
  return focus(a,'photos');
}
if(action==='right'){
  return focus(nearest(current,grid(),'right')||current,'photos');
}
let next=nearest(current,grid(),action);
if(next)return focus(next,'photos');
if(action==='up'){
  const sc=scrollContainer(current);
  if(!sc||sc.scrollTop<=1){
    const toolbar=controls.filter(e=>coords(e).y>=45&&coords(e).y<88);
    if(toolbar.length)return focus(toolbar.reduce((best,e)=>
       !best||Math.abs(coords(e).x-coords(current).x)<
       Math.abs(coords(best).x-coords(current).x)?e:best,null),'controls');
  }
}
// Reached a virtualized grid edge: scroll the actual photo pane, wait until
// React has rendered replacement rows, then focus the closest visible tile.
const sc=scrollContainer(current);
if(!sc)return focus(current,'photos');
const oldTop=sc.scrollTop;
const dr=action==='down'?1:-1;
const amount=Math.max(170,Math.min(450,Math.floor(sc.clientHeight*.65)));
sc.scrollTop+=dr*amount;
if(sc.scrollTop===oldTop)return focus(current,'photos');
await new Promise(resolve=>view.setTimeout(resolve,125));
const fresh=grid();
const tiles=fresh.filter(e=>{
  const r=e.getBoundingClientRect();
  return r.top>=148 && r.bottom<=view.innerHeight-5 && r.left>=250;
});
if(!tiles.length)return focus(current,'photos');
const x=state.photoX||coords(current).x;
tiles.sort((a,b)=>{
  const aa=coords(a),bb=coords(b);
  const va=(dr>0?aa.y:view.innerHeight-aa.y);
  const vb=(dr>0?bb.y:view.innerHeight-bb.y);
  return (Math.abs(aa.x-x)*2+va)-(Math.abs(bb.x-x)*2+vb);
});
const result=focus(tiles[0],'photos');
return {...result,scrolled:true,scrollDelta:sc.scrollTop-oldTop};
})()
"""
class Browser:
    def __init__(self):
        self.lock = threading.RLock()
        self.socket = None
        self.auth_socket = None
        self.auth_target_id = None
        self.message_id = 0
        self.last_frame = None
        self.last_sha = ""
        self.last_frame_at = 0
        self.last_action_at = 0
        self.last_error = ""
        self.url = ""
        self.bytes_sent = 0
        self.nav_count=0
        self.last_nav_mode=""
        self.last_nav_action=""
        self.last_focus_type=""
        self.last_focus_rect={}
        self.last_input_secure=False
        self.last_input_kind=""
        self.last_tier="controls"
        self.last_scroll_delta=0

    def disconnect(self):
        if self.socket:
            try:self.socket.close()
            except Exception:pass
        self.socket = None
        if self.auth_socket:
            try:self.auth_socket.close()
            except Exception:pass
        self.auth_socket = None
        self.auth_target_id = None

    @staticmethod
    def _choose_cdp_target(pages):
        candidates=[p for p in pages if p.get("type")=="page" and p.get("webSocketDebuggerUrl")]
        if not candidates:raise ConnectionError("browser_no_page")
        # Apple sign-in often opens a distinct browser window. The capture
        # comes from Wayland, so CDP navigation should follow that window.
        # Restrict switching to known Apple sign-in origins only.
        from urllib.parse import urlsplit
        auth_hosts={"idmsa.apple.com","appleid.apple.com","account.apple.com","signin.apple.com","auth.apple.com"}
        auth=[]
        for item in candidates:
            try:
                uri=urlsplit(item.get("url",""))
                if uri.scheme=="https" and uri.hostname in auth_hosts:
                    auth.append(item)
            except (ValueError,TypeError):
                pass
        if auth:return auth[0]
        return next((p for p in candidates if "icloud.com/photos" in p.get("url","")), 
            next((p for p in candidates if "icloud.com" in p.get("url","")),candidates[0]))

    def _targets(self):
        req=urllib.request.Request(CDP_ENDPOINT+"/json/list")
        with urllib.request.urlopen(req,timeout=2) as res:
            return json.load(res)

    def _current_target(self):
        return self._choose_cdp_target(self._targets())

    @staticmethod
    def _auth_target(pages):
        from urllib.parse import urlsplit
        hosts={"idmsa.apple.com","appleid.apple.com","account.apple.com","signin.apple.com","auth.apple.com"}
        for p in pages:
            if p.get("type")!="iframe" or not p.get("webSocketDebuggerUrl"):continue
            try:
                u=urlsplit(p.get("url",""))
                if u.scheme=="https" and u.hostname in hosts:return p
            except (TypeError,ValueError):pass
        return None

    def _connect_auth_target(self):
        selected=self._auth_target(self._targets())
        new_id=selected.get("id") if selected else None
        if new_id==self.auth_target_id and (self.auth_socket is not None or not new_id):
            return
        if self.auth_socket:
            try:self.auth_socket.close()
            except Exception:pass
        self.auth_socket=None
        self.auth_target_id=None
        if not selected:return
        ws_url=selected["webSocketDebuggerUrl"].replace(
            "ws://0.0.0.0:9222","ws://127.0.0.1:39222").replace(
            "ws://127.0.0.1:9222","ws://127.0.0.1:39222")
        self.auth_socket=websocket.create_connection(ws_url,timeout=5,
                        origin="http://localhost:39222",
                        suppress_origin=False,enable_multithread=True)
        self.auth_socket.settimeout(5)
        self.auth_target_id=new_id

    def _ensure_correct_window(self):
        target=self._current_target()
        if self.socket and target.get("id")!=getattr(self,"target_id",None):
            self.disconnect()
        if not self.socket:self.connect(target=target)
        self._connect_auth_target()
        # The auth iframe can disappear after sign-in. Remove the temporary
        # main-page suppression so the photo-library focus ring is visible again.
        try:
            if self.auth_socket is not None:
                self._command_main("Runtime.evaluate", {"expression":
                    "document.getElementById('__atv3_photos_focus_ring')?.remove();if(!document.getElementById('__atv3_auth_ring_guard')){let s=document.createElement('style');s.id='__atv3_auth_ring_guard';s.textContent='body > #__atv3_photos_focus_ring,html > #__atv3_photos_focus_ring{display:none!important}';document.documentElement.appendChild(s)}"})
            else:
                self._command_main("Runtime.evaluate", {"expression":
                    "document.getElementById('__atv3_auth_ring_guard')?.remove();"})
        except Exception:pass

    def _command_main(self,method,params=None):
        self.message_id+=1
        mid=self.message_id
        self.socket.send(json.dumps({"id":mid,"method":method,"params":params or {}},separators=(",",":")))
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            obj=json.loads(self.socket.recv())
            if obj.get("id")==mid:return obj.get("result",{})
        raise TimeoutError("main_target_timeout")

    def connect(self,target=None):
        if self.socket:return
        selected=target or self._current_target()
        ws_url=selected["webSocketDebuggerUrl"].replace(
           "ws://0.0.0.0:9222","ws://127.0.0.1:39222").replace(
           "ws://127.0.0.1:9222","ws://127.0.0.1:39222")
        self.socket=websocket.create_connection(ws_url,timeout=5,
                      origin="http://localhost:39222",
                      suppress_origin=False,enable_multithread=True)
        self.socket.settimeout(5)
        self.target_id=selected.get("id")
        self._command("Page.enable")
        # Do not apply CDP device-metric overrides to live Wayland output.
        self.url=selected.get("url","")
        self.last_frame=None
        self.last_frame_at=0

    def _command(self, method, params=None):
        self.message_id+=1
        mid=self.message_id
        target_socket=(self.auth_socket if self.auth_socket is not None
                       and (method=="Runtime.evaluate" or method.startswith("Input."))
                       else self.socket)
        target_socket.send(json.dumps({"id":mid,"method":method,"params":params or {}},separators=(",",":")))
        deadline=time.monotonic()+6
        while time.monotonic()<deadline:
            obj=json.loads(target_socket.recv())
            if obj.get("id")==mid:
                if "error" in obj:
                    raise RuntimeError("browser_command_failed")
                return obj.get("result",{})
        raise TimeoutError("browser_command_timeout")

    def request(self, method, params=None):
        with self.lock:
            try:
                self.connect()
                return self._command(method, params)
            except Exception as ex:
                self.last_error=type(ex).__name__
                self.disconnect()
                raise

    def frame(self):
        with self.lock:
            if self.last_frame is not None and time.monotonic()-self.last_frame_at < 1.4:
                return self.last_frame,self.last_sha
            result=self.request("Page.captureScreenshot",
                 {"format":"jpeg","quality":90,"fromSurface":True,"captureBeyondViewport":False})
            data=base64.b64decode(result["data"])
            if not data.startswith(b"\xff\xd8") or len(data)>3_500_000:
                raise ValueError("invalid_screen_frame")
            sha=hashlib.sha256(data).hexdigest()[:24]
            self.last_frame=data
            self.last_sha=sha
            self.last_frame_at=time.monotonic()
            self.last_error=""
            return data,sha

    def nav(self, action):
        with self.lock:
            self._ensure_correct_window()
            if action not in ("up","down","left","right","select","hold","viewer_sync","back","init","resume","menu"):
                raise ValueError("invalid_action")
            if action=="menu":
                value={"mode":"escape","tier":self.last_tier}
                self.request("Input.dispatchKeyEvent", {"type":"keyDown","key":"Escape","code":"Escape","windowsVirtualKeyCode":27})
                self.request("Input.dispatchKeyEvent", {"type":"keyUp","key":"Escape","code":"Escape","windowsVirtualKeyCode":27})
            else:
                if action=="back" and self.last_tier=="photos":
                    for event_type in ("keyDown","keyUp"):
                        self.request("Input.dispatchKeyEvent",{
                            "type":event_type,"key":"Escape","code":"Escape",
                            "windowsVirtualKeyCode":27})
                js=SPATIAL_JS.replace("__ACTION__",json.dumps(action))
                result=self.request("Runtime.evaluate", {
                    "expression":js,"returnByValue":True,"awaitPromise":True,
                    "userGesture":action=="select"})
                value=result.get("result",{}).get("value",{})
                if value.get("mode")=="click":
                    x,y=value["x"],value["y"]
                    self.request("Input.dispatchMouseEvent",{"type":"mousePressed","x":x,"y":y,"button":"left","clickCount":1})
                    self.request("Input.dispatchMouseEvent",{"type":"mouseReleased","x":x,"y":y,"button":"left","clickCount":1})
                    if value.get("popupCheck") or value.get("type")=="menu_item":
                        # React mounts the Account drop-down only after click.
                        # The menu has its own tier and independent focus.
                        for probe in range(5):
                            time.sleep(.13)
                            sync=self.request("Runtime.evaluate",{
                              "expression":SPATIAL_JS.replace("__ACTION__",'"popup_sync"'),
                              "returnByValue":True,"awaitPromise":True}).get("result",{}).get("value",{})
                            if sync.get("mode")=="focus" and sync.get("tier")=="popup":
                                value=sync
                                break
                            if sync.get("mode")!="popup_wait":
                                value=sync
                                break
                        else:
                            value=self.request("Runtime.evaluate",{
                              "expression":SPATIAL_JS.replace("__ACTION__",'"popup_return"'),
                              "returnByValue":True,"awaitPromise":True}).get("result",{}).get("value",{})
                    if value.get("type")=="photo":
                        # Grid double-click opens OneUp; rebind to its bottom
                        # thumbstrip after React has constructed the viewer.
                        self.request("Input.dispatchMouseEvent",{"type":"mousePressed","x":x,"y":y,"button":"left","clickCount":2})
                        self.request("Input.dispatchMouseEvent",{"type":"mouseReleased","x":x,"y":y,"button":"left","clickCount":2})
                        time.sleep(.22)
                        for i in range(6):
                            newer=self.request("Runtime.evaluate",{
                              "expression":SPATIAL_JS.replace("__ACTION__",'"viewer_sync"'),
                              "returnByValue":True,"awaitPromise":True}).get("result",{}).get("value",{})
                            if newer.get("tier")=="viewer" and newer.get("mode")=="focus":
                                value=newer
                                break
                            time.sleep(.12)
                elif value.get("mode")=="popup_close":
                    # One Menu closes Account's popover, then focus returns
                    # to the exact button which opened it.
                    for typ in ("keyDown","keyUp"):
                        self.request("Input.dispatchKeyEvent",{
                           "type":typ,"key":"Escape","code":"Escape",
                           "windowsVirtualKeyCode":27})
                    time.sleep(.12)
                    probe=self.request("Runtime.evaluate",{
                      "expression":SPATIAL_JS.replace("__ACTION__",'"popup_probe"'),
                      "returnByValue":True,"awaitPromise":True}).get("result",{}).get("value",{})
                    if probe.get("mode")=="popup_open" and isinstance(value.get("ax"),(int,float)):
                        # Fallback for Account menus that do not close on Escape.
                        for typ in ("mousePressed","mouseReleased"):
                            self.request("Input.dispatchMouseEvent",{
                              "type":typ,"x":value["ax"],"y":value["ay"],
                              "button":"left","clickCount":1})
                    value=self.request("Runtime.evaluate",{
                      "expression":SPATIAL_JS.replace("__ACTION__",'"popup_return"'),
                      "returnByValue":True,"awaitPromise":True}).get("result",{}).get("value",{})
                elif value.get("mode")=="viewer_back":
                    if isinstance(value.get("x"),(int,float)):
                        for typ in ("mousePressed","mouseReleased"):
                            self.request("Input.dispatchMouseEvent",{
                                "type":typ,"x":value["x"],"y":value["y"],
                                "button":"left","clickCount":1})
                        time.sleep(.32)
                    # Wait for OneUp to disappear before changing the layer.
                    # If Apple's animation/event handler ignored the click,
                    # try the browser's own Escape rather than leaving the
                    # native controller in the wrong photo-navigation state.
                    for attempt in range(3):
                        is_open=self.request("Runtime.evaluate",{
                          "expression":"!!document.querySelector('iframe')?.contentDocument?.querySelector('.OneUp-mainViewerContainer')",
                          "returnByValue":True}).get("result",{}).get("value",False)
                        if not is_open:break
                        if attempt==0:
                            for typ in ("keyDown","keyUp"):
                                self.request("Input.dispatchKeyEvent",{
                                    "type":typ,"key":"Escape","code":"Escape",
                                    "windowsVirtualKeyCode":27})
                        time.sleep(.18)
                    if is_open:
                        value=self.request("Runtime.evaluate",{
                          "expression":SPATIAL_JS.replace("__ACTION__","'viewer_sync'"),
                          "returnByValue":True,"awaitPromise":True}).get("result",{}).get("value",{})
                    else:
                        value=self.request("Runtime.evaluate",{
                          "expression":SPATIAL_JS.replace("__ACTION__","'viewer_return'"),
                          "returnByValue":True,"awaitPromise":True}).get("result",{}).get("value",{})
                elif value.get("mode") in ("viewer_step","viewer_edge"):
                    # One command advances the actual iCloud OneUp photo;
                    # the border remains anchored at the filmstrip centre.
                    mapping={"left":("ArrowLeft",37),"right":("ArrowRight",39)}
                    key,virtual=mapping[action]
                    for typ in ("keyDown","keyUp"):
                        self.request("Input.dispatchKeyEvent",{
                            "type":typ,"key":key,"code":key,
                            "windowsVirtualKeyCode":virtual})
                    for attempt in range(5):
                        time.sleep(.13)
                        value=self.request("Runtime.evaluate",{
                          "expression":SPATIAL_JS.replace("__ACTION__",'"viewer_sync"'),
                          "returnByValue":True,"awaitPromise":True}).get("result",{}).get("value",{})
                        if not value.get("stepPending"):
                            break
                elif value.get("mode") in ("edge","none"):
                    mapping={"up":("ArrowUp","ArrowUp",38),"down":("ArrowDown","ArrowDown",40),
                             "left":("ArrowLeft","ArrowLeft",37),"right":("ArrowRight","ArrowRight",39)}
                    key,code,virtual=mapping[action]
                    self.request("Input.dispatchKeyEvent",{"type":"keyDown","key":key,"code":code,"windowsVirtualKeyCode":virtual})
                    self.request("Input.dispatchKeyEvent",{"type":"keyUp","key":key,"code":code,"windowsVirtualKeyCode":virtual})
            self.last_action_at=time.monotonic()
            self.last_frame_at=0
            self.nav_count+=1
            self.last_nav_action=action
            self.last_nav_mode=value.get("mode","unknown")
            self.last_tier=value.get("tier",self.last_tier)
            self.last_scroll_delta=value.get("scrollDelta",0)
            self.last_focus_type=value.get("type","")
            self.last_input_secure=value.get("secure",False) is True
            self.last_input_kind=value.get("kind","") if value.get("mode")=="text_input" else ""
            if all(isinstance(value.get(k),(int,float)) for k in ("x","y","w","h")):
                self.last_focus_rect={k:value[k] for k in ("x","y","w","h")}
            return self.last_nav_mode

    def insert_browser_text(self,plaintext):
        """Use only the exact visible input explicitly selected via ATV UI."""
        with self.lock:
            self._ensure_correct_window()
            result=self.request("Runtime.evaluate",{
                "expression":"""(()=>{
                  let f=window.__atv3AuthInput;
                  if(!f || !f.isConnected || !f.matches('input,textarea,[contenteditable="true"]'))
                    return false;
                  let rect=f.getBoundingClientRect();
                  if(rect.width<8 || rect.height<8)return false;
                  f.focus();
                  return f.ownerDocument.activeElement===f;
                })()""","returnByValue":True})
            if not result.get("result",{}).get("value",False):
                return {"ok":False,"error":"selected_input_not_available"}
            # Replace the entire selected field, rather than appending to prior input.
            # React-controlled inputs require the native setter plus an input event.
            script="""(()=>{const f=window.__atv3AuthInput;
              if(!f||!f.isConnected||document.activeElement!==f)return false;
              const proto=f instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
              const setter=Object.getOwnPropertyDescriptor(proto,'value')?.set;
              if(!setter)return false;
              setter.call(f,__TEXT__);
              f.dispatchEvent(new Event('input',{bubbles:true}));
              f.dispatchEvent(new Event('change',{bubbles:true}));
              return f.value===__TEXT__;
            })()""".replace('__TEXT__',json.dumps(plaintext))
            outcome=self.request("Runtime.evaluate",{"expression":script,"returnByValue":True})
            return {"ok":bool(outcome.get("result",{}).get("value")),"accepted":True}

    def submit_hidden_password(self,password):
        # Never persist password, expose it in status, or log it.
        # Only enter it into a real iCloud Photos password input if one exists.
        with self.lock:
            def evaluate(expr):
                r=self.request("Runtime.evaluate",{
                    "expression":expr,"returnByValue":True})
                return r.get("result",{}).get("value",{})
            # First click the actual View Album UI; it may open an Apple ID
            # reauthentication window on the remote browser.
            target=evaluate("""(()=>{
              const doc=document.querySelector('iframe')?.contentDocument||document;
              const e=[...doc.querySelectorAll('ui-button,[role=button],button')].find(x=>
                (x.getAttribute('aria-label')||x.textContent||'').trim()==='View Album');
              if(!e)return null;
              const r=e.getBoundingClientRect();
              return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)};
            })()""")
            if target:
                for t in ("mousePressed","mouseReleased"):
                    self.request("Input.dispatchMouseEvent",{
                        "type":t,"x":target["x"],"y":target["y"],
                        "button":"left","clickCount":1})
            time.sleep(.3)
            # Browser password form may be inside the same-origin iCloud iframe.
            found=evaluate("""(()=>{
              const docs=[document];
              for(const frame of document.querySelectorAll('iframe')){
                try{if(frame.contentDocument)docs.push(frame.contentDocument)}catch(e){}
              }
              for(const d of docs){
                const f=d.querySelector('input[type=password]');
                if(f&&f.getBoundingClientRect().width>1){
                  f.focus();
                  return true;
                }
              }
              return false;
            })()""")
            if not found:
                # The iCloud website may request reauthentication via an
                # out-of-page Apple security prompt. Never enter credentials
                # into an unrelated field or falsely report unlocking.
                evaluate("""(()=>{
                  let el=document.getElementById('__atv3_photos_unlock_notice');
                  if(!el){
                    el=document.createElement('div');
                    el.id='__atv3_photos_unlock_notice';
                    Object.assign(el.style,{position:'fixed',top:'60px',
                      left:'300px',maxWidth:'680px',padding:'16px',
                      background:'rgba(35,35,35,.92)',color:'white',
                      borderRadius:'10px',zIndex:'2147483646',
                      font:'19px -apple-system,sans-serif',
                      pointerEvents:'none'});
                    document.documentElement.appendChild(el);
                  }
                  el.textContent='iCloud requires a separate browser authentication step. The secure password field is not exposed; unlock Hidden in the NAS browser.';
                  setTimeout(()=>el?.remove(),8000);
                  return true;
                })()""")
                return {"ok":False,"error":"icloud_password_field_not_available"}
            self.request("Input.insertText",{"text":password})
            # Submit using Enter on the focused native webpage password field.
            self.request("Input.dispatchKeyEvent",{
                "type":"keyDown","key":"Enter","code":"Enter",
                "windowsVirtualKeyCode":13})
            self.request("Input.dispatchKeyEvent",{
                "type":"keyUp","key":"Enter","code":"Enter",
                "windowsVirtualKeyCode":13})
            return {"ok":True,"submitted":True}

browser=Browser()

class Handler(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"

    def log_message(self,*args):
        pass

    def reply(self,code,data,content_type="application/json",etag=None):
        self.send_response(code)
        self.send_header("Content-Type",content_type)
        self.send_header("Cache-Control","no-store, private")
        self.send_header("X-Content-Type-Options","nosniff")
        if etag:self.send_header("ETag",etag)
        self.send_header("Content-Length",str(len(data)))
        self.end_headers()
        if data:self.wfile.write(data)

    def json(self,obj,code=200):
        self.reply(code,json.dumps(obj,separators=(",",":")).encode())

    def authenticated(self):
        source=self.client_address[0]
        if source not in ALLOWED:return False
        supplied=self.headers.get("X-ATV-Photos-Key","")
        return hmac.compare_digest(supplied,SECRET)

    def do_GET(self):
        route=self.path.split("?",1)[0]
        if route=="/health":
            return self.json({"ok":True,"service":"atv3-icloud-photos","version":"0.1",
                             "browser_online":browser.socket is not None,"last_error":browser.last_error})
        if not self.authenticated():return self.json({"ok":False,"error":"unauthorized"},403)
        if route=="/v1/photos/status":
            try:
                pages=browser.request("Runtime.evaluate",{
                    "expression":"location.hostname","returnByValue":True})
                host=pages.get("result",{}).get("value","")
                return self.json({"ok":True,"browser":True,"hostname":host,
                                  "frame_ready":browser.last_frame is not None,
                                  "nav_count":browser.nav_count,
                                  "last_nav_mode":browser.last_nav_mode,
                                  "last_nav_action":browser.last_nav_action,
                                  "focus_type":browser.last_focus_type,
                                  "focus_rect":browser.last_focus_rect,
                                  "tier":browser.last_tier})
            except Exception:
                return self.json({"ok":False,"browser":False,"error":"browser_unavailable"},503)
        if route=="/v1/photos/frame.jpg":
            try:
                frame,sha=browser.frame()
                if self.headers.get("If-None-Match","")==sha:
                    return self.reply(304,b"","image/jpeg",etag=sha)
                return self.reply(200,frame,"image/jpeg",etag=sha)
            except Exception:
                return self.json({"ok":False,"error":"browser_unavailable"},503)
        return self.json({"ok":False,"error":"not_found"},404)

    def do_POST(self):
        if not self.authenticated():return self.json({"ok":False,"error":"unauthorized"},403)
        if self.path not in ("/v1/photos/nav","/v1/photos/input"):
            return self.json({"ok":False,"error":"not_found"},404)
        try:
            n=int(self.headers.get("Content-Length","0"))
            if n<1 or n>4096:return self.json({"ok":False,"error":"invalid_body"},400)
            obj=json.loads(self.rfile.read(n))
            if self.path=="/v1/photos/input":
                try: plaintext=_decrypt_native_input(obj)
                except ValueError:return self.json({"ok":False,"error":"invalid_encrypted_input"},400)
                result=browser.insert_browser_text(plaintext)
                del plaintext
                return self.json(result,200 if result.get("ok") else 409)
            action=obj.get("action")
            if action not in ("up","down","left","right","select","hold","viewer_sync","back","init","resume","menu"):
                return self.json({"ok":False,"error":"invalid_action"},400)
            mode=browser.nav(action)
            return self.json({"ok":True,"action":action,"mode":mode,
                              "focus_type":browser.last_focus_type,
                              "focus_rect":browser.last_focus_rect,
                              "tier":browser.last_tier,
                              "secure":browser.last_input_secure if browser.last_nav_mode=="text_input" else False,
                              "kind":browser.last_input_kind,
                              "scroll_delta":browser.last_scroll_delta})
        except Exception:
            return self.json({"ok":False,"error":"browser_unavailable"},503)

if __name__=="__main__":
    server=ThreadingHTTPServer((HOST,PORT),Handler)
    server.daemon_threads=True
    server.serve_forever()
