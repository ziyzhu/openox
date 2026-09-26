const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const text = value => String(value ?? '').replace(/\s+/g, ' ').trim();
const visible = el => !!el && !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
const wait = async (read, label, timeout = 9000) => {
  const deadline = Date.now() + timeout;
  do { const result = read(); if (result) return result; await sleep(100); } while (Date.now() < deadline);
  throw new Error(label + ' not ready');
};
const provides = () => document.querySelector('#app')?.__vue_app__?._context?.provides;
const values = () => { const p = provides(); return p ? Reflect.ownKeys(p).map(k => p[k]) : []; };
const findContext = key => values().find(v => v && typeof v === 'object' && key in v);
const service = async typeName => {
  return wait(() => {
    const p = provides(); if (!p) return null;
    const entry = Reflect.ownKeys(p).map(k => p[k]).find(v => v?.serviceMap instanceof Map);
    return entry && [...entry.serviceMap.entries()].find(([d]) => d.typeName === typeName)?.[1];
  }, 'Kimi request client');
};
const identityWaiters = new Set();
const originalFetch = typeof window.fetch === 'function' ? window.fetch.bind(window) : null;
if (originalFetch) window.fetch = function(input, init) {
  const url = input instanceof Request ? input.url : String(input);
  const matched = /\/apiv2\/kimi\.gateway\.account\.v1\.UserService\/GetCurrentUser(?:\?|$)/.test(url)
    ? [...identityWaiters] : [];
  return originalFetch(input, init).then(response => {
    if (matched.length) {
      response.clone().json().then(body => {
        for (const w of matched) { if (identityWaiters.delete(w)) { clearTimeout(w.timer); w.resolve({status: response.status, body}); } }
      }, error => { for (const w of matched) { if (identityWaiters.delete(w)) { clearTimeout(w.timer); w.reject(new Error('Invalid account response JSON')); } } });
    }
    return response;
  }, error => {
    for (const w of matched) { if (identityWaiters.delete(w)) { clearTimeout(w.timer); w.reject(new Error('Account network request failed')); } }
    throw error;
  });
};
const identity = async () => {
  const client = await service('kimi.gateway.account.v1.UserService');
  let registration;
  const observed = new Promise((resolve, reject) => {
    registration = {resolve, reject};
    registration.timer = setTimeout(() => { identityWaiters.delete(registration); reject(new Error('Fresh account response was not observed')); }, 8000);
    identityWaiters.add(registration);
  });
  const request = Promise.resolve().then(() => client.getCurrentUser({}, {timeoutMs: 7500}));
  void request.catch(() => {});
  const result = await observed;
  if (result.status === 401 && result.body?.code === 'unauthenticated') return null;
  if (result.status === 200 && typeof result.body?.user?.id === 'string' && result.body.user.id) return result.body.user;
  throw new Error('Unclassified account response: HTTP ' + result.status);
};
const router = async () => wait(() => values().find(v => v && typeof v.push === 'function' && typeof v.resolve === 'function'), 'Kimi navigation');
const composer = () => [...document.querySelectorAll('.chat-input-editor[contenteditable="true"]')].find(visible);
const ready = () => wait(composer, 'Kimi composer');
const chatId = () => { const m = location.pathname.match(/^\/chat\/([A-Za-z0-9_-]+)\/?$/); return m && m[1] !== 'history' ? m[1] : null; };
const homeRef = 'new-' + Math.random().toString(36).slice(2);
const destination = () => ({conversationRef: chatId() || homeRef, url: location.origin + location.pathname});
const ensureNoDraft = () => { const e = composer(); if (e && text(e.innerText)) throw new Error('An existing Kimi draft is present; it was not changed.'); };
const readMessages = () => [...document.querySelectorAll('.segment-user, .segment-assistant')].map(el => {
  const user = el.classList.contains('segment-user');
  const parts = user ? [...el.querySelectorAll('.user-content__text')] : [...el.querySelectorAll('.markdown')];
  return {role: user ? 'user' : 'assistant', text: parts.map(p => p.innerText || '').join('\n').trim()};
}).filter(x => x.text);
const readConversation = async limit => {
  await ready();
  const id = chatId();
  if (id) await wait(() => { const c = findContext('chatInfo'); return c?.chatInfo?.value?.id === id && !c?.isFetchingChat?.value; }, 'Current conversation');
  const all = readMessages();
  return {...destination(), messages: all.slice(-limit), renderedOnly: true, truncated: all.length > limit};
};
const chats = async args => {
  const client = await service('kimi.gateway.chat.v1.ChatService');
  const result = await client.listChats({pageSize: args.limit ?? 20, pageToken: args.cursor || '', query: args.query || '', includePinned: false, withMessageContent: !!args.query}, {timeoutMs: 10000});
  if (!Array.isArray(result.chats)) throw new Error('Unexpected chat list response');
  return {items: result.chats.map(c => {
    if (typeof c.id !== 'string' || typeof c.name !== 'string') throw new Error('Invalid conversation identity');
    return {id: c.id, title: c.name, url: 'https://www.kimi.com/chat/' + encodeURIComponent(c.id), snippet: c.messageContent || null};
  }), nextCursor: result.nextPageToken || null};
};
const modelButtons = () => [...document.querySelectorAll('button.model-item[data-moon-key]')].filter(visible);
const openModels = async () => {
  await ready();
  if (!modelButtons().length) { const trigger = await wait(() => [...document.querySelectorAll('.current-model')].find(visible), 'Model picker'); trigger.click(); }
  return wait(() => modelButtons().length ? modelButtons() : null, 'Model options', 4000);
};
const models = async () => {
  const buttons = await openModels();
  const items = buttons.map(b => ({id: b.getAttribute('data-moon-key'), name: text(b.querySelector('.name')?.textContent), description: text(b.querySelector('.desc')?.textContent), selected: b.getAttribute('aria-checked') === 'true', available: !b.disabled && b.getAttribute('aria-disabled') !== 'true'}));
  document.querySelector('.current-model.active')?.click();
  return {items, nextCursor: null};
};
const send = async message => {
  const editor = await ready();
  ensureNoDraft();
  const context = findContext('segments');
  if (context?.isStreaming?.value || context?.isLoading?.value) throw new Error('Kimi is still responding; no message sent.');
  const previousCount = document.querySelectorAll('.segment-user').length;
  editor.focus();
  if (!document.execCommand('insertText', false, message)) throw new Error('Kimi editor did not accept the draft; no send attempted.');
  await wait(() => text(editor.innerText) === text(message), 'Entered message', 1500);
  const button = await wait(() => {
    const b = document.querySelector('.send-button-container');
    return visible(b) && !b.classList.contains('disabled') && b.getAttribute('aria-disabled') !== 'true' ? b : null;
  }, 'Send control', 2500);
  button.click(); // Exactly once. Never retry a submission.
  let confirmed = false;
  const deadline = Date.now() + 14000;
  let response = '';
  do {
    const users = [...document.querySelectorAll('.segment-user')];
    const last = users.at(-1);
    if (users.length > previousCount && text([...last.querySelectorAll('.user-content__text')].map(e => e.innerText).join('\n')) === text(message)) confirmed = true;
    if (confirmed) {
      const segments = [...document.querySelectorAll('.segment-user, .segment-assistant')];
      const lastUser = segments.lastIndexOf(last);
      response = segments.slice(lastUser + 1).filter(e => e.classList.contains('segment-assistant')).flatMap(e => [...e.querySelectorAll('.markdown')].map(x => x.innerText)).join('\n').trim();
      const live = findContext('segments');
      if (response && live && !live.isStreaming?.value && !live.isLoading?.value) return {...destination(), response, status: 'complete'};
    }
    await sleep(150);
  } while (Date.now() < deadline);
  return {...destination(), response, status: confirmed ? 'responding' : 'submissionUnconfirmed'};
};
window.ox.install(({action}) => {
registerModelActions(action);
  action('getSignInUrl', {async invoke() {return {url: 'https://www.kimi.com/'};}});
  action('getSignInState', {async invoke() {return {signedIn: !!(await identity())};}});
  action('getCurrentUser', {async invoke() {const u = await identity(); if (!u) throw new Error('Sign in to Kimi first'); return {id: u.id, name: u.nickname || null};}});
  action('getInterfaceState', {async invoke() {await service('kimi.gateway.account.v1.UserService'); return {path: location.pathname, readyState: document.readyState, composer: !!composer(), modelPicker: !!document.querySelector('.current-model')};}});
  action('listConversations', {async invoke(args) {return chats(args);}});
  action('searchConversations', {async invoke(args) {return chats(args);}});
  action('openConversation', {async invoke(args) {
    ensureNoDraft();
    const client = await service('kimi.gateway.chat.v1.ChatService');
    const r = await client.getChat({chatId: args.conversationId}, {timeoutMs: 8000});
    if (r.chat?.id !== args.conversationId) throw new Error('Requested conversation was not returned');
    await (await router()).push('/chat/' + encodeURIComponent(args.conversationId));
    await wait(() => chatId() === args.conversationId && findContext('chatInfo')?.chatInfo?.value?.id === args.conversationId && !findContext('chatInfo')?.isFetchingChat?.value, 'Requested conversation');
    await ready(); return destination();
  }});
  action('getCurrentConversation', {async invoke(args) {return readConversation(args.limit ?? 50);}});
  action('listWebsiteModels', {async invoke() {return models();}});
  action('chat', {async invoke(args) {ensureNoDraft(); await (await router()).push('/'); await wait(() => location.pathname === '/' && !document.querySelector('.segment-user'), 'New chat'); await ready(); return send(args.message);}});
  action('continueChat', {async invoke(args) {if (!chatId() || destination().conversationRef !== args.conversationRef) throw new Error('Stale conversation reference; reopen the intended chat first.'); await readConversation(1); return send(args.message);}});
});

