const pause=ms=>new Promise(r=>setTimeout(r,ms));
const clean=s=>String(s??'').replace(/\s+/g,' ').trim();
async function wait(fn,ms=8000){const end=Date.now()+ms;do{const v=fn();if(v)return v;await pause(120)}while(Date.now()<end);throw Error('Gemini interface not ready');}
const editor=()=>document.querySelector('.ql-editor[role="textbox"][contenteditable="true"]');
const cid=()=>{const m=location.pathname.match(/^\/app\/([a-f0-9]+)$/);return m?m[1]:null};
const links=()=>[...document.querySelectorAll('a[href]')].filter(a=>a.origin===location.origin&&/^\/app\/[a-f0-9]+$/.test(a.pathname));
function messages(){return [...document.querySelectorAll('user-query,model-response')].filter(e=>!e.closest('.conversation-container-leave-animation')).map(e=>{const user=e.tagName==='USER-QUERY';const source=e.querySelector(user?'.query-text':'.markdown');if(!source)return {role:user?'user':'assistant',text:''};const clone=source.cloneNode(true);clone.querySelectorAll('.cdk-visually-hidden,button').forEach(n=>n.remove());return {role:user?'user':'assistant',text:clone.textContent.trim()};}).filter(m=>m.text).slice(-100);}
async function ready(){await wait(()=>editor());}
async function read(){await ready();if(cid())await wait(()=>messages().some(m=>m.role==='assistant'));const id=cid();return {conversationId:id,url:id?location.origin+'/app/'+id:null,messages:id?messages():[],scope:'rendered'};}
async function open(id){await ready();if(cid()!==id){const previous=document.querySelector('user-query');const a=await wait(()=>links().find(a=>a.pathname==='/app/'+id));a.click();await wait(()=>cid()===id&&(!previous||!previous.isConnected||!!previous.closest('.conversation-container-leave-animation')));}await wait(()=>messages().some(m=>m.role==='assistant'));return await read();}
async function signInState(){const c=new AbortController();const timer=setTimeout(()=>c.abort(),7000);try{const r=await fetch('/app',{credentials:'include',cache:'no-store',signal:c.signal});if(r.status!==200||new URL(r.url).origin!==location.origin||new URL(r.url).pathname!=='/app')throw Error('Unexpected Gemini authentication response');const t=await r.text();const m=t.match(/window\.WIZ_global_data\s*=\s*(\{[\s\S]*?\});/);if(!m)throw Error('Gemini authentication data missing');const j=JSON.parse(m[1]);if(typeof j.oPEP7c==='string'&&j.oPEP7c.includes('@')&&typeof j.QrtxK==='string'&&j.QrtxK&&Object.hasOwn(j,'W3Yyqf'))return {signedIn:true};if(!Object.hasOwn(j,'oPEP7c')&&j.QrtxK===''&&!Object.hasOwn(j,'W3Yyqf'))return {signedIn:false};throw Error('Unrecognized Gemini authentication state');}finally{clearTimeout(timer)}}
async function send(message,id,beforeSubmit=()=>{}){if(!message.trim())throw Error('Message must not be blank');await ready();const initial=editor();if(initial.textContent.trim())throw Error('Existing Gemini draft; refusing to overwrite');if(id)await open(id);else if(cid()){const a=[...document.querySelectorAll('a[href]')].find(a=>a.origin===location.origin&&a.pathname==='/app'&&a.getAttribute('aria-label')==='New chat');if(!a)throw Error('New chat control unavailable');a.click();await wait(()=>location.pathname==='/app'&&messages().length===0);}const e=await wait(()=>editor());const q=e.parentElement.__quill;if(!q||typeof q.setText!=='function'||typeof q.getText!=='function')throw Error('Gemini editor API unavailable');if(q.getText().trim())throw Error('Existing Gemini draft; refusing to overwrite');const before=messages();if(before.length>=98)throw Error('Conversation exceeds supported send confirmation window; use a shorter chat');console.log('chat phase: editor ready');q.setText(message,'user');await wait(()=>q.getText().trim()===message.trim()&&clean(e.textContent)===clean(message),2500);const button=await wait(()=>{const b=document.querySelector('button[aria-label="Send message"]');return b&&!b.disabled?b:null},3500);console.log('chat phase: sending once');beforeSubmit();button.click();let confirmed=false,reply=null;const end=Date.now()+12000;do{const current=messages();const added=current.slice(before.length);const userIndex=added.findIndex(m=>m.role==='user'&&clean(m.text)===clean(message));if(userIndex>=0&&cid()&&(!id||cid()===id)){confirmed=true;reply=added.slice(userIndex+1).filter(m=>m.role==='assistant').map(m=>m.text).join('\n\n')||null;if(reply)break;}await pause(250)}while(Date.now()<end);const resultId=cid();return {conversationId:resultId,url:resultId?location.origin+'/app/'+resultId:null,submissionConfirmed:confirmed,status:confirmed?'submitted':'unconfirmed',reply};}

