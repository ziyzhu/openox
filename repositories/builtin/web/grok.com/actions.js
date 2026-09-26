const pause=ms=>new Promise(r=>setTimeout(r,ms));
const visible=e=>e&&e.getClientRects().length>0;
const editor=()=>[...document.querySelectorAll('[contenteditable="true"][role="textbox"]')].find(e=>visible(e)&&e.getAttribute('aria-disabled')!=='true');
const id=()=>location.pathname.match(/^\/c\/([a-zA-Z0-9-]+)/)?.[1]||null;
async function wait(fn,ms=8000){const end=Date.now()+ms;do{const v=fn();if(v)return v;await pause(150);}while(Date.now()<end);throw new Error('Grok interface not ready; no automatic retry.');}
async function session(){const r=await fetch('/rest/user-settings',{credentials:'include',cache:'no-store'});if(r.redirected)throw new Error('Unexpected session redirect');const j=await r.json();if(r.status===401&&typeof j.code==='number'&&typeof j.message==='string')return {signedIn:false};if(r.status===401&&typeof j.code==='string'&&typeof j.message==='string')return {signedIn:false};if(r.status===400&&j.code===3&&j.message==='Only authenticated users')return {signedIn:false};if(r.status===200&&typeof j.enableMemory==='boolean'&&typeof j.excludeFromTraining==='boolean')return {signedIn:true};throw new Error('Unrecognized Grok session response: '+r.status);}
function read(status='rendered'){return {conversationId:id(),url:location.href,messages:[...document.querySelectorAll('.message-bubble')].filter(visible).slice(-200).map(e=>({role:e.className.includes('wd-user-bubble')?'user':'assistant',text:e.innerText.trim()})),status};}
async function send(prompt){
 const e=await wait(editor);const t=e.editor;
 if(!t?.commands?.insertContent||!t.state?.doc)throw new Error('Grok editor API unavailable; nothing submitted.');
 if(t.state.doc.textContent.trim()||e.textContent.trim())throw new Error('Existing draft present; refusing to overwrite.');
 const initialId=id();const oldNodes=new Set(document.querySelectorAll('.message-bubble'));
 e.focus();
 if(!t.commands.insertContent(prompt))throw new Error('Editor rejected prompt; nothing submitted.');
 await wait(()=>t.state.doc.textContent.trim()===prompt.trim()&&e.textContent.trim()===prompt.trim(),2000);
 await pause(800);
 if(t.state.doc.textContent.trim()!==prompt.trim()||e.textContent.trim()!==prompt.trim())throw new Error("Draft changed before submit.");
 const button=await wait(()=>{const b=document.querySelector('button[data-testid="chat-submit"][aria-label="Submit"]');return visible(b)&&!b.disabled&&b.getAttribute('aria-disabled')!=='true'?b:null;},3000);
 const form=e.closest('form');if(!form||typeof form.requestSubmit!=='function')throw new Error('Grok submit form unavailable');form.requestSubmit();
 const end=Date.now()+14000;
 while(Date.now()<end){
   const fresh=[...document.querySelectorAll('.message-bubble')].filter(n=>!oldNodes.has(n));
   const user=fresh.find(n=>n.className.includes('wd-user-bubble')&&n.textContent.trim()===prompt.trim());
   const target=id();
   if(user&&target&&(!initialId||target===initialId)){
     const result=read('accepted');return {...result,submissionConfirmed:true};
   }
   await pause(250);
 }
 return {...read('uncertain'),submissionConfirmed:false};
}
async function serverRead(conversationId){
 const request=async(path,options={})=>{const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),8000);try{const r=await fetch(path,{...options,credentials:'include',cache:'no-store',signal:controller.signal});if(!r.ok||r.redirected)throw new Error('Grok message read failed: '+r.status);return await r.json();}finally{clearTimeout(timer);}};
 const root='/rest/app-chat/conversations/'+encodeURIComponent(conversationId);
 const index=await request(root+'/response-node');
 if(!Array.isArray(index.responseNodes)||!Array.isArray(index.inflightResponses))throw new Error('Unexpected Grok message index');
 const nodes=index.responseNodes;if(nodes.length>200)throw new Error('Conversation exceeds the current 200-message read limit');
 const children=new Map();for(const n of nodes){if(typeof n.responseId!=='string')throw new Error('Invalid response identifier');if(n.parentResponseId){children.set(n.parentResponseId,(children.get(n.parentResponseId)||0)+1);}}
 if([...children.values()].some(n=>n>1))throw new Error('Branched conversations are not yet supported by server reads');
 if(!nodes.length)return {conversationId,url:'https://grok.com/c/'+encodeURIComponent(conversationId),messages:[],status:index.inflightResponses.length?'pending':'complete'};
 const data=await request(root+'/load-responses',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({responseIds:nodes.map(n=>n.responseId)})});
 if(!Array.isArray(data.responses))throw new Error('Unexpected Grok response body');
 const byId=new Map(data.responses.map(r=>[r.responseId,r]));
 const responses=nodes.map(n=>{const r=byId.get(n.responseId);if(!r||typeof r.message!=='string'||!['human','assistant'].includes(r.sender))throw new Error('Incomplete or unsupported Grok message');return r;});
 responses.sort((a,b)=>String(a.createTime).localeCompare(String(b.createTime)));
 return {conversationId,url:'https://grok.com/c/'+encodeURIComponent(conversationId),messages:responses.map(r=>({role:r.sender==='human'?'user':'assistant',text:r.message})),status:index.inflightResponses.length||responses.some(r=>r.partial)?'pending':'complete'};
}
async function openTarget(conversationId){
  await wait(editor);
  if(id()!==conversationId){
    if(editor().innerText.trim())throw new Error('Existing draft present; refusing to navigate away.');
    const oldNodes=[...document.querySelectorAll('.message-bubble')];
    const a=await wait(()=>[...document.querySelectorAll('a[href]')].find(e=>new URL(e.href).pathname==='/c/'+conversationId));
    a.click();
    await wait(()=>id()===conversationId&&editor()&&oldNodes.every(e=>!e.isConnected)&&[...document.querySelectorAll('.message-bubble')].some(visible));
  }else{await wait(()=>editor()&&[...document.querySelectorAll('.message-bubble')].some(visible));}
  if(id()!==conversationId)throw new Error('Conversation changed during loading.');
  return read();
}
window.ox.install(({action})=>{
registerModelActions(action);
action('searchConversations',{async invoke({query}){if(!query.trim())throw Error('Search query must not be blank');const r=await fetch('/rest/app-chat/conversations?pageSize=60&searchQuery='+encodeURIComponent(query),{credentials:'include',cache:'no-store'});if(!r.ok||r.redirected)throw Error('Grok search failed: '+r.status);const j=await r.json();if(!Array.isArray(j.conversations)||j.conversations.some(x=>typeof x.conversationId!=='string'||typeof x.title!=='string'))throw Error('Unexpected Grok search response');if(j.nextPageToken)throw Error('Grok returned more search results; continuation is not yet verified. Narrow the query.');return {items:j.conversations.map(x=>({id:x.conversationId,title:x.title,url:'https://grok.com/c/'+encodeURIComponent(x.conversationId)})),nextCursor:null};}});
action('getInterfaceState',{async invoke(){const e=await wait(editor);const b=document.querySelector('button[data-testid="chat-submit"]');const text=e.editor?.state?.doc?.textContent;return {path:location.pathname,editorPresent:!!e,domLength:e.textContent.trim().length,stateLength:typeof text==='string'?text.trim().length:-1,testDraftMatches:text?.trim()==='Reply exactly OX_GROK_OK',messageCount:document.querySelectorAll('.message-bubble').length,submitPresent:!!b,submitDisabled:!b||b.disabled,sidebarIds:[...document.querySelectorAll('a[href]')].map(a=>new URL(a.href).pathname).filter(p=>p.startsWith('/c/')).slice(0,60)};}});
action('getSignInUrl',{invoke:async()=>({url:'https://grok.com/sign-in?return_to=%2F'})});
action('getSignInState',{invoke:session});
action('listConversations',{async invoke({limit=20}){const r=await fetch('/rest/app-chat/conversations?pageSize='+limit,{credentials:'include',cache:'no-store'});if(!r.ok||r.redirected)throw new Error('Conversation request failed: '+r.status);const j=await r.json();if(!Array.isArray(j.conversations))throw new Error('Unexpected conversation response');return {items:j.conversations.map(c=>({conversationId:c.conversationId,title:c.title||'',url:'https://grok.com/c/'+encodeURIComponent(c.conversationId),createTime:c.createTime||null,modifyTime:c.modifyTime||null})),nextCursor:j.nextPageToken||null};}});
action('openConversation',{invoke:({conversationId})=>openTarget(conversationId)});
action('getCurrentConversation',{invoke:({conversationId})=>serverRead(conversationId)});
action('chat',{async invoke({prompt}){await wait(editor);if(editor().innerText.trim())throw new Error('Existing draft present; refusing to navigate away.');if(location.pathname!=='/'){const a=[...document.querySelectorAll('a[href="/"]')].find(e=>visible(e));if(!a)throw new Error('New-chat control unavailable');a.click();await wait(()=>location.pathname==='/'&&editor()&&!document.querySelector('.message-bubble'));}return send(prompt);}});
action('continueChat',{async invoke({conversationId,prompt}){await openTarget(conversationId);if(id()!==conversationId)throw new Error('Conversation changed before submission.');return send(prompt);}});
});

