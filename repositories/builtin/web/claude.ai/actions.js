const BOOT='/edge-api/bootstrap?statsig_hashing_algorithm=djb2&growthbook_format=sdk&cache_bust=1&include_system_prompts=false';
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function json(path){const r=await fetch(path,{credentials:'include',cache:'no-store'});if(r.redirected||r.status!==200)throw Error('Claude request failed: HTTP '+r.status);if(!(r.headers.get('content-type')||'').includes('json'))throw Error('Unexpected Claude response type');return r.json();}
async function account(){const j=await json(BOOT);if(j.account===null)return null;if(j.account&&typeof j.account.uuid==='string'&&Array.isArray(j.account.memberships))return j.account;throw Error('Unrecognized Claude session response');}
async function org(id){const a=await account();if(!a)throw Error('Sign in to Claude first');const ms=a.memberships.map(x=>x.organization).filter(x=>x&&typeof x.uuid==='string');if(id){if(!ms.some(x=>x.uuid===id))throw Error('Organization is not available to this account');return id;}if(ms.length!==1)throw Error('Choose an organizationId from getCurrentUser');return ms[0].uuid;}
// The new-chat page's resolved_org_uuid identifies the organization selected by Claude.
// Do not relax org() for ordinary Actions, where the caller must disambiguate.
async function modelActiveOrg(){const j=await json(BOOT);if(j.account===null)throw Error('Sign in to Claude first');const memberships=j.account?.memberships;if(!Array.isArray(memberships))throw Error('Unrecognized Claude session response');const active=j.resolved_org_uuid;if(typeof active!=='string'||!memberships.some(m=>m.organization?.uuid===active))throw Error('Claude active organization is unavailable');return active;}
const url=id=>'https://claude.ai/chat/'+id;
const summary=j=>({id:j.uuid,title:j.name||'',model:j.model||null,url:url(j.uuid),updatedAt:j.updated_at||null});
async function detail(organizationId,id){const o=await org(organizationId);const j=await json('/api/organizations/'+encodeURIComponent(o)+'/chat_conversations/'+encodeURIComponent(id)+'?tree=True&rendering_mode=messages&render_all_tools=true&include_inline_comparison=true&consistency=strong');if(j.uuid!==id||!Array.isArray(j.chat_messages))throw Error('Conversation identity or message shape mismatch');return {id:j.uuid,title:j.name||'',model:j.model||null,url:url(j.uuid),messages:j.chat_messages.map(m=>({id:m.uuid,parentId:m.parent_message_uuid||null,role:m.sender,text:typeof m.text==='string'&&m.text?m.text:(m.content||[]).filter(c=>c.type==='text'&&typeof c.text==='string').map(c=>c.text).join('\n'),createdAt:m.created_at||null}))};}
const visible=e=>!!e&&e.getClientRects().length>0;
async function wait(fn,ms=7000){const end=Date.now()+ms;while(Date.now()<end){const v=fn();if(v)return v;await pause(120);}throw Error('Claude interface not ready; no submission retried');}
const editor=()=>{const e=document.querySelector('[data-testid="chat-input"][contenteditable="true"]');return visible(e)?e:null;};
const picker=()=>document.querySelector('[data-testid="model-selector-dropdown"]');
const modelOptions=()=>Array.from(document.querySelectorAll('[role="menuitemradio"]')).filter(e=>visible(e)&&/^(Opus|Sonnet|Haiku)\s/.test(e.innerText.trim()));
const modelName=e=>e.innerText.trim().split('\n')[0].trim();
async function openModels(){await wait(editor);const p=await wait(()=>visible(picker())&&picker());if(p.getAttribute('aria-expanded')!=='true')p.click();await wait(()=>modelOptions().length);let prior='',since=Date.now();const end=Date.now()+4000;while(Date.now()<end){const key=modelOptions().map(modelName).join('|');if(key!==prior){prior=key;since=Date.now();}if(key&&Date.now()-since>=700)return modelOptions();await pause(100);}return modelOptions();}
function closeModels(){const p=picker();if(p&&p.getAttribute('aria-expanded')==='true')p.click();}
function conversationId(){return location.pathname.match(/^\/chat\/([a-f0-9-]{36})$/)?.[1]||null;}
async function send(message,target,organizationId){
 const organization=await org(organizationId);
 const baseline=target?await detail(organization,target):null;
 const known=new Set(baseline?baseline.messages.map(m=>m.id):[]);
 await wait(editor,5000);
 if(target){const link=await wait(()=>Array.from(document.querySelectorAll('a[href]')).find(a=>new URL(a.href,location.href).pathname==='/chat/'+target),3000);link.click();const lastHuman=baseline.messages.filter(m=>m.role==='human').pop();await wait(()=>{const users=Array.from(document.querySelectorAll('[data-testid="user-message"]'));const assistants=Array.from(document.querySelectorAll('[data-testid="assistant-message"]'));return conversationId()===target&&editor()&&(!lastHuman||users.at(-1)?.innerText.trim()===lastHuman.text.trim())&&(!assistants.length||assistants.at(-1).getAttribute('data-is-streaming')==='false');},6000);
 }else if(location.pathname!=='/new')throw Error('Expected a fresh new-chat page');
 const e=await wait(editor,2000);if(e.innerText.trim())throw Error('Existing draft present; refusing to overwrite it');if(!message.trim())throw Error('Message must not be blank');
 e.focus();if(!document.execCommand('insertText',false,message))throw Error('Unable to enter message; nothing submitted');
 const button=await wait(()=>{const b=document.querySelector('[data-testid="chat-input-send"]');return editor()?.innerText.trim()===message.trim()&&visible(b)&&!b.disabled&&b.getAttribute('aria-disabled')!=='true'?b:null;},2500);
 button.click();
 const end=Date.now()+12000;let confirmed=false;let observedId=null;
 while(Date.now()<end){const id=conversationId();if(id&&(!target||id===target)){observedId=id;try{const state=await detail(organization,id);const sent=state.messages.find(m=>m.role==='human'&&!known.has(m.id)&&m.text.trim()===message.trim());if(sent){confirmed=true;const reply=state.messages.find(m=>m.role==='assistant'&&!known.has(m.id)&&m.parentId===sent.id);const elements=Array.from(document.querySelectorAll('[data-testid="assistant-message"]'));const last=elements.at(-1);if(reply?.text&&last?.getAttribute('data-is-streaming')==='false'&&last.innerText.includes(reply.text.trim()))return {status:'response_available',conversationId:id,url:url(id),response:reply.text};}}catch(error){console.log('Claude response read pending');}}await pause(600);}
 return {status:confirmed?'submitted_pending':'submission_unconfirmed',conversationId:observedId,url:location.href,response:null};
}
window.ox.install(({action})=>{
registerModelActions(action);
 action('getSignInUrl',{async invoke(){return {url:'https://claude.ai/login'};}});
 action('getSignInState',{async invoke(){return {signedIn:(await account())!==null};}});
 action('getCurrentUser',{async invoke(){const a=await account();if(!a)throw Error('Sign in to Claude first');return {id:a.uuid,name:a.full_name||a.display_name||'',email:a.email_address||'',organizations:a.memberships.map(m=>({id:m.organization.uuid,name:m.organization.name||''}))};}});
 action('listConversations',{async invoke({organizationId,limit=20,cursor='0'}){const o=await org(organizationId),offset=Number(cursor);if(!Number.isSafeInteger(offset)||offset<0)throw Error('Invalid cursor');const j=await json('/api/organizations/'+encodeURIComponent(o)+'/chat_conversations_v2?limit='+limit+'&offset='+offset+'&archived=false&consistency=eventual');if(!Array.isArray(j.data)||typeof j.has_more!=='boolean')throw Error('Unexpected conversation list');if(j.has_more&&j.data.length===0)throw Error('Source pagination stalled');return {items:j.data.map(summary),nextCursor:j.has_more?String(offset+j.data.length):null};}});
 action('searchConversations',{async invoke({organizationId,query,scope='ranked',cursor,limit=25}){if(!query.trim())throw Error('Search query must not be blank');const o=await org(organizationId);if(scope==='titles'){const offset=Number(cursor||'0'),pageSize=Math.min(limit,30);if(!Number.isSafeInteger(offset)||offset<0)throw Error('Invalid title-search cursor');const j=await json('/api/organizations/'+encodeURIComponent(o)+'/chat_conversations_v2?limit='+pageSize+'&offset='+offset+'&archived=false&consistency=eventual');if(!Array.isArray(j.data)||typeof j.has_more!=='boolean'||j.has_more&&!j.data.length)throw Error('Unexpected history pagination response');const q=query.trim().toLocaleLowerCase();return {items:j.data.filter(x=>String(x.name||'').toLocaleLowerCase().includes(q)).map(summary),nextCursor:j.has_more?String(offset+j.data.length):null,degraded:false,mode:'title-substring',scope:'titles-unarchived',complete:!j.has_more};}if(cursor)throw Error('Native ranked search has no verified continuation; use scope=titles for paginated title search');const j=await json('/api/organizations/'+encodeURIComponent(o)+'/conversation/search/v2?query='+encodeURIComponent(query)+'&n='+limit+'&target_snippet_size=100');if(!Array.isArray(j.data)||typeof j.degraded!=='boolean'||typeof j.executed_mode!=='string')throw Error('Unexpected search response');if(j.next_page_token!==null)throw Error('Source returned an unsupported ranked-search continuation; use title search or narrow the query');return {items:j.data.map(x=>summary(x.conversation)),nextCursor:null,degraded:j.degraded,mode:j.executed_mode,scope:'ranked',complete:false};}});
 action('getConversation',{async invoke({organizationId,conversationId}){return detail(organizationId,conversationId);}});
 action('listWebsiteModels',{async invoke(){const items=(await openModels()).map(e=>({name:modelName(e),selected:e.getAttribute('aria-checked')==='true'}));closeModels();return {items,nextCursor:null};}});
 action('selectModel',{async invoke({name}){await openModels();let option;try{option=await wait(()=>modelOptions().find(e=>modelName(e)===name),4000);}catch(e){closeModels();throw Error('Requested model is not a selectable displayed option');}option.click();await wait(()=>picker()?.innerText.includes(name));return {selected:name};}});
 action('chat',{async invoke({message,organizationId}){return send(message,null,organizationId);}});
 action('continueChat',{async invoke({message,conversationId,organizationId}){return send(message,conversationId,organizationId);}});
});


