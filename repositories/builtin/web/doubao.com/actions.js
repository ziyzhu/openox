let lastSubmissionEvents=[];
const norm = s => String(s ?? '').replace(/\s+/g, ' ').trim();
const visible = e => !!e && e.getClientRects().length > 0;
const sel = test => '[data-testid="' + test + '"]';
const editor = () => Array.from(document.querySelectorAll('.tiptap[contenteditable="true"]')).find(visible);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const draftText = () => editor()?.editor?.view?.state?.doc?.textContent ?? editor()?.textContent ?? '';
async function wait(check, ms=7000, label='interface') { const end=Date.now()+ms; do { const v=check();if(v)return v;await sleep(120); }while(Date.now()<end);throw new Error('Doubao '+label+' not ready; no automatic retry.'); }
const currentRef = () => location.pathname.match(/^\/chat\/(\d+)\/?$/)?.[1] || '';
const blankRoute = () => /^\/chat\/?$/.test(location.pathname);
function messages(){return Array.from(document.querySelectorAll(sel('send_message')+','+sel('receive_message'))).filter(visible).map(e=>({role:e.getAttribute('data-testid')==='send_message'?'user':'assistant',text:Array.from(e.querySelectorAll(sel('message_text_content'))).map(x=>(x.innerText||x.textContent||'').trim()).join('\n\n')})).filter(x=>x.text);}
function recent(){return Array.from(document.querySelectorAll(sel('conversation-list-v2-item'))).map(e=>({element:e,title:norm(e.children[1]?.innerText||e.children[1]?.textContent),conversationRef:e.getAttribute('data-conversation-id')||''})).filter(x=>x.title&&x.conversationRef);}
async function ready(){await wait(()=>editor(),6000,'editor');if(!blankRoute()&&!currentRef())throw Error('Unsupported Doubao route.');if(currentRef())await wait(()=>messages().length>0,6000,'conversation messages');}
function assertEmpty(){const e=editor();if(!e)throw Error('Composer unavailable.');if(norm(draftText()))throw Error('Existing draft: refusing to overwrite or discard it.');}
async function signInState(){
 const ctrl=new AbortController();const timer=setTimeout(()=>ctrl.abort(),8000);
 try{
  const r=await fetch('/chat/',{credentials:'include',cache:'no-store',signal:ctrl.signal});
  const u=new URL(r.url);if(r.status!==200||u.origin!==location.origin||u.pathname!='/chat/'||!r.headers.get('content-type')?.includes('text/html'))throw Error('Unexpected session response.');
  const d=new DOMParser().parseFromString(await r.text(),'text/html');
  const prefix='window._ROUTER_DATA = ';
  const scripts=Array.from(d.scripts).filter(s=>s.textContent.startsWith(prefix));
  if(scripts.length!==1)throw Error('Session response schema changed.');
  const b=JSON.parse(scripts[0].textContent.slice(prefix.length).trim().replace(/;$/,''));
  const c=b?.loaderData?.chat_layout?.chat_layout;const a=c?.accountInfo;const s=c?.userSetting;
  // Observed fresh server responses: anonymous account error/id=0 and setting code 671000007;
  // signed in: account success, nonvisitor string ID, setting code 0 and is_login=true.
  if(a?.message==='error'&&a?.data?.user_id===0&&String(s?.code)==='671000007')return {signedIn:false};
  if(a?.message==='success'&&a?.data?.is_visitor_account===false&&typeof a?.data?.user_id_str==='string'&&a.data.user_id_str.length>0&&s?.code===0&&s?.data?.is_login===true)return {signedIn:true};
  throw Error('Unclassified Doubao session response.');
 }finally{clearTimeout(timer);}
}
async function open(title){await ready();assertEmpty();const matches=recent().filter(x=>x.title===norm(title));if(matches.length!==1)throw Error(matches.length?'Ambiguous title in loaded sidebar.':'Title not found in loaded sidebar; older unloaded chats unsupported.');const target=matches[0];if(currentRef()===target.conversationRef)return {url:location.href,conversationRef:currentRef()};const old=document.querySelector(sel('message-list'));const before=JSON.stringify(messages());target.element.click();await wait(()=>currentRef()===target.conversationRef&&editor()&&messages().length>0&&document.querySelector(sel('message-list'))&&(document.querySelector(sel('message-list'))!==old||JSON.stringify(messages())!==before),10000,'target conversation');return {url:location.href,conversationRef:currentRef()};}
async function send(message,ref){
 if(!norm(message))throw Error('Message must contain text.');await ready();assertEmpty();
 if(ref!==null&&(!ref||currentRef()!==ref))throw Error('Stale conversationRef; reopen or read current chat first.');
 if(ref===null&&!blankRoute()){const previousEditor=editor();const previousView=previousEditor?.editor?.view;const button=document.querySelector(sel('create_conversation_button')+' > div');if(!button)throw Error('New-chat control unavailable.');button.click();await wait(()=>blankRoute()&&editor()&&messages().length===0&&(editor()!==previousEditor||editor()?.editor?.view!==previousView),6000,'new chat editor');assertEmpty();}
 await wait(()=>editor()?.editor?.isInitialized===true&&editor()?.editor?.view?.dom===editor()&&editor()?.editor?.view?.editable,3000,'live editor');
 const route=location.pathname;const before=messages();const e=editor();const view=e.editor?.view;if(!view||view.dom!==e||!view.editable)throw Error('Live editor view unavailable; not submitted.');
 view.dispatch(view.state.tr.insertText(message));
 await wait(()=>norm(draftText())===norm(message)&&norm(editor()?.textContent)===norm(message),2000,'draft');
 const settleDeadline=Date.now()+3500;let stableAt=Date.now();while(Date.now()<settleDeadline){if(editor()!==e||e.editor.state!==view.state||norm(draftText())!==norm(message)){stableAt=Date.now();}if(Date.now()-stableAt>=1000)break;await sleep(100);}if(editor()!==e||e.editor.state!==view.state||norm(draftText())!==norm(message))throw Error('Editor state changed; not submitted.');
 const button=await wait(()=>{const b=document.querySelector(sel('chat_input_send_button'));return visible(b)&&!b.disabled&&b.getAttribute('data-disabled')!=='true'?b:null;},2500,'send control');
 if(location.pathname!==route)throw Error('Conversation changed before submission; draft not sent.');
 lastSubmissionEvents=[];const originalFetch=window.fetch;const originalOpen=XMLHttpRequest.prototype.open;const originalSend=XMLHttpRequest.prototype.send;const tracked=new WeakMap();const add=(method,url,status)=>{try{const u=new URL(url,location.href);if(u.origin===location.origin&&lastSubmissionEvents.length<30)lastSubmissionEvents.push({method:String(method),path:u.pathname.replace(/\d{8,}/g,'<id>'),status:Number(status)||0});}catch{}};window.fetch=function(...args){const request=args[0];const method=args[1]?.method||request?.method||'GET';const url=typeof request==='string'?request:request?.url;return originalFetch.apply(this,args).then(r=>{add(method,url,r.status);return r;});};XMLHttpRequest.prototype.open=function(method,url,...rest){tracked.set(this,{method,url});return originalOpen.call(this,method,url,...rest);};XMLHttpRequest.prototype.send=function(...args){const t=tracked.get(this);if(t)this.addEventListener('loadend',()=>add(t.method,t.url,this.status),{once:true});return originalSend.apply(this,args);};
 try{
 button.click(); // Exactly once. All following work is read-only.
 const deadline=Date.now()+12000;let confirmed=false;let response='';let last='';let stableSince=Date.now();
 while(Date.now()<deadline){
  const now=messages();const users=now.filter(x=>x.role==='user');const oldUsers=before.filter(x=>x.role==='user');
  confirmed=users.length>oldUsers.length&&norm(users[users.length-1]?.text)===norm(message);
  if(confirmed){const lastUser=now.map(x=>x.role).lastIndexOf('user');response=now.slice(lastUser+1).filter(x=>x.role==='assistant').map(x=>x.text).join('\n\n');}
  if(response!==last){last=response;stableSince=Date.now();}
  if(confirmed&&response&&Date.now()-stableSince>1200)break;
  await sleep(180);
 }
 return {url:location.href,conversationRef:currentRef(),response,status:response?'reply_observed':'pending',submissionConfirmed:confirmed};
 }finally{window.fetch=originalFetch;XMLHttpRequest.prototype.open=originalOpen;XMLHttpRequest.prototype.send=originalSend;}
}

