const oxNativeRequestAnimationFrame = typeof window.requestAnimationFrame === 'function'
  ? window.requestAnimationFrame.bind(window)
  : callback => window.setTimeout?.(() => callback(window.performance?.now?.() || Date.now()), 16);
const oxNativeCancelAnimationFrame = typeof window.cancelAnimationFrame === 'function'
  ? window.cancelAnimationFrame.bind(window)
  : id => window.clearTimeout?.(id);
let oxNextAnimationFrameId = 1000000000;
const oxAnimationFrames = new Map();
window.requestAnimationFrame = callback => {
  const id = oxNextAnimationFrameId++;
  const record = {nativeId: null, timerId: null, done: false};
  const finish = timestamp => {
    if (record.done) return;
    record.done = true;
    if (record.timerId !== null) window.clearTimeout?.(record.timerId);
    oxAnimationFrames.delete(id);
    callback(timestamp);
  };
  oxAnimationFrames.set(id, record);
  record.nativeId = oxNativeRequestAnimationFrame(finish);
  record.timerId = window.setTimeout?.(() => {
    if (!record.done && record.nativeId !== null) oxNativeCancelAnimationFrame(record.nativeId);
    finish(window.performance?.now?.() || Date.now());
  }, 100) ?? null;
  return id;
};
window.cancelAnimationFrame = id => {
  const record = oxAnimationFrames.get(id);
  if (!record) return oxNativeCancelAnimationFrame(id);
  record.done = true;
  if (record.nativeId !== null) oxNativeCancelAnimationFrame(record.nativeId);
  if (record.timerId !== null) window.clearTimeout?.(record.timerId);
  oxAnimationFrames.delete(id);
};

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const visible = element => !!element && element.getClientRects().length > 0;
const nodeText = element => String(element?.innerText || element?.textContent || '').trim();
const generations = new Map();

const nativeManusFetch = window.fetch;
let manuscriptAuthObservation = null;
window.fetch = async function(...args) {
  const request = args[0];
  const url = typeof request === 'string' ? request : request?.url || '';
  const method = String(args[1]?.method || request?.method || 'GET').toUpperCase();
  const response = await nativeManusFetch.apply(this, args);
  if (method === 'POST' && url === 'https://api.manus.im/user.v1.UserService/UserInfo') {
    void (async () => {
      try {
        const value = await response.clone().json();
        if (response.status === 200 && typeof value?.userId === 'string' && value.userId) manuscriptAuthObservation = {signedIn: true, at: Date.now()};
        else if (response.status === 401 && value?.code === 'unauthenticated' && value?.message === 'missing authorization header') manuscriptAuthObservation = {signedIn: false, at: Date.now()};
      } catch {}
    })();
  }
  return response;
};

let manusRuntimeModuleId = 987660000;
async function waitForManusAuthShell() {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (/^\/login(?:\/|$)/.test(location.pathname) || document.querySelector('[data-testid="chat-input-composer"] [contenteditable="true"]')) return;
    await pause(100);
  }
}
async function loadManusRuntime() {
  const source = [...document.scripts].find(script => script.src && script.src.includes('manuscdn.com/webapp/'));
  if (!source || typeof window.TURBOPACK?.push !== 'function') throw Error('Manus page client is unavailable');
  let runtime = null;
  const id = manusRuntimeModuleId++;
  window.TURBOPACK.push([source, id, value => { runtime = value; }]);
  await window.TURBOPACK.push([source, {otherChunks: [], runtimeModuleIds: [id]}]);
  if (!runtime) throw Error('Manus page client did not initialize');
  return runtime;
}
async function freshManusUserInfo() {
  const runtime = await loadManusRuntime();
  const userInfo = runtime.i(978776)?.api?.UserService?.userInfo;
  if (typeof userInfo !== 'function') throw Error('Manus account endpoint is unavailable');
  const deadline = Date.now() + 6000;
  while (true) {
    try {
      const value = await userInfo({});
      if (value && typeof value.userId === 'string' && value.userId) return value;
      throw Error('Unrecognized Manus account response');
    } catch (error) {
      const message = String(error?.message || error);
      const signedOut = error?.code === 16 && message === '[unauthenticated] missing authorization header';
      if (!signedOut) throw Error('Manus account request failed: ' + message);
      if (/^\/login(?:\/|$)/.test(location.pathname) || Date.now() >= deadline) return null;
      await pause(250);
    }
  }
}