// Observe the page-owned completion response; never send or retry a completion ourselves.
function createModelSite(send) {
  const active = new Map();
  const nativeFetch = window.fetch;
  const nativeXHR = window.XMLHttpRequest;
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const pathId = path => String(path).match(/\/chat_conversations\/([a-f0-9-]{36})\/completion(?:\?|$)/)?.[1] || null;
  const consume = async (response, generation) => {
    try {
      if (response.status !== 200 || !(response.headers.get('content-type') || '').includes('text/event-stream'))
        throw Error('Claude completion rejected: HTTP ' + response.status);
      generation.requestId = response.headers.get('x-completion-request-id') || '';
      const reader = response.body?.getReader();
      if (!reader) throw Error('Claude completion stream unavailable');
      const decoder = new TextDecoder();
      let pending = '', answer = '', finished = false, blockType = new Map(), textIndex = null;
      const frame = raw => {
        const lines = raw.replace(/\r/g, '').split('\n');
        const type = lines.find(line => line.startsWith('event:'))?.slice(6).trim() || '';
        const data = lines.filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
        if (!data) return;
        const value = JSON.parse(data);
        if (type === 'error' || value.type === 'error') throw Error('Claude completion stream reported an error');
        if (type === 'content_block_start') {
          const kind = value.content_block?.type;
          blockType.set(value.index, kind);
          if (kind === 'text' && textIndex === null) textIndex = value.index;
        }
        if (type === 'content_block_delta' && value.delta?.type === 'text_delta' && typeof value.delta.text === 'string') {
          if (textIndex === null) textIndex = value.index;
          if (value.index === textIndex && !generation.stopped) {
            answer += value.delta.text;
            send({id: generation.id, type: 'snapshot', text: answer, chatId: generation.chatId});
          }
        }
        if (type === 'message_delta' && value.delta?.stop_reason === 'end_turn') finished = true;
        if (type === 'message_stop' && !generation.stopped) {
          if (!finished || !answer) throw Error('Claude stream ended without a finished text answer');
          generation.finished = true;
          send({id: generation.id, type: 'completed', chatId: generation.chatId});
        }
      };
      while (!generation.finished && !generation.stopped) {
        const {done, value} = await reader.read();
        if (done) break;
        pending += decoder.decode(value, {stream: true});
        let end;
        while ((end = pending.indexOf('\n\n')) >= 0) {
          const raw = pending.slice(0, end);
          pending = pending.slice(end + 2);
          frame(raw);
          if (generation.finished || generation.stopped) break;
        }
        if (pending.length > 1000000) throw Error('Claude stream frame exceeded limit');
      }
      if (!generation.finished && !generation.stopped) throw Error('Claude completion stream ended without message_stop');
    } catch (error) {
      if (!generation.stopped) send({id: generation.id, type: 'failed', message: String(error.message || error)});
    }
  };
  window.fetch = async function(...args) {
    const request = args[0];
    const destination = typeof request === 'string' ? request : request?.url || '';
    const method = (args[1]?.method || request?.method || 'GET').toUpperCase();
    const chatId = method === 'POST' ? pathId(destination) : null;
    const generation = chatId && [...active.values()].find(item => item.phase === 'submitted' && !item.chatId && !item.stopped);
    if (generation) generation.chatId = chatId;
    try {
      const result = await nativeFetch.apply(this, args);
      if (generation) void consume(result.clone(), generation);
      return result;
    } catch (error) {
      if (generation && !generation.stopped) send({id: generation.id, type: 'failed', message: 'Claude completion network request failed'});
      throw error;
    }
  };
  // Some fresh Claude pages use XHR rather than fetch for completion.
  if (nativeXHR) {
    const open = nativeXHR.prototype.open, sendXHR = nativeXHR.prototype.send;
    nativeXHR.prototype.open = function(method, url, ...rest) {
      this.__oxCompletionChat = String(method).toUpperCase() === 'POST' ? pathId(url) : null;
      return open.call(this, method, url, ...rest);
    };
    nativeXHR.prototype.send = function(...args) {
      const chatId = this.__oxCompletionChat;
      const generation = chatId && [...active.values()].find(item => item.phase === 'submitted' && !item.chatId && !item.stopped);
      if (generation) {
        generation.chatId = chatId;
        let length = 0, buffer = '', answer = '', finished = false;
        this.addEventListener('progress', () => {
          if (generation.stopped || generation.finished) return;
          generation.requestId ||= this.getResponseHeader('x-completion-request-id') || '';
          const chunk = this.responseText.slice(length); length = this.responseText.length; buffer += chunk;
          let end; while ((end = buffer.indexOf('\n\n')) >= 0) {
            const raw = buffer.slice(0, end); buffer = buffer.slice(end + 2);
            const type = raw.match(/(?:^|\n)event: ([^\n]+)/)?.[1];
            let data; try { data = JSON.parse(raw.match(/(?:^|\n)data: (.+)/)?.[1] || '{}'); } catch { continue; }
            if (type === 'content_block_delta' && data.delta?.type === 'text_delta') {
              answer += data.delta.text;
              send({id: generation.id, type: 'snapshot', text: answer, chatId});
            }
            if (type === 'message_delta' && data.delta?.stop_reason === 'end_turn') finished = true;
            if (type === 'message_stop') {
              if (finished && answer) { generation.finished = true; send({id: generation.id, type: 'completed', chatId}); }
              else send({id: generation.id, type: 'failed', message: 'Claude stream ended without finished text'});
            }
          }
        });
        this.addEventListener('loadend', () => {
          generation.requestId ||= this.getResponseHeader('x-completion-request-id') || '';
          if (!generation.finished && !generation.stopped) send({id: generation.id, type: 'failed', message: 'Claude completion stream ended without message_stop'});
        });
      }
      return sendXHR.apply(this, args);
    };
  }
  const visible = element => !!element && element.getClientRects().length > 0;
  const editor = () => { const e = document.querySelector('[data-testid="chat-input"][contenteditable="true"]'); return visible(e) ? e : null; };
  const submit = async (prompt, state, modelId, systemText) => {
    try {
      if (location.pathname !== '/new') throw Error('Claude is not on a fresh conversation');
      let input; for (let i = 0; i < 150 && !input; i++) { input = editor(); if (!input) await pause(100); }
      if (!input) throw Error('Claude editor did not load');
      if (input.innerText.trim()) throw Error('Claude has an existing draft; refusing to overwrite it');
      // JSON escapes multiline system instructions; compare parsed messages, not source substrings.
      if (systemText) {
        const serialized = JSON.parse(prompt).conversation;
        if (!Array.isArray(serialized) || serialized.filter(message => message.role === 'system').map(message => message.text).join('\n\n') !== systemText)
          throw Error('System instructions missing from serialized prompt');
      }
      if (modelId) {
        const choices = await openModels();
        const option = choices.find(e => e.getAttribute('data-model-id') === modelId);
        if (!option) { closeModels(); throw Error('Requested model is not selectable on Claude'); }
        option.click();
        await wait(() => picker()?.innerText.includes(modelName(option)), 3000);
      }
      const files = window.__oxWebsiteFiles || [];
      delete window.__oxWebsiteFiles;
      const uploadInput = document.querySelector('input[data-testid="file-upload"]');
      const tiles = () => [...(uploadInput?.closest('fieldset')?.querySelectorAll('[data-testid="file-thumbnail"]') || [])];
      if (tiles().length) throw Error('Claude contains existing draft attachments');
      if (files.length) {
        if (!uploadInput) throw Error('Claude attachment input is unavailable');
        const transfer = new DataTransfer(); files.forEach(file => transfer.items.add(file));
        uploadInput.files = transfer.files;
        uploadInput.dispatchEvent(new Event('change', {bubbles: true}));
        let ready = false;
        for (let i = 0; i < 120 && !ready; i++) {
          if (state.canceled) throw Error('Claude attachment upload canceled');
          const uploaded = tiles().flatMap(element => {
            let fiber = element[Object.keys(element).find(key => key.startsWith('__reactFiber'))];
            const candidates = [];
            for (let depth = 0; fiber && depth < 20; depth++, fiber = fiber.return)
              for (const props of [fiber.memoizedProps, fiber.alternate?.memoizedProps])
                if (props?.file && typeof props.pending === 'boolean') candidates.push(props);
            return candidates;
          });
          if (uploaded.some(value => value.file.success === false)) throw Error('Claude could not process an attachment');
          ready = tiles().length === files.length && files.every(file => uploaded.some(value => value.file.file_name === file.name && value.file.file_uuid && value.file.success === true && value.pending === false));
          if (!ready) await pause(1000);
        }
        if (!ready) throw Error('Claude attachment processing timed out');
      }
      input = undefined;
      for (let i = 0; i < 30; i++) { input = editor(); if (input?.editor?.commands?.insertContent) break; await pause(100); }
      if (!input?.editor?.commands?.insertContent) throw Error('Claude editor unavailable after attachment processing');
      input.focus();
      if (!input.editor.commands.insertContent({type: 'text', text: prompt})) throw Error('Claude editor rejected prompt');
      await pause(0);
      let button;
      for (let i = 0; i < 30 && !button; i++) {
        const candidate = document.querySelector('[data-testid="chat-input-send"]');
        if (editor()?.editor?.state?.doc?.textContent === prompt && editor()?.innerText.trim() === prompt.trim() && visible(candidate) && !candidate.disabled && candidate.getAttribute('aria-disabled') !== 'true') button = candidate;
        else await pause(100);
      }
      if (!button) throw Error('Claude submit form unavailable');
      if (state.canceled) throw Error('Claude submission canceled');
      state.phase = 'submitted';
      button.click(); // One submission only. An uncertain outcome is never retried.
    } catch (error) { send({id: state.id, type: 'failed', message: String(error.message || error)}); }
  };
  return {
    start(id, prompt, modelId, systemText) {
      const state = {id, phase: 'preparing', canceled: false, stopped: false, finished: false, chatId: '', requestId: ''};
      active.set(id, state);
      void submit(prompt, state, modelId, systemText);
    },
    async cancel(id) {
      const state = active.get(id);
      if (!state) return 'unsupported';
      if (state.finished) return 'completed';
      if (state.phase === 'preparing') { state.canceled = true; state.stopped = true; return 'cancelled'; }
      const until = Date.now() + 3000;
      while ((!state.chatId || !state.requestId) && Date.now() < until && !state.finished) await pause(50);
      if (state.finished) return 'completed';
      if (!state.chatId || !state.requestId) return 'requested';
      const organization = state.organization;
      if (!organization) return 'requested';
      const endpoint = '/api/organizations/' + encodeURIComponent(organization) + '/chat_conversations/' + encodeURIComponent(state.chatId) + '/stop_response';
      let response;
      try { response = await nativeFetch(endpoint, {method: 'POST', credentials: 'include', headers: {'content-type': 'application/json'}, body: JSON.stringify({completion_request_id: state.requestId})}); }
      catch { return 'requested'; }
      if (response.status !== 200 || !(response.headers.get('content-type') || '').includes('json')) return 'requested';
      const value = await response.json();
      if (typeof value.stop_uuid !== 'string' || !value.stop_uuid) return 'requested';
      state.stopped = true;
      state.canceled = true;
      return 'cancelled';
    },
    setOrganization(id, organization) { const state = active.get(id); if (state) state.organization = organization; }
  };
}

async function modelCatalog() {
  // The website-default is always available; other picker entries are deliberately not advertised.
  return [{id: 'website-default', name: 'Default', input: ['text', 'image', 'pdf'], contextTokens: null, outputTokens: null, streaming: true, cancellation: true, options: []}];
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
    try {
      const organization = await modelActiveOrg(); // One bootstrap request per generation, never per read.
      modelSite.start(id, prompt, selected.id === 'website-default' ? '' : selected.id, args.messages.filter(message => message.role === 'system').map(message => message.text).join('\n\n'));
      modelSite.setOrganization(id, organization);
    } catch (error) { modelEvent({id, type: 'failed', message: String(error.message || error)}); }
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
    const status = await modelSite.cancel(generationId);
    if (status === 'cancelled') state.canceled = true;
    console.log('model cancel', generationId, status);
    return {status};
  }});
}
