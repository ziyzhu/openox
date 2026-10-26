const sleep = ms => new Promise(r => setTimeout(r, ms));
const clean = s => String(s || '').replace(/\s+/g, ' ').trim();
async function until(fn, label, ms=8000) { const end=Date.now()+ms; do { const value=fn(); if(value)return value; await sleep(120); }while(Date.now()<end); throw new Error(label+' not ready'); }
let moduleLoader;
async function client() {
  await until(()=>window.rspackChunk_deepseek_chat,'DeepSeek application');
  if(!moduleLoader)window.rspackChunk_deepseek_chat.push([['ox_deepseek_read_'+Date.now()],{},r=>{moduleLoader=r;}]);
  if(!moduleLoader)throw new Error('DeepSeek module loader unavailable');
  const mod=moduleLoader(54906);
  if(typeof mod.Ax!=='function')throw new Error('DeepSeek client contract changed');
  const c=mod.Ax();
  if(typeof c?.http?.http?.get!=='function')throw new Error('DeepSeek HTTP client unavailable');
  return c.http.http;
}
async function identity(){
  const c=await client();
  let timer;
  try {
    const r=await Promise.race([c.get('/api/v0/users/current'),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('DeepSeek identity request timed out')),7000);})]);
    const j=r.json;
    if(r.status===200&&j?.code===0&&j.data?.biz_code===0&&typeof j.data.biz_data?.id==='string'&&j.data.biz_data.id.length>0)return {signedIn:true};
    if(r.status===200&&j?.code===40002&&j.msg==='Missing Token')return {signedIn:false};
    throw new Error('Unrecognized DeepSeek identity response');
  }finally{clearTimeout(timer);}
}
function chatPath(){return /^\/a\/chat\/s\/[^/]+$/.test(location.pathname);}
const richInt=v=>Number.isSafeInteger(v)&&v>=0?v:null;
const richUrl=v=>{if(typeof v!=='string'||!v)return null;try{const u=new URL(v,location.origin);return ['http:','https:'].includes(u.protocol)?u.href:null;}catch{return null;}};
const richKind=m=>typeof m==='string'&&m.startsWith('image/')?'image':typeof m==='string'&&/(pdf|document|text|sheet|presentation)/i.test(m)?'document':'file';
function domFiles(e,source){const out=[];for(const i of e.querySelectorAll('img[src]')){const u=richUrl(i.currentSrc||i.src);if(!u||i.getAttribute('aria-hidden')==='true'||(i.naturalWidth&&i.naturalWidth<64))continue;out.push({id:null,name:i.alt||'',kind:'image',mimeType:null,sizeBytes:null,url:u,thumbnailUrl:null,width:richInt(i.naturalWidth),height:richInt(i.naturalHeight),pageCount:null,tokenCount:null,source,downloadable:true});}for(const x of e.querySelectorAll('a[href][download],a[href*="/file"],a[href*="download"]')){const u=richUrl(x.href);if(!u)continue;out.push({id:null,name:x.getAttribute('download')||x.textContent.trim(),kind:'file',mimeType:null,sizeBytes:null,url:u,thumbnailUrl:null,width:null,height:null,pageCount:null,tokenCount:null,source,downloadable:true});}return out;}
function fragmentFiles(m){const out=[];for(const f of (m.fragments||[])){if(!f||['REQUEST','RESPONSE','THINK'].includes(f.type))continue;const xs=[f,...(Array.isArray(f.files)?f.files:[]),...(Array.isArray(f.attachments)?f.attachments:[])];for(const x of xs){if(!x||typeof x!=='object')continue;const mime=typeof x.mime_type==='string'?x.mime_type:typeof x.mimeType==='string'?x.mimeType:null,u=richUrl(x.url)||richUrl(x.file_url)||richUrl(x.download_url)||richUrl(x.content_url);if(!u&&!x.file_id&&!x.id&&!x.filename&&!x.file_name)continue;out.push({id:String(x.file_id||x.id||x.uuid||'')||null,name:String(x.filename||x.file_name||x.name||''),kind:richKind(mime||String(x.type||f.type||'')),mimeType:mime,sizeBytes:richInt(x.size||x.size_bytes),url:u,thumbnailUrl:richUrl(x.thumbnail_url)||richUrl(x.preview_url),width:richInt(x.width),height:richInt(x.height),pageCount:richInt(x.page_count),tokenCount:richInt(x.token_count),source:m.role==='ASSISTANT'?'generated':'attachment',downloadable:!!u});}}return out;}
function messages(){return Array.from(document.querySelectorAll('.ds-message')).slice(-100).flatMap(e=>{const a=e.querySelector('.ds-assistant-message-main-content');const user=e.classList.contains('d29f3d7d');if(!a&&!user)return [];const role=a?'assistant':'user';return [{role,text:((a||e).innerText||(a||e).textContent||'').trim(),files:domFiles(e,role==='assistant'?'generated':'attachment')}];}).filter(m=>m.text||m.files.length);}
function guardDraft(){if(document.querySelector('textarea')?.value.trim())throw new Error('Existing draft must be handled before navigating or sending');}
async function read(){
 await until(()=>document.querySelector('textarea'),'DeepSeek composer');
 if(chatPath())await until(()=>document.querySelector('.ds-message'),'Conversation messages');
 return {url:location.href,messages:messages(),renderedOnly:true};
}
async function open(title){
 await until(()=>document.querySelector('a[href*="/a/chat/s/"]'),'Conversation sidebar');
 const links=Array.from(document.querySelectorAll('a[href*="/a/chat/s/"]')).filter(e=>clean(e.textContent)===clean(title));
 if(links.length!==1)throw new Error(links.length?'Conversation title is ambiguous':'Conversation is not in the loaded sidebar');
 const target=new URL(links[0].href).pathname;
 if(location.pathname!==target){
   guardDraft();
   const old=document.querySelector('.ds-message');links[0].click();
   await until(()=>location.pathname===target,'Selected conversation');
   await until(()=>document.querySelector('.ds-message')&&(!old||!old.isConnected||document.querySelector('.ds-message')!==old),'Fresh conversation messages');
 }
 return read();
}
async function fresh(){
 await until(()=>document.querySelector('textarea'),'DeepSeek composer');
 guardDraft();
 if(location.pathname==='/'&&!document.querySelector('.ds-message'))return;
 const e=document.querySelector('._7b40dad ._5a8ac7a');
 if(!e)throw new Error('New chat control unavailable');
 e.click();await until(()=>location.pathname==='/'&&!document.querySelector('.ds-message'),'Empty new chat');
}
async function send(message){
 const t=await until(()=>document.querySelector('textarea'),'Message editor');
 if(t.value.trim())throw new Error('Existing draft must be handled before sending');
 const before=messages();const prior=location.pathname;
 const setter=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set;
 setter.call(t,message);t.dispatchEvent(new Event('input',{bubbles:true}));
 await until(()=>t.value===message,'Message draft');
 const button=await until(()=>{const es=Array.from(document.querySelectorAll('[role="button"].ds-button--primary.ds-button--circle')).filter(e=>!e.classList.contains('ds-button--disabled'));return es.length===1?es[0]:null;},'Send control',4000);
 button.click();
 const deadline=Date.now()+12000;let confirmed=false,reply=null;
 while(Date.now()<deadline){
  const now=messages();
  const extra=now.slice(before.length);
  if(chatPath()&&(prior!=='/'||location.pathname!==prior)&&extra.some(m=>m.role==='user'&&m.text.trim()===message.trim()))confirmed=true;
  if(confirmed){const last=extra.filter(m=>m.role==='assistant').at(-1);if(last?.text){reply=last.text;break;}}
  await sleep(200);
 }
 const responseFiles=confirmed?(messages().filter(m=>m.role==='assistant').at(-1)?.files||[]):[];return {status:confirmed?'accepted':'pending',submissionConfirmed:confirmed,url:chatPath()?location.href:null,reply,responseFiles};
}

