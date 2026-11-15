'use strict';
// Real Chromium executing the shipping shelf renderer with synthetic native IPC.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const http=require('node:http');
const {chromium}=require('playwright');
const {DropShelf}=require('../lib/drop-shelf.cjs');
const {translated}=require('../lib/status-summary.cjs');
async function main(){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'drop-shelf-browser-')),model=new DropShelf();
 const file=path.join(root,'Taslak <test>.txt');fs.writeFileSync(file,'synthetic');
 const args=process.argv.slice(2),option=name=>args[args.indexOf(name)+1];
 const server=http.createServer((request,response)=>{const name=request.url.slice(1);const mime={'drop-shelf.html':'text/html','drop-shelf.js':'text/javascript','drop-shelf.css':'text/css'}[name];if(!mime){response.writeHead(404);response.end();return;}response.writeHead(200,{'Content-Type':mime});response.end(fs.readFileSync(path.join(__dirname,'..',name)));});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({headless:true,...(args.includes('--browser')?{executablePath:option('--browser')}:{})});
 let dragged=[],closed=false;
 const state=()=>({files:model.snapshot(),language:'tr',labels:{title:translated('tr','Drop shelf'),drop:translated('tr','Drop files here'),drag:translated('tr','Drag to another window'),close:translated('tr','Close'),unavailable:translated('tr','A dropped file is no longer available.')}});
 try{
  const page=await browser.newPage({viewport:{width:216,height:228},deviceScaleFactor:2});
  await page.exposeFunction('nativeState',state);
  await page.exposeFunction('nativeAdd',names=>{model.add(names.map(name=>path.join(root,name)));return state();});
  await page.exposeFunction('nativeDrag',()=>{dragged=model.dragPaths();});
  await page.exposeFunction('nativeClose',()=>{closed=true;model.clear();});
  await page.addInitScript(()=>{window.dropShelf={state:()=>window.nativeState(),add:files=>window.nativeAdd(files.map(file=>file.name)),drag:()=>window.nativeDrag(),close:()=>window.nativeClose(),subscribe:()=>()=>{}};});
  await page.goto('http://127.0.0.1:'+server.address().port+'/drop-shelf.html');
  await page.getByText('Dosyaları buraya bırak').waitFor();
  await page.evaluate(()=>{const dt=new DataTransfer();dt.items.add(new File(['synthetic'],'Taslak <test>.txt'));document.dispatchEvent(new DragEvent('dragenter',{dataTransfer:dt,bubbles:true}));});
  assert.equal(await page.locator('body').evaluate(node=>node.classList.contains('hover')),true);
  await page.evaluate(()=>{const dt=new DataTransfer();dt.items.add(new File(['synthetic'],'Taslak <test>.txt'));document.dispatchEvent(new DragEvent('drop',{dataTransfer:dt,bubbles:true,cancelable:true}));});
  await page.getByText('Taslak <test>.txt',{exact:true}).waitFor();
  assert.equal(await page.locator('test').count(),0,'Names must render as text, never HTML');
  assert.equal(await page.locator('#count').textContent(),'1');
  await page.locator('#target').dispatchEvent('dragstart');
  await page.waitForTimeout(50);assert.deepEqual(dragged,[file]);
  if(args.includes('--output'))await page.screenshot({path:option('--output'),omitBackground:true});
  // Unsupported plain text must neither navigate the page nor alter the shelf.
  await page.evaluate(()=>{const dt=new DataTransfer();dt.setData('text/uri-list','https://example.invalid');const e=new DragEvent('drop',{dataTransfer:dt,bubbles:true,cancelable:true});document.dispatchEvent(e);if(!e.defaultPrevented)throw new Error('Unexpected navigation allowed');});
  assert.equal(model.files.length,1);
  await page.getByRole('button',{name:translated('tr','Close')}).click();await page.waitForTimeout(50);
  assert.equal(closed,true);assert.equal(model.files.length,0);assert.equal(fs.readFileSync(file,'utf8'),'synthetic');
  console.log('PASS real Chromium: Turkish empty/drop/filled UI, drag-out, text-safe filename, unsupported drop, close preserving originals');
 }finally{await browser.close();server.close();fs.rmSync(root,{recursive:true,force:true});}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
