(() => {
// Google Forms declares its own global ox function after document-start installation.
// Retain that function and restore only missing Ox runtime properties on it.
const docsOxRuntime = window.ox;
function restoreDocsOxRuntime(){
 const current=window.ox;
 if(current===docsOxRuntime||!current||!['object','function'].includes(typeof current))return;
 for(const key of Reflect.ownKeys(docsOxRuntime)){
  if(!Reflect.has(current,key))Object.defineProperty(current,key,Object.getOwnPropertyDescriptor(docsOxRuntime,key));
 }
}
window.addEventListener?.('DOMContentLoaded',restoreDocsOxRuntime,{once:true});
window.addEventListener?.('load',restoreDocsOxRuntime,{once:true});
async function sharingClient(documentId){
 if(!location.pathname.startsWith('/document/d/'+documentId+'/'))throw Error('Document mismatch');
 let f=[...document.querySelectorAll('iframe')].find(e=>e.src.includes('/drivesharing/dialog/share'));
 if(!f){const b=await docWait(()=>[...document.querySelectorAll('[role="button"],button')].find(e=>/^Share\./.test(e.getAttribute('aria-label')||'')));docClick(b);f=await docWait(()=>[...document.querySelectorAll('iframe')].find(e=>e.src.includes('/drivesharing/dialog/share')));}
 return docWait(()=>f.contentWindow?.gapi?.client?.request?f.contentWindow.gapi.client:null,15000,'sharing API client');
}
async function readDocumentAccess(client,id,context){
 const items=[];let token;for(let i=0;i<5;i++){let r;try{r=await client.request({path:'https://www.googleapis.com/drive/v3/files/'+encodeURIComponent(id)+'/permissions',method:'GET',params:{fields:'permissions(id,type,role,emailAddress),nextPageToken',pageSize:100,...(token?{pageToken:token}:{})}});}catch(e){throw Error('Permission read '+(e.status||'failed')+': '+(e.result?.error?.message||'Google API error'));}
 const a=r.result;if(!Array.isArray(a?.permissions))throw Error('Unrecognized permission list');items.push(...a.permissions);token=a.nextPageToken;if(!token)break;}if(token)throw Error('Permission list exceeds bounded verification');
 const sessions=await discoverAuthenticatedSessions();if(sessions.length!==1||!items.some(p=>p.role==='owner'&&p.emailAddress?.toLowerCase()===sessions[0].id.toLowerCase()))throw Error('Current page account is not verified document owner');return items;
}

async function currentDoc(id){
 if(!location.pathname.startsWith('/document/d/'+id+'/'))throw Error('Document mismatch');
 const r=await fetch(location.href,{credentials:'include',cache:'no-store'});if(!r.ok)throw Error('Document read HTTP '+r.status);
 const html=await r.text();
 const scripts=html.split('<script').slice(1).map(s=>s.slice(s.indexOf('>')+1,s.indexOf('<\/script>')));
 const chunks=[];for(const t of scripts){const prefix='DOCS_modelChunk = ';const i=t.indexOf(prefix+'{');if(i<0)continue;const end=t.indexOf('; DOCS_modelChunkLoadStart',i);if(end<0)throw Error('Unknown model boundary');chunks.push(JSON.parse(t.slice(i+prefix.length,end)));}
 if(!chunks.length)throw Error('Document text model unavailable');
 const urls=[],fonts=[];const walk=x=>{if(typeof x==='string'){if(/^https?:\/\//.test(x)&&!/[\s]/.test(x))urls.push(x);}else if(x&&typeof x==='object'){for(const [k,v]of Object.entries(x)){if(k==='ts_ff'&&typeof v==='string')fonts.push(v);if(!(k==='s'&&x.ty==='is'))walk(v);}}};chunks.forEach(walk);return {text:chunks.flatMap(c=>c.chunk.filter(x=>x.ty==='is').map(x=>x.s)).join(''),hyperlinks:[...new Set(urls)],fontFamilies:[...new Set(fonts)]};
}
function docMenuClick(e){for(const type of ['mousedown','mouseup','click'])e.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,view:window,button:0}));}
function docClick(e){if(!e)throw Error('Editor control missing');const r=e.getBoundingClientRect();for(const type of ['mouseover','mousemove','mousedown','mouseup','click'])e.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,view:window,button:0,clientX:r.x+r.width/2,clientY:r.y+r.height/2}));}
async function docWait(read,ms=10000,label='unspecified'){const end=Date.now()+ms;while(Date.now()<end){const v=read();if(v)return v;await new Promise(r=>setTimeout(r,100));}throw Error('Editor readiness timeout: '+label);}
async function findDialog(){const visible=e=>e&&e.getClientRects().length&&getComputedStyle(e).display!=='none';const dialog=()=>[...document.querySelectorAll('.appsDocsUiWizFindandreplacedialogContainer')].find(e=>visible(e)&&e.querySelector('input[aria-label="Find"]'));let d=dialog();if(d)return d;const e=await docWait(()=>document.querySelector('#docs-edit-menu'),10000,'edit menu');const findItem=()=>[...document.querySelectorAll('[role="menuitem"]')].find(x=>visible(x)&&x.textContent.startsWith('Find and replace'));let m=findItem();if(!m){docMenuClick(e);m=await docWait(findItem,10000,'find menu item');}docClick(m.querySelector('.goog-menuitem-label')||m);return docWait(dialog,10000,'find inputs');}
function setDocInput(e,value){Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,value);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));}

