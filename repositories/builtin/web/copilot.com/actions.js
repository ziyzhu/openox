async function readSession() {
  const r = await fetch('/', {credentials:'include',cache:'no-store',signal:AbortSignal.timeout(10000)});
  if(r.status!==200 || new URL(r.url).origin!==location.origin || new URL(r.url).pathname!=='/') throw new Error('Unexpected Copilot session response');
  const text=await r.text();
  const m=text.match(/window\.__staticRouterHydrationData\s*=\s*JSON\.parse\(("(?:\\.|[^"\\])*")\)/);
  if(m){
    const data=JSON.parse(JSON.parse(m[1]));
    const a=data?.loaderData?.root?.store?.accountInfo;
    if(a?.accountType==='MSA' && typeof a.objectId==='string' && a.objectId.length>0 && Array.isArray(a.signInState) && a.signInState.includes('kmsi')) return {signedIn:true,account:a};
    throw new Error('Unrecognized Copilot account state');
  }
  if(/id="unauthConfig"/.test(text) && text.includes('<title>Microsoft Copilot | Sign in</title>')) return {signedIn:false};
  throw new Error('Unrecognized Copilot session page');
}

const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn,ms=6500){const end=Date.now()+ms;do{const v=fn();if(v)return v;await pause(120)}while(Date.now()<end);throw Error('Copilot interface not ready');}
const editor=()=>document.querySelector('[contenteditable][aria-label="Message Copilot"]');
function text(e){if(!e)return '';const c=e.cloneNode(true);c.querySelectorAll('[aria-hidden=true],button,[role=button]').forEach(n=>n.remove());return c.textContent.trim();}
function draft(){return text(editor());}
function ref(){const m=location.pathname.match(/^\/chat\/conversation\/([^/]+)$/);return m?m[1]:null;}
function readChat(){const messages=[];for(const e of document.querySelectorAll('[data-testid="m365-chat-llm-web-ui-chat-message"]')){const q=e.querySelector('[data-testid=chatQuestion] [data-testid=chatOutput]')||e.querySelector('[data-testid=chatQuestion]');const a=e.querySelector('[data-testid=markdown-reply]');if(q)messages.push({role:'user',text:text(q).replace(/^You said:\s*/,'')});if(a){const s=text(a).replace(/^Copilot said:\s*/,'');if(s)messages.push({role:'assistant',text:s});}}return {conversationId:ref(),url:location.origin+location.pathname,messages:messages.slice(-100),generating:!!document.querySelector('button[aria-label="Stop generating"]'),coverage:'Rendered messages only; at most 100.'};}
async function ready(){await until(()=>editor());}
async function sidebar(){await ready();const b=document.querySelector('button[aria-label="Expand sidebar"],button[aria-label="Expand navigation"]');if(b)b.click();await until(()=>document.querySelector('a[aria-label="Search chats"]'));}
function links(){return [...document.querySelectorAll('a[href*="/chat/conversation/"]')].filter(e=>new URL(e.href).origin===location.origin);}
async function openChat(id){await ready();if(ref()===id){await until(()=>text(document.querySelector('[data-testid=markdown-reply]')));return;}if(draft())throw Error('Unsent draft: navigation refused');const old=document.querySelector('[data-testid=chatQuestion]');history.pushState(null,'','/chat/conversation/'+encodeURIComponent(id));window.dispatchEvent(new PopStateEvent('popstate',{state:history.state}));await until(()=>ref()===id&&(!old||!old.isConnected)&&text(document.querySelector('[data-testid=markdown-reply]')),10000);}
const modes=['Auto','Quick response','Think deeper'];
async function modeMenu(){await ready();const b=await until(()=>[...document.querySelectorAll('button')].find(e=>modes.includes(e.textContent.trim())));const selected=b.textContent.trim();b.click();await until(()=>document.querySelector('[role=menuitem]'));return selected;}
async function send(message){await ready();if(draft())throw Error('Unsent draft: refusing to replace it');const before=readChat();if(before.generating||before.messages.length>=98)throw Error('Busy or rendered message limit reached');const e=editor();e.focus();if(!document.execCommand('insertText',false,message))throw Error('Draft insertion failed');await until(()=>draft()===message.trim()&&!e.__lexicalEditor?._pendingEditorState&&!e.__lexicalEditor?._updating);await pause(800);if(draft()!==message.trim()||e.__lexicalEditor?._pendingEditorState)throw Error('Editor state changed before submission');const b=await until(()=>{const x=document.querySelector('button[aria-label=Send]');return x&&!x.disabled?x:null});b.click();const end=Date.now()+12000;let current;while(Date.now()<end){await pause(250);current=readChat();const fresh=current.messages.slice(before.messages.length);if(fresh.some(x=>x.role==='user'&&x.text===message.trim())&&fresh.some(x=>x.role==='assistant')&&!current.generating)return {submissionConfirmed:true,status:'completed',conversation:current};}current=readChat();return {submissionConfirmed:current.messages.slice(before.messages.length).some(x=>x.role==='user'&&x.text===message.trim()),status:'pending',conversation:current};}