function classify(message) {
  const value = String(message || '').toLowerCase();
  if (/sign in|login|session|unauth|401/.test(value)) return 'authentication';
  if (/rate.?limit|too many|429|credit|quota/.test(value)) return 'rateLimited';
  if (/context|too (?:many|long)|prompt.*long|token/.test(value)) return 'contextOverflow';
  if (/network|timed out|load failed|offline/.test(value)) return 'network';
  if (/attachment|image|pdf|unsupported/.test(value)) return 'unsupportedInput';
  return 'provider';
}
function fail(state, message) {
  if (state.terminal) return;
  state.terminal = {type: 'failed', message: String(message || 'Manus generation failed'), kind: classify(message)};
}
function currentTurn(prompt) {
  return [...document.querySelectorAll('[data-turn-id]')].find(turn => {
    const question = turn.querySelector('[data-chat-question-bubble="true"] .chat-message-body');
    return question && nodeText(question) === prompt.trim();
  }) || null;
}
function taskState(state) {
  const turn = currentTurn(state.prompt);
  if (!turn) return {turn: null, answer: '', complete: false, failed: false};
  const answer = [...turn.querySelectorAll('.latest-chat-reply .chat-message-body')]
    .map(nodeText).filter(Boolean).join('\n');
  const labels = [...turn.querySelectorAll('span')].map(element => element.textContent.trim());
  return {turn, answer, complete: labels.includes('Task completed'), failed: labels.some(text => /task failed|task stopped|insufficient credits/i.test(text))};
}
async function monitor(state) {
  const deadline = Date.now() + 600000;
  while (!state.terminal && Date.now() < deadline) {
    if (/^\/login(?:\/|$)/.test(location.pathname)) { fail(state, 'Sign in to Manus first'); break; }
    const task = taskState(state);
    if (task.turn) state.confirmed = true;
    if (task.failed) { fail(state, 'Manus reported that the task failed or stopped'); break; }
    if (task.complete) {
      if (!task.answer) { fail(state, 'Manus completed without a readable text response'); break; }
      if (task.answer.length > 500000) { fail(state, 'Manus response exceeded the size limit'); break; }
      state.text = task.answer;
      state.events.push({type: 'text', text: task.answer}, {type: 'completed'});
      state.terminal = {type: 'completed'};
      break;
    }
    await pause(200);
  }
  if (!state.terminal) fail(state, 'Manus generation timed out');
  if (state.terminal?.type === 'failed') state.events.push(state.terminal);
}
async function readyEditor() {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (/^\/login(?:\/|$)/.test(location.pathname)) throw Error('Sign in to Manus first');
    const editor = [...document.querySelectorAll('[data-testid="chat-input-composer"] [contenteditable="true"]')].find(visible);
    if (editor) return editor;
    await pause(100);
  }
  throw Error('Manus editor did not load');
}
function sendButton() {
  return [...document.querySelectorAll('[data-testid="chat-input-composer"] button')].find(button => {
    const icon = button.querySelector('svg[viewBox="0 0 16 16"]');
    return visible(button) && icon && !button.disabled && button.getAttribute('aria-disabled') !== 'true';
  }) || null;
}


