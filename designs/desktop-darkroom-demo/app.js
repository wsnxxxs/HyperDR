(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const defaults = {brightness:.6,strength:.4,headroom:2.5,threshold:25,coverage:100,recovery:'blend',mode:'manual'};
  let state={...defaults}, past=[], future=[], split=50, view='compare', histMode='rgb', clipMode=null;
  let versions=[{name:'自然光线',note:'示例参数 · V1',settings:{...defaults,brightness:.25,strength:.2}},{name:'柔和高光',note:'示例参数 · V2',settings:{...defaults,brightness:.5,strength:.32,headroom:2.2}}];
  let zoom=1, pan={x:0,y:0}, objectUrl=null, toastTimer, histogramTimer, exportTimer=null, exportSnapshot=null, renderedPixels=null;
  const photo=$('photo-original'), frame=$('image-frame'), ranges=['brightness','strength','headroom','threshold','coverage'];
  const sample=document.createElement('canvas'); sample.width=360; sample.height=240;
  const sampleCtx=sample.getContext('2d',{willReadFrequently:true});
  const formatNames={adaptive:'Apple Adaptive HDR',ultra:'Google Ultra HDR',pq:'PQ · HDR10',hlg:'HLG','avif-pq':'AVIF PQ','avif-hlg':'AVIF HLG'};
  const ceilings={adaptive:3,ultra:4,pq:4,hlg:2.3,'avif-pq':4,'avif-hlg':2.3};
  const outputValue = name => document.querySelector(`input[name="${name}"]:checked`).value;
  const clone = value => JSON.parse(JSON.stringify(value));
  function toast(message){$('toast').textContent=message;$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,3000);}
  function checkpoint(){past.push(clone(state));if(past.length>60)past.shift();future=[];}
  function changed(){ $('save-status').textContent='当前调整尚未导出'; $('status-text').textContent='就绪'; $('editing-note').textContent='所有调整仅在此演示中生效'; document.querySelector('.document-title .unsaved').hidden=false; render(); }
  function filter(s=state){const region=s.coverage/100*(1-s.threshold/180);const strength=s.strength*region;const recovery=s.recovery==='rebuild'?.94:s.recovery==='clip'?1.08:1;return `brightness(${(1+s.brightness*.27).toFixed(4)}) contrast(${((1+strength*.19+s.headroom*.012)*recovery).toFixed(4)}) saturate(${(1+strength*.15).toFixed(4)})`;}
  function syncPressed(selector,attribute,value){document.querySelectorAll(selector).forEach(b=>b.setAttribute('aria-pressed',String(b.dataset[attribute]===value)));}
  function render(){
    ranges.forEach(key=>{$(key).value=state[key];});
    $('brightness-value').innerHTML=`+${state.brightness.toFixed(2)} <small>EV</small>`;
    $('strength-value').textContent=state.strength.toFixed(2);
    $('headroom-value').innerHTML=`${state.headroom.toFixed(1)} <small>档</small>`;
    $('threshold-value').textContent=state.threshold+'%';$('coverage-value').textContent=state.coverage+'%';
    frame.style.setProperty('--preview-filter',filter());
    syncPressed('[data-mode]','mode',state.mode);syncPressed('[data-recovery]','recovery',state.recovery);
    $('mode-note').textContent=state.mode==='ai'?'已应用 AI 示例参数，可继续手动微调。':'从亮度开始，让光线自然呈现。';
    $('recovery-label').firstChild.textContent={blend:'混合',rebuild:'重建',clip:'裁切'}[state.recovery];
    $('undo').disabled=!past.length;$('redo').disabled=!future.length;
    clearTimeout(histogramTimer);histogramTimer=setTimeout(drawHistogram,60);
  }
  ranges.forEach(key=>{let start;$(key).addEventListener('pointerdown',()=>start=clone(state));$(key).addEventListener('input',()=>{if(!start)start=clone(state);state[key]=Number($(key).value);state.mode='manual';changed();});$(key).addEventListener('change',()=>{if(start){past.push(start);future=[];start=null;}render();});$(key).addEventListener('dblclick',()=>{checkpoint();state[key]=Math.min(defaults[key],Number($(key).max));changed();});});
  $('undo').onclick=()=>{if(!past.length)return;future.push(clone(state));state=past.pop();clampHeadroom();changed();};
  $('redo').onclick=()=>{if(!future.length)return;past.push(clone(state));state=future.pop();clampHeadroom();changed();};
  $('reset').onclick=()=>{checkpoint();state={...defaults};clampHeadroom();changed();toast('已重置画面调整，可撤销');};
  document.querySelectorAll('[data-mode]').forEach(b=>b.onclick=()=>{checkpoint();state.mode=b.dataset.mode;if(state.mode==='ai')Object.assign(state,{brightness:.45,strength:.58,headroom:Math.min(2.8,ceilings[outputValue('format')]),threshold:32,coverage:88});changed();if(state.mode==='ai')toast('已应用示例参数，未运行 AI 模型');});
  document.querySelectorAll('[data-recovery]').forEach(b=>b.onclick=()=>{checkpoint();state.recovery=b.dataset.recovery;changed();});

  function setView(next){view=next;frame.dataset.view=view;syncPressed('.view-segments [data-view]','view',view);document.querySelector('.toolbar-hint').textContent={compare:'拖动分界线，查看高光与暗部',original:'未应用调整的原始画面',hdr:'浏览器 SDR 观感示意'}[view];drawHistogram();}
  document.querySelectorAll('.view-segments [data-view]').forEach(b=>b.onclick=()=>setView(b.dataset.view));
  function setSplit(value){split=Math.max(0,Math.min(100,value));frame.style.setProperty('--split',split+'%');$('split-handle').setAttribute('aria-valuenow',String(Math.round(split)));}
  $('split-handle').onpointerdown=e=>{e.preventDefault();e.stopPropagation();e.currentTarget.setPointerCapture(e.pointerId);};
  $('split-handle').onpointermove=e=>{if(!e.currentTarget.hasPointerCapture(e.pointerId))return;const rect=frame.getBoundingClientRect();setSplit((e.clientX-rect.left)/rect.width*100);};
  $('split-handle').onkeydown=e=>{if(['ArrowLeft','ArrowRight','Home','End'].includes(e.key)){e.preventDefault();setSplit(e.key==='Home'?0:e.key==='End'?100:split+(e.key==='ArrowLeft'?-2:2));}};
  function applyZoom(){frame.style.transform=`translate(${pan.x}px,${pan.y}px) scale(${zoom})`;$('zoom').value=String(zoom);$('image-viewport').classList.toggle('panning',zoom>1);}
  $('zoom').onchange=()=>{zoom=Number($('zoom').value);pan={x:0,y:0};applyZoom();};
  function fitImage(){zoom=1;pan={x:0,y:0};applyZoom();}
  const zoomLevels=[1,1.5,2,3];
  $('zoom-in').onclick=()=>{zoom=zoomLevels[Math.min(3,zoomLevels.indexOf(zoom)+1)];applyZoom();};
  $('zoom-out').onclick=()=>{zoom=zoomLevels[Math.max(0,zoomLevels.indexOf(zoom)-1)];if(zoom===1)pan={x:0,y:0};applyZoom();};
  let dragStart;
  $('image-viewport').onpointerdown=e=>{if(zoom<=1||e.target.closest('#split-handle'))return;dragStart={x:e.clientX-pan.x,y:e.clientY-pan.y};e.currentTarget.setPointerCapture(e.pointerId);e.currentTarget.classList.add('dragging');};
  $('image-viewport').onpointermove=e=>{if(!dragStart||!e.currentTarget.hasPointerCapture(e.pointerId))return;const limitX=e.currentTarget.clientWidth*(zoom-1)/2,limitY=e.currentTarget.clientHeight*(zoom-1)/2;pan={x:Math.max(-limitX,Math.min(limitX,e.clientX-dragStart.x)),y:Math.max(-limitY,Math.min(limitY,e.clientY-dragStart.y))};applyZoom();};
  $('image-viewport').onpointerup=e=>{dragStart=null;e.currentTarget.classList.remove('dragging');};

  function drawHistogram(){
    if(!photo.complete||!photo.naturalWidth)return;
    sample.height=Math.max(1,Math.round(sample.width*photo.naturalHeight/photo.naturalWidth));
    sampleCtx.clearRect(0,0,sample.width,sample.height);sampleCtx.filter=view==='original'?'none':filter();sampleCtx.drawImage(photo,0,0,sample.width,sample.height);sampleCtx.filter='none';
    renderedPixels=sampleCtx.getImageData(0,0,sample.width,sample.height);
    const bins=Array.from({length:4},()=>new Float32Array(128));let low=0,high=0;
    const pixels=renderedPixels.data;
    for(let i=0;i<pixels.length;i+=4){const r=pixels[i],g=pixels[i+1],b=pixels[i+2],l=.2126*r+.7152*g+.0722*b;bins[0][r>>1]++;bins[1][g>>1]++;bins[2][b>>1]++;bins[3][Math.min(127,Math.floor(l/2))]++;if(l<5)low++;if(l>250)high++;}
    $('shadow-value').textContent=(low/(pixels.length/4)*100).toFixed(1)+'%';$('highlight-value').textContent=(high/(pixels.length/4)*100).toFixed(1)+'%';
    const canvas=$('histogram'),rect=canvas.getBoundingClientRect(),dpr=devicePixelRatio||1;canvas.width=Math.max(1,Math.round(rect.width*dpr));canvas.height=Math.max(1,Math.round(rect.height*dpr));const ctx=canvas.getContext('2d');ctx.scale(dpr,dpr);const w=rect.width,h=rect.height;ctx.strokeStyle='#ffffff09';ctx.lineWidth=1;for(let n=1;n<4;n++){ctx.beginPath();ctx.moveTo(w*n/4,0);ctx.lineTo(w*n/4,h);ctx.stroke();ctx.beginPath();ctx.moveTo(0,h*n/4);ctx.lineTo(w,h*n/4);ctx.stroke();}
    const channels=histMode==='rgb'?[0,1,2]:[3],colors=['#de9b87','#b9cf97','#90b7cd','#c9d6c3'];
    channels.forEach(c=>{const smooth=Array.from(bins[c],(v,i)=>(v+(bins[c][i-1]||v)+(bins[c][i+1]||v))/3);const max=Math.max(...smooth)*1.2;ctx.beginPath();ctx.moveTo(0,h);smooth.forEach((v,i)=>ctx.lineTo(i/127*w,h-((v/max)**.66)*(h-14)));ctx.lineTo(w,h);ctx.closePath();ctx.globalAlpha=histMode==='rgb'?.32:.55;ctx.fillStyle=colors[c];ctx.fill();ctx.globalAlpha=.85;ctx.strokeStyle=colors[c];ctx.lineWidth=.8;ctx.stroke();ctx.globalAlpha=1;});
    drawZebra();
  }
  document.querySelectorAll('[data-hist]').forEach(b=>b.onclick=()=>{histMode=b.dataset.hist;syncPressed('[data-hist]','hist',histMode);drawHistogram();});
  function setClip(mode){clipMode=clipMode===mode?null:mode;$('highlight-clip').setAttribute('aria-pressed',String(clipMode==='high'));$('shadow-clip').setAttribute('aria-pressed',String(clipMode==='low'));drawZebra();if(clipMode)toast(clipMode==='high'?'标记高亮区域（SDR 示意阈值）':'标记暗部裁切区域');}
  $('highlight-clip').onclick=()=>setClip('high');$('shadow-clip').onclick=()=>setClip('low');
  function drawZebra(){const c=$('zebra-canvas');c.hidden=!clipMode;if(!clipMode||!renderedPixels)return;c.width=sample.width;c.height=sample.height;const ctx=c.getContext('2d'),out=ctx.createImageData(c.width,c.height),p=renderedPixels.data;for(let i=0;i<p.length;i+=4){const l=.2126*p[i]+.7152*p[i+1]+.0722*p[i+2],x=i/4%c.width,y=Math.floor(i/4/c.width);if((clipMode==='high'?l>230:l<12)&&(x+y)%10<5){out.data[i]=clipMode==='high'?244:101;out.data[i+1]=clipMode==='high'?197:181;out.data[i+2]=clipMode==='high'?113:240;out.data[i+3]=190;}}ctx.putImageData(out,0,0);}

  function showVersions(){renderVersions();$('version-drawer').hidden=!$('version-drawer').hidden;$('versions-button').setAttribute('aria-expanded',String(!$('version-drawer').hidden));}
  $('versions-button').onclick=showVersions;$('versions-close').onclick=()=>{$('version-drawer').hidden=true;$('versions-button').setAttribute('aria-expanded','false');};
  function renderVersions(){const grid=$('version-grid');grid.replaceChildren();versions.forEach((version,index)=>{const card=document.createElement('article');card.className='version-item';const img=document.createElement('img');img.src=photo.src;img.alt=version.name;img.style.filter=filter(version.settings);const info=document.createElement('div'),title=document.createElement('strong'),note=document.createElement('p'),button=document.createElement('button');title.textContent=version.name;note.textContent=version.note;button.textContent='使用这版参数';button.onclick=()=>{checkpoint();state=clone(version.settings);clampHeadroom();changed();grid.querySelectorAll('.version-item').forEach(e=>e.classList.remove('active'));card.classList.add('active');toast(`已恢复「${version.name}」参数`);};info.append(title,note,button);card.append(img,info);grid.append(card);});$('version-count').textContent=String(versions.length);}

  function clampHeadroom(){state.headroom=Math.min(state.headroom,ceilings[outputValue('format')]);}
  function outputChanged(){const type=outputValue('format'),max=ceilings[type];$('headroom').max=String(max);$('headroom-max').textContent=max+' 档';if(state.headroom>max){checkpoint();clampHeadroom();changed();toast(`此格式的扩展范围已调整为 ${max} 档`);}$('quality-value').textContent=$('quality').value;$('format-note').textContent={adaptive:'适用于支持 Adaptive HDR 的 Apple 相册工作流。',ultra:'带增益图的 JPEG，供支持 Ultra HDR 的应用使用。',pq:'PQ 编码，面向兼容 HDR10 的显示工作流。',hlg:'HLG 编码，面向兼容 HLG 的显示工作流。','avif-pq':'使用 AVIF 容器保存 PQ 编码图像。','avif-hlg':'使用 AVIF 容器保存 HLG 编码图像。'}[type];}
  document.querySelectorAll('input[name="format"], input[name="gamut"], #quality').forEach(input=>input.addEventListener('input',outputChanged));
  function openExport(){if(exportTimer)return;$('export-thumbnail').src=photo.src;$('export-thumbnail').style.filter=filter();$('export-success').hidden=true;$('export-progress').hidden=true;$('download-preview').hidden=true;$('export-start').hidden=false;$('export-start').disabled=false;$('export-start').textContent='开始演示导出';$('export-dialog').showModal();}
  $('export-open').onclick=openExport;
  $('export-start').onclick=()=>{if(exportTimer)return;exportSnapshot={...clone(state),format:outputValue('format'),gamut:outputValue('gamut'),quality:Number($('quality').value)};$('export-start').disabled=true;$('export-progress').hidden=false;$('export-success').hidden=true;let value=0;$('progress').value=0;$('status-text').textContent='正在演示导出';exportTimer=setInterval(()=>{value+=20;$('progress').value=value;$('progress-label').textContent=value<60?'正在生成演示预览…':'正在保存演示版本…';if(value>=100){clearInterval(exportTimer);exportTimer=null;$('export-progress').hidden=true;$('export-success').hidden=false;$('export-start').hidden=true;$('download-preview').hidden=false;versions.push({name:`导出版本 ${versions.length+1}`,note:`演示导出 · ${formatNames[exportSnapshot.format]}`,settings:clone(exportSnapshot)});renderVersions();$('save-status').textContent='当前调整已保存为演示版本';$('status-text').textContent='演示导出完成';document.querySelector('.document-title .unsaved').hidden=true;}},260);};
  $('export-dialog').addEventListener('close',()=>{if(exportTimer){clearInterval(exportTimer);exportTimer=null;$('status-text').textContent='演示导出已取消';}});
  function download(blob,name){const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),10000);}
  $('save-settings').onclick=()=>download(new Blob([JSON.stringify({demo:true,note:'Design demo settings; not a HyperDR CLI configuration.',...state,format:outputValue('format'),gamut:outputValue('gamut'),quality:Number($('quality').value)},null,2)],{type:'application/json'}),'hyperdr-demo-settings.json');
  $('download-preview').onclick=()=>{const c=document.createElement('canvas'),ratio=Math.min(1,2048/photo.naturalWidth);c.width=Math.round(photo.naturalWidth*ratio);c.height=Math.round(photo.naturalHeight*ratio);const ctx=c.getContext('2d');ctx.filter=filter(exportSnapshot||state);ctx.drawImage(photo,0,0,c.width,c.height);c.toBlob(blob=>{if(blob){download(blob,'HyperDR-demo-SDR.png');toast('已保存 SDR PNG 演示图');}},'image/png');};
  ['about-open','preview-info','shortcuts-open'].forEach(id=>$(id).onclick=()=>$('about-dialog').showModal());
  for(const dialog of document.querySelectorAll('dialog'))dialog.addEventListener('click',e=>{if(e.target===dialog){const r=dialog.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)dialog.close();}});

  $('open-photo').onclick=()=>$('file-input').click();
  async function loadFile(file){if(!file)return;const url=URL.createObjectURL(file),probe=new Image();probe.src=url;try{await probe.decode();}catch{URL.revokeObjectURL(url);toast('无法解码此图片，请选择 JPG、PNG 或 WebP');return;}if(objectUrl)URL.revokeObjectURL(objectUrl);objectUrl=url;past=[];future=[];state={...defaults};clampHeadroom();versions=[];renderVersions();photo.src=url;$('photo-effect').src=url;$('export-thumbnail').src=url;$('filename').textContent=file.name;$('export-filename').textContent=file.name;$('photo-title').textContent=file.name.replace(/\.[^.]+$/,'');fitImage();setSplit(50);changed();toast('照片已在本机打开');}
  $('file-input').onchange=()=>{loadFile($('file-input').files[0]);$('file-input').value='';};
  const drop=$('image-viewport');drop.addEventListener('dragover',e=>{e.preventDefault();$('drop-message').hidden=false;});drop.addEventListener('dragleave',e=>{if(!drop.contains(e.relatedTarget))$('drop-message').hidden=true;});drop.addEventListener('drop',e=>{e.preventDefault();$('drop-message').hidden=true;loadFile(e.dataTransfer.files[0]);});
  photo.onload=()=>{$('dimensions').textContent=`${photo.naturalWidth} × ${photo.naturalHeight}`;drawHistogram();};
  photo.onerror=()=>{$('dimensions').textContent='示例照片未载入';toast('示例照片未载入，可以打开自己的 JPG 或 PNG');};
  document.addEventListener('keydown',e=>{if(document.querySelector('dialog[open]'))return;const input=/INPUT|SELECT|TEXTAREA/.test(e.target.tagName);if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='o'){e.preventDefault();$('open-photo').click();}else if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='e'){e.preventDefault();openExport();}else if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='z'&&!input){e.preventDefault();$(e.shiftKey?'redo':'undo').click();}else if(!input&&!e.ctrlKey&&!e.metaKey&&!e.altKey){if(e.key.toLowerCase()==='c')setView(view==='compare'?'hdr':'compare');if(e.key.toLowerCase()==='f')fitImage();if(e.key.toLowerCase()==='z')setClip('high');if(e.key==='Escape')$('versions-close').click();}});
  new ResizeObserver(()=>{clearTimeout(histogramTimer);histogramTimer=setTimeout(drawHistogram,80);}).observe($('histogram'));
  document.querySelectorAll('i.ph').forEach(icon=>icon.setAttribute('aria-hidden','true'));
  render();renderVersions();outputChanged();if(photo.complete&&photo.naturalWidth)photo.onload();
})();