function createModelSite(send) {
  const site = {};
const active = new Map();

  const service = async typeName => {
    for (let attempt = 0; attempt < 100; attempt++) {
      const provides = document.querySelector('#app')?.__vue_app__?._context?.provides;
      const provider = provides && Reflect.ownKeys(provides).map(key => provides[key]).find(value => value?.serviceMap instanceof Map);
      const client = provider && [...provider.serviceMap.entries()].find(([descriptor]) => descriptor.typeName === typeName)?.[1];
      if (client) return client;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error('Kimi request client is unavailable');
  };
  site.signedIn = async () => !!(await identity());
  site.start = (id, prompt, modelID, systemPrompt) => {
    const generation = {controller: new AbortController(), chatId: '', messageId: '', offset: 0, blocks: new Map()};
    active.set(id, generation);
    void (async () => {
      try {
        if (!await site.signedIn()) throw new Error('Sign in to Kimi in Ox provider settings');
        const client = await service('kimi.gateway.chat.v1.ChatService');
        const files = window.__oxWebsiteFiles || [];
        delete window.__oxWebsiteFiles;
        const fileBlocks = [];
        if (files.length) {
          const provides = document.querySelector('#app')?.__vue_app__?._context?.provides;
          const request = provides && Reflect.ownKeys(provides).filter(key => key.description === 'requestClient').map(key => provides[key])[0];
          if (typeof request !== 'function') throw new Error('Kimi attachment uploader is unavailable');
          const fileService = await service('kimi.gateway.file.v1.FileService');
          for (const file of files) {
            generation.controller.signal.throwIfAborted();
            const data = new FormData();
            data.append('file', file);
            send({id, type: 'progress', attachment: file.name, phase: 'uploading'});
            const response = await request({baseURL: '/apiv2-files', url: '/file/upload', method: 'POST', data,
              responseType: 'text', timeout: 120000, signal: generation.controller.signal});
            const uploaded = (typeof response === 'string' ? JSON.parse(response) : response)?.file;
            if (!uploaded?.id) throw new Error('Kimi did not return an uploaded file ID');
            let ready = false;
            for (let attempt = 0; attempt < 120; attempt++) {
              generation.controller.signal.throwIfAborted();
              const result = await fileService.getFileParseProgress({fileIds: [uploaded.id]}, {signal: generation.controller.signal});
              const progress = result.progresses?.find(value => value.fileId === uploaded.id);
              if (progress?.status === 4) throw new Error('Kimi could not process attachment: ' + file.name);
              if (progress?.status === 3) { ready = true; break; }
              send({id, type: 'progress', attachment: file.name, phase: 'processing'});
              await new Promise(resolve => setTimeout(resolve, 1000));
            }
            if (!ready) throw new Error('Kimi attachment processing timed out: ' + file.name);
            fileBlocks.push({$typeName: 'kimi.chat.v1.Block', id: '', messageId: '', content: {
              case: 'file', value: {$typeName: 'kimi.gateway.file.v1.File', id: uploaded.id, status: 3, failReason: ''}
            }});
          }
        }
        generation.controller.signal.throwIfAborted();
        const message = {
          $typeName: 'kimi.chat.v1.ChatMessage', id: '', parentId: '', role: 2,
          blocks: [{$typeName: 'kimi.chat.v1.Block', id: '', messageId: '', content: {
            case: 'text', value: {$typeName: 'kimi.chat.v1.TextBlock', content: prompt}
          }}, ...fileBlocks], labels: [], references: [], childrenMessageIds: [], refVotes: []
        };
        const request = {
          $typeName: 'kimi.gateway.chat.v1.ChatRequest', chatId: '', kimiplusId: '',
          scenario: 1, tools: [], message,
          options: {$typeName: 'kimi.gateway.chat.v1.ChatRequestOptions', thinking: false,
            ...(systemPrompt ? {systemPrompt} : {})}
        };
        const update = event => {
          generation.offset = Math.max(generation.offset, event.eventOffset || 0);
          if (event.event.case === 'chat') generation.chatId = event.event.value.id || generation.chatId;
          if (event.event.case === 'message') {
            const value = event.event.value;
            if (value.role === 3) {
              generation.messageId = value.id || generation.messageId;
              for (const block of value.blocks || []) {
                if (block.content?.case === 'text') generation.blocks.set(block.id, block.content.value.content || '');
              }
            }
          }
          if (event.event.case === 'block') {
            const block = event.event.value;
            if (block.content?.case === 'text') {
              const old = generation.blocks.get(block.id) || '';
              generation.blocks.set(block.id, event.op === 2 ? old + (block.content.value.content || '') : (block.content.value.content || ''));
              send({id, type: 'snapshot', text: [...generation.blocks.values()].join(''), chatId: generation.chatId, messageId: generation.messageId});
            }
          }
          if (event.event.case !== 'block') send({id, type: 'progress', chatId: generation.chatId, messageId: generation.messageId});
        };
        for await (const event of client.chat(request, {signal: generation.controller.signal})) update(event);
        if (!generation.chatId || !generation.messageId) throw new Error('Kimi stream ended without a generation identity');
        let result = await client.getMessage({chatId: generation.chatId, messageId: generation.messageId});
        for (let attempt = 0; result.message?.status === 1 && attempt < 2; attempt++) {
          for await (const event of client.resumeChat({chatId: generation.chatId, messageId: generation.messageId, eventOffset: generation.offset}, {signal: generation.controller.signal})) update(event);
          result = await client.getMessage({chatId: generation.chatId, messageId: generation.messageId});
        }
        const finalMessage = result.message;
        if (finalMessage?.status !== 2) throw new Error('Kimi generation ended with status ' + (finalMessage?.status ?? 'unknown'));
        const finalText = (finalMessage.blocks || []).filter(block => block.content?.case === 'text').map(block => block.content.value.content || '').join('');
        send({id, type: 'snapshot', text: finalText, chatId: generation.chatId, messageId: generation.messageId});
        send({id, type: 'completed', chatId: generation.chatId, messageId: generation.messageId});
      } catch (error) {
        send({id, type: 'failed', message: String(error?.message || error), chatId: generation.chatId, messageId: generation.messageId});
      } finally {
        active.delete(id);
      }
    })();
    return true;
  };
  site.cancel = async id => {
    const generation = active.get(id);
    if (!generation) return false;
    generation.controller.abort();
    if (!generation.chatId || !generation.messageId) return false;
    const client = await service('kimi.gateway.chat.v1.ChatService');
    await client.cancelChat({chatId: generation.chatId, messageId: generation.messageId});
    const result = await client.getMessage({chatId: generation.chatId, messageId: generation.messageId});
    return result.message?.status === 3;
  };
  return site;
}

async function modelCatalog() {
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
