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
const richInt=v=>Number.isSafeInteger(v)&&v>=0?v:null;
const richUrl=v=>{if(typeof v!=='string'||!v)return null;try{const u=new URL(v,location.origin);return ['http:','https:'].includes(u.protocol)?u.href:null;}catch{return null;}};
function richFiles(e,source){const out=[];for(const img of e.querySelectorAll('img[src]')){const u=richUrl(img.currentSrc||img.src);if(!u||img.getAttribute('aria-hidden')==='true'||(img.naturalWidth&&img.naturalWidth<64))continue;out.push({id:null,name:img.alt||'',kind:'image',mimeType:null,sizeBytes:null,url:u,thumbnailUrl:null,width:richInt(img.naturalWidth),height:richInt(img.naturalHeight),pageCount:null,tokenCount:null,source,downloadable:true});}for(const x of e.querySelectorAll('a[href][download],a[href*="download"],a[href*="/file"],a[href$=".pdf"],a[href$=".docx"],a[href$=".csv"],a[href$=".zip"]')){const u=richUrl(x.href);if(!u)continue;out.push({id:null,name:x.getAttribute('download')||(x.textContent||'').trim(),kind:/\.pdf(?:$|\?)/i.test(u)?'document':'file',mimeType:null,sizeBytes:null,url:u,thumbnailUrl:null,width:null,height:null,pageCount:null,tokenCount:null,source,downloadable:true});}const seen=new Set;return out.filter(f=>{if(seen.has(f.url))return false;seen.add(f.url);return true;});}
function messages(){return Array.from(document.querySelectorAll(sel('send_message')+','+sel('receive_message'))).filter(visible).map(e=>{const role=e.getAttribute('data-testid')==='send_message'?'user':'assistant';return {role,text:Array.from(e.querySelectorAll(sel('message_text_content'))).map(x=>(x.innerText||x.textContent||'').trim()).join('\n\n'),files:richFiles(e,role==='assistant'?'generated':'attachment')};}).filter(x=>x.text||x.files.length);}
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
 const deadline=Date.now()+12000;let confirmed=false;let response='';let responseFiles=[];let last='';let stableSince=Date.now();
 while(Date.now()<deadline){
  const now=messages();const users=now.filter(x=>x.role==='user');const oldUsers=before.filter(x=>x.role==='user');
  confirmed=users.length>oldUsers.length&&norm(users[users.length-1]?.text)===norm(message);
  responseFiles=[];if(confirmed){const lastUser=now.map(x=>x.role).lastIndexOf('user');const assistants=now.slice(lastUser+1).filter(x=>x.role==='assistant');response=assistants.map(x=>x.text).filter(Boolean).join('\n\n');responseFiles=assistants.flatMap(x=>x.files);}
  if(response!==last){last=response;stableSince=Date.now();}
  if(confirmed&&(response||responseFiles.length)&&Date.now()-stableSince>1200)break;
  await sleep(180);
 }
 return {url:location.href,conversationRef:currentRef(),response:response||null,responseFiles,status:response||responseFiles.length?'reply_observed':'pending',submissionConfirmed:confirmed};
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
registerModelActions(action);
 action('searchConversations',{invoke:searchChats});
 action('getSignInUrl',{async invoke(){return {url:'https://www.doubao.com/chat/'};}});
 action('getSignInState',{async invoke(){return await signInState();}});
 action('getCurrentConversation',{async invoke({limit=50}){await ready();const all=messages();const animationFrameObserved=await new Promise(resolve=>{let done=false;const timer=setTimeout(()=>{if(!done){done=true;resolve(false);}},600);requestAnimationFrame(()=>{if(!done){done=true;clearTimeout(timer);resolve(true);}});});return {lastSubmissionEvents:lastSubmissionEvents.slice(),url:location.href,conversationRef:currentRef(),messages:all.slice(-limit),renderedOnly:true,truncated:all.length>limit,interfaceState:{animationFrameObserved,editorStateSynchronized:editor()?.editor?.state===editor()?.editor?.view?.state,editorCount:document.querySelectorAll('.tiptap[contenteditable="true"]').length,draftLength:editor()?.innerText?.length||0,docLength:editor()?.editor?.view?.state?.doc?.textContent?.length||0,editorInitialized:editor()?.editor?.isInitialized===true,sameView:editor()?.editor?.view?.dom===editor()},recentConversations:recent().slice(0,100).map(({title,conversationRef})=>({title,conversationRef}))};}});
 action('openConversation',{async invoke({title}){return await open(title);}});
 action('diagnoseComposer',{async invoke(){await ready();assertEmpty();await wait(()=>editor()?.editor?.isInitialized,3000,'initialized editor');const e=editor();const v=e.editor.view;const text='OX unsent composer diagnostic';let result;try{v.dispatch(v.state.tr.insertText(text));await wait(()=>draftText()===text,2500,'diagnostic draft');await sleep(1000);const bs=Array.from(document.querySelectorAll(sel('chat_input_send_button')));const b=bs.find(visible);const key=b&&Object.keys(b).find(k=>k.startsWith('__reactProps'));result={draftAccepted:draftText()===text,draftCleared:false,editorStateSynchronized:e.editor.state===v.state,buttonCount:bs.length,sendHandlerPresent:!!key&&typeof b[key].onClick==='function',sendEnabled:!!b&&!b.disabled&&b.getAttribute('data-disabled')!=='true',buttonConnected:!!b?.isConnected};}finally{if(editor()===e&&v.state.doc.textContent===text){v.dispatch(v.state.tr.delete(0,v.state.doc.content.size));}}if(!result)throw Error('Diagnostic failed; check draft before proceeding.');result.draftCleared=!draftText();return result;}});
 action('chat',{async invoke({message}){return await send(message,null);}});
 action('continueChat',{async invoke({conversationRef,message}){return await send(message,conversationRef);}});
});

