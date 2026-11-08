async function createDriveMarkdownFile(args,context){
 const target=driveFolderURL(args.parentId,context.session.id);if(location.pathname.replace(/^\/drive\/u\/\d+\//,'/drive/')!==target.pathname)throw Error('Parent page mismatch: route pageUrl to requested parent');
 if(!args.name.trim()||args.name!==args.name.trim()||/[\u0000-\u001f]/.test(args.name)||!args.name.endsWith('.md'))throw Error('Use an exact nonblank .md filename without control characters');
 const bytes=new TextEncoder().encode(args.text);if(bytes.byteLength>65536)throw Error('UTF-8 content exceeds 64 KiB upload bound');
 const before=await folderSnapshot(args.parentId,context);if(before.snapshot!==args.expectedParentSnapshot)throw Error('Conflict: parent snapshot changed; nothing uploaded');if(before.items.some(i=>i.name===args.name))throw Error('Conflict: same-name child observed; nothing uploaded');
 if([...document.querySelectorAll('[role="dialog"]')].some(driveVisible))throw Error('Unexpected dialog; nothing uploaded');
 const targets=[...document.querySelectorAll('[jscontroller="y9Qy5d"][jsaction]')].filter(e=>(e.getAttribute('jsaction')||'').includes('drop:swrgtc'));if(targets.length!==1)throw Error('Observed upload drop target unavailable or ambiguous');
 const dt=new DataTransfer();dt.items.add(new File([bytes],args.name,{type:'text/markdown'}));
 await assertSelectedAccount(context);const latest=await folderSnapshot(args.parentId,context);if(latest.snapshot!==before.snapshot)throw Error('Conflict immediately before upload; nothing uploaded');
 targets[0].dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dt}));
 const end=Date.now()+25000;while(Date.now()<end){const after=await folderSnapshot(args.parentId,context);const added=after.items.filter(i=>i.name===args.name&&!before.items.some(b=>b.id===i.id));if(added.length===1){if(added[0].mimeType!=='text/markdown')throw Error('Unexpected upload MIME type; inspect created resource without retry');return {item:added[0],accountId:after.accountId,conflictGuarantee:'bestEffortNotAtomic'};}if(added.length>1)throw Error('Uncertain upload outcome: multiple new same-name items; do not retry');await new Promise(r=>setTimeout(r,300));}
 throw Error('Uncertain upload outcome after one drop; inspect listChildren and upload UI without retrying');
}


async function createDriveWordFile(args,context){
 const target=driveFolderURL(args.parentId,context.session.id);if(location.pathname.replace(/^\/drive\/u\/\d+\//,'/drive/')!==target.pathname)throw Error('Parent page mismatch: route pageUrl to requested parent');
 if(!args.name.trim()||args.name!==args.name.trim()||/[\u0000-\u001f]/.test(args.name)||!args.name.endsWith('.docx'))throw Error('Use an exact nonblank .docx filename without control characters');
 const bytes=Uint8Array.from(atob(args.base64),c=>c.charCodeAt(0));if(bytes.byteLength>196608)throw Error('DOCX exceeds upload bound');
 const before=await folderSnapshot(args.parentId,context);if(before.snapshot!==args.expectedParentSnapshot)throw Error('Conflict: parent snapshot changed; nothing uploaded');if(before.items.some(i=>i.name===args.name))throw Error('Conflict: same-name child observed; nothing uploaded');
 if([...document.querySelectorAll('[role="dialog"]')].some(driveVisible))throw Error('Unexpected dialog; nothing uploaded');
 const targets=[...document.querySelectorAll('[jscontroller="y9Qy5d"][jsaction]')].filter(e=>(e.getAttribute('jsaction')||'').includes('drop:swrgtc'));if(targets.length!==1)throw Error('Observed upload drop target unavailable or ambiguous');
 const dt=new DataTransfer();dt.items.add(new File([bytes],args.name,{type:'application/vnd.openxmlformats-officedocument.wordprocessingml.document'}));
 await assertSelectedAccount(context);const latest=await folderSnapshot(args.parentId,context);if(latest.snapshot!==before.snapshot)throw Error('Conflict immediately before upload; nothing uploaded');
 targets[0].dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dt}));
 const end=Date.now()+25000;while(Date.now()<end){const after=await folderSnapshot(args.parentId,context);const added=after.items.filter(i=>i.name===args.name&&!before.items.some(b=>b.id===i.id));if(added.length===1){if(added[0].mimeType!=='application/vnd.openxmlformats-officedocument.wordprocessingml.document')throw Error('Unexpected upload MIME type; inspect created resource without retry');return {item:added[0],accountId:after.accountId,conflictGuarantee:'bestEffortNotAtomic'};}if(added.length>1)throw Error('Uncertain upload outcome: multiple new same-name items; do not retry');await new Promise(r=>setTimeout(r,300));}
 throw Error('Uncertain upload outcome after one drop; inspect listChildren and upload UI without retrying');
}