async function discoverAuthenticatedSessions(){const deadline=Date.now()+12000;while(Date.now()<deadline){const el=[...document.querySelectorAll('[aria-label]')].find(e=>/Google Account:/i.test(e.getAttribute('aria-label')||''));const label=el?.getAttribute('aria-label')||'';const match=label.match(/Google Account:\s*(.*?)\s*\(([^)]+@[^)]+)\)/is);if(match){const email=match[2].trim();return [{id:email,label:match[1].trim()+' ('+email+')',url:'https://docs.google.com'+(location.pathname.startsWith('/document/')?'/document/u/1/':'/forms/u/0/')+'?authuser='+encodeURIComponent(email)}];}if(location.hostname==='accounts.google.com')return [];await new Promise(r=>setTimeout(r,200));}throw Error('Google account identity unavailable; refusing to infer authentication from page presence');}
const clean=v=>String(v??"").replace(/\s+/g," ").trim();
const account=()=>{const e=[...document.querySelectorAll("[aria-label]")].find(x=>/Google Account:/i.test(x.getAttribute("aria-label")||""));if(!e)return null;const s=e.getAttribute("aria-label")||"";const m=s.match(/Google Account:\s*(.*?)\s*\(([^)]+@[^)]+)\)/is);return m?{name:clean(m[1]),email:clean(m[2])}:{name:null,email:null};};
window.ox.install(({ action }) => {
action('listSessions',{async invoke(){return discoverAuthenticatedSessions();}});
action('login',{async invoke(){return null;}});
action('listDocumentPermissions',{async invoke({documentId},context){const client=await sharingClient(documentId);const a=await readDocumentAccess(client,documentId,context);return {items:a.map(p=>({id:p.id,email:p.emailAddress||'',role:p.role,type:p.type})),nextCursor:null};}});
action('shareDocumentEditor',{async invoke({documentId,email},context){
 if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))throw Error('Invalid recipient email');const client=await sharingClient(documentId),before=await readDocumentAccess(client,documentId,context),existing=before.filter(p=>p.emailAddress?.toLowerCase()===email.toLowerCase());
 if(existing.some(p=>['writer','owner'].includes(p.role)))return {email,role:'writer',status:'alreadyEditor',notificationRequested:false};if(existing.length)throw Error('Recipient already has a different role; no duplicate permission created');
 try{await client.request({path:'https://www.googleapis.com/drive/v3/files/'+encodeURIComponent(documentId)+'/permissions',method:'POST',params:{sendNotificationEmail:true,fields:'id,emailAddress,type,role'},body:{type:'user',role:'writer',emailAddress:email}});}catch(e){throw Error('Permission create '+(e.status||'uncertain')+': '+(e.result?.error?.message||'Inspect permission list before retry'));}
 const after=await readDocumentAccess(client,documentId,context);if(!after.some(p=>p.emailAddress?.toLowerCase()===email.toLowerCase()&&p.role==='writer'))throw Error('Create submitted but writer access not yet verified; inspect without retry');return {email,role:'writer',status:'shared',notificationRequested:true};
}});
action('prepareDocumentSharing',{async invoke({documentId,emails},context){
 if(!Array.isArray(emails)||emails.length<1||emails.length>4)throw Error('prepareDocumentSharing: emails must contain between 1 and 4 items');
 if(!location.pathname.startsWith('/document/d/'+documentId+'/'))throw Error('Document mismatch');
 const share=await docWait(()=>[...document.querySelectorAll('[role="button"],button')].find(e=>/^Share\./.test(e.getAttribute('aria-label')||'')));
 docClick(share);const frame=await docWait(()=>[...document.querySelectorAll('iframe')].find(e=>e.src.includes('/drivesharing/dialog/share')));
 const d=await docWait(()=>frame.contentDocument?.querySelector('input[role="combobox"]')?frame.contentDocument:null),w=d.defaultView;
 for(const email of emails){
 const i=d.querySelector('input[role="combobox"]');if(!i)throw Error('Recipient input missing; no invitation sent');i.focus();Object.getOwnPropertyDescriptor(w.HTMLInputElement.prototype,'value').set.call(i,email);i.dispatchEvent(new w.Event('input',{bubbles:true}));i.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
 const end=Date.now()+7000;let option;while(Date.now()<end){option=[...d.querySelectorAll('[role="option"]')].find(e=>e.textContent.toLowerCase().includes(email.toLowerCase()));if(option)break;await new Promise(r=>setTimeout(r,100));}
 if(option)docClick(option);else if(!d.body.innerText.toLowerCase().includes(email.toLowerCase()))throw Error('Exact recipient could not be staged; no invitation sent');
 }
 return {text:d.body.innerText.slice(0,6000),controls:[...d.querySelectorAll('button,[role="button"],[role="combobox"]')].filter(e=>e.getClientRects().length).map(e=>({label:e.getAttribute('aria-label')||'',text:e.textContent.slice(0,150),role:e.getAttribute('role')||e.tagName.toLowerCase()}))};
}});
action('setDocumentArial',{async invoke({documentId},context){
 const before=await currentDoc(documentId);const visible=e=>e&&e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden';
 const notice=[...document.querySelectorAll('[role="dialog"]')].find(e=>visible(e)&&e.textContent.startsWith("This document's author is using the pageless format"));if(notice){const b=[...notice.querySelectorAll('button')].find(e=>e.textContent.trim()==='Got it!');if(!b)throw Error('Pageless notice control unavailable');b.click();await docWait(()=>!visible(notice));}
 const dialogs=[...document.querySelectorAll('[role="dialog"]')].filter(e=>visible(e)&&!e.classList.contains('docs-ml-promotion'));if(dialogs.length)throw Error('Existing dialog blocks font formatting; no changes made');
 const edit=await docWait(()=>document.querySelector('#docs-edit-menu'));if(edit.getAttribute('aria-expanded')!=='true')docMenuClick(edit);
 const all=await docWait(()=>[...document.querySelectorAll('[role="menuitem"]')].find(e=>visible(e)&&e.textContent.startsWith('Select all')));docClick(all.querySelector('.goog-menuitem-label')||all);
 const font=await docWait(()=>document.querySelector('#docs-font-family'));if(font.getAttribute('aria-expanded')!=='true')docMenuClick(font);
 const arial=await docWait(()=>[...document.querySelectorAll('[role="menuitemcheckbox"]')].find(e=>visible(e)&&e.textContent.trim()==='Arial'));
 docClick(arial.querySelector('span[style*="font-family"]')||arial);
 await docWait(()=>document.querySelector('#docs-font-family .goog-toolbar-menu-button-caption')?.textContent.trim()==='Arial');
 const end=Date.now()+15000;while(Date.now()<end){const s=[...document.querySelectorAll('[role="status"]')].map(e=>e.textContent).join(' ');if(!/unsaved|saving/i.test(s)){const after=await currentDoc(documentId);if(after.text!==before.text)throw Error('Unexpected text change after font operation; inspect without retry');return {font:'Arial',textUnchanged:true,verified:true};}await new Promise(r=>setTimeout(r,200));}
 throw Error('Font applied but save state unverified; inspect without retry');
}});
action('refreshEditor',{async invoke({documentId}){if(!location.pathname.startsWith('/document/d/'+documentId+'/'))throw Error('Document mismatch');location.reload();return null;}});
action('formatInlineLink',{async invoke(args,context){let stage='precheck';try{
 const u=new URL(args.url);if(!['https:','http:'].includes(u.protocol))throw Error('Invalid link protocol');
 const before=await currentDoc(args.documentId);if(before.text.split(args.find).length-1!==1)throw Error('Reference is missing or ambiguous; nothing changed');
 for(const target of [document.activeElement,document])if(target)target.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',keyCode:27,which:27,bubbles:true,cancelable:true}));
 stage='findDialog';console.log('inlineLink stage=findDialog');const d=await findDialog();stage='search';console.log('inlineLink stage=search');if([...d.querySelectorAll('input[type="checkbox"]')][1]?.checked)throw Error('Regex search enabled');setDocInput(d.querySelector('input[aria-label="Find"]'),args.find);
 await docWait(()=>d.querySelector('[class*="FindInputCounter"]')?.textContent.endsWith(' of 1'));
 stage='closeSearch';console.log('inlineLink stage=closeSearch');d.querySelector('button[aria-label="Close"]').click();
 await docWait(()=>!d.isConnected||getComputedStyle(d).display==='none'||getComputedStyle(d).visibility==='hidden');
 stage='insertMenu';console.log('inlineLink stage=insertMenu');const menu=await docWait(()=>document.querySelector('#docs-insert-menu'));if(menu.getAttribute('aria-expanded')!=='true')docMenuClick(menu);
 const link=await docWait(()=>[...document.querySelectorAll('[role="menuitem"]')].find(e=>e.getClientRects().length&&e.textContent.startsWith('Link')));docClick(link.querySelector('.goog-menuitem-label')||link);
 stage='anchor';console.log('inlineLink stage=anchor');const anchor=await docWait(()=>document.querySelector('input[aria-label="Anchor Text"]'));if(anchor.value!==args.find)throw Error('Selected anchor mismatch; link not applied');
 setDocInput(anchor,args.label);const url=document.querySelector('input[aria-label="Link"]');if(!url)throw Error('Link input unavailable');setDocInput(url,args.url);
 const apply=await docWait(()=>{const b=document.querySelector('button.appsElementsLinkInsertionApplyButton');return b&&!b.disabled?b:null;});apply.click();
 const end=Date.now()+15000;while(Date.now()<end){const after=await currentDoc(args.documentId);if(!after.text.includes(args.find)&&after.text.includes(args.label)&&after.hyperlinks.includes(args.url))return {verified:true,label:args.label,url:args.url};await new Promise(r=>setTimeout(r,250));}
 throw Error('Link submitted but save not verified; inspect without retry');
}catch(e){throw Error(stage+': '+e.message);}}});