async function searchHistory({query,cursor}){
 if(!query.trim())throw Error('Search query must not be blank');
 const c=await client();const wrap=moduleLoader(54906).Ax().http;let raw='';
 await c.get('/api/v0/index/prepare',{context:wrap.withDefaultHttpContext({suppressToast:true}),signal:AbortSignal.timeout(7000)});
 const r=await c({method:'post',url:'/api/v0/index/query',context:wrap.withDefaultHttpContext({mayMissingApiCode:true,suppressToast:true}),json:{query,before_seq_id:cursor||null},signal:AbortSignal.timeout(18000),onDownloadProgress:e=>{raw=e.originalRequest.responseText;}});
 if(r.status!==200||!raw)throw Error('DeepSeek search stream unavailable');
 let close=null,last=cursor||null;const items=[];const nl=String.fromCharCode(10);
 const text=v=>{if(!v||!Array.isArray(v.parts)||v.parts.some(p=>typeof p.text!=='string'))throw Error('Invalid search text');return v.parts.map(p=>p.text).join('');};
 for(const block of raw.replaceAll(String.fromCharCode(13),'').split(nl+nl)){if(!block.trim())continue;const lines=block.split(nl);const event=lines.find(l=>l.startsWith('event:'))?.slice(6).trim();const data=lines.filter(l=>l.startsWith('data:')).map(l=>l.slice(5).trim()).join(nl);if(!event&&!data)continue;const j=JSON.parse(data);
 if(event==='item'){if(typeof j.chat_session_id!=='string'||typeof j.seq_id!=='string'||!['number','string'].includes(typeof j.message_id))throw Error('Invalid search result');items.push({id:j.chat_session_id,title:text(j.chat_session_title),url:'https://chat.deepseek.com/a/chat/s/'+encodeURIComponent(j.chat_session_id),messageId:String(j.message_id),excerpt:text(j.content)});last=j.seq_id;}
 else if(event==='status'){if(typeof j.queried_seq_id!=='string')throw Error('Invalid search cursor');last=j.queried_seq_id;}
 else if(event==='close')close=j.close_reason;
 }
 if(!['success','timeout'].includes(close))throw Error('DeepSeek search did not complete successfully: '+String(close));
 if(items.length>1000)throw Error('Search response exceeds safe result bound');
 const nextCursor=last==='0'?null:last;
 if(nextCursor===cursor&&nextCursor)throw Error('DeepSeek search cursor did not advance');
 if(close==='timeout'&&!nextCursor)throw Error('Search timed out without continuation');
 return {items,nextCursor,partial:close==='timeout'};
}
async function serverHistory(conversationId){const c=await client();const r=await c.get('/api/v0/chat/history_messages',{query:{chat_session_id:conversationId,cache_version:null,cache_reset_at:null},signal:AbortSignal.timeout(8000)});const j=r.json,d=j?.data?.biz_data;if(r.status!==200||j.code!==0||j.data?.biz_code!==0||d?.chat_session?.id!==conversationId||!Array.isArray(d.chat_messages)||d.cache_control!=='REPLACE')throw Error('Unexpected DeepSeek history response');const map=new Map(d.chat_messages.map(m=>[String(m.message_id),m]));let p=d.chat_session.current_message_id;const path=[],seen=new Set();while(p!=null&&path.length<100){const key=String(p),m=map.get(key);if(!m||seen.has(key))throw Error('Incomplete or cyclic message history');seen.add(key);path.unshift(m);p=m.parent_id;}return {id:conversationId,title:String(d.chat_session.title||''),url:'https://chat.deepseek.com/a/chat/s/'+encodeURIComponent(conversationId),messages:path.map(m=>{if(!['USER','ASSISTANT'].includes(m.role)||!Array.isArray(m.fragments))throw Error('Unsupported message shape');return {id:String(m.message_id),role:m.role==='USER'?'user':'assistant',text:m.fragments.filter(f=>['REQUEST','RESPONSE'].includes(f.type)&&typeof f.content==='string').map(f=>f.content).join(String.fromCharCode(10)),files:fragmentFiles(m)};}),truncated:p!=null};}

window.ox.install(({action})=>{
 action('searchConversations',{async invoke(args){return searchHistory(args);}});
 action('getConversation',{async invoke({conversationId}){return serverHistory(conversationId);}});
 action('getSignInUrl',{async invoke(){return {url:'https://chat.deepseek.com/sign_in'};}});
 action('getSignInState',{async invoke(){return identity();}});
 action('getCurrentConversation',{async invoke(){return read();}});
 action('openConversation',{async invoke(args){return open(args.title);}});
 action('chat',{async invoke(args){await fresh();return send(args.message);}});
 action('continueChat',{async invoke(args){await open(args.title);return send(args.message);}});
});