function routeTaskId() {
  return location.pathname.match(/^\/app\/([A-Za-z0-9_-]+)$/)?.[1] || null;
}
function recentTaskItems() {
  const seen = new Set();
  return [...document.querySelectorAll('[data-session-item="true"][data-session-id]')].map(element => {
    const id = element.getAttribute('data-session-id') || '';
    return {id, title: nodeText(element).replace(/\s+/g, ' '), url: 'https://manus.im/app/' + encodeURIComponent(id)};
  }).filter(item => item.id && item.title && !seen.has(item.id) && seen.add(item.id)).slice(0, 60);
}
async function ensureTaskSidebar() {
  if (/\bTasks\b/.test(document.body.innerText) || document.querySelector('[data-session-item="true"][data-session-id]')) return;
  const trigger = document.querySelector('svg.lucide-panel-left')?.parentElement;
  if (visible(trigger)) trigger.click();
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (/\bTasks\b/.test(document.body.innerText) || document.querySelector('[data-session-item="true"][data-session-id]')) return;
    await pause(100);
  }
}
async function waitRecentTaskItems() {
  await ensureTaskSidebar();
  const deadline = Date.now() + 10000;
  let key = '', changedAt = Date.now();
  while (Date.now() < deadline) {
    const items = recentTaskItems();
    const next = items.map(item => item.id + ':' + item.title).join('|');
    if (next !== key) { key = next; changedAt = Date.now(); }
    if (items.length && Date.now() - changedAt >= 600) return items;
    if (!items.length && /No tasks yet/.test(document.body.innerText) && Date.now() - changedAt >= 600) return [];
    await pause(100);
  }
  return recentTaskItems();
}
function renderedTask() {
  const id = routeTaskId();
  if (!id) throw Error('Manus is not showing a task');
  const turns = [...document.querySelectorAll('[data-turn-id]')];
  const messages = [];
  for (const turn of turns) {
    const question = turn.querySelector('[data-chat-question-bubble="true"] .chat-message-body');
    if (nodeText(question)) messages.push({id: question.closest('[data-event-id]')?.getAttribute('data-event-id') || null, role: 'user', text: nodeText(question)});
    for (const reply of turn.querySelectorAll('.latest-chat-reply .chat-message-body')) {
      const text = nodeText(reply);
      if (text) messages.push({id: reply.closest('[data-event-id]')?.getAttribute('data-event-id') || null, role: 'assistant', text});
    }
  }
  const last = turns.at(-1);
  const labels = last ? [...last.querySelectorAll('span')].map(element => element.textContent.trim()) : [];
  const status = labels.includes('Task completed') ? 'completed' : labels.some(text => /task failed|task stopped|insufficient credits/i.test(text)) ? 'failed' : turns.length ? 'running' : 'unknown';
  const listed = recentTaskItems().find(item => item.id === id);
  const pageTitle = document.title.replace(/\s*-\s*Manus\s*$/, '').trim();
  return {id, title: listed?.title || pageTitle || 'Manus task', url: 'https://manus.im/app/' + encodeURIComponent(id), status, messages};
}