async function createDriveTextFile(args,context){
 const target=driveFolderURL(args.parentId,context.session.id);if(location.pathname.replace(/^\/drive\/u\/\d+\//,'/drive/')!==target.pathname)throw Error('Parent page mismatch: route pageUrl to requested parent');
 if(!args.name.trim()||args.name!==args.name.trim()||/[\u0000-\u001f]/.test(args.name)||!args.name.endsWith('.txt'))throw Error('Use an exact nonblank .txt filename without control characters');
 const bytes=new TextEncoder().encode(args.text);if(bytes.byteLength>65536)throw Error('UTF-8 content exceeds 64 KiB upload bound');
 const before=await folderSnapshot(args.parentId,context);if(before.snapshot!==args.expectedParentSnapshot)throw Error('Conflict: parent snapshot changed; nothing uploaded');if(before.items.some(i=>i.name===args.name))throw Error('Conflict: same-name child observed; nothing uploaded');
 if([...document.querySelectorAll('[role="dialog"]')].some(driveVisible))throw Error('Unexpected dialog; nothing uploaded');
 const targets=[...document.querySelectorAll('[jscontroller="y9Qy5d"][jsaction]')].filter(e=>(e.getAttribute('jsaction')||'').includes('drop:swrgtc'));if(targets.length!==1)throw Error('Observed upload drop target unavailable or ambiguous');
 const dt=new DataTransfer();dt.items.add(new File([bytes],args.name,{type:'text/plain'}));
 await assertSelectedAccount(context);const latest=await folderSnapshot(args.parentId,context);if(latest.snapshot!==before.snapshot)throw Error('Conflict immediately before upload; nothing uploaded');
 targets[0].dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dt}));
 const end=Date.now()+25000;while(Date.now()<end){const after=await folderSnapshot(args.parentId,context);const added=after.items.filter(i=>i.name===args.name&&!before.items.some(b=>b.id===i.id));if(added.length===1){if(added[0].mimeType!=='text/plain')throw Error('Unexpected upload MIME type; inspect created resource without retry');return {item:added[0],accountId:after.accountId,conflictGuarantee:'bestEffortNotAtomic'};}if(added.length>1)throw Error('Uncertain upload outcome: multiple new same-name items; do not retry');await new Promise(r=>setTimeout(r,300));}
 throw Error('Uncertain upload outcome after one drop; inspect listChildren and upload UI without retrying');
}