function createModelSite(emit) {
  let active = null;
  const fail = (state, error) => { if (!state.canceled && state.phase !== 'completed') emit({id: state.id, type: 'failed', message: String(error.message || error)}); };
  const progress = state => result => { if (!state.canceled) emit({id: state.id, type: 'snapshot', ...result}); };
  function observeSubmission() {
    const matches = url => {
      const value = new URL(url, location.href);
      return active?.phase === 'submitted' && value.origin === location.origin && value.pathname === '/chat/completion';
    };
    const claim = () => {
      if (active.captured) { fail(active, Error('Doubao started more than one generation request')); return false; }
      active.captured = true;
      return true;
    };
    const originalFetch = window.fetch;
    window.fetch = function(input, init) {
      const capture = matches(typeof input === 'string' ? input : input.url || String(input)) && claim();
      const state = active;
      const response = originalFetch.apply(this, arguments);
      if (capture) {
        console.log('model capture', 'fetch');
        void response.then(value => collect(value.clone(), state)).catch(error => fail(state, error));
      }
      return response;
    };
    const opened = new WeakMap();
    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
      opened.set(this, String(url));
      return originalOpen.call(this, method, url, ...rest);
    };
    XMLHttpRequest.prototype.send = function(body) {
      if (matches(opened.get(this) || '') && claim()) {
        const state = active;
        const parser = createModelParser(state.prompt, progress(state));
        let observed = 0;
        console.log('model capture', 'xhr');
        let broken = false;
        const consume = () => {
          if (broken) return;
          if (state.canceled) return;
          if (typeof this.responseText !== 'string') throw Error('Doubao XHR response is not text');
          const next = this.responseText;
          if (next.length < observed) throw Error('Doubao XHR response was reset');
          parser.push(next.slice(observed));
          observed = next.length;
        };
        this.addEventListener('progress', () => { try { consume(); } catch (error) { broken = true; fail(state, error); } });
        this.addEventListener('loadend', () => {
          try {
            if (state.canceled || broken) return;
            if (this.status !== 200) throw Error('Doubao generation HTTP ' + this.status);
            const next = this.responseText;
            if (next.length < observed) throw Error('Doubao XHR response was reset');
            parser.push(next.slice(observed));
            observed = next.length;
            void complete(parser.push('', true), state).catch(error => fail(state, error));
          } catch (error) { fail(state, error); }
        }, {once: true});
      }
      return originalSend.call(this, body);
    };
  }
  async function complete(result, state) {
    if (state.canceled) return;
    // SSE_ACK plus exact user echo and terminal stream markers are authoritative.
    // The SPA route can update later; never block a finished stream on it.
    if (state.canceled) return;
    state.phase = 'completed';
    emit({id: state.id, type: 'snapshot', ...result});
    emit({id: state.id, type: 'completed'});
  }
  async function collect(response, state) {
    if (!response.ok || response.redirected) throw Error('Doubao generation HTTP ' + response.status);
    const reader = response.body?.getReader();
    if (!reader) throw Error('Doubao generation response is unavailable');
    const decoder = new TextDecoder();
    const parser = createModelParser(state.prompt, progress(state));
    const timeout = setTimeout(() => { state.expired = true; void reader.cancel(); }, 290000);
    try {
      while (true) {
        const part = await reader.read();
        if (state.canceled || state.expired) throw Error(state.expired ? 'Doubao generation timed out' : 'Doubao generation observation canceled');
        if (part.done) break;
        parser.push(decoder.decode(part.value, {stream: true}));
      }
      parser.push(decoder.decode());
      await complete(parser.push('', true), state);
    } finally {
      clearTimeout(timeout);
      void reader.cancel().catch(() => {});
    }
  }
  return {
    start(id, prompt) {
      console.log('model prompt', prompt.length);
      const state = {id, prompt, phase: 'preparing', canceled: false, captured: false, expired: false};
      active = state;
      void (async () => {
        if (!(await signInState()).signedIn) throw Error('Sign in to Doubao');
        if (state.canceled) return;
        await send(prompt, null, () => {
          if (state.canceled) throw Error('Doubao submission canceled');
          observeSubmission();
          state.phase = 'submitted';
        });
        if (!state.captured && !state.canceled) throw Error('Doubao submission could not be correlated; it was not resubmitted');
      })().catch(error => fail(state, error));
    },
    cancel(id) {
      if (active?.id !== id) return 'unsupported';
      const state = active;
      if (state.phase === 'completed') return 'completed';
      state.canceled = true;
      if (state.phase === 'preparing') return 'requested';
      const stopRoute = location.pathname;
      // Native local break delegates to Doubao's active chat request/store.
      // Do not wait for its asynchronous network path before returning to Ox.
      const stop = document.querySelector('[data-testid="chat_input_local_break_button"]');
      if (stop && visible(stop) && !stop.classList.contains('!hidden')) {
        setTimeout(() => { if (active === state && location.pathname === stopRoute) try { stop.click(); } catch (error) { console.log('Doubao stop control unavailable', String(error)); } }, 0);
      } else {
        const deadline = Date.now() + 1500;
        const later = () => {
          const control = document.querySelector('[data-testid="chat_input_local_break_button"]');
          if (active !== state || location.pathname !== stopRoute) return;
          if (control && visible(control) && !control.classList.contains('!hidden')) {
            try { control.click(); } catch (error) { console.log('Doubao stop control unavailable', String(error)); }
          } else if (Date.now() < deadline) setTimeout(later, 50);
          else console.log('Doubao stop control did not appear');
        };
        setTimeout(later, 0);
      }
      return 'requested';
    },
  };
}