action('deleteDocumentTable',{async invoke({documentId,cellLabel},context){const before=await currentDoc(documentId);if(before.text.split(cellLabel).length-1!==1)throw Error('Table label missing or ambiguous');const p=before.text.indexOf(cellLabel),start=before.text.lastIndexOf('\u0010',p),end=before.text.indexOf('\u0011',p)+1;if(start<0||end<=p)throw Error('Target is not within a verified table');const prefix=before.text.slice(0,start).trimEnd(),suffix=before.text.slice(end).trimStart();for(const t of [document.activeElement,document])t?.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',keyCode:27,which:27,bubbles:true,cancelable:true}));const d=await findDialog();if([...d.querySelectorAll('input[type="checkbox"]')][1]?.checked)throw Error('Regex search enabled');setDocInput(d.querySelector('input[aria-label="Find"]'),cellLabel);await docWait(()=>d.querySelector('[class*="FindInputCounter"]')?.textContent.endsWith(' of 1'));d.querySelector('button[aria-label="Close"]').click();await docWait(()=>getComputedStyle(d).display==='none'||getComputedStyle(d).visibility==='hidden');docMenuClick(document.querySelector('#docs-format-menu'));const table=await docWait(()=>[...document.querySelectorAll('[role="menuitem"]')].find(e=>e.getClientRects().length&&e.textContent.startsWith('Table(')));if(table.getAttribute('aria-disabled')==='true')throw Error('Table command unavailable; nothing deleted');docClick(table);const del=await docWait(()=>[...document.querySelectorAll('[role="menuitem"]')].find(e=>e.getClientRects().length&&e.textContent.trim()==='Delete table'));docClick(del);const deadline=Date.now()+14000;while(Date.now()<deadline){const after=await currentDoc(documentId);if(!after.text.includes(cellLabel)){if(!after.text.startsWith(prefix)||!after.text.trimEnd().endsWith(suffix))throw Error('Table removed; outside text verification failed; inspect without retry');return {verified:true};}await new Promise(r=>setTimeout(r,200));}throw Error('Delete submitted but not verified; inspect without retry');}});

action('replaceDocumentMarkdown',{async invoke(args,context){
 if(!Array.isArray(args.requiredFragments)||args.requiredFragments.length<1||args.requiredFragments.length>20)throw Error('replaceDocumentMarkdown: requiredFragments must contain between 1 and 20 items');
 const client=await sharingClient(args.documentId);const beforePermissions=await readDocumentAccess(client,args.documentId,context);const formats=await client.request({path:'https://www.googleapis.com/drive/v3/about',method:'GET',params:{fields:'importFormats'}});if(!formats.result?.importFormats?.['text/markdown']?.includes('application/vnd.google-apps.document'))throw Error('Google Markdown import unavailable');const metadata=await client.request({path:'https://www.googleapis.com/drive/v3/files/'+encodeURIComponent(args.documentId),method:'GET',params:{fields:'id,mimeType'}});if(metadata.result?.mimeType!=='application/vnd.google-apps.document')throw Error('Target is not a native Google Doc');const before=await currentDoc(args.documentId);if(before.text!==args.expectedText)throw Error('Document changed since read; no upload submitted');
 try{await client.request({path:'https://www.googleapis.com/upload/drive/v3/files/'+encodeURIComponent(args.documentId),method:'PATCH',params:{uploadType:'media',fields:'id,mimeType'},headers:{'Content-Type':'text/markdown; charset=UTF-8'},body:args.markdown});}catch(e){throw Error('Markdown update '+(e.status||'uncertain')+': '+(e.result?.error?.message||'Inspect saved content before retrying'));}
 const deadline=Date.now()+18000;while(Date.now()<deadline){const after=await currentDoc(args.documentId);if(args.requiredFragments.every(t=>after.text.includes(t))&&!/^#{1,3} /m.test(after.text)&&!after.text.includes('| ---')&&after.hyperlinks.includes('https://expe.onelink.me/hnLd/9zfbnek2')){const afterPermissions=await readDocumentAccess(client,args.documentId,context);const signature=a=>JSON.stringify(a.map(p=>[p.id,p.emailAddress||'',p.role,p.type]).sort((a,b)=>a[0].localeCompare(b[0])));if(signature(beforePermissions)!==signature(afterPermissions))throw Error('Content replaced but sharing verification changed; inspect without retry');return {documentId:args.documentId,verified:true,sharingUnchanged:true};}await new Promise(r=>setTimeout(r,300));}throw Error('Markdown update submitted; rendering unverified. Inspect without retry');
}});
action('getDocumentText',{async invoke({documentId}){return currentDoc(documentId);}});
action('replaceDocumentText',{async invoke(args,context){
 const before=await currentDoc(args.documentId);const count=before.text.split(args.find).length-1;if(count!==args.expectedCount)throw Error('Expected text occurrence mismatch: '+count+'; nothing changed');
 const d=await findDialog();const checks=[...d.querySelectorAll('input[type="checkbox"]')];if(checks[1]?.checked)throw Error('Regex search enabled; refusing literal replacement');
 setDocInput(d.querySelector('input[aria-label="Find"]'),args.find);setDocInput(d.querySelector('input[aria-label="Replace with"]'),args.replacement);
 const b=await docWait(()=>{const c=d.querySelector('[class*="FindInputCounter"]')?.textContent||'';const b=[...d.querySelectorAll('button')].find(e=>e.textContent.trim()==='Replace all');return c.endsWith(' of '+count)&&b&&!b.disabled?b:null;});
 docClick(b);
 const end=Date.now()+15000;while(Date.now()<end){const after=await currentDoc(args.documentId);if(!after.text.includes(args.find)&&after.text.includes(args.replacement))return {replaced:count,verified:true};await new Promise(r=>setTimeout(r,250));}
 throw Error('Replacement submitted but save not verified; inspect without retry');
}});
action('getEditorStatus',{async invoke(){return {title:document.title,url:location.href,dialogs:[...document.querySelectorAll('[role="dialog"]')].filter(e=>e.getClientRects().length).map(e=>JSON.stringify({text:e.textContent.slice(0,1600),display:getComputedStyle(e).display,visibility:getComputedStyle(e).visibility,inputs:[...e.querySelectorAll("input")].map(i=>({label:i.getAttribute("aria-label"),value:i.value.slice(0,300)}))})),links:[...document.querySelectorAll('a[href*="/document/d/"]')].map(e=>e.href),messages:[JSON.stringify({edit:document.querySelector('#docs-edit-menu')?.outerHTML,find:[...document.querySelectorAll('[role="menuitem"]')].filter(e=>e.textContent.startsWith('Find and replace')).map(e=>({html:e.outerHTML,rect:e.getBoundingClientRect().toJSON(),visibility:getComputedStyle(e).visibility})),ready:document.readyState}),...[...document.querySelectorAll('[role="alert"],[role="status"]')].map(e=>e.textContent.slice(0,500))]};}});
action('convertMarkdownDocument',{async invoke(args,context){
 if(location.pathname!=='/document/d/'+args.sourceId+'/edit')throw Error('Source Markdown document route mismatch');
 const deadline=Date.now()+15000;while(Date.now()<deadline&&!document.querySelector('#docs-file-menu'))await new Promise(r=>setTimeout(r,150));
 
 const click=e=>{for(const type of ['mousedown','mouseup','click'])e.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,view:window,button:0}));};
 const file=document.querySelector('#docs-file-menu');if(!file)throw Error('File menu unavailable');if(file.getAttribute('aria-expanded')!=='true')click(file);
 const end=Date.now()+5000;let save;while(Date.now()<end){save=[...document.querySelectorAll('[role="menuitem"]')].find(e=>e.getClientRects().length&&/^Save as Google Docs/.test(e.textContent));if(save)break;await new Promise(r=>setTimeout(r,100));}
 if(!save)throw Error('Save as Google Docs unavailable; source may already be native. Inspect state without replay.');
 const target=save.querySelector('.goog-menuitem-label')||save;
 const box=target.getBoundingClientRect();
 for(const type of ['mouseover','mousemove','mousedown','mouseup','click'])target.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,view:window,button:0,clientX:box.x+box.width/2,clientY:box.y+box.height/2}));
 return {status:'conversionRequested',sourceId:args.sourceId};
}});
action('convertWordDocument',{async invoke(args,context){
 if(location.pathname!=='/document/d/'+args.sourceId+'/edit')throw Error('Source Word document route mismatch');
 const deadline=Date.now()+15000;while(Date.now()<deadline&&!document.querySelector('#docs-file-menu'))await new Promise(r=>setTimeout(r,150));
 
 const click=e=>{for(const type of ['mousedown','mouseup','click'])e.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,view:window,button:0}));};
 const file=document.querySelector('#docs-file-menu');if(!file)throw Error('File menu unavailable');if(file.getAttribute('aria-expanded')!=='true')click(file);
 const end=Date.now()+5000;let save;while(Date.now()<end){save=[...document.querySelectorAll('[role="menuitem"]')].find(e=>e.getClientRects().length&&/^Save as Google Docs/.test(e.textContent));if(save)break;await new Promise(r=>setTimeout(r,100));}
 if(!save)throw Error('Save as Google Docs unavailable; source may already be native. Inspect state without replay.');
 const target=save.querySelector('.goog-menuitem-label')||save;
 const box=target.getBoundingClientRect();
 for(const type of ['mouseover','mousemove','mousedown','mouseup','click'])target.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,view:window,button:0,clientX:box.x+box.width/2,clientY:box.y+box.height/2}));
 return {status:'conversionRequested',sourceId:args.sourceId};
}});
 action("getCurrentAccount",{async invoke(){const a=account();if(!a)throw new Error("Google Forms is not signed in.");return a;}});
 action("listRecentForms",{async invoke(){if(!account())throw new Error("Google Forms is not signed in.");const nodes=[...document.querySelectorAll("a[href*='/forms/d/'],[role='link'][data-id],.docs-homescreen-grid-item")];const seen=new Set(),items=[];for(const e of nodes){const a=e.closest("a[href]")||e.querySelector?.("a[href]");const href=a?.href||e.getAttribute?.("data-url");const title=clean(e.getAttribute?.("aria-label")||e.getAttribute?.("title")||e.innerText);if(!href||!title||seen.has(href)||/Blank form|Contact Information|RSVP|Party Invite/i.test(title))continue;seen.add(href);items.push({title:title.slice(0,300),url:new URL(href,location.href).href});if(items.length>=100)break;}return {items,nextCursor:null};}});
 action("openBlankForm",{async invoke(){if(!account())throw new Error("Google Forms is not signed in.");const option=[...document.querySelectorAll("[role='option']")].find(e=>/Blank form/i.test(clean(e.innerText)));if(!option)throw new Error("Blank form template is unavailable.");option.click();const started=Date.now();while(Date.now()-started<10000){await new Promise(r=>requestAnimationFrame(()=>r()));if(/\/forms\/d\//.test(location.pathname))return {url:location.href};}throw new Error("The blank form did not open.");}});
});
})();
