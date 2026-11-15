'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {DropShelf,placement}=require('../lib/drop-shelf.cjs');
const contract=require('../../contracts/shelf-behavior.json');
function fixture(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'drop-shelf-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));for(const name of ['document.txt','picture.png'])fs.writeFileSync(path.join(root,name),'synthetic');for(const name of ['Folder','Sample.app'])fs.mkdirSync(path.join(root,name));return root;}
test('shared drop shelf contract runs against real files, including folders and application bundles',t=>{
 const root=fixture(t),shelf=new DropShelf();
 for(const step of contract.dropShelfCases){if(step.action==='clear')shelf.clear();else shelf.add(step.files.map(name=>path.join(root,name)));assert.deepEqual(shelf.snapshot().map(file=>file.name),step.expected);}
 assert.deepEqual(shelf.dragPaths(),[path.join(root,'Folder')]);shelf.clear();assert.equal(fs.readFileSync(path.join(root,'document.txt'),'utf8'),'synthetic');assert.ok(fs.statSync(path.join(root,'Folder')).isDirectory());
});
test('failed batches are atomic, missing originals prevent drag, close never deletes sources',t=>{
 const root=fixture(t),shelf=new DropShelf(),file=path.join(root,'document.txt');shelf.add([file]);const before=shelf.snapshot();
 assert.throws(()=>shelf.add([path.join(root,'picture.png'),path.join(root,'missing')]));assert.deepEqual(shelf.snapshot(),before);
 assert.throws(()=>shelf.add(['https://example.com/file']));assert.throws(()=>shelf.add(['\\\\server\\share\\file']));
 fs.unlinkSync(file);assert.throws(()=>shelf.dragPaths());shelf.clear();assert.ok(fs.existsSync(path.join(root,'picture.png')));
});
test('batches are bounded, deduplicated, and display names do not expose paths',t=>{
 const root=fixture(t),shelf=new DropShelf(),file=path.join(root,'document.txt');shelf.add([file,file]);assert.equal(shelf.files.length,1);assert.equal(Object.hasOwn(shelf.snapshot()[0],'path'),false);
 assert.throws(()=>shelf.add(Array(101).fill(file)));assert.equal(shelf.files.length,1);
});
test('placement finds unused space and never covers the cursor when another area is free',()=>{
 const area={x:0,y:0,width:1200,height:800},window={x:0,y:0,width:900,height:800},point={x:1160,y:50};
 const r=placement(area,point,[window]);assert.ok(r.x>=900);assert.ok(r.y>point.y+48);assert.ok(r.x+r.width<=1200&&r.y+r.height<=800);
});
test('placement respects negative monitor coordinates and a completely occupied small screen',()=>{
 const area={x:-400,y:100,width:180,height:200},r=placement(area,{x:-350,y:120},[area]);assert.deepEqual(r,{x:-400,y:100,width:180,height:200});
});