// Folder snapshot transport: observed Drive initial HTML data, not a private API guess.
const DRIVE_ID=/^[A-Za-z0-9_-]+$/;
function driveFolderURL(id,email){if(id!=='root'&&!DRIVE_ID.test(id))throw Error('Invalid folder ID');const u=new URL(id==='root'?'/drive/my-drive':'/drive/folders/'+encodeURIComponent(id),location.origin);u.searchParams.set('authuser',email);return u;}
function decodeDriveString(s){return s.replace(/\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|[\\'"/bfnrt])/g,(_,c)=>c[0]==='x'||c[0]==='u'?String.fromCharCode(parseInt(c.slice(1),16)):({b:'\b',f:'\f',n:'\n',r:'\r',t:'\t'}[c]??c));}
async function folderSnapshot(folderId,context){
 const email=context?.session?.id;if(!email)throw Error('Select a Drive account first');
 const u=driveFolderURL(folderId,email);const r=await fetch(u,{credentials:'include',cache:'no-store'});if(!r.ok)throw Error('Folder snapshot HTTP '+r.status);if(new URL(r.url).origin!==location.origin||new URL(r.url).pathname.replace(/^\/drive\/u\/\d+\//,'/drive/')!==u.pathname)throw Error('Folder navigation redirected; no account fallback');
 const doc=new DOMParser().parseFromString(await r.text(),'text/html');
 const labels=[...doc.querySelectorAll('[aria-label]')].map(e=>e.getAttribute('aria-label')||'');
 const label=labels.find(s=>s.startsWith('Google Account:'))||'';const actual=label.match(/\(([^)]+@[^)]+)\)/)?.[1]?.trim();
 if(!actual||actual.toLowerCase()!==email.toLowerCase())throw Error('Fetched folder account mismatch or unavailable; no fallback');
 const script=[...doc.scripts].find(s=>s.textContent.includes("window['_DRIVE_ivd'] ="));
 const match=script?.textContent.match(/window\['_DRIVE_ivd'\]\s*=\s*'((?:\\.|[^'\\])*)'/);
 if(!match)throw Error('Folder bootstrap unavailable; missing resource or unsupported response');
 const data=JSON.parse(decodeDriveString(match[1]));if(!Array.isArray(data))throw Error('Unrecognized folder bootstrap');
 let raw=data[0];if(raw===null){if(!/Drop files here|No items|No files/.test(doc.body.textContent))throw Error('Empty folder readiness not established');raw=[];}
 if(!Array.isArray(raw))throw Error('Unrecognized child list');
 const items=raw.map(x=>{if(!Array.isArray(x)||typeof x[0]!=='string'||typeof x[2]!=='string'||typeof x[3]!=='string'||!Array.isArray(x[1])||!x[1].every(p=>typeof p==='string'))throw Error('Unrecognized child metadata');if(folderId!=='root'&&!x[1].includes(folderId))throw Error('Unexpected child parent; refusing cross-folder results');return {id:x[0],name:x[2],mimeType:x[3],parentIds:x[1],url:'https://drive.google.com/'+(x[3]==='application/vnd.google-apps.folder'?'drive/folders/':'file/d/')+encodeURIComponent(x[0])+(x[3]==='application/vnd.google-apps.folder'?'':'/view')+'?authuser='+encodeURIComponent(email)};});
 const canonical=JSON.stringify({accountId:email,folderId,items:[...items].sort((a,b)=>a.id.localeCompare(b.id))});
 const snapshot=[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(canonical)))].map(x=>x.toString(16).padStart(2,'0')).join('');
 return {items,nextCursor:null,coverage:'partial',completenessReason:'Initial server HTML snapshot only; server pagination and exhaustive completeness are unverified. No continuation exposed.',folderId,accountId:email,snapshot};
}
const driveVisible=e=>!!e.getClientRects().length;
function driveClick(e){if(!e)throw Error('Expected unique Drive control unavailable');for(const type of ['mousedown','mouseup','click'])e.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,view:window,button:0}));}
async function driveWait(find,message,ms=12000){const end=Date.now()+ms;while(Date.now()<end){const v=find();if(v)return v;await new Promise(r=>setTimeout(r,150));}throw Error(message);}
async function createDriveFolder(args,context){
 const target=driveFolderURL(args.parentId,context.session.id);if(location.pathname.replace(/^\/drive\/u\/\d+\//,'/drive/')!==target.pathname)throw Error('Parent page mismatch: route pageUrl to the requested parent with selected authuser');
 if(args.name.trim()!==args.name||/[\u0000-\u001f]/.test(args.name))throw Error('Folder name must be nonblank, exact, and contain no control characters');
 const before=await folderSnapshot(args.parentId,context);if(before.snapshot!==args.expectedParentSnapshot)throw Error('Conflict: parent snapshot changed; nothing submitted');if(before.items.some(i=>i.name===args.name))throw Error('Conflict: same-name child observed; nothing submitted');
 if([...document.querySelectorAll('[role="dialog"]')].some(driveVisible))throw Error('Unexpected existing dialog; nothing submitted');
 const buttons=[...document.querySelectorAll('button')].filter(e=>e.innerText.trim()==='New'&&driveVisible(e));if(buttons.length!==1)throw Error('New control ambiguous');driveClick(buttons[0]);
 const menu=await driveWait(()=>[...document.querySelectorAll('[role="menuitem"]')].find(e=>e.innerText.startsWith('New folder')&&driveVisible(e)),'New folder menu unavailable');driveClick(menu);
 const dialog=await driveWait(()=>[...document.querySelectorAll('[role="dialog"]')].find(e=>driveVisible(e)&&e.querySelector('input[aria-label="New folder"]')),'New folder dialog unavailable');
 const input=dialog.querySelector('input[aria-label="New folder"]');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,args.name);input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));
 await assertSelectedAccount(context);const latest=await folderSnapshot(args.parentId,context);if(latest.snapshot!==before.snapshot)throw Error('Conflict before submit: parent snapshot changed; nothing submitted');
 const create=[...dialog.querySelectorAll('button')].filter(e=>e.innerText.trim()==='Create');if(create.length!==1||create[0].disabled)throw Error('Create control unavailable');driveClick(create[0]);
 const end=Date.now()+25000;while(Date.now()<end){const after=await folderSnapshot(args.parentId,context);const added=after.items.filter(i=>i.name===args.name&&!before.items.some(b=>b.id===i.id));if(added.length===1)return {item:added[0],accountId:after.accountId,conflictGuarantee:'bestEffortNotAtomic'};if(added.length>1)throw Error('Uncertain outcome: multiple new same-name folders; inspect without retrying');await new Promise(r=>setTimeout(r,300));}
 throw Error('Uncertain create outcome after single submit; inspect listChildren before any retry');
}