async function modelCatalog() {
  return [{id: 'website-default', name: 'Default', input: ['text'], contextTokens: null, outputTokens: null, streaming: true, cancellation: false, options: []}];
}

const modelGenerations = new Map();
const modelSite = createModelSite(modelEvent);
const modelDelay = ms => new Promise(resolve => setTimeout(resolve, ms));
function modelFailure(message) {
  const value = message.toLowerCase();
  if (/sign.in|session ended|unauth|401/.test(value)) return 'authentication';
  if (/rate.?limit|parallel.?limit|too.many.requests|429/.test(value)) return 'rateLimited';
  if (/context|too many tokens|prompt too long/.test(value)) return 'contextOverflow';
  if (/network|timed out|fetch failed|stream ended/.test(value)) return 'network';
  return 'provider';
}
function modelEvent(event) {
  const state = modelGenerations.get(event.id);
  if (!state || state.terminal || state.canceled) return;
  if (event.chatId) state.chatId = event.chatId;
  if (event.messageId) state.messageId = event.messageId;
  if (event.type === 'snapshot') {
    if (typeof event.text !== 'string' || event.text.length > 500000 || !event.text.startsWith(state.text.slice(0, state.emitted))) {
      state.terminal = {type: 'failed', message: 'Model response revised published text or exceeded the size limit', kind: 'provider'};
    } else if (event.text.startsWith(state.text)) state.text = event.text;
    else state.terminal = {type: 'failed', message: 'Doubao revised buffered answer', kind: 'provider'};
  }
  if (event.type === 'completed') state.terminal = {type: 'completed'};
  if (event.type === 'failed') {
    const message = String(event.message || 'Model generation failed');
    state.terminal = {type: 'failed', message, kind: modelFailure(message)};
  }
}
function registerModelActions(action) {
  action('listModels', {async invoke() { return {models: await modelCatalog()}; }});
  action('startModelGeneration', {async invoke(args) {
    if (modelGenerations.size) throw Error('This page already owns a generation');
    const models = await modelCatalog();
    const selected = models.find(model => model.id === args.modelId);
    if (!selected) throw Error('The selected website model is unavailable');
    if (args.options.temperature !== null || args.options.maxTokens !== null) throw Error('This website does not support generation options');
    const staged = window.__oxWebsiteFiles || [];
    const files = args.attachments.map(ref => {
      const file = staged[ref.id];
      if (!(file instanceof File) || file.name !== ref.name || file.type !== ref.mimeType) throw Error('Staged attachment does not match its reference');
      const modality = file.type === 'application/pdf' ? 'pdf' : file.type.startsWith('image/') ? 'image' : null;
      if (!modality || !selected.input.includes(modality)) throw Error('The selected model does not support this attachment');
      return file;
    });
    if (new Set(args.attachments.map(ref => ref.id)).size !== files.length) throw Error('Duplicate attachment references');
    window.__oxWebsiteFiles = files;
    const id = crypto.randomUUID();
    const prompt = JSON.stringify({task: 'Follow the supplied conversation and system instructions. Return only the assistant response.', conversation: args.messages});
    const state = {id, prompt, text: '', emitted: 0, events: [], terminal: null, publishedTerminal: false, chatId: '', messageId: '', started: Date.now()};
    modelGenerations.set(id, state);
    console.log('model start', id, selected.id, files.length);
    try { modelSite.start(id, prompt, selected.id === 'website-default' ? '' : selected.id, args.messages.filter(message => message.role === 'system').map(message => message.text).join('\n\n')); }
    catch (error) { modelEvent({id, type: 'failed', message: String(error.message || error)}); }
    return {generationId: id, submission: 'uncertain'};
  }});
  action('readModelGeneration', {async invoke({generationId, after, waitMilliseconds}) {
    const state = modelGenerations.get(generationId);
    if (!state || !Number.isInteger(after) || after < 0 || after > state.events.length) throw Error('Invalid generation or event cursor');
    const deadline = Date.now() + Math.min(1000, Math.max(0, waitMilliseconds));
    while (after === state.events.length && state.emitted === state.text.length && !state.terminal && Date.now() < deadline) await modelDelay(Math.min(50, deadline - Date.now()));
    if (!state.terminal && Date.now() - state.started > 300000) state.terminal = {type: 'failed', message: 'Model generation timed out', kind: 'network'};
    if (state.events.length >= 4095 && !state.terminal) state.terminal = {type: 'failed', message: 'Model event history exceeded the limit', kind: 'provider'};
    if (state.emitted !== state.text.length && state.events.length < 4095) {
      state.emitted = state.text.length;
      state.events.push({type: 'text', length: state.emitted});
    }
    if (state.terminal && !state.publishedTerminal) {
      state.events.push(state.terminal);
      state.publishedTerminal = true;
      console.log('model terminal', generationId, state.terminal.type);
    }
    const events = state.events.slice(after, after + 1000).map(event => event.type === 'text' ? {type: 'text', text: state.text.slice(0, event.length)} : event);
    return {nextCursor: after + events.length, events};
  }});
  action('cancelModelGeneration', {async invoke({generationId}) {
    const state = modelGenerations.get(generationId);
    if (!state) throw Error('Unknown generation');
    if (state.terminal) return {status: state.terminal.type === 'completed' ? 'completed' : 'requested'};
    state.canceled = true;
    const result = modelSite.cancel(generationId);
    const status = typeof result === 'string' ? result : result === true ? 'cancelled' : 'requested';
    if (status !== 'completed') state.terminal = {type: 'failed', message: 'Generation stopped by Ox', kind: 'provider'};
    console.log('model cancel', generationId, status);
    return {status};
  }});
}