let searchSession=null;
const searchInput=()=>document.querySelector('input[aria-label="Search chats"]');
let searchObserverInstalled=false;
function observeSearch(){if(searchObserverInstalled)return;searchObserverInstalled=true;const open=XMLHttpRequest.prototype.open,send=XMLHttpRequest.prototype.send;const reqs=new WeakMap();XMLHttpRequest.prototype.open=function(method,url,...rest){reqs.set(this,String(url).includes('rpcids=unqWSc'));return open.call(this,method,url,...rest);};XMLHttpRequest.prototype.send=function(body){if(reqs.get(this)&&typeof body==='string'){try{const field=body.split('&').find(s=>s.startsWith('f.req='));if(field){const envelope=JSON.parse(decodeURIComponent(field.slice(6).replaceAll('+',' ')));const row=envelope.flat().find(x=>Array.isArray(x)&&x[0]==='unqWSc');if(row){const a=JSON.parse(row[1]);let session;if(typeof a[0]==='string'){session={query:a[0],pages:new Map(),seen:new Set()};searchSession=session;}else session=searchSession;const cursor=typeof a[2]==='string'?a[2]:'';if(session)this.addEventListener('load',()=>{try{if(this.status!==200)throw Error('Gemini search HTTP '+this.status);let data;for(const line of this.responseText.split(String.fromCharCode(10))){if(!line.startsWith('['))continue;let rows;try{rows=JSON.parse(line);}catch{continue;}for(const r of rows)if(r?.[0]==='wrb.fr'&&r[1]==='unqWSc')data=JSON.parse(r[2]);}if(!Array.isArray(data)||!Array.isArray(data[0])||(data[1]!=null&&typeof data[1]!=='string'))throw Error('Unexpected Gemini search response');const items=data[0].map(x=>{const pair=x?.[0];if(!Array.isArray(pair)||typeof pair[0]!=='string'||!pair[0].startsWith('c_')||typeof pair[1]!=='string')throw Error('Invalid Gemini search result');const id=pair[0].slice(2);return {id,title:pair[1],url:location.origin+'/app/'+encodeURIComponent(id)};});const nextCursor=data[1]||null;if(nextCursor===cursor&&cursor)throw Error('Gemini search cursor stalled');session.pages.set(cursor,{items,nextCursor});while(session.pages.size>12)session.pages.delete(session.pages.keys().next().value);}catch(e){session.pages.set(cursor,{error:e.message});}},{once:true});}}}catch{}}return send.call(this,body);};}
async function searchChats({query,cursor}){observeSearch();if(!query.trim())throw Error('Search query must not be blank');if(editor()?.textContent.trim())throw Error('Existing Gemini draft preserved');await wait(()=>searchInput()||document.querySelector('a[aria-label="Search chats"]'));if(!searchInput())document.querySelector('a[aria-label="Search chats"]').click();const input=await wait(searchInput);const key=cursor||'';
 if(cursor){if(!searchSession||searchSession.query!==query||input.value!==query)throw Error('Search session changed; restart with no cursor');if(![...searchSession.pages.values()].some(p=>p.nextCursor===cursor))throw Error('Cursor was not returned by this search session');}
 else if(!searchSession||searchSession.query!==query||input.value!==query){if(input.value===query){input.value='';input.dispatchEvent(new Event('input',{bubbles:true}));await pause(400);}input.value=query;input.dispatchEvent(new Event('input',{bubbles:true}));}
 if(cursor&&!searchSession.pages.has(key)){const scroll=await wait(()=>document.querySelector('infinite-scroller.results-list'));scroll.scrollTop=scroll.scrollHeight;scroll.dispatchEvent(new Event('scroll'));}
 const page=await wait(()=>searchSession?.query===query&&searchSession.pages.get(key),14000);if(page.error)throw Error(page.error);page.items.forEach(i=>searchSession.seen.add(i.id));return page;
}
async function openSearch(id){if(!searchSession?.seen.has(id))throw Error('Search for this conversation first');if(searchInput()?.value!==searchSession.query)throw Error('Search state changed');const a=await wait(()=>[...document.querySelectorAll('search-snippet a[href]')].find(a=>a.pathname==='/app/'+id));const old=document.querySelector('user-query');a.click();await wait(()=>cid()===id&&(!old||!old.isConnected||!!old.closest('.conversation-container-leave-animation')));return read();}

