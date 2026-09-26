const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function wait(fn,ms=12000){const end=Date.now()+ms;do{const v=fn();if(v)return v;await pause(120);}while(Date.now()<end);throw Error('Qwen interface not ready');}
async function api(){const s=await wait(()=>[...document.scripts].find(x=>x.src.includes('/qwen-chat-fe/')&&x.src.endsWith('/js/main.js')));const m=await import(s.src);if(typeof m.dN!=='function'||!String(m.dN).includes('/auths/')||typeof m.p!=='function'||!String(m.p).includes('Accept-Language'))throw Error('Qwen website module changed');return m;}
async function identity(){const m=await api();const j=await m.dN(false);if(j?.success===true&&typeof j.data?.id==='string'&&j.data.id&&j.data.role==='user')return j.data;if(j?.success===false&&j.data?.code==='Unauthorized')return null;throw Error('Unexpected Qwen identity response');}
async function request(path,params){const m=await api();const j=await m.p(path,{method:'GET',params,toast:false});if(j?.success!==true)throw Error('Qwen read failed: '+String(j?.data?.code||'unexpected response'));return j.data;}
async function list(page){const a=await request('/chats/',{page,exclude_project:true});if(!Array.isArray(a))throw Error('Unexpected Qwen history');return a;}
window.ox.install(({action})=>{
registerModelActions(action);
action('getSignInUrl',{async invoke(){return {url:'https://chat.qwen.ai/'};}});
action('getSignInState',{async invoke(){return {signedIn:!!(await identity())};}});
action('getCurrentUser',{async invoke(){const u=await identity();if(!u)throw Error('Sign in to Qwen');return {id:u.id,name:String(u.name||''),email:String(u.email||'')};}});
action('listWebsiteModels',{async invoke(){const d=await request('/models/');if(!Array.isArray(d?.data))throw Error('Unexpected model catalog');return {items:d.data.map(x=>({id:String(x.id),name:String(x.name)})),nextCursor:null};}});
action('listConversations',{async invoke(a){const page=Number(a.cursor||1);const items=await list(page);return {items:items.map(x=>({id:String(x.id),title:String(x.title||'')})),nextCursor:items.length?String(page+1):null};}});
action('searchConversations',{async invoke({query,cursor='1'}){if(!query.trim())throw Error('Search query must not be blank');const page=Number(cursor);if(!Number.isSafeInteger(page)||page<1)throw Error('Invalid search cursor');const rows=await request('/chats/search',{text:query,page});if(!Array.isArray(rows)||rows.some(x=>typeof x.id!=='string'||typeof x.title!=='string'))throw Error('Unexpected Qwen search response');return {items:rows.map(x=>({id:x.id,title:x.title,url:'https://chat.qwen.ai/c/'+encodeURIComponent(x.id)})),nextCursor:rows.length?String(page+1):null};}});
action('getConversation',{async invoke(a){return detail(a.conversationId);}});
action('openConversation',{async invoke(a){return openTarget(a.conversationId);}});
action('chat',{async invoke(a){return send(a.message,null);}});
action('continueChat',{async invoke(a){return send(a.message,a.conversationId);}});
action('selectModel',{async invoke(a){const b=await wait(()=>document.querySelector('[aria-label^="Models "]'));if(b.getAttribute('aria-label')==='Models '+a.name)return {selected:a.name};b.click();const option=await wait(()=>[...document.querySelectorAll('[role="option"]')].find(x=>x.querySelector('.mms-list__name-text')?.textContent.trim()===a.name));option.click();await wait(()=>document.querySelector('[aria-label^="Models "]')?.getAttribute('aria-label')==='Models '+a.name);return {selected:a.name};}});
});
async function detail(id){const d=await request('/chats/'+id);if(d?.id!==id||!Array.isArray(d.chat?.messages))throw Error('Qwen conversation identity mismatch');return {id:d.id,title:String(d.title||''),url:'https://chat.qwen.ai/c/'+d.id,messages:d.chat.messages.slice(-100).map(x=>({id:String(x.id),role:String(x.role),text:typeof x.content==='string'&&x.content?x.content:(x.content_list||[]).filter(y=>y.phase==='answer').map(y=>y.content||'').join('\n'),done:x.role==='user'||x.done===true})),hasEarlierMessages:!!d.chat.history?.pagination||d.chat.messages.length>100};}
async function editor(){return wait(()=>document.querySelector('textarea.message-input-textarea'));}
async function openTarget(id){const e=await editor();if(e.value.trim())throw Error('Existing Qwen draft preserved');const d=await detail(id);if(location.pathname!=='/c/'+id){const target=await wait(()=>{const matches=[...document.querySelectorAll('.chat-item-title-text')].filter(x=>x.textContent.trim()===d.title);if(matches.length>1)throw Error('Ambiguous sidebar title');return matches.length===1?matches[0]:null;});target.click();await wait(()=>location.pathname==='/c/'+id);await editor();}return detail(id);}
async function send(message,id){let before;if(id){before=await openTarget(id);}else{const e=await editor();if(e.value.trim())throw Error('Existing Qwen draft preserved');if(location.pathname!=='/'){const b=await wait(()=>document.querySelector('[role="button"][aria-label="New Chat"]'));b.click();await wait(()=>location.pathname==='/');}before=null;}const initial=await list(1);const e=await editor();if(e.value.trim())throw Error('Existing Qwen draft preserved');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,message);e.dispatchEvent(new Event('input',{bubbles:true}));const b=await wait(()=>document.querySelector('button.send-button[aria-label="Send"]'));if(b.disabled||e.value!==message)throw Error('Qwen composer not ready');b.click();let latest=null,confirmed=false;const end=Date.now()+15000;do{await pause(700);if(!id){const now=await list(1);const fresh=now.find(x=>!initial.some(y=>y.id===x.id));if(fresh)id=String(fresh.id);}if(id){latest=await detail(id);const fresh=latest.messages.filter(x=>!before?.messages.some(y=>y.id===x.id));const user=fresh.find(x=>x.role==='user'&&x.text===message);confirmed=!!user;const reply=user&&fresh.slice(fresh.indexOf(user)+1).find(x=>x.role==='assistant'&&x.done&&x.text);if(reply)return {submissionConfirmed:true,status:'completed',conversation:latest};}}while(Date.now()<end);return {submissionConfirmed:confirmed,status:confirmed?'pending':'uncertain',conversation:latest};}