function fileKind(value, name, mimeType) {
  const raw = String(value || '').toLowerCase();
  const ext = String(name || '').split('.').pop()?.toLowerCase() || '';
  if (raw.includes('image') || String(mimeType || '').startsWith('image/') || /^(png|jpe?g|gif|webp|svg)$/.test(ext)) return 'image';
  if (raw.includes('pdf') || mimeType === 'application/pdf' || ext === 'pdf') return 'pdf';
  if (raw.includes('presentation') || /^(pptx?|key)$/.test(ext)) return 'presentation';
  if (raw.includes('document') || /^(docx?|txt|md|rtf)$/.test(ext)) return 'document';
  if (raw.includes('spreadsheet') || /^(xlsx?|csv)$/.test(ext)) return 'spreadsheet';
  if (raw.includes('web') || raw.includes('artifact')) return 'artifact';
  return raw || 'file';
}
function normalizeManusFile(value, source = 'generated') {
  if (!value || typeof value !== 'object') return null;
  const url = String(value.fileUrl || value.url || value.downloadUrl || value.previewUrl || value.signedUrl || '').trim() || null;
  const name = String(value.displayName || value.fileName || value.filename || value.name || value.path || '').trim() || (url ? decodeURIComponent(url.split('/').pop()?.split('?')[0] || '') : 'Untitled file');
  const mimeType = String(value.mimeType || value.contentType || value.mediaType || '').trim() || null;
  const size = Number(value.fileSize ?? value.size ?? value.sizeBytes);
  const width = Number(value.width);
  const height = Number(value.height);
  const pages = Number(value.pageCount ?? value.numPages);
  return {
    id: value.uid == null && value.id == null && value.fileId == null ? null : String(value.uid ?? value.id ?? value.fileId),
    name,
    kind: fileKind(value.fileType || value.type || value.kind, name, mimeType),
    mimeType,
    sizeBytes: Number.isSafeInteger(size) && size >= 0 ? size : null,
    url,
    thumbnailUrl: String(value.thumbnailUrl || value.thumbnail || value.previewImageUrl || '').trim() || null,
    width: Number.isSafeInteger(width) && width > 0 ? width : null,
    height: Number.isSafeInteger(height) && height > 0 ? height : null,
    pageCount: Number.isSafeInteger(pages) && pages > 0 ? pages : null,
    tokenCount: null,
    source,
    downloadable: !!url
  };
}
function eventFiles(event) {
  const values = [];
  if (Array.isArray(event?.attachments)) values.push(...event.attachments);
  if (event?.attachmentRefs && typeof event.attachmentRefs === 'object') values.push(...Object.values(event.attachmentRefs));
  return values.map(value => normalizeManusFile(value, event?.sender === 'user' ? 'attachment' : 'generated')).filter(Boolean);
}
function taskSummary(value) {
  const id = String(value?.uid || '');
  return {
    id,
    title: String(value?.title || value?.displayTitle || 'Untitled Manus task'),
    url: 'https://manus.im/app/' + encodeURIComponent(id),
    status: value?.status === 7 ? 'completed' : value?.hasRunningBackgroundJobs ? 'running' : 'unknown',
    statusCode: Number.isInteger(value?.status) ? value.status : null,
    costCredits: Number.isSafeInteger(Number(value?.costedCredits)) ? Number(value.costedCredits) : null,
    isArchived: !!value?.isArchived,
    isFavorite: !!value?.isFavorite,
    lastMessage: String(value?.lastDisplayMessage || '')
  };
}

