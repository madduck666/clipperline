'use strict';
const path=require('node:path');
const {pathToFileURL}=require('node:url');
const {spawn}=require('node:child_process');
const {windowsEnvironment}=require('./windows-environment.cjs');
const {DropShelf,placement}=require('./drop-shelf.cjs');
const {translated,languageCode}=require('./status-summary.cjs');

class DropShelfWindow {
 constructor({electron,language=()=> 'en'}){
  this.electron=electron;this.language=()=>languageCode(language(),electron.app.getLocale());this.model=new DropShelf();this.window=null;this.timer=null;this.monitor=null;this.icon=null;this.generation=0;this.error='';this.suppressed=false;this.active=false;
  this.entry=pathToFileURL(path.join(__dirname,'../drop-shelf.html')).href;
  const {ipcMain}=electron;
  this.handlers={
   'dropshelf:state':event=>{this.trusted(event);return this.state();},
   'dropshelf:add':async(event,paths)=>{this.trusted(event);try{await this.add(paths);}catch{this.error=this.t('A dropped file is no longer available.');}return this.state();}
  };
  for(const [name,handler]of Object.entries(this.handlers))ipcMain.handle(name,handler);
  this.closeListener=event=>{this.trusted(event);this.dismiss();};
  this.dragListener=event=>{this.trusted(event);try{const files=this.model.dragPaths();event.sender.startDrag({files,icon:this.icon||this.electron.nativeImage.createFromPath(path.join(__dirname,'../assets/clipboardline.png'))});}catch{this.error=this.t('A dropped file is no longer available.');this.broadcast();}};
  ipcMain.on('dropshelf:close',this.closeListener);ipcMain.on('dropshelf:drag',this.dragListener);
 }
 t(key){return translated(this.language(),key);}
 state(){return {files:this.model.snapshot(),icon:this.icon?.toDataURL(),language:this.language(),error:this.error,labels:{title:this.t('Drop shelf'),drop:this.t('Drop files here'),drag:this.t('Drag to another window'),close:this.t('Close'),unavailable:this.t('A dropped file is no longer available.')}};}
 trusted(event){if(!this.window||event.sender!==this.window.webContents||!event.senderFrame||event.senderFrame!==this.window.webContents.mainFrame||event.senderFrame.url!==this.entry)throw new Error('Untrusted drop shelf frame');}
 broadcast(){if(this.window&&!this.window.isDestroyed())this.window.webContents.send('dropshelf:changed',this.state());}
 async prepare(){
  if(this.window)return;
  const {BrowserWindow}=this.electron;
  const window=this.window=new BrowserWindow({width:216,height:228,show:false,frame:false,transparent:true,resizable:false,minimizable:false,maximizable:false,skipTaskbar:true,alwaysOnTop:true,hasShadow:false,webPreferences:{preload:path.join(__dirname,'../drop-shelf-preload.cjs'),nodeIntegration:false,contextIsolation:true,sandbox:true,webSecurity:true}});
  window.webContents.setWindowOpenHandler(()=>({action:'deny'}));
  window.webContents.on('will-navigate',(event,url)=>{if(url!==this.entry)event.preventDefault();});
  window.webContents.on('will-frame-navigate',event=>{if(!event.isMainFrame||event.url!==this.entry)event.preventDefault();});
  window.webContents.on('will-attach-webview',event=>event.preventDefault());
  window.on('close',event=>{event.preventDefault();this.dismiss();});
  await window.loadURL(this.entry);
 }
 reveal(obstacles=[]){
  if(!this.window||this.suppressed)return;
  clearTimeout(this.timer);this.error='';
  if(!this.window.isVisible()){
   const {screen}=this.electron,pointer=screen.getCursorScreenPoint(),area=screen.getDisplayNearestPoint(pointer).workArea;
   this.window.setBounds(placement(area,pointer,obstacles));this.window.showInactive();
  }
  this.broadcast();
 }
 end(){this.active=false;this.suppressed=false;clearTimeout(this.timer);this.timer=setTimeout(()=>{if(!this.model.files.length)this.window?.hide();},500);}
 async add(paths){
  this.model.add(paths);const generation=++this.generation;clearTimeout(this.timer);this.error='';
  this.broadcast();
  const icon=await this.electron.app.getFileIcon(this.model.files[0].path,{size:'large'}).catch(()=>null);
  if(generation===this.generation){this.icon=icon;this.broadcast();}
 }
 dismiss(){this.suppressed=this.active;this.generation++;clearTimeout(this.timer);this.model.clear();this.icon=null;this.error='';this.window?.hide();this.broadcast();}
 start(){
  if(process.platform!=='win32'||this.monitor)return;
  const script=__dirname.includes('app.asar')?path.join(process.resourcesPath,'native','windows-drop-monitor.ps1'):path.join(__dirname,'../native/windows-drop-monitor.ps1');
  const executable=path.win32.join(process.env.SystemRoot||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');
  const child=this.monitor=spawn(executable,['-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',script],{windowsHide:true,stdio:['ignore','pipe','pipe'],env:windowsEnvironment()});
  let buffer='';child.stdout.on('data',chunk=>{buffer+=chunk;if(buffer.length>65536){child.kill();return;}let i;while((i=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,i);buffer=buffer.slice(i+1);try{const value=JSON.parse(line);if(value.drag===true){this.active=true;const rects=(value.windows||[]).filter(r=>['x','y','width','height'].every(k=>Number.isFinite(r[k])));this.reveal(rects.slice(0,64).map(r=>this.electron.screen.screenToDipRect(null,r)));}else if(value.drag===false)this.end();}catch{}}});
  child.on('error',()=>{this.monitor=null;});child.on('exit',()=>{this.monitor=null;this.end();});
 }
 dispose(){clearTimeout(this.timer);this.generation++;this.monitor?.kill();this.monitor=null;this.window?.destroy();this.window=null;for(const name of Object.keys(this.handlers))this.electron.ipcMain.removeHandler(name);this.electron.ipcMain.removeListener('dropshelf:close',this.closeListener);this.electron.ipcMain.removeListener('dropshelf:drag',this.dragListener);}
}
module.exports={DropShelfWindow};
