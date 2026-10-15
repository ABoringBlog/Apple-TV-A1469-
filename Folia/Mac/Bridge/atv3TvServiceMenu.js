// ATV3 dedicated full-screen music service chooser, rendered on the Mac only.
// Account selection and QR login call Folia's existing library controller.
(() => {
  if(window.__atv3TVServiceMenu)return;
  let open=true;
  let choice=0;
  let methodChoice=0;
  let lastProvider='';
  let noticed='';
  let root=null;
  let lastPaintSignature='';
  let success=false;
  const names={netease:'网易云音乐',qq:'QQ 音乐',kugou:'酷狗音乐',bodian:'波点音乐'};
  function state(){
    const controller=window.__atv3TVAccount;
    const providers=controller?controller.list():[];
    const login=window.__atv3TVLogin?.state?.()||null;
    if(lastProvider && !login){
      const row=providers.find(p=>p.id===lastProvider);
      if(row&&row.direct)success=true;
    }
    return {providers,login,success,open};
  }
  function make(tag,cls,text){
    const el=document.createElement(tag);if(cls)el.className=cls;
    if(text!=null)el.textContent=String(text);
    return el;
  }
  function init(){
    if(root)return;
    const style=make('style');
    style.textContent='#atv3-account-screen{position:fixed;inset:0;z-index:2147483100;background:radial-gradient(circle at 68% 14%,#20324e,#0d121b 55%,#080c12);color:#f4f6fa;box-sizing:border-box;padding:45px 74px;font-family:-apple-system,BlinkMacSystemFont,Arial,sans-serif;display:flex;flex-direction:column}#atv3-account-screen *{box-sizing:border-box}#atv3-account-screen h1{font-size:38px;line-height:1.18;margin:0 0 14px;font-weight:700}#atv3-account-screen .sub{font-size:21px;color:#adbcd0;line-height:1.5;margin-bottom:30px}#atv3-account-screen .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:18px;max-width:1050px}#atv3-account-screen .card{min-height:135px;border:2px solid #354256;border-radius:18px;background:#172232;padding:22px;display:flex;flex-direction:column;gap:13px}#atv3-account-screen .card.selected{border:4px solid #ffcd55;box-shadow:0 0 24px #b77e2499;padding:20px}#atv3-account-screen .card.off{opacity:.48}#atv3-account-screen .card strong{font-size:25px}#atv3-account-screen .card span{font-size:17px;color:#b0c0d4}#atv3-account-screen .foot{margin-top:auto;font-size:20px;color:#c9d4e3}#atv3-account-screen .qrrow{display:flex;align-items:center;gap:52px;max-width:1040px;min-height:310px}#atv3-account-screen .qrbox{width:300px;height:300px;background:white;border-radius:20px;padding:18px;display:flex;align-items:center;justify-content:center}#atv3-account-screen .qrbox img{width:264px;height:264px;object-fit:contain}#atv3-account-screen .qrcopy{font-size:22px;line-height:1.6;max-width:580px}';
    document.head.appendChild(style);
    root=make('div');root.id='atv3-account-screen';document.body.appendChild(root);
  }
  function optionCard(title,desc,i,disabled){
    const card=make('div','card'+(choice===i?' selected':'')+(disabled?' off':''));card.append(make('strong',null,title),make('span',null,desc));return card;
  }
  function draw(){
    const data=state();
    if(!open){lastPaintSignature='';if(root)root.style.display='none';return;}
    const sig=JSON.stringify({choice,methodChoice,noticed,login:data.login,
      providers:data.providers,success:data.success});
    if(sig===lastPaintSignature)return;
    lastPaintSignature=sig;
    init();root.style.display='flex';root.replaceChildren();
    if(data.login && data.login.kind==='login'){
      const f=data.login;
      root.append(make('h1',null,f.title||'连接音乐平台'),make('div','sub','请用手机对应的音乐 App 扫描二维码，完成账户授权。'));
      const row=make('div','qrrow');
      const square=make('div','qrbox');
      if(f.qr?.kind==='image'&&f.qr.url){
        const img=make('img');
        if(/^(data:image\/|https?:\/\/|blob:)/.test(f.qr.url))img.src=f.qr.url;
        img.alt='登录二维码';square.append(img);
      }else square.append(make('div',null,f.qr?.kind==='backend-failure'?'服务连接失败':'正在生成二维码…'));
      const copy=make('div','qrcopy');
      copy.append(make('div',null,f.status||f.qr?.text||f.note||''));
      if(f.methods&&f.methods.options?.length){
        const opts=f.methods.options;
        methodChoice=Math.min(methodChoice,opts.length-1);
        for(let i=0;i<opts.length;i++){
          copy.append(make('div',null,(i===methodChoice?'▶ ':'   ')+opts[i].label));
        }
      }
      if(noticed)copy.append(make('div',null,noticed));
      row.append(square,copy);root.append(row);
      root.append(make('div','foot',f.methods?.options?.length?'左右：选择登录方式 · 确定：确认 · Menu：退出':'手机扫码授权 · 下：重新获取二维码 · Menu：退出'));
      return;
    }
    if(data.login && data.login.kind==='confirm'){
      root.append(make('h1',null,data.login.title||'切换音乐平台'),make('div','sub',data.login.description||'是否切换？'));
      const cards=make('div','cards');
      cards.append(optionCard('确认切换','继续',0,false),optionCard('取消','返回',1,false));root.append(cards);
      root.append(make('div','foot','左右：选择 · 确定：确认 · Menu：退出'));return;
    }
    if(success){
      root.append(make('h1',null,'音乐账户已连接'),make('div','sub','连接成功。按确定进入 Folia 音乐库，或选择其他音乐平台。'));
      root.append(make('div','foot','确定：进入音乐库 · 方向键：切换平台 · Menu：退出'));return;
    }
    root.append(make('h1',null,'Folia · 连接音乐服务'),make('div','sub','ATV3 专用版尚未登录音乐账户。请选择平台，使用手机扫码登录。'));
    const cards=make('div','cards');
    for(let i=0;i<data.providers.length;i++){
      const p=data.providers[i];
      const title=names[p.id]||p.label;
      cards.append(optionCard(title,p.configured?(p.direct?'已连接 · 可以使用':'按确定进入扫码登录'):'服务暂不可用',i,!p.configured));
    }
    choice=Math.min(choice,data.providers.length);
    cards.append(optionCard('进入 Folia 音乐库','暂不连接，继续浏览',data.providers.length,false));
    root.append(cards);
    if(noticed)root.append(make('div','sub',noticed));
    root.append(make('div','foot','方向键：移动 · 确定：选择 · Menu：返回 ATV3 主界面'));
  }
  function key(command){
    const data=state();
    if(!open){if(command==='key-up'&&!window.__atv3HasTrack){open=true;draw();return {ok:true,serviceMenu:true};}return null;}
    if(data.login?.kind==='login'){
      if((command==='key-left'||command==='key-right')&&data.login.methods?.options?.length){
        const count=data.login.methods.options.length;
        methodChoice=(methodChoice+(command==='key-right'?1:-1)+count)%count;
      }else if(command==='key-select'&&data.login.methods?.options?.length){
        window.__atv3TVLogin.selectMethod(data.login.methods.options[methodChoice].id);
      }else if(command==='key-down'&&data.login.retry&&!data.login.retry.disabled){
        window.__atv3TVLogin.retry();
      }
      draw();return {ok:true,serviceMenu:true,view:'login',provider:data.login.providerId,qr:data.login.qr?.kind};
    }
    if(data.login?.kind==='confirm'){
      if(command==='key-left'||command==='key-right')choice=choice?0:1;
      if(command==='key-select'){
        if(choice===0)window.__atv3TVLogin.confirm(data.login.requestId);
        else window.__atv3TVLogin.close();
      }
      draw();return {ok:true,serviceMenu:true,view:'confirm'};
    }
    if(success && command==='key-select'){open=false;draw();return {ok:true,serviceMenu:false,view:'library'};}
    const count=data.providers.length+1;
    if(command==='key-left'||command==='key-right')choice=(choice+(command==='key-right'?1:-1)+count)%count;
    if(command==='key-up'||command==='key-down')choice=(choice+(command==='key-down'?3:-3)+count*3)%count;
    if(command==='key-select'){
      if(choice===data.providers.length){open=false;draw();return {ok:true,serviceMenu:false,view:'library'};}
      const provider=data.providers[choice];
      if(provider){
        if(!provider.configured)noticed='当前平台服务尚不可用，请选择其他音乐来源。';
        else {
          noticed='';lastProvider=provider.id;
          window.__atv3TVAccount?.select(provider.id);
        }
      }
    }
    draw();return {ok:true,serviceMenu:true,view:'providers',selected:data.providers[choice]?.id||'library',providers:data.providers.length};
  }
  window.__atv3TVServiceMenu={key,status:()=>({open,...state(),choice}),show:()=>{open=true;draw();}};
  const original=window.__atv3TVNavigation;
  window.__atv3TVNavigation=(command)=>{
    const result=key(command);
    return result||original?.(command)||{ok:false};
  };
  setInterval(()=>{if(open)draw();},700);
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',draw,{once:true});
  else draw();
  console.log('[ATV3-TV] service menu installed');
})();