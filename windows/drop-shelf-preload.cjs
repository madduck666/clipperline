'use strict';
const {contextBridge,ipcRenderer,webUtils}=require('electron');
contextBridge.exposeInMainWorld('dropShelf',Object.freeze({
 state:()=>ipcRenderer.invoke('dropshelf:state'),
 add:files=>ipcRenderer.invoke('dropshelf:add',Array.from(files,file=>webUtils.getPathForFile(file))),
 close:()=>ipcRenderer.send('dropshelf:close'),
 drag:()=>ipcRenderer.send('dropshelf:drag'),
 subscribe:listener=>{const receive=(_event,value)=>listener(value);ipcRenderer.on('dropshelf:changed',receive);return()=>ipcRenderer.removeListener('dropshelf:changed',receive);}
}));