window.ox.install(({action})=>{
registerModelActions(action);
action('searchConversations',{invoke:searchChats});
action('openSearchConversation',{async invoke({conversationId}){return openSearch(conversationId);}});
action('getSignInUrl',{async invoke(){return {url:'https://gemini.google.com/app'}}});
action('getSignInState',{invoke:signInState});
action('getCurrentConversation',{invoke:read});
action('openConversation',{async invoke({conversationId}){return open(conversationId)}});
action('listWebsiteModels',{async invoke(){await ready();const b=await wait(()=>document.querySelector('button[aria-label^="Open mode picker"]'));b.click();try{await wait(()=>document.querySelector('[role="menu"] [role="menuitem"]'));const items=[...document.querySelectorAll('[role="menu"] [role="menuitem"]')].map(e=>{const lines=e.innerText.split('\n').map(clean).filter(Boolean);return {name:lines[0],description:lines.slice(1).join(' ')}});return {items,nextCursor:null};}finally{document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));}}});
action('chat',{async invoke({message}){return send(message,null)}});
action('continueChat',{async invoke({conversationId,message}){return send(message,conversationId)}});
});

function parseModelResponse(text) {
  if (text.length > 4000000) throw Error('Gemini response exceeded the size limit');
  let result = null;
  for (const line of text.split('\n')) {
    if (!line.startsWith('[')) continue;
    for (const row of JSON.parse(line)) {
      if (row?.[0] !== 'wrb.fr' || typeof row[2] !== 'string') continue;
      const data = JSON.parse(row[2]);
      const candidate = data?.[4]?.[0];
      if (data?.[14] !== true || candidate?.[8]?.[0] !== 2) continue;
      const chatId = data?.[1]?.[0];
      const messageId = data?.[1]?.[1];
      const answer = candidate?.[1]?.[0];
      if (typeof chatId !== 'string' || !/^c_[a-f0-9]+$/.test(chatId) || typeof messageId !== 'string' || !/^r_[a-f0-9]+$/.test(messageId) || typeof answer !== 'string' || !answer) throw Error('Invalid completed Gemini response');
      if (result && (result.chatId !== chatId.slice(2) || result.messageId !== messageId || result.text !== answer)) throw Error('Gemini completion identity changed');
      result = {chatId: chatId.slice(2), messageId, text: answer};
    }
  }
  if (!result) throw Error('Gemini stream ended without confirmed completion');
  return result;
}

