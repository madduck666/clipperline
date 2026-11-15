'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
module.exports=async function({application,check,until}){
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'drop-shelf-native-')),file=path.join(directory,'Synthetic shelf file.txt');
 fs.writeFileSync(file,'synthetic native drop fixture');
 try{
  await application.evaluate(()=>global.__clipboardLineTest.getDropShelf().reveal());
  const page=await until(()=>application.windows().find(page=>page.url().endsWith('/drop-shelf.html')),Boolean);
  await page.waitForFunction(()=>!!window.dropShelf);
  assert.equal(await page.evaluate(()=>typeof require),'undefined');
  // A browser-backed File with its real path exercises webUtils and trusted IPC.
  await page.evaluate(()=>{const input=document.createElement('input');input.type='file';input.id='synthetic-file';input.hidden=true;document.body.append(input);});
  await page.locator('#synthetic-file').setInputFiles(file);
  await page.evaluate(()=>{const dt=new DataTransfer();dt.items.add(document.getElementById('synthetic-file').files[0]);document.getElementById('synthetic-file').remove();document.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dt}));});
  await page.getByText('Synthetic shelf file.txt',{exact:true}).waitFor();
  assert.deepEqual(await application.evaluate(()=>global.__clipboardLineTest.getDropShelf().model.dragPaths()),[file]);
  await application.evaluate(()=>global.__clipboardLineTest.getDropShelf().end());
  await until(()=>application.evaluate(()=>global.__clipboardLineTest.getDropShelf().window.isVisible()),Boolean);
  await page.locator('#close').click();
  await until(()=>application.evaluate(()=>!global.__clipboardLineTest.getDropShelf().window.isVisible()),Boolean);
  assert.equal(fs.readFileSync(file,'utf8'),'synthetic native drop fixture');
  check('floating shelf accepts a real File through isolated preload, retains its original path and closes without deleting it');
 }finally{await application.evaluate(()=>global.__clipboardLineTest.getDropShelf().dismiss());fs.rmSync(directory,{recursive:true,force:true});}
};
