// ATV3 remote adapter for the ORIGINAL Folia user interface.
// No custom pages, overlays, captions, popups, or other visual components.
// Only keyboard focus of Folia's actual buttons/inputs and .click() activation.
(() => {
  if (window.__atv3TVNavigation) return;
  let active = null;
  let commands = 0;
  let focusRing = null;
  let animationFrame = 0;
  let scopeRoot = null;
  let deferredScopeTimer = null;
  let lastSelectTrigger = null;
  let lastSongTitle=null,lastSongCenter=null,lastSongClick=0;
  let pendingNativeWallTimer=null;
  let lastNativeWallAction=null;
  let latestCollectionEnteredAt=0;
  let stageWasVisible=false;
  let bottomReturnFocus=null;
  let bottomFocusTimer=null;
  let toolsReturnToBottom=false;
  const progressRange=el=>!!el?.matches?.('input[type="range"]') &&
    !!el.closest?.('[data-ponder="player-bar"] [data-folium-part="progress.track"]');
  const focusVisual=el=>progressRange(el)
    ?el.closest('[data-folium-part="progress.track"]'):el;
  const stronglyVisible=el=>{
    if(progressRange(el)){
      if(el.disabled || !el.isConnected)return false;
      const track=focusVisual(el),r=track?.getBoundingClientRect();
      return !!r && r.width>=40 && r.right>0 && r.left<innerWidth &&
        r.top<innerHeight && r.bottom>0 &&
        getComputedStyle(track).display!=='none';
    }
    if(!isVisible(el))return false;
    const r=el.getBoundingClientRect();
    const w=Math.max(0,Math.min(innerWidth,r.right)-Math.max(0,r.left));
    const h=Math.max(0,Math.min(innerHeight,r.bottom)-Math.max(0,r.top));
    return w>=Math.min(65,r.width*.55) && h>=Math.min(55,r.height*.55);
  };
  // SettingsModal uses data-folia-keyboard-window, NOT role="dialog".
  // Track current interactive scope and never focus obscured base-page buttons.
  // The original Folia's CSS uses :focus-visible and often suppresses
  // programmatic outlines. A small temporary ring around the ORIGINAL
  // focused element provides a remote-selection cue with no changed layout.
  function ensureRing() {
    if(focusRing)return focusRing;
    focusRing=document.createElement('div');
    focusRing.id='atv3-remote-focus-ring';
    Object.assign(focusRing.style,{
      position:'fixed',zIndex:'2147483000',pointerEvents:'none',
      boxSizing:'border-box',border:'3px solid #ffffff',
      borderRadius:'9px',boxShadow:'0 0 0 2px rgba(9,14,21,.95),0 0 12px rgba(255,255,255,.42)',
      display:'none',transition:'left 80ms, top 80ms, width 80ms, height 80ms'
    });
    document.body.appendChild(focusRing);
    return focusRing;
  }
  // Settings has nested overflow-y-auto panes. Browser viewport and pane
  // viewport differ: focus the button AND scroll its nearest scroll parent.
  function scrollParents(el){
    const result=[];
    for(let node=el?.parentElement;node && node!==document.body;node=node.parentElement){
      if(!(node instanceof HTMLElement))continue;
      const css=getComputedStyle(node);
      const y=css.overflowY||css.overflow||'';
      if(/auto|scroll|overlay/.test(y) &&
          node.scrollHeight>node.clientHeight+1)result.push(node);
    }
    return result;
  }
  function scrollSettingsFocusIntoView(el){
    if(!el || currentScope()===document)return false;
    let moved=false;
    for(const parent of scrollParents(el)){
      const target=el.getBoundingClientRect();
      const clip=parent.getBoundingClientRect();
      const pad=Math.min(22,Math.max(4,clip.height*.09));
      const top=clip.top+pad,bottom=clip.bottom-pad;
      let delta=0;
      if(target.top<top)delta=target.top-top;
      else if(target.bottom>bottom)delta=target.bottom-bottom;
      if(delta){
        const before=parent.scrollTop;
        parent.scrollTop=Math.max(0,Math.min(parent.scrollHeight-parent.clientHeight,
                                           before+delta));
        moved=moved || before!==parent.scrollTop;
      }
    }
    return moved;
  }
  function visibleInsideScrollport(el){
    const rect=el.getBoundingClientRect();
    let top=0,bottom=innerHeight,left=0,right=innerWidth;
    for(const parent of scrollParents(el)){
      const r=parent.getBoundingClientRect();
      top=Math.max(top,r.top);bottom=Math.min(bottom,r.bottom);
      left=Math.max(left,r.left);right=Math.min(right,r.right);
    }
    return {
      left:Math.max(left,rect.left-4),top:Math.max(top,rect.top-4),
      right:Math.min(right,rect.right+4),bottom:Math.min(bottom,rect.bottom+4)
    };
  }
  function positionRing(){
    if(!focusRing || !active || !stronglyVisible(active)){
      if(focusRing)focusRing.style.display='none';
      return;
    }
    const isRange=progressRange(active);
    const clip=visibleInsideScrollport(focusVisual(active));
    const left=Math.max(1,clip.left),top=Math.max(1,clip.top-(isRange?9:0));
    const right=Math.min(innerWidth-1,clip.right);
    const bottom=Math.min(innerHeight-1,clip.bottom+(isRange?9:0));
    // Prevent white ring from bleeding outside Settings scroll panel.
    if(right-left<10||bottom-top<8){focusRing.style.display='none';return;}
    Object.assign(focusRing.style,{
      display:'block',left:left+'px',top:top+'px',
      width:(right-left)+'px',height:(bottom-top)+'px'
    });
  }
  function keepRingPosition(){
    // The ORIGINAL Folia swaps out Bravais when opening the full-screen
    // player, and swaps it back on Menu. A detached song-wall action cannot
    // remain the TV remote's active target across either transition.
    const stage=[...document.querySelectorAll('[data-library-stage="bravais"]')]
      .find(stronglyVisible);
    const stageVisible=!!stage;
    const canRetarget=!deferredScopeTimer && !pendingNativeWallTimer &&
      currentScope()===document;
    if(canRetarget){
      if(active && !active.isConnected){
        setFocus(stageVisible?currentMiddleStrip():null);
      }else if(stageVisible && !stageWasVisible &&
         (!active || !stronglyVisible(active))){
        const middle=currentMiddleStrip();
        if(middle)setFocus(middle);
      }else if(!stageVisible && active && !stronglyVisible(active)){
        setFocus(null);
      }
    }
    stageWasVisible=stageVisible;
    positionRing();
    animationFrame=requestAnimationFrame(keepRingPosition);
  }
  // Ring is a focus indicator only; Folia owns the actual screen and click.
  const SELECTOR='button,[role="button"],[role="menuitem"],[role="menuitemradio"],[role="option"],a[href],input,select,textarea,[tabindex]:not([tabindex="-1"])';
  const isVisible = el => {
    if (!el || !el.isConnected || el.closest('[inert],[aria-hidden="true"]')) return false;
    const rect=el.getBoundingClientRect();
    if (rect.width<6 || rect.height<6 || rect.right<=0 || rect.bottom<=0
        || rect.left>=innerWidth || rect.top>=innerHeight)return false;
    const style=getComputedStyle(el);
    return style.visibility!=='hidden'&&style.display!=='none'&&+style.opacity>0;
  };
  function currentScope() {
    // CustomSelectMenu uses createPortal(...,document.body). Its listbox
    // is a sibling of SettingsModal; it must take priority over the modal.
    const dropdown=[...document.querySelectorAll('[role="listbox"]')].filter(isVisible).pop();
    if(dropdown)return dropdown;
    // Settings, command palette, Bravais login, nested Folia dialogs all
    // mark their OWN interactive root; filter animated invisible windows.
    const win=[...document.querySelectorAll('[data-folia-keyboard-window="true"]')].filter(isVisible);
    const full=win.filter(el=>{
      const r=el.getBoundingClientRect();
      return r.width>innerWidth*.5 && r.height>innerHeight*.5;
    });
    if(full.length)return full[full.length-1];
    const accountLogin=[...document.querySelectorAll('[data-bravais-account-login],[data-bravais-account-confirm]')].filter(isVisible).pop();
    if(accountLogin)return accountLogin;
    const dialog=[...document.querySelectorAll('[role="dialog"],[role="alertdialog"]')].filter(isVisible).pop();
    if(dialog)return dialog;
    const menu=[...document.querySelectorAll('[data-bravais-account-list],[role="menu"]')].filter(isVisible).pop();
    return menu||win.pop()||document;
  }
  function syncScope() {
    const root=currentScope();
    if(root!==scopeRoot) {
      const former=scopeRoot;
      scopeRoot=root;
      const opts=elements();
      // An opened WallTools menu is a separate focus scope. Closing it
      // returns to its REAL lower-right trigger, never the center rail.
      if(root===document && former?.matches?.('.lattice-tools-panel')){
        const trigger=rightBottomTool();
        if(trigger){setFocus(trigger);return true;}
      }
      // Initial remote startup already chose the current middle category.
      // The first arrow must not discard that focus and jump to DOM[0].
      if(former===null && root===document && active && opts.includes(active)){
        positionRing();
        return false;
      }
      // Modal entry must still leave the covered original page.
      let next;
      if(root.matches?.('[role="listbox"]')){
        next=opts.find(el=>el.getAttribute('aria-selected')==='true')||
             opts.find(el=>!el.disabled);
      }else if(lastSelectTrigger && lastSelectTrigger.isConnected &&
               root.contains(lastSelectTrigger)){
        next=lastSelectTrigger;
        lastSelectTrigger=null;
      }else{
        next=opts.find(el=>root!==document && /^(Options|选项|设置)$/.test(title(el)||''))||
             opts.find(el=>!el.disabled)||opts[0];
      }
      setFocus(next||null);
      return true;
    }
    return false;
  }
  function elements() {
    const root=currentScope();
    // Include settings controls farther down scrollable content. Their
    // window coordinates may be outside a pane until focused.
    const eligible=el=>{
      if(root===document)return isVisible(el);
      if(!el.isConnected || el.closest('[inert],[aria-hidden="true"]'))return false;
      const r=el.getBoundingClientRect();
      if(r.width<6||r.height<6)return false;
      const css=getComputedStyle(el);
      if(css.display==='none'||css.visibility==='hidden'||+css.opacity===0)return false;
      return true;
    };
    const all=[...root.querySelectorAll(SELECTOR)].filter(eligible);
    // Nested controls occasionally match both wrapper and its internal button.
    return all.filter(el=>!all.some(other=>other!==el&&el.contains(other)));
  }
  function title(el) {
    if(!el)return null;
    return String(el.getAttribute('aria-label')||el.getAttribute('title')
      ||el.textContent||el.getAttribute('placeholder')||el.tagName).replace(/\s+/g,' ').trim().slice(0,80);
  }
  // Bravais itself owns keyboard wall navigation, camera motion and
  // virtualization. Never constrain a remote to the initially visible DOM.
  function originalWallFocusedTile(){
    return [...document.querySelectorAll('[data-bravais-slot][data-bravais-focused="true"]')]
      .find(el=>el.isConnected && el.querySelector('[role="button"]'))||null;
  }
  function useOriginalWallKeyboard(direction){
    const field=document.querySelector('[data-library-stage="bravais"] .bravais-field');
    if(!field)return null;
    const keys={up:'ArrowUp',down:'ArrowDown',left:'ArrowLeft',right:'ArrowRight'};
    if(!keys[direction])return null;
    // Target the actual wall field, never a nested button: the application's
    // useBravaisKeyboard handler skips control-target key events by design.
    const beforeTile=originalWallFocusedTile()?.getAttribute('data-bravais-slot')||null;
    const e=new KeyboardEvent('keydown',{
      key:keys[direction],code:keys[direction],bubbles:true,cancelable:true
    });
    field.dispatchEvent(e);
    if(!e.defaultPrevented)return null; // don't steal keys from other screens
    lastNativeWallAction=direction;
    if(deferredScopeTimer){clearInterval(deferredScopeTimer);deferredScopeTimer=null;}
    if(pendingNativeWallTimer)clearInterval(pendingNativeWallTimer);
    let checked=0;
    const sync=()=>{
      checked++;
      const tile=originalWallFocusedTile();
      const candidate=tile?.querySelector('[role="button"]');
      // Focus is committed before camera reveal animation finishes. Don't
      // select an unrelated header control while the camera is moving.
      const moved=tile?.getAttribute('data-bravais-slot')!==beforeTile;
      // React marks the next tile in a later commit. Immediately after the
      // keypress, the old tile still has data-bravais-focused: don't stop
      // waiting and falsely keep the remote trapped in the first viewport.
      if(candidate && stronglyVisible(candidate) && (moved || checked>=25)){
        setFocus(candidate);
        clearInterval(pendingNativeWallTimer);
        pendingNativeWallTimer=null;
        return;
      }
      if(checked>=40){
        clearInterval(pendingNativeWallTimer);
        pendingNativeWallTimer=null;
        positionRing();
      }
    };
    pendingNativeWallTimer=setInterval(sync,50);
    sync();
    return {ok:true,nativeWall:true,panHandled:true};
  }
  function expandedPlayForSlot(slotKey){
    if(!slotKey)return null;
    const tiles=[...document.querySelectorAll('[data-bravais-slot][data-bravais-expanded="true"]')];
    const match=tiles.find(el=>el.getAttribute('data-bravais-slot')===slotKey);
    const play=match?.querySelector('[data-bravais-action="play"]');
    return play && !play.disabled && stronglyVisible(play)?play:null;
  }
  function afterSong(){
    const expandedPlay=[...document.querySelectorAll('[data-bravais-expanded="true"] [data-bravais-action="play"]')]
      .find(el=>!el.disabled && stronglyVisible(el));
    if(expandedPlay)return expandedPlay;
    const options=elements().filter(el=>!el.disabled && stronglyVisible(el));
    if(!options.length)return null;
    return options.find(el=>lastSongTitle && title(el)===lastSongTitle)
      ||options.find(el=>el.closest('[data-bravais-current="true"],[data-bravais-focused="true"],[data-bravais-expanded="true"]'))
      ||[...options].sort((x,y)=>{
        const point=lastSongCenter||[innerWidth/2,innerHeight/2];
        const distance=el=>{
          const r=el.getBoundingClientRect();
          return Math.hypot(r.left+r.width/2-point[0],r.top+r.height/2-point[1]);
        };
        return distance(x)-distance(y);
      })[0];
  }
  function centerActiveSeamTab(){
    const tabs=[...document.querySelectorAll('[data-bravais-seam] [data-bravais-tab]')]
      .filter(el=>!el.disabled && stronglyVisible(el));
    return tabs.find(el=>el.getAttribute('aria-selected')==='true') || tabs[0] || null;
  }
  // In a playlist, Bravais REPLACES home tabs with its own collection
  // strip. Returning to home tabs is NOT the same as returning to the middle
  // strip of the current playlist.
  function currentMiddleStrip(){
    const seam=[...document.querySelectorAll('[data-bravais-seam]')]
      .find(stronglyVisible);
    if(!seam)return null;
    return centerActiveSeamTab()||
      [
        '[data-bravais-seam-action="play-scope"]',
        '[data-bravais-seam-action="list"]',
        '[data-bravais-seam-action="expand"]',
        '[data-bravais-seam-toggle]',
        '[data-bravais-seam-action="back"]',
        'button'
      ].map(sel=>[...seam.querySelectorAll(sel)]
        .find(el=>!el.disabled && stronglyVisible(el)))
       .find(Boolean)||null;
  }
  function collectionReady(){
    const seam=document.querySelector('[data-bravais-seam]');
    return !!seam && stronglyVisible(seam) &&
      !centerActiveSeamTab() &&
      !!seam.querySelector('.bravais-seam-full,.bravais-seam-spine');
  }
  function expandedTrackControls(){
    const expanded=active?.closest?.('[data-bravais-slot][data-bravais-expanded="true"]');
    if(!expanded)return null;
    const controls=[...expanded.querySelectorAll('[data-bravais-action]')]
      .filter(el=>!el.disabled && stronglyVisible(el));
    return controls.includes(active)?controls:null;
  }
  function moveInExpandedTrack(direction){
    const controls=expandedTrackControls();
    if(!controls)return null;
    if(direction!=='left'&&direction!=='right'&&direction!=='up'&&direction!=='down')return null;
    const [x,y]=aabb(active);
    const dx=direction==='left'?-1:direction==='right'?1:0;
    const dy=direction==='up'?-1:direction==='down'?1:0;
    const scored=controls.filter(el=>el!==active).map(el=>{
      const [cx,cy]=aabb(el),ahead=(cx-x)*dx+(cy-y)*dy;
      return {el,ahead,cross:Math.abs(dx?cy-y:cx-x)};
    }).filter(o=>o.ahead>2).sort((a,b)=>
      a.ahead+a.cross*1.8-b.ahead-b.cross*1.8);
    if(scored.length)setFocus(scored[0].el);
    // Never hand an expanded card's arrows to the wall camera. The current
    // track's Enter Fullscreen button is next to its Play control.
    return {ok:true,trackActions:true,moved:scored.length>0};
  }
  // The original Folia bottom player collapses its buttons during playback.
  // A TV remote has no mouse hover, so enter its existing hover expansion
  // before focusing its REAL play/pause button (never create a replacement).
  function bottomBar() {
    const bar=document.querySelector('[data-ponder="player-bar"]');
    if(!bar || !isVisible(bar))return null;
    // The wrapper becomes transparent when Folia intentionally hides the bar.
    const wrapper=bar.parentElement?.parentElement;
    if(wrapper && +getComputedStyle(wrapper).opacity===0)return null;
    return bar;
  }
  function bottomBarButtons(bar) {
    return [...(bar?.querySelectorAll(SELECTOR)||[])]
      .filter(el=>el.tagName==='BUTTON' && !el.disabled && stronglyVisible(el));
  }
  function bottomSeek(bar) {
    const el=bar?.querySelector('[data-folium-part="progress.track"] input[type="range"]');
    return el && !el.disabled && stronglyVisible(el)?el:null;
  }
  function rightBottomTool() {
    // Folia's ORIGINAL WallToolsDock -> WallToolsSurface -> SlideActionButton.
    // The dock is outside the Bravais camera, so wall-native keyboard motion
    // never traverses this button by itself. This is its concrete DOM target.
    const nodes=[...document.querySelectorAll('.lattice-tools > .relative > button')];
    return nodes.find(el=>!el.disabled && stronglyVisible(el))||null;
  }
  function toolPanel() {
    const tool=rightBottomTool();
    const panel=tool?.closest('.lattice-tools')?.querySelector('.lattice-tools-panel[role="menu"]');
    return panel && stronglyVisible(panel)?panel:null;
  }
  function focusRightBottomTool() {
    const button=rightBottomTool();
    if(!button || currentScope()!==document)return null;
    toolsReturnToBottom=!!active?.closest?.('[data-ponder="player-bar"]');
    releaseBottomBar();
    setFocus(button);
    return {ok:true,rightBottomTool:true,focusMoved:true};
  }
  function navigateRightBottomTool(direction) {
    const tools=active?.closest?.('.lattice-tools');
    if(!tools || currentScope()!==document)return null;
    const trigger=rightBottomTool(),panel=toolPanel();
    if(!trigger)return null;
    if(active===trigger){
      if(direction==='left' || direction==='down'){
        if(toolsReturnToBottom){
          const bottom=enterBottomBar();
          if(bottom)return {ok:true,rightBottomToolExit:true,...bottom};
        }
        const middle=currentMiddleStrip();
        if(middle)setFocus(middle);
        toolsReturnToBottom=false;
        return {ok:true,rightBottomToolExit:true};
      }
      if(direction==='up' && panel){
        const choices=[...panel.querySelectorAll(SELECTOR)]
          .filter(el=>el!==panel && !el.disabled && stronglyVisible(el));
        const target=choices.sort((a,b)=>aabb(b)[1]-aabb(a)[1])[0];
        if(target)setFocus(target);
        return {ok:true,toolPanel:true,focusMoved:!!target};
      }
      return {ok:true,rightBottomTool:true,focusMoved:false};
    }
    if(panel && panel.contains(active)){
      const choices=[...panel.querySelectorAll(SELECTOR)]
        .filter(el=>!el.disabled && stronglyVisible(el) && el!==active);
      const [x,y]=aabb(active);
      const dx=direction==='left'?-1:direction==='right'?1:0;
      const dy=direction==='up'?-1:direction==='down'?1:0;
      const candidate=choices.map(el=>{
        const [nx,ny]=aabb(el),ahead=(nx-x)*dx+(ny-y)*dy;
        return {el,ahead,score:ahead+1.8*Math.abs(dx?ny-y:nx-x)};
      }).filter(o=>o.ahead>3).sort((a,b)=>a.score-b.score)[0]?.el;
      if(candidate){setFocus(candidate);return {ok:true,toolPanel:true,focusMoved:true};}
      if(direction==='down'){setFocus(trigger);return {ok:true,toolPanel:true,focusMoved:true};}
      return {ok:true,toolPanel:true,focusMoved:false};
    }
    return null;
  }
  function bottomPlayButton(bar) {
    // The original expanded play/pause is the 48x48 round button.
    // Unlike a positional nth-child it survives dynamic track title / slots.
    return bottomBarButtons(bar).find(el=>
      el.classList.contains('h-12') && el.classList.contains('w-12') &&
      el.classList.contains('rounded-full'))||null;
  }
  function releaseBottomBar() {
    if(bottomFocusTimer){clearInterval(bottomFocusTimer);bottomFocusTimer=null;}
    const bar=bottomBar();
    if(bar)bar.dispatchEvent(new MouseEvent('mouseout',{
      bubbles:true,relatedTarget:document.body
    }));
  }
  function enterBottomBar() {
    if(currentScope()!==document)return null;
    const bar=bottomBar();
    if(!bar)return null;
    if(!active?.closest?.('[data-ponder="player-bar"]')){
      bottomReturnFocus=active?.isConnected?active:null;
    }
    bar.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,relatedTarget:null}));
    if(bottomFocusTimer)clearInterval(bottomFocusTimer);
    let tries=0;
    const sync=()=>{
      tries++;
      if(currentScope()!==document || !bar.isConnected){
        clearInterval(bottomFocusTimer);bottomFocusTimer=null;return;
      }
      const play=bottomPlayButton(bar);
      if(play){
        clearInterval(bottomFocusTimer);bottomFocusTimer=null;
        setFocus(play);return;
      }
      if(tries>=16){clearInterval(bottomFocusTimer);bottomFocusTimer=null;}
    };
    bottomFocusTimer=setInterval(sync,50);
    sync();
    return {ok:true,bottomBar:true,expanding:true};
  }
  function navigateBottomBar(direction) {
    const bar=active?.closest?.('[data-ponder="player-bar"]');
    if(!bar || currentScope()!==document)return null;
    const range=bottomSeek(bar);
    if(progressRange(active)){
      // The progress element is a focus target ONLY on ATV3. The remote's
      // four arrows are navigation, never native range input/seek commands.
      const buttons=bottomBarButtons(bar);
      const [x,y]=aabb(active);
      const dx=direction==='left'?-1:direction==='right'?1:0;
      const dy=direction==='up'?-1:direction==='down'?1:0;
      const next=buttons.map(el=>{
        const [nx,ny]=aabb(el),ahead=(nx-x)*dx+(ny-y)*dy;
        const cross=Math.abs(dx?ny-y:nx-x);
        return {el,ahead,score:ahead+cross*1.8};
      }).filter(item=>item.ahead>3)
        .sort((a,b)=>a.score-b.score)[0]?.el
        || (direction==='up'?bottomPlayButton(bar):null);
      if(next){
        setFocus(next);
        return {ok:true,bottomSeek:true,focusMoved:true};
      }
      // No more buttons in this direction: Down leaves the player and
      // returns to the previously focused original Folia control.
      if(direction==='down'){
        const target=bottomReturnFocus?.isConnected && stronglyVisible(bottomReturnFocus)
          ?bottomReturnFocus:currentMiddleStrip();
        releaseBottomBar();
        bottomReturnFocus=null;
        if(target)setFocus(target);
        return {ok:true,bottomBarExit:true,focusMoved:!!target};
      }
      if(direction==='right'){
        const tool=focusRightBottomTool();
        if(tool)return tool;
      }
      return {ok:true,bottomSeek:true,focusMoved:false};
    }
    if(direction==='down' && range){
      setFocus(range);
      return {ok:true,bottomSeek:true,entered:true};
    }
    if(direction==='up'){
      const target=bottomReturnFocus?.isConnected && stronglyVisible(bottomReturnFocus)
        ?bottomReturnFocus:currentMiddleStrip();
      releaseBottomBar();
      bottomReturnFocus=null;
      if(target)setFocus(target);
      return {ok:true,bottomBarExit:true};
    }
    // Only move within original player buttons; don't accidentally jump back
    // into the song wall when pressing Left/Right on the transport.
    const buttons=bottomBarButtons(bar);
    const [x,y]=aabb(active);
    const dx=direction==='left'?-1:direction==='right'?1:0;
    const dy=direction==='up'?-1:direction==='down'?1:0;
    const next=buttons.filter(el=>el!==active).map(el=>{
      const [nx,ny]=aabb(el);
      const ahead=(nx-x)*dx+(ny-y)*dy;
      const cross=Math.abs(dx?ny-y:nx-x);
      return {el,ahead,score:ahead+cross*1.8};
    }).filter(item=>item.ahead>3).sort((a,b)=>a.score-b.score)[0]?.el;
    if(next)setFocus(next);
    else if(direction==='right'){
      const tool=focusRightBottomTool();
      if(tool)return tool;
    }
    return {ok:true,bottomBar:true,moved:!!next};
  }
  function preferred() {
    const scope=currentScope(),opts=elements();
    if(!opts.length)return null;
    if(scope!==document) {
      const chosen=opts.find(el=>el.matches('[data-bravais-account-provider]')&&!el.disabled);
      const options=opts.find(el=>/^(Options|选项|设置)$/.test(title(el)||'')&&!el.disabled);
      return chosen||options||opts.find(el=>!el.disabled)||opts[0];
    }
    // Start in the real central navigation column, not an arbitrary wall item.
    return currentMiddleStrip() || opts.find(el=>!el.disabled)||opts[0];
  }
  function setFocus(el) {
    if(active && active!==el && active.isConnected) active.removeAttribute('data-atv3-key-focus');
    active=el;
    if(!el){positionRing();return;}
    ensureRing();
    if(!animationFrame)animationFrame=requestAnimationFrame(keepRingPosition);
    // Focus the real Folia button; outline applies only while remote-focused,
    // matching ordinary keyboard focus without altering any page structure.
    el.setAttribute('data-atv3-key-focus','');
    try { el.focus({preventScroll:true,focusVisible:true}); }
    catch { el.focus({preventScroll:true}); }
    if(currentScope()!==document){
      scrollSettingsFocusIntoView(el);
    }
    positionRing();
  }
  const aabb = el => {
    const r=el.getBoundingClientRect();
    return [r.left+r.width/2,r.top+r.height/2,r.width,r.height];
  };
  function chooseDirection(direction) {
    syncScope();
    const scope=currentScope();
    if(scope===document){
      const toolMove=navigateRightBottomTool(direction);
      if(toolMove)return toolMove;
      const bottomMove=navigateBottomBar(direction);
      if(bottomMove)return bottomMove;
      // The center rail is an exit from the infinitely scrolling song wall.
      // Down at its last real action enters the bottom player, rather than
      // jumping to an unrelated tile elsewhere in the document.
      if(direction==='down' && active?.closest?.('[data-bravais-seam]')){
        const seam=active.closest('[data-bravais-seam]');
        const [,y]=aabb(active);
        const further=[...seam.querySelectorAll(SELECTOR)]
          .some(el=>el!==active && !el.disabled && stronglyVisible(el) &&
                 aabb(el)[1]>y+4);
        if(!further){
          const bottom=enterBottomBar();
          if(bottom)return bottom;
        }
      }
      const actionMove=moveInExpandedTrack(direction);
      if(actionMove){
        // Last action on a song card -> bottom transport with Down.
        if(direction==='down' && !actionMove.moved){
          const bottom=enterBottomBar();
          if(bottom)return bottom;
        }
        return actionMove;
      }
    }
    if(scope===document &&
       (active?.closest?.('[data-bravais-slot]') ||
        (document.querySelector('[data-library-stage="bravais"]') &&
         document.activeElement?.matches?.('.bravais-field')))){
      const original=useOriginalWallKeyboard(direction);
      if(original)return original;
    }
    // Folia language dropdown and other CustomSelect options are native
    // React button children of a portaled listbox, not the settings panel.
    if(scope.matches?.('[role="listbox"]')){
      const options=elements();
      if(!options.length)return {ok:false,reason:'empty_dropdown'};
      let index=options.indexOf(active);
      if(index<0)index=0;
      if(direction==='down'||direction==='right')
        index=Math.min(options.length-1,index+1);
      else if(direction==='up'||direction==='left')
        index=Math.max(0,index-1);
      setFocus(options[index]);
      return {ok:true,dropdown:true};
    }
    // On original Settings -> Options -> General, Right moves from
    // section/navigation chips into the real language CustomSelect. It
    // is often scrolled outside the visible portion of the modal.
    if(scope!==document && (direction==='right'||direction==='down') &&
       !active?.matches?.('[aria-haspopup="listbox"]')){
      const anchor=scope.querySelector('[data-settings-anchor="languageSettings"]');
      const isGeneralNavigation=/^(General|通用|常规|语言|Language)/i.test(title(active)||'');
      const dropdownTrigger=(isGeneralNavigation || anchor?.contains(active))
         ? anchor?.querySelector('[aria-haspopup="listbox"]') : null;
      if(dropdownTrigger && !dropdownTrigger.disabled){
        dropdownTrigger.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});
        setFocus(dropdownTrigger);
        return {ok:true,languageSelect:true};
      }
    }
    const opts=elements();
    if(!opts.length)return {ok:false,reason:'no_candidates'};
    if(!active || !opts.includes(active) ||
       (scope===document && !stronglyVisible(active))){
      setFocus(active?(afterSong()||preferred()):preferred());
      return {ok:true,recovered:!!active};
    }
    const [x,y]=aabb(active);
    const dx=direction==='left'?-1:direction==='right'?1:0;
    const dy=direction==='up'?-1:direction==='down'?1:0;
    const scores=[];
    for(const node of opts) {
      if(node===active)continue;
      const [nx,ny]=aabb(node),ahead=(nx-x)*dx+(ny-y)*dy;
      if(ahead<=4)continue;
      const cross=Math.abs(dx?ny-y:nx-x);
      scores.push({node,rank:ahead+cross*2.2+(node.disabled?400:0)});
    }
    scores.sort((a,b)=>a.rank-b.rank);
    if(scores.length)setFocus(scores[0].node);
    else if(scope===document && direction==='down'){
      const bottom=enterBottomBar();
      if(bottom)return bottom;
    }
    return {ok:true};
  }
  function activate(){
    syncScope();
    if(progressRange(active))return {ok:true,bottomSeek:true,selected:false};
    const opts=elements();
    if(!active || !opts.includes(active)){setFocus(preferred());return {ok:true,selected:false};}
    if(active.disabled)return {ok:false,reason:'disabled',selected:false};
    const old=active,oldTitle=title(old);
    const pos=old.getBoundingClientRect();
    lastSongTitle=oldTitle;
    lastSongCenter=[Math.max(0,Math.min(innerWidth,pos.left+pos.width/2)),
                    Math.max(0,Math.min(innerHeight,pos.top+pos.height/2))];
    lastSongClick=Date.now();
    // Selection on an original Bravais tile expands a focus card. Its real
    // primary action is [data-bravais-action=play], not the header button.
    const slotElement=old.closest?.('[data-bravais-slot]');
    const clickedTrack=!!slotElement && !!old.matches?.('[role="button"]') &&
       !slotElement.matches('[data-bravais-expanded="true"]') &&
       slotElement.getAttribute('data-bravais-kind')==='track';
    const selectedSlot=clickedTrack?slotElement.getAttribute('data-bravais-slot'):null;
    const enteringCollection=!!slotElement &&
       !!old.matches?.('[role="button"]') &&
       !slotElement.matches('[data-bravais-expanded="true"]') &&
       slotElement.getAttribute('data-bravais-kind')!=='track' &&
       currentScope()===document;
    if(enteringCollection)latestCollectionEnteredAt=Date.now();
    if(old.matches?.('[aria-haspopup="listbox"]'))lastSelectTrigger=old;
    try {
      old.focus({preventScroll:true});
      // React/FramerMotion original handlers still handle the click.
      const before=currentScope();
      old.click();
      // Settings and nested Folia dialogs mount asynchronously. Transfer
      // the white rectangle as soon as the original modal is interactable.
      if(deferredScopeTimer)clearInterval(deferredScopeTimer);
      let checks=0;
      deferredScopeTimer=setInterval(()=>{
        checks++;
        if(enteringCollection){
          if(collectionReady()){
            const middle=currentMiddleStrip();
            if(middle){
              setFocus(middle);
              clearInterval(deferredScopeTimer);
              deferredScopeTimer=null;
              return;
            }
          }
          if(checks<45)return;
          clearInterval(deferredScopeTimer);
          deferredScopeTimer=null;
          return; // Keep selection while React transitions; never jump into tracks.
        }
        if(selectedSlot){
          const play=expandedPlayForSlot(selectedSlot);
          if(play){
            setFocus(play);
            clearInterval(deferredScopeTimer);
            deferredScopeTimer=null;
            return;
          }
          if(checks>=45){
            clearInterval(deferredScopeTimer);
            deferredScopeTimer=null;
            positionRing(); // unresolved: remain on card, never top-right
          }
          return; // wait for that SAME song's real play button only
        }
        if(syncScope() || checks>=20) {
          clearInterval(deferredScopeTimer);
          deferredScopeTimer=null;
          const optsNow=elements();
          if(!optsNow.includes(active) || !stronglyVisible(active)){
            const next=currentScope()===document && Date.now()-lastSongClick<2500
              ?afterSong():preferred();
            if(next)setFocus(next);
            else positionRing();
          }
        }
      },60);
      setTimeout(()=>{
        if(enteringCollection){
          if(collectionReady()){
            const middle=currentMiddleStrip();
            if(middle)setFocus(middle);
          }
          return;
        }
        if(selectedSlot){
          const play=expandedPlayForSlot(selectedSlot);
          if(play){setFocus(play);return;}
        }
        if(!selectedSlot && currentScope()===before && !stronglyVisible(old)){
          const next=afterSong();
          if(next)setFocus(next);
          else positionRing();
        }
      },320);
      return {ok:true,selected:true,activated:oldTitle};
    }catch(error){
      console.warn('[ATV3-REMOTE] Folia native button activation failed',error);
      return {ok:false,reason:'activation_failed'};
    }
  }
  function status(){
    const root=currentScope();
    const rect=active&&stronglyVisible(active)&&root.contains(active)
      ?focusVisual(active).getBoundingClientRect():null;
    return {originalFoliaUI:true,focus:progressRange(active)?'播放进度条':title(active),
      bottomSeek:progressRange(active),
      rightBottomToolAvailable:!!rightBottomTool(),
      media:[...document.querySelectorAll('audio')].slice(0,2).map(el=>({
        paused:el.paused,ended:el.ended,
        time:Number(el.currentTime.toFixed(1)),duration:Number(el.duration.toFixed(1))
      })),
      autoPlayOnLaunch:(()=>{try{return localStorage.getItem('folia_auto_play_on_launch')}catch{return null}})(),
      scope:root===document?'main':root.getAttribute('role')||root.getAttribute('data-bravais-account-login')||'menu',
      options:elements().length,commands,
      // Pixel coordinates are relative to Folia's offscreen 1280x720 browser viewport.
      // The ATV uses these only for a noninteractive native focus highlight.
      rect:rect?[Math.round(rect.left),Math.round(rect.top),
                 Math.round(rect.width),Math.round(rect.height)]:null,
      viewport:[innerWidth,innerHeight]};
  }
  // The ONLY visual behavior introduced is a standard keyboard focus outline,
  // not a UI layout, title, label or new control. This helps operate from TV.
  // Existing Folia page untouched. Only a single remote ring is visible.
  // Startup focus is visible before the first physical remote event.
  // Folia mounts its normal controls asynchronously, so wait for a real
  // original Bravais button, never create a synthetic TV-only control.
  let firstFocusDone=false;
  const startupStarted=Date.now();
  let startupObserver=null;
  let startupTimer=null;
  function tryStartupFocus(){
    if(firstFocusDone || commands>0){
      if(startupObserver){startupObserver.disconnect();startupObserver=null;}
      if(startupTimer){clearInterval(startupTimer);startupTimer=null;}
      return;
    }
    const match=preferred();
    // Wait for the middle category column to mount. Keep its active tab;
    // don't force the user to the radio category.
    const middle=centerActiveSeamTab();
    if(Date.now()-startupStarted<1200)return;
    if(!middle && Date.now()-startupStarted<3000)return;
    if(match){
      setFocus(middle||match);
      firstFocusDone=true;
      if(startupObserver){startupObserver.disconnect();startupObserver=null;}
      if(startupTimer){clearInterval(startupTimer);startupTimer=null;}
      console.log('[ATV3-REMOTE] initial white focus ready',title(active));
    }
  }
  function startWhiteFocus(){
    if(firstFocusDone || commands>0)return;
    tryStartupFocus();
    if(firstFocusDone)return;
    // Avoid observing every React style change. A low-frequency timer
    // is enough to detect initial mount, and ends after focus is set.
    startupTimer=setInterval(tryStartupFocus,160);
  }
  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',startWhiteFocus,{once:true});
  }else{
    startWhiteFocus();
  }
  window.__atv3TVStatus=status;
  window.__atv3TVNavigation=(command)=>{
    if(!['key-up','key-down','key-left','key-right','key-select','key-back','key-playback'].includes(command))
      return {ok:false,reason:'unsupported'};
    commands++;
    if(startupTimer){clearInterval(startupTimer);startupTimer=null;}
    if(command==='key-playback')return {ok:true,playback:true,...status()};
    if(command==='key-back'){
      if(active?.closest?.('.lattice-tools')){
        const button=rightBottomTool(),panel=toolPanel();
        if(panel && button){
          button.click();setFocus(button);
          return {ok:true,back:true,toolPanelClosed:true,...status()};
        }
        if(button && toolsReturnToBottom){
          const bottom=enterBottomBar();
          toolsReturnToBottom=false;
          return {ok:true,back:true,rightBottomToolExit:true,...status()};
        }
        const middle=currentMiddleStrip();
        if(middle)setFocus(middle);
        toolsReturnToBottom=false;
        return {ok:true,back:true,rightBottomToolExit:true,...status()};
      }
      if(currentScope()===document && active?.closest?.('[data-ponder="player-bar"]')){
        const target=bottomReturnFocus?.isConnected && stronglyVisible(bottomReturnFocus)
          ?bottomReturnFocus:currentMiddleStrip();
        releaseBottomBar();bottomReturnFocus=null;
        if(target)setFocus(target);
        return {ok:true,back:true,bottomBarExit:true,...status()};
      }
      // From the song wall, return focus to its CURRENT middle category tab,
      // without changing the selected category. Keep modal dialogs' native
      // one-step Escape behavior unchanged.
      const middle=currentScope()===document?currentMiddleStrip():null;
      const onSongWall=active?.closest?.('[data-bravais-slot]') ||
        document.activeElement?.matches?.('.bravais-field');
      if(middle && active!==middle && (onSongWall ||
         !active?.closest?.('[data-bravais-seam]'))){
        if(pendingNativeWallTimer){clearInterval(pendingNativeWallTimer);pendingNativeWallTimer=null;}
        if(deferredScopeTimer){clearInterval(deferredScopeTimer);deferredScopeTimer=null;}
        setFocus(middle);
        return {ok:true,back:true,centerColumn:true,...status()};
      }
      // Normal Escape hierarchy applies to dialogs and if already focused
      // on center rail.
      const target=document.activeElement instanceof HTMLElement
        ? document.activeElement : document.body;
      const keyEvent=new KeyboardEvent('keydown',{
        key:'Escape',code:'Escape',bubbles:true,cancelable:true,repeat:false
      });
      target.dispatchEvent(keyEvent);
      // React commits modal/back changes asynchronously: realign the
      // existing original-button focus rectangle after the layout settles.
      setTimeout(()=>{try{syncScope()}catch(e){}},100);
      return {ok:true,back:true,handled:keyEvent.defaultPrevented,...status()};
    }
    syncScope();
    const result=command==='key-select'?activate():chooseDirection(command.slice(4));
    return {...result,playback:false,...status()};
  };
  console.log('[ATV3-REMOTE] original Folia UI focus navigation initialized');
})();