let searchWaiter=null;
const originalSearchFetch=window.fetch;
window.fetch=async function(...args){
  let wanted=null;try{const url=typeof args[0]==='string'?args[0]:args[0]?.url;if(searchWaiter&&url&&new URL(url,location.href).pathname==='/searchservice/api/v2/query'){const body=typeof args[1]?.body==='string'?JSON.parse(args[1].body):null;const request=body?.EntityRequests?.[0];if(request?.Query?.DisplayQueryString===searchWaiter.query&&request.From===0)wanted=searchWaiter;}}catch{}
  const response=await originalSearchFetch.apply(this,args);
  if(wanted)response.clone().json().then(j=>{if(!response.ok)throw Error('Copilot search HTTP '+response.status);if(!Array.isArray(j.EntitySets))throw Error('Unexpected search response');const items=[];let total=0;for(const set of j.EntitySets){if(set.IsPartial)throw Error('Copilot returned partial search results');for(const rs of set.ResultSets||[]){if(rs.MoreResultsAvailable)throw Error('Copilot search has additional pages; continuation is not yet supported. Narrow the query.');const rows=rs.Results===undefined&&rs.Total===0&&rs.MoreResultsAvailable===false?[]:rs.Results;if(!Array.isArray(rows)||typeof rs.Total!=='number'||typeof rs.MoreResultsAvailable!=='boolean')throw Error('Unexpected search result set');total+=rs.Total;for(const result of rows){const ext=result.Source?.Extensions;const id=ext?.SkypeSpaces_ConversationPost_Extension_CopilotConversationId;const title=ext?.SkypeSpaces_ConversationPost_Extension_UpdatedTopic||ext?.SkypeSpaces_ConversationPost_Extension_Topic;if(typeof id!=='string'||typeof title!=='string')throw Error('Unsupported conversation result type');items.push({conversationId:id,title,url:'https://copilot.com/chat/conversation/'+encodeURIComponent(id)});}}}wanted.result={items:[...new Map(items.map(x=>[x.conversationId,x])).values()],nextCursor:null,total};}).catch(e=>{wanted.error=String(e.message||e)});
  return response;
};
async function searchChats(query){if(!query.trim())throw Error('Search query must not be blank');const e=await until(()=>document.querySelector('input[placeholder="Search chats"]'),10000);const set=v=>{Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,v);e.dispatchEvent(new Event('input',{bubbles:true}));};if(e.value){set('');await pause(600);}const w={query};searchWaiter=w;try{e.focus();set(query);await until(()=>w.result||w.error,14000);if(w.error)throw Error(w.error);return w.result;}finally{if(searchWaiter===w)searchWaiter=null;}}

window.ox.install(({action})=>{
 action('searchConversations',{async invoke({query}){return searchChats(query);}});
  action('getCurrentConversation',{async invoke(){await ready();if(ref())await until(()=>text(document.querySelector('[data-testid=markdown-reply]')));return readChat();}});
  action('getRecentConversations',{async invoke(){await until(()=>document.querySelector('[role=row]')||[...document.querySelectorAll('h1,h2,h3')].some(e=>e.textContent==="You don't have any chats yet"),10000);const n=document.querySelector('[role=row]');if(!n)return {items:[],coverage:'Loaded history view only; no pagination.'};let f=n[Object.keys(n).find(k=>k.startsWith('__reactFiber'))];for(let i=0;f&&i<18;i++,f=f.return){const xs=f.memoizedProps?.items;if(Array.isArray(xs)&&xs.some(x=>x.chat?.conversationId)){return {items:xs.filter(x=>x.chat?.conversationId).slice(0,60).map(({chat:c})=>({conversationId:c.conversationId,title:c.title,url:location.origin+'/chat/conversation/'+encodeURIComponent(c.conversationId)})),coverage:'Loaded history view only, at most 60; no full-history pagination.'};}}throw Error('History row schema unavailable');}});
  action('openConversation',{async invoke({conversationId}){await openChat(conversationId);return readChat();}});
  action('getResponseModes',{async invoke(){const selected=await modeMenu();const items=[...document.querySelectorAll('[role=menuitem]')].map(e=>modes.find(m=>e.textContent.trim().startsWith(m))).filter(Boolean);document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return {items,selected};}});
  action('selectResponseMode',{async invoke({mode}){await modeMenu();const item=[...document.querySelectorAll('[role=menuitem]')].find(e=>e.textContent.trim().startsWith(mode));if(!item)throw Error('Mode unavailable');item.click();await until(()=>[...document.querySelectorAll('button')].some(e=>e.textContent.trim()===mode));return {selected:mode};}});
  action('chat',{async invoke({message}){await ready();if(draft())throw Error('Unsent draft: refusing new chat');if(ref()||readChat().messages.length){await sidebar();document.querySelector('a[aria-label="New chat"]').click();await until(()=>location.pathname==='/chat'&&!document.querySelector('[data-testid=chatQuestion]'));}return send(message);}});
  action('continueChat',{async invoke({conversationId,message}){await openChat(conversationId);return send(message);}});

  action('getSignInUrl',{async invoke(){return {url:'https://copilot.com/'};}});
  action('getSignInState',{async invoke(){return {signedIn:(await readSession()).signedIn};}});
  action('getCurrentUser',{async invoke(){const s=await readSession();if(!s.signedIn)throw new Error('Sign in to Copilot first');const a=s.account;return {name:typeof a.userName==='string'?a.userName:'',email:typeof a.accountUpn==='string'?a.accountUpn:'',accountType:a.accountType};}});
});
