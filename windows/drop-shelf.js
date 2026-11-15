'use strict';
const api=window.dropShelf,target=document.getElementById('target'),error=document.getElementById('error');
let current;
function render(state){
 current=state;document.documentElement.lang=state.language||'en';
 const files=state.files,t=state.labels;document.getElementById('close').ariaLabel=t.close;
 document.getElementById('shelf').ariaLabel=t.title;
 document.getElementById('count').textContent=files.length||'';
 document.getElementById('title').textContent=files.length===1?files[0].name:t.title;
 document.getElementById('hint').textContent=files.length?t.drag:t.drop;
 const art=document.getElementById('art');art.replaceChildren();
 if(state.icon){const image=document.createElement('img');image.src=state.icon;art.append(image);}else art.textContent=files.length?'▱':'↓';
 document.getElementById('files').replaceChildren(...(files.length>1?files.map(file=>{const row=document.createElement('div');row.textContent=file.name;return row;}):[]));
 document.body.classList.toggle('filled',files.length>0);target.draggable=files.length>0;error.textContent=state.error||'';
}
function isFiles(event){return Array.from(event.dataTransfer?.types||[]).includes('Files');}
let depth=0;
document.addEventListener('dragenter',event=>{event.preventDefault();if(isFiles(event)){depth++;document.body.classList.add('hover');}});
document.addEventListener('dragover',event=>{event.preventDefault();if(event.dataTransfer)event.dataTransfer.dropEffect=isFiles(event)?'copy':'none';});
document.addEventListener('dragleave',()=>{if(--depth<=0){depth=0;document.body.classList.remove('hover');}});
document.addEventListener('drop',async event=>{event.preventDefault();depth=0;document.body.classList.remove('hover');if(!isFiles(event))return;try{render(await api.add(Array.from(event.dataTransfer.files)));}catch{error.textContent=current.labels.unavailable;}});
target.addEventListener('dragstart',event=>{event.preventDefault();api.drag();});
document.getElementById('close').addEventListener('click',()=>api.close());
document.addEventListener('keydown',event=>{if(event.key==='Escape')api.close();});
api.subscribe(render);api.state().then(render);