function normalizeLibraryItem(value, source) {
  const raw = value?.fileItem && typeof value.fileItem === 'object' ? value.fileItem : value;
  const file = normalizeManusFile({...raw, id: value?.fileUid ?? raw?.fileUid ?? raw?.id, displayName: value?.displayName || raw?.displayName, fileName: value?.fileName || raw?.fileName, thumbnailUrl: value?.coverImage || raw?.coverImage || raw?.thumbnailUrl}, 'generated');
  if (!file) return null;
  const sessionId = String(raw?.sessionUid || value?.sessionUid || '').trim() || null;
  return {
    ...file,
    sessionId,
    sessionTitle: String(value?.sessionTitle || raw?.sessionTitle || '').trim() || null,
    category: source,
    favorite: !!(value?.favorite ?? raw?.favorite),
    typeCode: raw?.fileType == null ? null : String(raw.fileType),
    artifactUri: String(raw?.addonResourceUri || value?.resourceUri || '').trim() || null
  };
}
const creationCategories = {all: 0, website: 1, mobile_app: 2, game: 3};
const documentTypes = {all: 0, websites: 1, documents: 2, media: 3, audio: 4, slides: 5, tables: 6, images: 7, audio_video: 8, web_apps: 9, games: 10, videos: 11, others: 100};
async function manusServiceApi() {
  const runtime = await loadManusRuntime();
  const api = runtime.i(978776)?.api;
  if (!api?.SessionService || !api?.UserService) throw Error('Manus service API is unavailable');
  return api;
}
async function readSessionEndpoint(name, input) {
  const runtime = await loadManusRuntime();
  const api = runtime.i(312276)?.sessionApi;
  const store = runtime.i(936538)?.store;
  const endpoint = api?.endpoints?.[name];
  if (!endpoint || !store) throw Error('Manus task endpoint is unavailable');
  const request = store.dispatch(endpoint.initiate(input, {forceRefetch: true, subscribe: false}));
  try { return await request.unwrap(); }
  finally { request.unsubscribe?.(); }
}
async function richTask(id) {
  await openLoadedTask(id);
  const rendered = renderedTask();
  const [details, fileResult] = await Promise.all([
    readSessionEndpoint('getSessionV2', {sessionId: id}),
    readSessionEndpoint('getSessionFiles', {sessionId: id, type: 'private'})
  ]);
  const events = (details?.segments || []).flatMap(segment => Array.isArray(segment?.events) ? segment.events : []);
  const messages = events.filter(event => event?.type === 'chat' && (event.sender === 'user' || event.sender === 'assistant')).map(event => {
    const contentParts = Array.isArray(event.contents) ? event.contents.filter(part => part?.type === 'text').map(part => String(part.value || '')).filter(Boolean) : [];
    return {id: event.id == null ? null : String(event.id), role: event.sender, text: String(event.content || contentParts.join('\n')), files: eventFiles(event)};
  });
  const taskFiles = (Array.isArray(fileResult?.files) ? fileResult.files : []).map(value => normalizeManusFile(value, 'generated')).filter(Boolean);
  const allFiles = [...taskFiles, ...messages.flatMap(message => message.files)];
  const seen = new Set();
  const files = allFiles.filter(file => { const key = [file.id, file.url, file.name].join('|'); return !seen.has(key) && seen.add(key); });
  return {...rendered, title: String(details?.title || rendered.title), messages: messages.length ? messages : rendered.messages.map(message => ({...message, files: []})), files};
}
async function openLoadedTask(id) {
  if (!/^[A-Za-z0-9_-]+$/.test(id)) throw Error('Invalid Manus task ID');
  if (routeTaskId() !== id) {
    history.pushState({}, '', '/app/' + encodeURIComponent(id));
    dispatchEvent(new PopStateEvent('popstate'));
  }
  const deadline = Date.now() + 12000;
  while (Date.now() < deadline) {
    if (/^\/login(?:\/|$)/.test(location.pathname)) throw Error('Sign in to Manus first');
    const turn = document.querySelector('[data-turn-id]');
    if (routeTaskId() === id && turn?.querySelector('[data-chat-question-bubble="true"] .chat-message-body') && document.querySelector('[data-testid="chat-input-composer"]')) return;
    await pause(100);
  }
  throw Error('Manus task was not found or did not load');
}
async function enterDraft(editor, message) {
  if (!message.trim()) throw Error('Message must not be blank');
  if (nodeText(editor)) throw Error('Manus has an existing draft; refusing to overwrite it');
  editor.focus();
  const inserted = editor.editor?.commands?.insertContent
    ? !!editor.editor.commands.insertContent({type: 'text', text: message})
    : document.execCommand('insertText', false, message);
  if (!inserted) throw Error('Manus editor rejected the message');
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const button = nodeText(editor) === message.trim() ? sendButton() : null;
    if (button) return button;
    await pause(100);
  }
  throw Error('Manus submit control was not ready; nothing submitted');
}
async function sendOrdinaryTask(message, targetId) {
  if (targetId) await openLoadedTask(targetId);
  else if (!/^\/app\/?$/.test(location.pathname)) throw Error('Manus is not on a fresh task page');
  const baseline = new Set([...document.querySelectorAll('[data-turn-id]')].map(turn => turn.getAttribute('data-turn-id')));
  const editor = await readyEditor();
  const button = await enterDraft(editor, message);
  button.click();
  const deadline = Date.now() + 18000;
  let taskId = targetId || null, matched = null;
  while (Date.now() < deadline) {
    taskId = routeTaskId() || taskId;
    matched = [...document.querySelectorAll('[data-turn-id]')].find(turn => {
      const id = turn.getAttribute('data-turn-id');
      const question = turn.querySelector('[data-chat-question-bubble="true"] .chat-message-body');
      return id && !baseline.has(id) && nodeText(question) === message.trim();
    }) || null;
    if (matched) {
      const state = taskState({prompt: message});
      if (state.complete && state.answer) {
        let responseFiles = [];
        if (taskId) {
          try {
            const task = await richTask(taskId);
            responseFiles = [...task.messages].reverse().find(item => item.role === 'assistant')?.files || task.files;
          } catch {}
        }
        return {status: 'response_available', taskId, url: location.href, response: state.answer, responseFiles};
      }
      if (state.failed) throw Error('Manus reported that the task failed or stopped');
    }
    await pause(200);
  }
  return {status: matched ? 'submitted_pending' : 'submission_unconfirmed', taskId, url: location.href, response: null, responseFiles: []};
}

