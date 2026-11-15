'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),{EventEmitter}=require('node:events'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {DropShelfWindow}=require('../lib/drop-shelf-window.cjs');
function fixture(t){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'drop-shelf-window-')),file=path.join(root,'synthetic.txt');fs.writeFileSync(file,'original');
 const handlers=new Map(),ipcMain=new EventEmitter();ipcMain.handle=(name,fn)=>handlers.set(name,fn);ipcMain.removeHandler=name=>handlers.delete(name);
 class Window extends EventEmitter{
  constructor(options){super();this.options=options;this.visible=false;this.moves=0;this.webContents=new EventEmitter();this.webContents.mainFrame={};this.webContents.setWindowOpenHandler=fn=>this.open=fn;this.webContents.send=(_name,value)=>this.last=value;this.webContents.startDrag=value=>this.drag=value;}
  async loadURL(url){this.webContents.mainFrame.url=url;}
  isDestroyed(){return !!this.destroyed;}isVisible(){return this.visible;}showInactive(){this.visible=true;}hide(){this.visible=false;}setBounds(value){this.bounds=value;this.moves++;}destroy(){this.destroyed=true;}
 }
 const image={toDataURL:()=> 'data:image/png;base64,c3ludGhldGlj'};
 const electron={BrowserWindow:Window,ipcMain,app:{getLocale:()=> 'tr-TR',getFileIcon:async()=>image},nativeImage:{createFromPath:()=>image},screen:{getCursorScreenPoint:()=>({x:800,y:400}),getDisplayNearestPoint:()=>({workArea:{x:0,y:0,width:1200,height:800}})}};
 const controller=new DropShelfWindow({electron,language:()=> 'system'});t.after(()=>{controller.dispose();fs.rmSync(root,{recursive:true,force:true});});
 return {controller,file,handlers,electron,event:()=>({sender:controller.window.webContents,senderFrame:controller.window.webContents.mainFrame})};
}
test('trusted native IPC accepts real files and drag exports the same references without touching originals',async t=>{
 const f=fixture(t),c=f.controller;await c.prepare();c.reveal();assert.equal(c.window.visible,true);assert.equal(c.state().language,'tr');
 await f.handlers.get('dropshelf:add')(f.event(),[f.file]);assert.equal(c.state().files.length,1);
 f.electron.ipcMain.emit('dropshelf:drag',f.event());assert.deepEqual(c.window.drag.files,[f.file]);
 c.reveal();assert.equal(c.window.moves,1,'An occupied shelf stays put when a second drag begins');
 f.electron.ipcMain.emit('dropshelf:close',f.event());assert.equal(c.window.visible,false);assert.equal(c.model.files.length,0);assert.equal(fs.readFileSync(f.file,'utf8'),'original');
 c.reveal();assert.equal(c.window.visible,true,'Closing outside a gesture does not suppress the next gesture');
});
test('untrusted frames cannot add files, export references, or close the shelf',async t=>{
 const f=fixture(t);await f.controller.prepare();
 for(const event of [{sender:{}},{...f.event(),senderFrame:{url:f.controller.entry}}]){
  await assert.rejects(f.handlers.get('dropshelf:add')(event,[f.file]),/Untrusted/);
  assert.throws(()=>f.electron.ipcMain.emit('dropshelf:drag',event),/Untrusted/);
 }
 assert.equal(f.controller.model.files.length,0);assert.deepEqual(f.controller.window.open(),{action:'deny'});
});
test('cancelled drag hides an empty shelf; a completed drop keeps an occupied shelf visible',async t=>{
 const f=fixture(t),c=f.controller;await c.prepare();c.reveal();c.end();await new Promise(resolve=>setTimeout(resolve,550));assert.equal(c.window.visible,false);
 c.reveal();c.end();await c.add([f.file]);await new Promise(resolve=>setTimeout(resolve,550));assert.equal(c.window.visible,true);
});
test('an icon completion after close cannot restore discarded file metadata',async t=>{
 const f=fixture(t),c=f.controller;await c.prepare();let finish;f.electron.app.getFileIcon=()=>new Promise(resolve=>finish=resolve);
 const pending=c.add([f.file]);c.dismiss();finish({toDataURL:()=> 'old'});await pending;assert.equal(c.icon,null);assert.deepEqual(c.state().files,[]);
});
