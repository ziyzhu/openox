// Kimi's request client owns authentication and transport. No credentials are read or copied.
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
// Every account invocation registers before a fresh page-owned network request.
// Only observed 200 user objects and 401 unauthenticated bodies classify session state.
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
  // Capture reads only the response. The website client supplies its own authentication.
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
  action('listModels', {async invoke() {return models();}});
  action('chat', {async invoke(args) {ensureNoDraft(); await (await router()).push('/'); await wait(() => location.pathname === '/' && !document.querySelector('.segment-user'), 'New chat'); await ready(); return send(args.message);}});
  action('continueChat', {async invoke(args) {if (!chatId() || destination().conversationRef !== args.conversationRef) throw new Error('Stale conversation reference; reopen the intended chat first.'); await readConversation(1); return send(args.message);}});
});