function createModelSite(send) {
  const site = {};
const active = new Map();

  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const client = async () => { const module = await api(); return {module, request: module.p, identity: module.dN}; };
const checked = async (request, path, options) => {
    const result = await request(path, {...options, toast: false});
    if (result?.success !== true) throw new Error('Qwen request failed: ' + String(result?.data?.message || result?.data?.code || 'unexpected response'));
    return result.data;
  };
  site.signedIn = async () => !!(await identity());

  site.start = (id, prompt, modelID) => {
    const generation = {chatId: '', responseId: '', text: '', canceled: false, requestSubmitted: false};
    active.set(id, generation);
    void (async () => {
      try {
        if (!await site.signedIn()) throw new Error('Sign in to Qwen in Ox provider settings');
        if (generation.canceled) return;
        const {module, request} = await client();
        let modelId = modelID || '';
        for (let attempt = 0; attempt < 100 && !modelId; attempt++) {
          const stores = Object.values(module).filter(value => typeof value === 'function' && typeof value.getState === 'function');
          const selected = stores.map(value => value.getState()?.selectedModelIds).find(value => Array.isArray(value) && value.length);
          modelId = typeof selected?.[0] === 'string' ? selected[0] : '';
          if (!modelId) await pause(100);
        }
        if (!modelId) throw new Error('Select a Qwen text model on the website');
        if (generation.canceled) return;
        const attachments = window.__oxWebsiteFiles || [];
        delete window.__oxWebsiteFiles;
        let files = [];
        if (attachments.length) {
          const managers = Object.values(module).filter(value => typeof value === 'function' && typeof value.prototype?.addFiles === 'function' && typeof value.prototype?.retryFile === 'function');
          if (managers.length !== 1) throw new Error('Qwen attachment uploader is unavailable');
          const identity = await module.dN(false);
          const manager = new managers[0]({parsedFileTypes: ['file'], userId: identity?.data?.id});
          send({id, type: 'progress', phase: 'uploading'});
          await manager.addFiles(attachments);
          let ready = false;
          for (let attempt = 0; attempt < 120; attempt++) {
            if (generation.canceled) return;
            files = manager.getFiles();
            if (files.length !== attachments.length) throw new Error('Qwen rejected one or more attachments');
            if (files.some(file => file.error || ['failed', 'upload_error'].includes(file.status) || file.greenNet === 'green_error' || file.file?.meta?.parse_meta?.parse_status === 'failed')) throw new Error('Qwen could not process an attachment');
            ready = files.every(file => file.id && file.status === 'uploaded' && file.greenNet === 'success'
              && (file.type === 'image' || file.file?.meta?.parse_meta?.parse_status === 'success'));
            if (ready) break;
            send({id, type: 'progress', phase: 'processing', statuses: files.map(file => [file.type, file.status, file.greenNet, file.file?.meta?.parse_meta?.parse_status].join('/')).join(', ')});
            await pause(1000);
          }
          if (!ready) throw new Error('Qwen attachment processing timed out: ' + files.map(file => [file.type, file.status, file.greenNet, file.file?.meta?.parse_meta?.parse_status].join('/')).join(', '));
        }
        if (generation.canceled) return;
        const created = await checked(request, '/chats/new', {method: 'POST', data: {chatId: '', models: [modelId], project_id: '', timestamp: Date.now(), chat_type: 't2t', chat_mode: 'normal'}});
        if (typeof created?.id !== 'string' || !created.id) throw new Error('Qwen did not return a conversation ID');
        if (generation.canceled) return;
        generation.chatId = created.id;
        send({id, type: 'progress', chatId: generation.chatId});
        const user = {id: null, fid: crypto.randomUUID(), parentId: null, parent_id: null, childrenIds: [], role: 'user', content: prompt, ...(files.length ? {files} : {}), user_action: 'chat', timestamp: Math.floor(Date.now() / 1000), models: [modelId], model: '', chat_type: 't2t', sub_chat_type: 't2t', feature_config: {thinking_enabled: false, output_schema: 'phase', research_mode: 'normal'}, extra: {meta: {subChatType: 't2t'}}};
        const body = {stream: true, version: '2.1', incremental_output: true, chatId: generation.chatId, parentId: '', chat_id: generation.chatId, chat_mode: 'normal', model: modelId, parent_id: null, messages: [user], timestamp: Math.floor(Date.now() / 1000)};
        generation.requestSubmitted = true;
        const result = await request('/chat/completions', {method: 'post', responseType: 'stream', headers: {'X-Accel-Buffering': 'no', 'X-Request-Id': crypto.randomUUID()}, params: {chat_id: generation.chatId}, data: body});
        if (result?.success !== true || result.isStream !== true || !result.data?.getReader) throw new Error('Qwen did not start a completion stream');
        const reader = result.data.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        let done = false;
        const frameKeys = new Set();
        while (!done) {
          const next = await reader.read();
          if (next.done) break;
          buffer = (buffer + decoder.decode(next.value, {stream: true})).replace(/\r\n/g, '\n');
if (buffer.length > 1048576) throw Error('Qwen stream frame exceeded limit');
          let boundary;
          while ((boundary = buffer.indexOf('\n\n')) >= 0) {
            const event = buffer.slice(0, boundary);
            buffer = buffer.slice(boundary + 2);
            const data = event.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
            if (data === '[DONE]') { done = true; break; }
            if (!data) continue;
            const frame = JSON.parse(data);
            for (const key of Object.keys(frame)) frameKeys.add(key);
            if (frame.error) throw new Error(String(frame.error.message || frame.error));
            const createdResponse = frame['response.created'];
            if (createdResponse?.response_id) {
              generation.responseId = createdResponse.response_id;
              send({id, type: 'progress', chatId: generation.chatId, messageId: generation.responseId});
            }
            if (frame['response.stopped']) throw new Error('Qwen stopped the response');
            const delta = frame.choices?.[0]?.delta;
            if (typeof delta?.content === 'string' && (!delta.phase || delta.phase === 'answer') && delta.role !== 'function') {
              generation.text += delta.content;
              send({id, type: 'snapshot', text: generation.text, chatId: generation.chatId, messageId: generation.responseId});
            }
          }
        }
        if (!generation.responseId) throw new Error('Qwen stream ended without a response ID; frames=' + [...frameKeys].join(','));
        let finalMessage;
        for (let attempt = 0; attempt < 20; attempt++) {
          const chat = await checked(request, '/chats/' + generation.chatId, {method: 'GET'});
          const messages = chat?.chat?.messages;
          finalMessage = Array.isArray(messages) ? messages.find(value => value.role === 'assistant' && (value.id === generation.responseId || value.fid === generation.responseId)) : undefined;
          if (finalMessage?.done === true) break;
          await pause(250);
        }
        if (finalMessage?.done !== true) throw new Error('Qwen did not confirm completion; streamTerminal=' + done + '; frames=' + [...frameKeys].join(','));
        if (finalMessage.error) throw new Error('Qwen completed with an error');
        const finalText = typeof finalMessage.content === 'string' && finalMessage.content ? finalMessage.content : (finalMessage.content_list || []).filter(value => value.phase === 'answer').map(value => value.content || '').join('\n');
        if (typeof finalText !== 'string' || !finalText) throw new Error('Qwen completed without text');
        send({id, type: 'snapshot', text: finalText, chatId: generation.chatId, messageId: generation.responseId});
        send({id, type: 'completed', chatId: generation.chatId, messageId: generation.responseId});
      } catch (error) {
        send({id, type: 'failed', message: String(error?.message || error), chatId: generation.chatId, messageId: generation.responseId});
      } finally {
        active.delete(id);
      }
    })();
    return true;
  };
  site.cancel = async id => {
    const generation = active.get(id);
    if (!generation) return false;
    generation.canceled = true;
    if (!generation.requestSubmitted) return true;
    for (let attempt = 0; attempt < 50 && !generation.responseId && active.has(id); attempt++) await pause(100);
    if (!generation.chatId || !generation.responseId) return false;
    const {request} = await client();
    const result = await request('/chat/completions/stop', {method: 'post', params: {chat_id: generation.chatId}, data: {chat_id: generation.chatId, response_id: generation.responseId}, toast: false});
    return result?.success === true && result?.data?.status === true;
  };
  return site;
}