async function searchChats({query}){
 if(!norm(query))throw Error('Search query must not be blank');await ready();assertEmpty();
 const originalOpen=XMLHttpRequest.prototype.open,originalSend=XMLHttpRequest.prototype.send;const tracked=new WeakSet();let result,error;
 XMLHttpRequest.prototype.open=function(method,url,...rest){if(String(url).includes('/alice/search/query'))tracked.add(this);return originalOpen.call(this,method,url,...rest);};
 XMLHttpRequest.prototype.send=function(body){if(tracked.has(this)&&typeof body==='string'){let request;try{request=JSON.parse(body);}catch{}if(request?.query===query)this.addEventListener('load',()=>{try{const j=JSON.parse(this.responseText);if(this.status!==200||j.code!==0||!Array.isArray(j.data?.search_result))throw Error('Doubao search failed');const d=j.data.search_result.find(x=>x.domain_key==='message');if(!d||d.err_code!==0||!Array.isArray(d.items)||typeof d.has_more!=='boolean')throw Error('Unexpected message search response');if(d.has_more)throw Error('Doubao returned additional message results; continuation is not verified. Narrow the query.');const rows=d.items.map(x=>{const parsed=JSON.parse(x.content),m=parsed?.flow_message_search_result;if(!m||typeof m.ConvMeta?.ConversationID!=='string'||typeof m.ConvMeta.Name!=='string')throw Error('Unsupported Doubao search result shape: '+Object.keys(parsed).join(',')+' meta='+Object.keys(m?.ConvMeta||{}).join(','));return {id:m.ConvMeta.ConversationID,title:m.ConvMeta.Name,url:'https://www.doubao.com/chat/'+encodeURIComponent(m.ConvMeta.ConversationID)};});result={items:[...new Map(rows.map(x=>[x.id,x])).values()],nextCursor:null,scope:'message-content'};}catch(e){error=e;}},{once:true});}return originalSend.call(this,body);};
 try{let input=document.querySelector('input[placeholder="搜索"]');if(!input){const b=await wait(()=>document.querySelector(sel('global-search-icon-entry')),6000,'search control');b.click();input=await wait(()=>document.querySelector('input[placeholder="搜索"]'),5000,'search input');}
 const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;if(input.value===query){setter.call(input,'');input.dispatchEvent(new Event('input',{bubbles:true}));await sleep(350);}setter.call(input,query);input.dispatchEvent(new Event('input',{bubbles:true}));await wait(()=>input.value===query,1000,'search query');await sleep(500);input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));await wait(()=>result||error,12000,'history search response');if(error)throw error;return result;
 }finally{XMLHttpRequest.prototype.open=originalOpen;XMLHttpRequest.prototype.send=originalSend;}
}