const ACCOUNTS_URL='https://accounts.google.com/ListAccounts?gpsia=1&source=Ox&json=standard';
async function accountFetch(url,options){
 if(location.pathname==='/_/og/bscframe') return fetch(url,options);
 const end=Date.now()+12000;
 while(Date.now()<end){const f=[...document.querySelectorAll('iframe')].find(e=>e.src.startsWith(location.origin+'/_/og/bscframe'));if(f?.contentDocument?.readyState==='complete')return f.contentWindow.fetch(url,options);await new Promise(r=>setTimeout(r,150));}
 throw Error('Google Drive account discovery frame unavailable');
}
    const decodeListAccountsPayload = (text) => {
        const trimmed = text.trim();
        if (trimmed.startsWith("["))
            return trimmed;
        const match = trimmed.match(/postMessage\('((?:\\.|[^'])*)'/);
        if (!match)
            throw new Error("Google account list response was not recognized");
        return match[1]
            .replace(/\\x([0-9a-f]{2})/gi, (_, value) => String.fromCharCode(Number.parseInt(value, 16)))
            .replace(/\\u([0-9a-f]{4})/gi, (_, value) => String.fromCharCode(Number.parseInt(value, 16)))
            .replace(/\\\//g, "/")
            .replace(/\\'/g, "'")
            .replace(/\\\\/g, "\\");
    };
    const availableAccounts = async () => {
        const response = await accountFetch(ACCOUNTS_URL, { credentials: "include" });
        if (!response.ok)
            throw new Error(`Google account list: HTTP ${response.status}`);
        const payload = JSON.parse(decodeListAccountsPayload(await response.text()));
        if (!Array.isArray(payload) || !Array.isArray(payload[1])) {
            throw new Error("Google account list response was invalid");
        }
        if (payload[1].some(entry => !Array.isArray(entry)
            || typeof entry[3] !== "string" || !entry[3].includes("@")
            || ![0, 1, false, true].includes(entry[9])))
            throw new Error("Google account authentication state was not recognized");
        const accounts = payload[1]
            .filter((entry) => Array.isArray(entry)
            && typeof entry[3] === "string"
            && entry[3].includes("@")
            && (entry[9] === 1 || entry[9] === true)
            && entry[14] !== 1
            && entry[14] !== true)
            .map((entry, index) => ({
            accountId: String(entry[3]),
            email: String(entry[3]),
            primary: index === 0,
        }));
        console.log(`listAccounts accounts=${accounts.length}`);
        return accounts;
    };

async function discoverAuthenticatedSessions(){return (await availableAccounts()).map(a=>({id:a.email,label:a.email,url:'https://drive.google.com/drive/my-drive?authuser='+encodeURIComponent(a.email)}));}
async function assertSelectedAccount(context){
 if(!context?.session)throw Error('Select a Drive account first');
 const end=Date.now()+12000;
 while(Date.now()<end){const el=[...document.querySelectorAll('[aria-label]')].find(e=>(e.getAttribute('aria-label')||'').includes('Google Account:'));const label=el?.getAttribute('aria-label')||'';const match=label.match(/\(([^)]+@[^)]+)\)/);if(match){if(match[1].trim().toLowerCase()!==context.session.id.toLowerCase())throw Error('Actual Drive account does not match selected session');return;}await new Promise(r=>setTimeout(r,150));}
 throw Error('Actual Drive account identity unavailable');
}
(() => {
  const clean = v => String(v ?? "").replace(/\s+/g, " ").trim();
  const sleep = ms => new Promise(resolve => window.setTimeout(resolve, ms));
  const kindFromLabel = label => {
    const s = clean(label).replace(/ Shared$/, "");
    const kinds = ["Google Docs","Google Sheets","Google Slides","Google Forms","Google Drawings","Folder","PDF","Video","Image","Audio","Compressed archive","Microsoft Word","Microsoft Excel","Microsoft PowerPoint"];
    return kinds.find(k => s.endsWith(" " + k)) || "File";
  };
  const nameFrom = (row, label, kind) => {
    const first = clean(row.querySelector('td[data-column-field="6"]')?.innerText || row.innerText).split(" Shared")[0];
    if (first) return first;
    const suffix = kind === "File" ? "" : " " + kind;
    return clean(label).replace(/ Shared$/, "").slice(0, Math.max(0, clean(label).replace(/ Shared$/, "").length - suffix.length));
  };
  const urlFor = (id, kind) => {
    const e = encodeURIComponent(id);
    if (kind === "Folder") return "https://drive.google.com/drive/folders/" + e;
    if (kind === "Google Docs") return "https://docs.google.com/document/d/" + e + "/edit";
    if (kind === "Google Sheets") return "https://docs.google.com/spreadsheets/d/" + e + "/edit";
    if (kind === "Google Slides") return "https://docs.google.com/presentation/d/" + e + "/edit";
    if (kind === "Google Forms") return "https://docs.google.com/forms/d/" + e + "/edit";
    if (kind === "Google Drawings") return "https://docs.google.com/drawings/d/" + e + "/edit";
    return "https://drive.google.com/file/d/" + e + "/view";
  };
  const rows = () => [...document.querySelectorAll('[role="main"] [role="row"][data-id], [role="grid"] [role="row"][data-id], [role="main"] [role="gridcell"][data-id]')];
  const parseRow = row => {
    const id = clean(row.getAttribute("data-id"));
    if(row.getAttribute('role')==='gridcell'){
      const label=clean(row.getAttribute('aria-label')).replace(/ More info.*$/,'');
      const kind=kindFromLabel(label);
      const name=kind==='File'?clean(row.innerText).replace(/ More actions$/,''):label.replace(/ Shared$/,'').slice(0,-kind.length).trim();
      return {id,name,kind,owner:null,modified:null,size:null,shared:/\bShared\b/.test(label),url:urlFor(id,kind)};
    }
    const nameCell = row.querySelector('td[data-column-field="6"]');
    const label = clean(nameCell?.querySelector("[aria-label]")?.getAttribute("aria-label") || row.querySelector("[aria-label]")?.getAttribute("aria-label"));
    const kind = kindFromLabel(label);
    const ownerCell = row.querySelector('td[data-column-field="8"]');
    const modifiedCell = row.querySelector('td[data-column-field="5"]');
    const sizeCell = row.querySelector('td[data-column-field="3"]');
    const ownerText = clean(ownerCell?.innerText || ownerCell?.querySelector("[aria-label]")?.getAttribute("aria-label"));
    const owner = !ownerText || /^Loading owner$/i.test(ownerText) ? null : ownerText;
    const modifiedText = clean(modifiedCell?.innerText);
    const modifiedAria = clean(modifiedCell?.querySelector("[aria-label]")?.getAttribute("aria-label"));
    const sizeText = clean(sizeCell?.innerText);
    return {id, name:nameFrom(row,label,kind), kind, owner, modified:modifiedText || modifiedAria || null, size:sizeText && sizeText !== "—" ? sizeText : null, shared:/\bShared\b/.test(label + " " + clean(nameCell?.innerText)), url:urlFor(id,kind)};
  };
  const waitRows = async (allowEmpty=false) => {
    const end = Date.now() + 10000;
    while (Date.now() < end) {
      const current = rows();
      const body = clean(document.body?.innerText);
      if (current.length || (allowEmpty && /No items|No files|Drop files here|No results|None of your files or folders matched/i.test(body))) return current;
      await sleep(150);
    }
    throw new Error("Google Drive did not finish loading its file list.");
  };
  const currentSignedIn = () => !!document.querySelector('[role="main"], a[href*="accounts.google.com/SignOutOptions"], [aria-label*="Google Account"]') && !/ServiceLogin|accounts\.google\.com\/signin/.test(location.href);
  window.ox.install(({ action: registerAction }) => {
const protectedActionIds=new Set(["searchFiles","listFiles","getFileText","listChildren","createFolder","createTextFile","createWordFile","openWordInDocs","createMarkdownFile","openMarkdownInDocs"]);
const action=(id,handler)=>registerAction(id,protectedActionIds.has(id)?{...handler,async invoke(args,context){await assertSelectedAccount(context);return handler.invoke(args,context);}}:handler);
action('listSessions',{async invoke(){return discoverAuthenticatedSessions();}});
action('login',{async invoke(){return null;}});
action('listChildren',{async invoke(args,context){const s=await folderSnapshot(args.folderId,context);const limit=args.limit||100;return {...s,items:s.items.slice(0,limit),completenessReason:s.completenessReason+(s.items.length>limit?' Caller limit truncates this initial snapshot.':'')};}});
action('createFolder',{async invoke(args,context){return createDriveFolder(args,context);}});
action('createTextFile',{async invoke(args,context){return createDriveTextFile(args,context);}});
action('createWordFile',{async invoke(args,context){return createDriveWordFile(args,context);}});
action('createMarkdownFile',{async invoke(args,context){return createDriveMarkdownFile(args,context);}});
action('openMarkdownInDocs',{async invoke({fileId},context){if(!location.pathname.includes('/d/'+encodeURIComponent(fileId)+'/'))throw Error('Markdown preview mismatch');const b=await driveWait(()=>[...document.querySelectorAll('[role="button"]')].find(e=>driveVisible(e)&&e.textContent.includes('Open with Google Docs')),'Google Docs importer unavailable');await assertSelectedAccount(context);driveClick(b);return null;}});
action('openWordInDocs',{async invoke(args,context){
 if(!location.pathname.includes('/d/'+encodeURIComponent(args.fileId)+'/'))throw Error('File preview mismatch');
 const b=await driveWait(()=>[...document.querySelectorAll('[role="button"]')].find(e=>driveVisible(e)&&e.textContent.includes('Open with Google Docs')),'Google Docs opener unavailable');
 let opened='';const old=window.open;window.open=function(url){opened=String(url||'');return null;};
 try{driveClick(b);const end=Date.now()+8000;while(Date.now()<end&&!opened)await new Promise(r=>setTimeout(r,100));}finally{window.open=old;}
 const u=new URL(opened,location.href);if(u.hostname!=='docs.google.com'||!u.pathname.startsWith('/document/'))throw Error('Editor route unavailable after opener; inspect without replay');return {url:u.href};
}});
    action("getFileText", {async invoke(args){
      if(!location.pathname.includes('/d/'+encodeURIComponent(args.fileId)+'/'))throw Error('File preview does not match requested ID');
      const end=Date.now()+15000;let previous='',stableSince=0;
      while(Date.now()<end){const el=document.querySelector('[role="document"]');const text=el?.innerText||'';if(text&&text===previous&&Date.now()-stableSince>1200)return {text,title:document.title};if(text!==previous){previous=text;stableSince=Date.now();}await sleep(200);}
      throw Error('File preview text unavailable or incomplete');
    }});
    action("listFiles", { async invoke(args) { if(!/^\/drive\/(?:u\/\d+\/)?my-drive$/.test(location.pathname)) throw Error("Expected My Drive root"); const list=await waitRows(true); return {items:list.slice(0,args.limit||100).map(parseRow),nextCursor:null}; } });
    action("searchFiles", { async invoke(args) { if(!/^\/drive\/(?:u\/\d+\/)?search$/.test(location.pathname)||new URL(location.href).searchParams.get("q")!==args.query)throw Error("Search page mismatch: supply pageUrl with /drive/search?q= the exact query and selected authuser; refusing stale rows"); const limit=Math.max(1,Math.min(100,args.limit||50)); const list=await waitRows(true); return {items:list.slice(0,limit).map(parseRow),nextCursor:null}; } });
  });
})();
