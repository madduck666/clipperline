'use strict';
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');

// A transient collection of references. Never move, delete or persist originals.
class DropShelf {
 constructor(){this.files=[];}
 add(paths){
  if(!Array.isArray(paths)||!paths.length||paths.length>100)throw new Error('Drop up to 100 files or folders.');
  const files=paths.map(file=>{
   if(typeof file!=='string'||!path.isAbsolute(file)||file.includes('\0')||/^[\\/]{2}/.test(file))throw new Error('Drop local files or folders.');
   const stat=fs.statSync(file);if(!stat.isFile()&&!stat.isDirectory())throw new Error('Drop local files or folders.');
   return {path:path.resolve(file),name:path.basename(file),directory:stat.isDirectory()};
  });
  const fresh=files.filter((file,index)=>!this.files.some(old=>old.path===file.path)&&files.findIndex(other=>other.path===file.path)===index);
  if(this.files.length+fresh.length>100)throw new Error('Drop up to 100 files or folders.');
  this.files.push(...fresh.map(file=>({...file,id:crypto.randomUUID()})));return this.snapshot();
 }
 snapshot(){return this.files.map(({id,name,directory})=>({id,name,directory}));}
 dragPaths(){
  if(!this.files.length)throw new Error('Drop files here');
  for(const file of this.files){const stat=fs.statSync(file.path);if(!stat.isFile()&&!stat.isDirectory())throw new Error('A dropped file is no longer available.');}
  return this.files.map(file=>file.path);
 }
 clear(){this.files=[];}
}

// Try corners and edges around visible windows. The cursor remains unobstructed.
function placement(area,pointer,obstacles=[],size={width:216,height:228}){
 const margin=16,width=Math.min(size.width,area.width),height=Math.min(size.height,area.height);
 const clampX=x=>Math.max(area.x,Math.min(area.x+area.width-width,x));
 const clampY=y=>Math.max(area.y,Math.min(area.y+area.height-height,y));
 const xs=[area.x+margin,area.x+area.width-width-margin],ys=[area.y+margin,area.y+area.height-height-margin];
 for(const r of obstacles){xs.push(r.x-width-margin,r.x+r.width+margin);ys.push(r.y-height-margin,r.y+r.height+margin);}
 const overlap=(a,b)=>Math.max(0,Math.min(a.x+a.width,b.x+b.width)-Math.max(a.x,b.x))*Math.max(0,Math.min(a.y+a.height,b.y+b.height)-Math.max(a.y,b.y));
 let best,score=Infinity;
 for(const x of xs)for(const y of ys){const r={x:Math.round(clampX(x)),y:Math.round(clampY(y)),width,height};
  const cursor={x:pointer.x-48,y:pointer.y-48,width:96,height:96};
  const next=obstacles.reduce((sum,o)=>sum+overlap(r,o),0)+overlap(r,cursor)*1000+Math.hypot(r.x+width/2-pointer.x,r.y+height/2-pointer.y)*0.001;
  if(next<score){best=r;score=next;}
 }
 return best;
}
module.exports={DropShelf,placement};