window.ox.install(({action}) => {
  action('getSignInUrl', {async invoke() {
    return {url: 'https://manus.im/login?redirectUrl=https%3A%2F%2Fmanus.im%2Fapp'};
  }});
  action('getSignInState', {async invoke() {
    await waitForManusAuthShell();
    const account = await freshManusUserInfo();
    if (account) return {signedIn: true};
    if (manuscriptAuthObservation?.signedIn === true && Date.now() - manuscriptAuthObservation.at < 30000) return {signedIn: true};
    if (/^\/login(?:\/|$)/.test(location.pathname) || manuscriptAuthObservation?.signedIn === false) return {signedIn: false};
    throw Error('Manus session state is not ready; reload and retry');
  }});
  action('getCurrentUser', {async invoke() {
    const account = await freshManusUserInfo();
    if (!account) throw Error('Sign in to Manus first');
    await readyEditor();
    const leaves = [...document.querySelectorAll('body *')].filter(element => element.children.length === 0);
    const websiteModel = nodeText(leaves.find(element => /^Manus\s+\d/i.test(nodeText(element))));
    if (!websiteModel) throw Error('Manus website model label is not available');
    const name = String(account.displayname || [account.firstname, account.lastname].filter(Boolean).join(' ') || '').trim();
    const version = String(account.membershipVersion || '').trim();
    if (!name || !version) throw Error('Unrecognized Manus account details');
    return {name, plan: version.charAt(0).toUpperCase() + version.slice(1) + ' plan', websiteModel};
  }});
  action('getCredits', {async invoke() {
    const value = await (await manusServiceApi()).UserService.getAvailableCredits({});
    return {total: Number(value.totalCredits || 0), free: Number(value.freeCredits || 0), refresh: Number(value.refreshCredits || 0), refreshInterval: String(value.refreshInterval || ''), addon: Number(value.addonCredits || 0)};
  }});
  action('listTasks', {async invoke({offset = 0, limit = 20}) {
    const value = await (await manusServiceApi()).SessionService.listSessions({offset, limit});
    const tasks = (value.sessions || []).map(taskSummary);
    return {tasks, nextOffset: value.hasNext ? offset + tasks.length : null, hasMore: !!value.hasNext};
  }});
  action('searchTasks', {async invoke({query, offset = 0, limit = 20}) {
    const value = await (await manusServiceApi()).SessionService.searchSession({keyword: query, offset, limit, includeEmptyTasks: true});
    const tasks = (value.sessions || []).map(taskSummary);
    return {tasks, total: Number(value.total || 0), nextOffset: value.hasNext ? offset + tasks.length : null, hasMore: !!value.hasNext};
  }});
  action('getTask', {async invoke({taskId}) {
    return richTask(taskId);
  }});
  action('getTaskFiles', {async invoke({taskId}) {
    const task = await richTask(taskId);
    return {taskId: task.id, url: task.url, files: task.files};
  }});
  action('listCreations', {async invoke({query = '', category = 'all', pageToken = '', pageSize = 20}) {
    const value = await (await manusServiceApi()).SessionService.listSessionArtifacts({query: query.trim(), category: creationCategories[category], pageToken, pageSize});
    return {items: (value.artifacts || []).map(item => normalizeLibraryItem(item, 'creation')).filter(Boolean), nextPageToken: String(value.nextPageToken || '') || null};
  }});
  action('listDocuments', {async invoke({query = '', type = 'all', favoritesOnly = false, offset = 0, limit = 20}) {
    const value = await (await manusServiceApi()).SessionService.listSessionDocuments({query: query.trim(), type: documentTypes[type], favoritesOnly, offset, limit});
    const grouped = (value.groups || []).flatMap(group => (group.files || []).map(item => ({...item, sessionTitle: item.sessionTitle || group.sessionTitle})));
    const items = (value.files?.length ? value.files : grouped).map(item => normalizeLibraryItem(item, 'document')).filter(Boolean);
    return {items, totalFiles: Number(value.totalFiles || items.length), totalSessions: Number(value.totalSessions || 0), hasMore: !!value.hasNext, nextOffset: value.hasNext ? offset + limit : null};
  }});
  action('chat', {async invoke({message}) {
    return sendOrdinaryTask(message, null);
  }});
  action('continueTask', {async invoke({taskId, message}) {
    return sendOrdinaryTask(message, taskId);
  }});
  action('listModels', {async invoke() {
    return {models: [{id: 'website-default', name: 'Manus website default', input: ['text'], contextTokens: null, outputTokens: null, streaming: false, cancellation: false, options: []}]};
  }});
  action('startModelGeneration', {async invoke(args) {
    if (generations.size) throw Error('This page already owns a generation');
    if (args.modelId !== 'website-default') throw Error('The selected Manus model is unavailable');
    if (args.options.temperature !== null || args.options.maxTokens !== null) throw Error('Manus does not expose generation options');
    if (args.attachments.length) throw Error('Manus attachments are not supported by this service');
    if (!Array.isArray(args.messages) || !args.messages.length) throw Error('A conversation is required');
    const prompt = JSON.stringify({task: 'Follow the supplied conversation and system instructions. Return only the assistant response.', conversation: args.messages});
    if (prompt.length > 200000) throw Error('The serialized conversation is too large for this Manus service');
    if (!/^\/app\/?$/.test(location.pathname)) throw Error('Manus is not on a fresh task page');
    const editor = await readyEditor();
    if (nodeText(editor)) throw Error('Manus has an existing draft; refusing to overwrite it');
    editor.focus();
    let inserted = false;
    if (editor.editor?.commands?.insertContent) inserted = !!editor.editor.commands.insertContent({type: 'text', text: prompt});
    else inserted = document.execCommand('insertText', false, prompt);
    if (!inserted) throw Error('Manus editor rejected the serialized conversation');
    const until = Date.now() + 5000;
    let button = null;
    while (Date.now() < until && !button) {
      if (nodeText(editor) === prompt.trim()) button = sendButton();
      if (!button) await pause(100);
    }
    if (!button) throw Error('Manus submit control was not ready; nothing submitted');
    const generationId = crypto.randomUUID();
    const state = {id: generationId, prompt, confirmed: false, text: '', events: [], terminal: null, started: Date.now()};
    generations.set(generationId, state);
    button.click();
    void monitor(state);
    const confirmationDeadline = Date.now() + 12000;
    while (!state.confirmed && !state.terminal && Date.now() < confirmationDeadline) await pause(100);
    console.log('Manus model start', generationId, state.confirmed ? 'confirmed' : 'uncertain');
    return {generationId, submission: state.confirmed ? 'confirmed' : 'uncertain'};
  }});
  action('readModelGeneration', {async invoke({generationId, after, waitMilliseconds}) {
    const state = generations.get(generationId);
    if (!state || !Number.isInteger(after) || after < 0 || after > state.events.length) throw Error('Invalid generation or event cursor');
    const deadline = Date.now() + Math.min(1000, Math.max(0, waitMilliseconds));
    while (after === state.events.length && !state.terminal && Date.now() < deadline) await pause(Math.min(50, Math.max(0, deadline - Date.now())));
    const events = state.events.slice(after, after + 1000);
    return {nextCursor: after + events.length, events};
  }});
  action('cancelModelGeneration', {async invoke({generationId}) {
    const state = generations.get(generationId);
    if (!state) throw Error('Unknown generation');
    return {status: state.terminal ? 'completed' : 'unsupported'};
  }});
});