async function modelCatalog() {
  const data = await request('/models/');
  if (!Array.isArray(data?.data)) throw Error('Unexpected Qwen model catalog');
  const models = data.data.filter(model => model.info?.is_active !== false && model.info?.meta?.chat_type?.includes('t2t')).map(model => {
    const meta = model.info.meta;
    const positive = value => Number.isInteger(value) && value > 0 ? value : null;
    return {id: model.id, name: model.name, input: ['text', ...(meta.abilities?.vision === 1 ? ['image'] : []), ...(meta.abilities?.document === 1 ? ['pdf'] : [])], contextTokens: positive(meta.max_context_length), outputTokens: positive(meta.max_generation_length ?? meta.max_output_length), streaming: true, cancellation: true, options: []};
  });
  const module = await api();
  const current = await wait(() => {
    const selected = Object.values(module).filter(value => typeof value === 'function' && typeof value.getState === 'function').map(value => value.getState()?.selectedModelIds).find(value => Array.isArray(value) && value.length)?.[0];
    return models.find(model => model.id === selected);
  }, 10000);
  return [{...current, id: 'website-default', name: 'Default'}, ...models];
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
    const result = await modelSite.cancel(generationId);
    const status = typeof result === 'string' ? result : result === true ? 'cancelled' : 'requested';
    console.log('model cancel', generationId, status);
    return {status};
  }});
}