function createModelSite(emit) {
  let active = null;
  const fail = (state, error) => emit({id: state.id, type: 'failed', message: String(error.message || error)});
  function observeSubmission() {
    const matches = url => {
      const value = new URL(url, location.href);
      return active?.phase === 'submitted' && value.origin === location.origin && value.pathname === '/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate';
    };
    const claim = () => {
      if (active.captured) { fail(active, Error('Gemini started more than one generation request')); return false; }
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
        console.log('model capture', 'xhr');
        this.addEventListener('loadend', () => {
          void (async () => {
            if (this.status !== 200) throw Error('Gemini generation HTTP ' + this.status);
            await complete(this.responseText, state);
          })().catch(error => fail(state, error));
        }, {once: true});
      }
      return originalSend.call(this, body);
    };
  }
  async function complete(text, state) {
    const result = parseModelResponse(text);
    await wait(() => cid() === result.chatId && messages().some(message => message.role === 'user' && clean(message.text) === clean(state.prompt)));
    if (state.canceled) return;
    state.phase = 'completed';
    emit({id: state.id, type: 'snapshot', ...result});
    emit({id: state.id, type: 'completed'});
  }
  async function collect(response, state) {
    if (!response.ok || response.redirected) throw Error('Gemini generation HTTP ' + response.status);
    const reader = response.body?.getReader();
    if (!reader) throw Error('Gemini generation response is unavailable');
    const decoder = new TextDecoder();
    let text = '';
    const timeout = setTimeout(() => { state.expired = true; void reader.cancel(); }, 290000);
    try {
      while (true) {
        const part = await reader.read();
        if (state.canceled || state.expired) throw Error(state.expired ? 'Gemini generation timed out' : 'Gemini generation observation canceled');
        if (part.done) break;
        text += decoder.decode(part.value, {stream: true});
        if (text.length > 4000000) throw Error('Gemini response exceeded the size limit');
      }
      text += decoder.decode();
      await complete(text, state);
    } finally {
      clearTimeout(timeout);
      await reader.cancel().catch(() => {});
    }
  }
  return {
    start(id, prompt) {
      if (prompt.length > 32000) throw Error('Gemini context exceeds the website input limit of 32000 characters');
      console.log('model prompt', prompt.length);
      const state = {id, prompt, phase: 'preparing', canceled: false, captured: false, expired: false};
      active = state;
      void (async () => {
        if (!(await signInState()).signedIn) throw Error('Sign in to Gemini');
        if (state.canceled) return;
        await send(prompt, null, () => {
          if (state.canceled) throw Error('Gemini submission canceled');
          observeSubmission();
          state.phase = 'submitted';
        });
        if (!state.captured && !state.canceled) throw Error('Gemini submission could not be correlated; it was not resubmitted');
      })().catch(error => fail(state, error));
    },
    cancel(id) {
      if (active?.id !== id) return 'unsupported';
      if (active.phase === 'completed') return 'completed';
      active.canceled = true;
      return active.phase === 'preparing' ? 'cancelled' : 'unsupported';
    },
  };
}

async function modelCatalog() {
  return [{id: 'website-default', name: 'Default', input: ['text'], contextTokens: null, outputTokens: null, streaming: false, cancellation: false, options: []}];
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
  if (!state || state.terminal) return;
  if (event.chatId) state.chatId = event.chatId;
  if (event.messageId) state.messageId = event.messageId;
  if (event.type === 'snapshot') {
    if (typeof event.text !== 'string' || event.text.length > 500000 || !event.text.startsWith(state.text.slice(0, state.emitted))) {
      state.terminal = {type: 'failed', message: 'Model response revised published text or exceeded the size limit', kind: 'provider'};
    } else state.text = event.text;
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
    if (state.terminal) return {status: 'completed'};
    state.canceled = true;
    const result = await modelSite.cancel(generationId);
    const status = typeof result === 'string' ? result : result === true ? 'cancelled' : 'requested';
    console.log('model cancel', generationId, status);
    return {status};
  }});
}
