async function readAdmin(path, signedOutOK=false){
 const r=await fetch('/admin/api/'+path,{credentials:'include',cache:'no-store'});
 const u=new URL(r.url);if(u.pathname==='/login'||r.status===401){if(signedOutOK)return null;throw Error('Tailscale sign-in required');}
 if(!r.ok)throw Error('Tailscale '+path+' HTTP '+r.status);
 const ct=r.headers.get('content-type')||'';if(!ct.includes('json'))throw Error('Tailscale '+path+' expected JSON');
 const j=await r.json();if(j.status!=='success'||!j.data)throw Error('Tailscale '+path+' returned an unexpected envelope');return j.data;
}
async function identity(){const s=await readAdmin('self',true);if(!s)return null;const t=await readAdmin('self/tailnets');const current=t.tailnets?.find(x=>x.tailnetID===t.currentTailnetID);if(!s.user?.id||!s.user.loginName||!current?.tailnetName)throw Error('Tailscale identity or current tailnet missing');return {s,t,current,id:s.user.id+':'+t.currentTailnetID};}
async function discoverAuthenticatedSessions(){const i=await identity();return i?[{id:i.id,label:i.s.user.loginName+' — '+i.current.tailnetName,url:'https://login.tailscale.com/admin/api/self'}]:[];}
async function assertSelectedAccount(context){const i=await identity();if(!i||!context?.session||i.id!==context.session.id)throw Error('Selected Tailscale account or tailnet changed');return i;}
const text=v=>typeof v==='string'?v:null;
function strings(v){if(v===undefined||v===null)return [];if(!Array.isArray(v)||v.some(x=>typeof x!=='string'))throw Error('Unexpected Tailscale address/tag contract');return v;}
function device(m){if(typeof m.id!=='string'||typeof m.name!=='string')throw Error('Tailscale device identity missing');const addresses=strings(m.addresses);return {id:m.id,stableId:text(m.stableId),name:m.name,hostname:text(m.hostname),fqdn:text(m.fqdn),addresses,online:typeof m.connectedToControl==='boolean'?m.connectedToControl:(typeof m.lastSeen==='string'?false:null),lastSeen:text(m.lastSeen),tags:strings(m.allowedTags),invalidTags:strings(m.invalidTags),os:text(m.os),osVersion:text(m.osVersion),tailscaleVersion:text(m.ipnVersion),created:text(m.created),keyExpiry:text(m.expires),authorized:typeof m.authorized==='boolean'?m.authorized:null,url:addresses.length?'https://console.tailscale.com/admin/machines/'+encodeURIComponent(addresses[0]):null};}
async function machines(){const d=await readAdmin('machines');if(!Array.isArray(d.machines))throw Error('Tailscale machine collection missing');return d.machines;}
const clean = value => String(value ?? "").replace(/\s+/g, " ").trim();
window.ox.install(({ action: registerAction }) => {
const protectedActionIds=new Set(["listDevices","getDevice","getTailnet"]);
const action=(id,handler)=>registerAction(id,protectedActionIds.has(id)?{...handler,async invoke(args,context){await assertSelectedAccount(context);return handler.invoke(args,context);}}:handler);
action('listSessions',{async invoke(){return discoverAuthenticatedSessions();}});
action('login',{async invoke(){return null;}});
  action("listDocs", { async invoke({ limit = 30 } = {}) { const r=await fetch("/docs"); if(!r.ok) throw new Error("Docs request failed: "+r.status); const d=new DOMParser().parseFromString(await r.text(),"text/html"); const items=[...d.querySelectorAll("a[href]")].map(a=>({title:clean(a.textContent),url:a.href})).filter(x=>x.title&&x.url.includes("tailscale.com/docs")).slice(0,limit); return {items,nextCursor:null}; } });
  action("getDoc", { async invoke({ path }) { const r=await fetch(path); if(!r.ok) throw new Error("Docs request failed: "+r.status); const d=new DOMParser().parseFromString(await r.text(),"text/html"); return {title:clean(d.querySelector("h1")?.textContent||d.title),url:new URL(path,location.origin).href,text:clean((d.querySelector("main,article")||d.body).textContent)}; } });
  action('listDevices',{async invoke({limit=50}={}){const ms=await machines();return {items:ms.slice(0,limit).map(device),nextCursor:null,total:ms.length,truncated:ms.length>limit};}});
 action('getDevice',{async invoke({id}){const ms=await machines();const m=ms.find(x=>x.id===id);if(!m)throw Error('Tailscale device not found in selected tailnet');return device(m);}});
 action('getTailnet',{async invoke(args,context){const i=await assertSelectedAccount(context);return {id:i.t.currentTailnetID,name:i.current.tailnetName,accountId:i.s.user.id,loginName:i.s.user.loginName,isPersonal:i.t.isPersonalTailnet===true,hasAdditionalTailnets:i.t.hasAdditionalTailnets===true};}});
});
