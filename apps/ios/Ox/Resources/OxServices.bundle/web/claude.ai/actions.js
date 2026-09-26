const BOOT='/edge-api/bootstrap?statsig_hashing_algorithm=djb2&growthbook_format=sdk&cache_bust=1&include_system_prompts=false';
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function json(path){const r=await fetch(path,{credentials:'include',cache:'no-store'});if(r.redirected||r.status!==200)throw Error('Claude request failed: HTTP '+r.status);if(!(r.headers.get('content-type')||'').includes('json'))throw Error('Unexpected Claude response type');return r.json();}
async function account(){const j=await json(BOOT);if(j.account===null)return null;if(j.account&&typeof j.account.uuid==='string'&&Array.isArray(j.account.memberships))return j.account;throw Error('Unrecognized Claude session response');}
async function org(id){const a=await account();if(!a)throw Error('Sign in to Claude first');const ms=a.memberships.map(x=>x.organization).filter(x=>x&&typeof x.uuid==='string');if(id){if(!ms.some(x=>x.uuid===id))throw Error('Organization is not available to this account');return id;}if(ms.length!==1)throw Error('Choose an organizationId from getCurrentUser');return ms[0].uuid;}
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

function createModelSite(send) {
  const active = new Map();
  const submit = async (prompt, state) => {
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const visible = element => !!element && element.getClientRects().length > 0;
const editor = () => {
  const element = document.querySelector('[data-testid="chat-input"][contenteditable="true"]');
  return visible(element) ? element : null;
};
try {
  if (location.pathname !== '/new') throw new Error('Claude is not on a fresh conversation');
  let input;
  for (let attempt = 0; attempt < 150 && !input; attempt++) { input = editor(); if (!input) await pause(100); }
  if (!input) throw new Error('Claude editor did not load');
  if (input.innerText.trim()) throw new Error('Claude has an existing draft; clear it on the website before retrying');
  const files = window.__oxWebsiteFiles || [];
  delete window.__oxWebsiteFiles;
  const uploadInput = document.querySelector('input[data-testid="file-upload"]');
  const tiles = () => [...(uploadInput?.closest('fieldset')?.querySelectorAll('[data-testid="file-thumbnail"]') || [])];
  if (tiles().length) throw new Error('Claude contains existing draft attachments: ' + tiles().map(value => value.querySelector('button[aria-label^="Remove "]')?.getAttribute('aria-label') || value.innerText?.trim() || 'unknown file').join(', '));
  if (files.length) {
    if (!uploadInput) throw new Error('Claude attachment input is unavailable');
    const transfer = new DataTransfer();
    files.forEach(file => transfer.items.add(file));
    uploadInput.files = transfer.files;
    uploadInput.dispatchEvent(new Event('change', {bubbles: true}));
    let ready = false;
    for (let attempt = 0; attempt < 120 && !ready; attempt++) {
      if (state.canceled) throw new Error('Claude attachment upload canceled');
      const uploaded = tiles().flatMap(element => {
        let fiber = element[Object.keys(element).find(key => key.startsWith('__reactFiber'))];
        const candidates = [];
        for (let depth = 0; fiber && depth < 20; depth++, fiber = fiber.return) {
          for (const props of [fiber.memoizedProps, fiber.alternate?.memoizedProps]) {
            if (props?.file && typeof props.pending === 'boolean') candidates.push(props);
          }
        }
        return candidates;
      });
      if (uploaded.some(value => value.file.success === false)) throw new Error('Claude could not process an attachment');
      ready = tiles().length === files.length && files.every(file => uploaded.some(value =>
        value.file.file_name === file.name && value.file.file_uuid && value.file.success === true && value.pending === false));
      if (!ready) await pause(1000);
    }
    if (!ready) throw new Error('Claude attachment processing timed out');
  }
  input = undefined;
  for (let attempt = 0; attempt < 30; attempt++) {
    input = editor();
    if (input?.editor?.commands?.insertContent) break;
    await pause(100);
  }
  if (!input?.editor?.commands?.insertContent) throw new Error('Claude editor is unavailable after attachment processing');
  input.focus();
  if (!input.editor.commands.insertContent({type: 'text', text: prompt})) throw new Error('Claude editor rejected the prompt');
  await pause(0);
  let button;
  for (let attempt = 0; attempt < 30 && !button; attempt++) {
    const candidate = document.querySelector('[data-testid="chat-input-send"]');
    if (editor()?.editor?.state?.doc?.textContent === prompt && editor()?.innerText.trim() === prompt.trim() && visible(candidate) && !candidate.disabled && candidate.getAttribute('aria-disabled') !== 'true') button = candidate;
    else await pause(100);
  }
  if (!button || editor()?.editor?.state?.doc?.textContent !== prompt || editor()?.innerText.trim() !== prompt.trim()) throw new Error('Claude submit form is unavailable');
  if (state.canceled) throw new Error('Claude submission canceled');
  state.phase = 'submitted';
button.click();
  return {status: 'submitted'};
} catch (error) { return {status: 'failed', message: String(error?.message || error)}; }
  };
  return {
    start(id, prompt) {
      const state = {phase: 'preparing', canceled: false};
      active.set(id, state);
      void submit(prompt, state).then(result => {
        if (result.status === 'failed') send({id, type: 'failed', message: result.message});
      }).catch(error => send({id, type: 'failed', message: String(error.message || error)}));
    },
    cancel(id) {
      const state = active.get(id);
      if (!state) return 'unsupported';
      state.canceled = true;
      return state.phase === 'preparing' ? 'cancelled' : 'unsupported';
    },
    async observe(prompt) {
const path = location.pathname.match(/^\/chat\/([a-f0-9-]{36})$/);
if (!path) return {status: 'pending'};
const chatId = path[1];
const request = async url => {
  const response = await fetch(url, {credentials: 'include', cache: 'no-store'});
  if (response.redirected || response.status !== 200) return null;
  return response.json();
};
const bootstrap = await request('/edge-api/bootstrap?statsig_hashing_algorithm=djb2&growthbook_format=sdk&cache_bust=1&include_system_prompts=false');
if (!bootstrap?.account) return {status: 'failed', message: 'Claude session ended during generation'};
const organizations = bootstrap.account.memberships?.map(value => value.organization?.uuid).filter(value => typeof value === 'string') || [];
if (!organizations.length) throw new Error('Claude organization is unavailable');
let conversation;
for (const organization of organizations) {
  const path = '/api/organizations/' + encodeURIComponent(organization) + '/chat_conversations/' + encodeURIComponent(chatId) + '?tree=True&rendering_mode=messages&render_all_tools=true&include_inline_comparison=true&consistency=strong';
  const value = await request(path);
  if (value?.uuid === chatId && Array.isArray(value.chat_messages)) { conversation = value; break; }
}
if (!conversation) return {status: 'pending'};
const messages = conversation.chat_messages;
const messageText = value => typeof value?.text === 'string' && value.text ? value.text : (value?.content || []).filter(block => block.type === 'text' && typeof block.text === 'string').map(block => block.text).join('\n');
const user = messages.find(value => value.sender === 'human' && messageText(value) === prompt);
if (!user) return {status: 'failed', message: 'Claude conversation did not contain the submitted prompt'};
const assistant = messages.find(value => value.sender === 'assistant' && value.parent_message_uuid === user.uuid);
const text = messageText(assistant);
if (!text || typeof assistant?.uuid !== 'string') return {status: 'pending'};
const rendered = [...document.querySelectorAll('[data-testid="assistant-message"]')].at(-1);
if (rendered?.getAttribute('data-is-streaming') !== 'false' || !rendered.innerText.trim()) return {status: 'pending'};
return {status: 'complete', chatId, messageId: assistant.uuid, text};
    }
  };
}

async function modelCatalog() {
  return [{id: 'website-default', name: 'Default', input: ['text', 'image', 'pdf'], contextTokens: null, outputTokens: null, streaming: false, cancellation: false, options: []}];
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
    void modelPollCompletion(state);
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

async function modelPollCompletion(state) {
  while (!state.terminal && !state.canceled && Date.now() - state.started < 300000) {
    await modelDelay(2000);
    if (state.terminal || state.canceled) return;
    try {
      const result = await modelSite.observe(state.prompt, state.chatId);
      if (result.status === 'complete') {
        modelEvent({id: state.id, type: 'snapshot', text: result.text, chatId: result.chatId, messageId: result.messageId});
        modelEvent({id: state.id, type: 'completed'});
      } else if (result.status === 'failed') modelEvent({id: state.id, type: 'failed', message: result.message});
    } catch (error) { modelEvent({id: state.id, type: 'failed', message: String(error.message || error)}); }
  }
}