function createModelSite(send) {
  const site = {};
const active = new Map();

  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const visible = element => !!element && element.getClientRects().length > 0;
  const editor = () => [...document.querySelectorAll('[contenteditable="true"][role="textbox"]')].find(element => visible(element) && element.getAttribute('aria-disabled') !== 'true');
  site.signedIn = async () => (await session()).signedIn;
  const fail = (generation, error) => {
    if (generation.terminal || generation.canceled) return;
    generation.terminal = true;
    send({id: generation.id, type: 'failed', message: String(error?.message || error), chatId: generation.chatId, messageId: generation.responseId});
    active.delete(generation.id);
  };
  const originalFetch = window.fetch?.bind(window);
  window.fetch = async function(input, init) {
    const url = typeof input === 'string' ? input : input?.url;
    const method = String(init?.method || input?.method || 'GET').toUpperCase();
    const generation = [...active.values()].find(value => value.submitting && !value.captured);
    const path = url ? new URL(url, location.href).pathname : '';
    const capture = generation && method === 'POST' && path === '/rest/app-chat/conversations/new';
    const response = await originalFetch(input, init);
    if (capture) {
      generation.captured = true;
      void observe(generation, response.clone());
    }
    return response;
  };
  const checked = async (path, options) => {
    const response = await fetch(path, {...options, credentials: 'include', cache: 'no-store'});
    if (response.status === 404) return null;
    if (!response.ok || response.redirected) throw new Error('Grok message read HTTP ' + response.status);
    return response.json();
  };
  const reconcile = async generation => {
    while (!generation.canceled && !generation.terminal && Date.now() - generation.started < 300000) {
      const chatId = generation.chatId || location.pathname.match(/^\/c\/([a-zA-Z0-9-]+)/)?.[1];
      if (!chatId) { await pause(250); continue; }
      generation.chatId = chatId;
      const root = '/rest/app-chat/conversations/' + encodeURIComponent(chatId);
      const index = await checked(root + '/response-node');
      if (!index) { await pause(500); continue; }
      if (!Array.isArray(index.responseNodes) || !Array.isArray(index.inflightResponses)) throw new Error('Grok message index changed');
      if (index.inflightResponses.length || !index.responseNodes.length) { await pause(250); continue; }
      if (index.responseNodes.length > 200 || index.responseNodes.some(value => typeof value.responseId !== 'string')) throw new Error('Grok message index is unsupported');
      const data = await checked(root + '/load-responses', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({responseIds: index.responseNodes.map(value => value.responseId)})});
      if (!data) { await pause(500); continue; }
      if (!Array.isArray(data.responses)) throw new Error('Grok message read changed');
      const messages = data.responses;
      const user = messages.find(value => value.sender === 'human' && value.message === generation.prompt);
      const assistants = messages.filter(value => value.sender === 'assistant' && typeof value.message === 'string' && value.message && value.partial !== true);
      const assistant = generation.responseId ? assistants.find(value => value.responseId === generation.responseId) : assistants.at(-1);
      if (!user || !assistant) { await pause(250); continue; }
      generation.responseId = assistant.responseId;
      if (!assistant.message.startsWith(generation.text)) throw new Error('Grok revised streamed output');
      if (assistant.message !== generation.text) {
        generation.text = assistant.message;
        send({id: generation.id, type: 'snapshot', text: generation.text, chatId, messageId: generation.responseId});
      }
      return;
    }
    if (!generation.canceled && !generation.terminal) throw new Error('Grok did not confirm a completed response');
  };
  const observe = async (generation, response) => {
    try {
      if (!response.ok || !response.body) throw new Error('Grok completion HTTP ' + response.status);
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      const frame = line => {
        if (!line.trim()) return;
        const value = JSON.parse(line);
        if (value.error) throw new Error(String(value.error.message || value.error));
        const result = value.result || {};
        const response = result.response || result;
        if (typeof result.conversation?.conversationId === 'string') generation.chatId = result.conversation.conversationId;
        if (typeof response.modelResponse?.responseId === 'string') generation.responseId = response.modelResponse.responseId;
        const token = response.token;
        if (typeof token === 'string' && token && response.isThinking !== true && !response.messageStepId) {
          generation.text += token;
          send({id: generation.id, type: 'snapshot', text: generation.text, chatId: generation.chatId, messageId: generation.responseId});
        }
        if (response.error) throw new Error(String(response.error.message || response.error));
      };
      while (!generation.canceled && !generation.terminal) {
        const next = await reader.read();
        if (next.done) break;
        buffer += decoder.decode(next.value, {stream: true});
        if (buffer.length > 1_048_576) throw new Error('Grok stream frame exceeded limit');
        let boundary;
        while ((boundary = buffer.indexOf('\n')) >= 0) {
          frame(buffer.slice(0, boundary));
          buffer = buffer.slice(boundary + 1);
        }
      }
      if (generation.canceled) return;
      if (buffer.trim()) frame(buffer);
    } catch (error) { fail(generation, error); }
  };
  site.start = (id, prompt) => {
    const generation = {id, prompt, text: '', chatId: '', responseId: '', submitting: false, captured: false, canceled: false, terminal: false, started: Date.now()};
    active.set(id, generation);
    void (async () => {
      try {
        if (!await site.signedIn()) throw new Error('Sign in to Grok in Ox provider settings');
        if (location.pathname !== '/') throw new Error('Grok is not on a fresh conversation');
        let input;
        for (let attempt = 0; attempt < 80 && !input; attempt++) { input = editor(); if (!input) await pause(100); }
        const documentText = input?.editor?.state?.doc?.textContent;
        if (!input || !input.editor?.commands?.insertContent || typeof documentText !== 'string') throw new Error('Grok editor API is unavailable');
        if (documentText.trim() || input.textContent.trim()) throw new Error('Grok contains an existing draft');
        const files = window.__oxWebsiteFiles || [];
        delete window.__oxWebsiteFiles;
        const uploadInput = input.closest('form')?.querySelector('input[type="file"][name="files"]');
        const chips = () => [...document.querySelectorAll('[aria-label="Conversation attachments"] button[aria-label="Open attachment"]')];
        if (chips().length) throw new Error('Grok contains existing draft attachments');
        if (files.length) {
          if (!uploadInput) throw new Error('Grok attachment input is unavailable');
          const transfer = new DataTransfer();
          files.forEach(file => transfer.items.add(file));
          uploadInput.files = transfer.files;
          uploadInput.dispatchEvent(new Event('change', {bubbles: true}));
          let ready = false;
          for (let attempt = 0; attempt < 120 && !ready; attempt++) {
            if (generation.canceled) return;
            const uploaded = chips().flatMap(element => {
              let fiber = element[Object.keys(element).find(key => key.startsWith('__reactFiber'))];
              const candidates = [];
              for (let depth = 0; fiber && depth < 40; depth++, fiber = fiber.return) {
                for (const props of [fiber.memoizedProps, fiber.alternate?.memoizedProps]) {
                  if (typeof props?.fileName === 'string') candidates.push(props);
                }
              }
              return candidates;
            });
            if (uploaded.some(value => value.metadata instanceof Error)) throw new Error('Grok could not process an attachment');
            ready = chips().length === files.length && files.every(file => uploaded.some(value =>
              value.fileName === file.name && value.metadata?.fileMetadataId));
            if (!ready) {
              send({id, type: 'progress'});
              await pause(1000);
            }
          }
          if (!ready) throw new Error('Grok attachment processing timed out');
        }
        input = undefined;
        for (let attempt = 0; attempt < 30; attempt++) {
          input = editor();
          if (input?.editor?.commands?.insertContent) break;
          await pause(100);
        }
        if (!input?.editor?.commands?.insertContent) throw new Error('Grok editor is unavailable after attachment processing');
        input.focus();
        if (!input.editor.commands.insertContent(prompt)) throw new Error('Grok editor rejected the prompt');
        for (let attempt = 0; attempt < 20 && input.editor.state.doc.textContent.trim() !== prompt.trim(); attempt++) await pause(100);
        if (input.editor.state.doc.textContent.trim() !== prompt.trim() || input.textContent.trim() !== prompt.trim()) throw new Error('Grok editor changed the prompt');
        const form = input.closest('form');
        let button;
        for (let attempt = 0; attempt < 30 && !button; attempt++) {
          const candidate = document.querySelector('button[data-testid="chat-submit"][aria-label="Submit"]');
          if (visible(candidate) && !candidate.disabled && candidate.getAttribute('aria-disabled') !== 'true') button = candidate;
          else await pause(100);
        }
        if (!button || typeof form?.requestSubmit !== 'function') throw new Error('Grok submit form is unavailable');
        if (generation.canceled) return;
        generation.submitting = true;
        form.requestSubmit();
        await reconcile(generation);
        if (generation.canceled || generation.terminal) return;
        generation.terminal = true;
        send({id, type: 'completed', chatId: generation.chatId, messageId: generation.responseId});
        active.delete(id);
      } catch (error) { fail(generation, error); }
    })();
    return true;
  };
  site.cancel = id => {
    const generation = active.get(id);
    if (!generation) return false;
    generation.canceled = true;
    active.delete(id);
    if (!generation.submitting) return true;
    const stop = document.querySelector('button[aria-label="Stop"]');
    if (visible(stop)) stop.click();
    return false;
  };
  return site;
}

async function modelCatalog() {
  return [{id: 'website-default', name: 'Default', input: ['text', 'image', 'pdf'], contextTokens: null, outputTokens: null, streaming: true, cancellation: false, options: []}];
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