window.ox.install(({action})=>{
 action('searchConversations',{invoke:searchChats});
 action('getSignInUrl',{async invoke(){return {url:'https://www.doubao.com/chat/'};}});
 action('getSignInState',{async invoke(){return await signInState();}});
 action('getCurrentConversation',{async invoke({limit=50}){await ready();const all=messages();const animationFrameObserved=await new Promise(resolve=>{let done=false;const timer=setTimeout(()=>{if(!done){done=true;resolve(false);}},600);requestAnimationFrame(()=>{if(!done){done=true;clearTimeout(timer);resolve(true);}});});return {lastSubmissionEvents:lastSubmissionEvents.slice(),url:location.href,conversationRef:currentRef(),messages:all.slice(-limit),renderedOnly:true,truncated:all.length>limit,interfaceState:{animationFrameObserved,editorStateSynchronized:editor()?.editor?.state===editor()?.editor?.view?.state,editorCount:document.querySelectorAll('.tiptap[contenteditable="true"]').length,draftLength:editor()?.innerText?.length||0,docLength:editor()?.editor?.view?.state?.doc?.textContent?.length||0,editorInitialized:editor()?.editor?.isInitialized===true,sameView:editor()?.editor?.view?.dom===editor()},recentConversations:recent().slice(0,100).map(({title,conversationRef})=>({title,conversationRef}))};}});
 action('openConversation',{async invoke({title}){return await open(title);}});
 action('diagnoseComposer',{async invoke(){await ready();assertEmpty();await wait(()=>editor()?.editor?.isInitialized,3000,'initialized editor');const e=editor();const v=e.editor.view;const text='OX unsent composer diagnostic';let result;try{v.dispatch(v.state.tr.insertText(text));await wait(()=>draftText()===text,2500,'diagnostic draft');await sleep(1000);const bs=Array.from(document.querySelectorAll(sel('chat_input_send_button')));const b=bs.find(visible);const key=b&&Object.keys(b).find(k=>k.startsWith('__reactProps'));result={draftAccepted:draftText()===text,draftCleared:false,editorStateSynchronized:e.editor.state===v.state,buttonCount:bs.length,sendHandlerPresent:!!key&&typeof b[key].onClick==='function',sendEnabled:!!b&&!b.disabled&&b.getAttribute('data-disabled')!=='true',buttonConnected:!!b?.isConnected};}finally{if(editor()===e&&v.state.doc.textContent===text){v.dispatch(v.state.tr.delete(0,v.state.doc.content.size));}}if(!result)throw Error('Diagnostic failed; check draft before proceeding.');result.draftCleared=!draftText();return result;}});
 action('chat',{async invoke({message}){return await send(message,null);}});
 action('continueChat',{async invoke({conversationRef,message}){return await send(message,conversationRef);}});
});
