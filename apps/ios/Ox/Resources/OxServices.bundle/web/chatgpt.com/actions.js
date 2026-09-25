(() => {
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const clean = value => String(value ?? '').replace(/\s+/g, ' ').trim();
  const visible = e => !!e && !!(e.getBoundingClientRect().width && e.getBoundingClientRect().height);
  const one = selector => [...document.querySelectorAll(selector)].find(visible);
  let pageRef;
  const reference = () => location.pathname.startsWith('/c/') ? location.origin + location.pathname : (pageRef ||= 'page:' + crypto.randomUUID());
  const pageUrl = () => location.origin + location.pathname;
  async function waitFor(get, message, timeout = 15000) {
    const end = Date.now() + timeout;
    while (Date.now() < end) { const value = get(); if (value) return value; await pause(150); }
    throw new Error(message);
  }
  async function identity() {
    const r = await fetch('/backend-api/me', {credentials:'include', cache:'no-store'});
    if (r.redirected) throw new Error('Unexpected redirect checking ChatGPT session');
    let j; try { j = await r.json(); } catch { throw new Error('Invalid ChatGPT session response'); }
    // Observed: 200 identity with string id; 401 {detail:"Unauthorized"} without credentials.
    if (r.status === 401 && j.detail === 'Unauthorized') return null;
    if (r.status !== 200 || typeof j.id !== 'string' || !j.id) throw new Error('Unclassified ChatGPT session response: HTTP ' + r.status);
    return j;
  }
  const composer = () => [...document.querySelectorAll('textarea#mobile-composer-prompt, textarea[aria-label="Chat with ChatGPT"], textarea[placeholder="Ask ChatGPT"], [contenteditable="true"][role="textbox"][aria-label="Ask ChatGPT"]')].find(e=>visible(e)&&!e.id.startsWith('pending-'));
  const roleNodes = () => { const legacy = [...document.querySelectorAll('[data-message-author-role="user"], [data-message-author-role="assistant"]')].filter(visible); if (legacy.length) return legacy; return [...document.querySelectorAll('main h4')].filter(h => /^(You said:|ChatGPT said:)$/.test(h.textContent.trim())).map(h => { const role = h.textContent.trim() === 'You said:' ? 'user' : 'assistant'; const e = h.parentElement.querySelector(role === 'user' ? '[data-user-message-bubble]' : '[data-markdown-text-style="assistant-message"]'); if (e) e.setAttribute('data-ox-message-role',role); return e; }).filter(visible); };
  const nodeRole = e => e.getAttribute('data-message-author-role') || e.getAttribute('data-ox-message-role');
  const messages = () => roleNodes().map(e => ({role:nodeRole(e),text:(e.innerText || '').trim()})).filter(m => m.text);
  async function send(message, fresh) {
    if (!message || !message.trim()) throw new Error('A nonempty message is required');
    const input = await waitFor(composer, 'ChatGPT composer is not ready; pending startup placeholders cannot accept messages', 3000);
    if (fresh && (location.pathname !== '/' || roleNodes().length)) throw new Error('Refusing to send: this is not a fresh conversation');
    if ((input.value ?? input.innerText ?? '').trim()) throw new Error('Refusing to overwrite an existing message draft');
    if (one('button[aria-label="Stop generating"], button[data-testid="stop-button"]')) throw new Error('A response is already generating');
    const before = new Set(roleNodes());
    input.focus();
    if (input.tagName === 'TEXTAREA') {
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,message);
      input.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:message}));
      input.dispatchEvent(new Event('change',{bubbles:true}));
    } else {
      const selection = getSelection(); const range = document.createRange();
      range.selectNodeContents(input); selection.removeAllRanges(); selection.addRange(range);
      if (!document.execCommand('insertText',false,message)) throw new Error('ChatGPT editor did not accept text');
    }
    await waitFor(() => clean(input.value ?? input.innerText) === clean(message), 'Message editor did not preserve the requested text', 3000);
    const button = await waitFor(() => {
      const b = one('button[aria-label="Send message"],button[aria-label="Send prompt"],button[data-testid="send-button"],button[type="submit"][aria-label="Send"]');
      return b && !b.disabled ? b : null;
    }, 'Send button unavailable; message remains as a draft', 5000);
    button.click(); // Never automatically retry a submission.
    const end = Date.now() + 18000;
    let last = '', stable = 0;
    while (Date.now() < end) {
      const nodes = roleNodes().filter(e => !before.has(e) && nodeRole(e) === 'assistant');
      const node = nodes[nodes.length - 1];
      const text = (node?.innerText || '').trim();
      if (text !== last) { last=text; stable=Date.now(); }
      const stop = one('button[aria-label="Stop generating"],button[data-testid="stop-button"]');
      const accepted = roleNodes().some(e => !before.has(e) && nodeRole(e) === 'user' && clean(e.innerText) === clean(message));
      if (accepted && text && !stop && Date.now()-stable >= 1800) return {response:text,conversationRef:reference(),url:pageUrl()};
      await pause(200);
    }
    throw new Error('Send outcome uncertain: response did not finish in time. Read the current conversation before any retry.');
  }
  async function modelMenu() {
    const button = await waitFor(() => one('button[aria-label="Select ChatGPT model"]'), 'ChatGPT model picker unavailable');
    if (button.getAttribute('aria-expanded') !== 'true') button.click();
    return waitFor(() => {
      const menu = [...document.querySelectorAll('[role="menu"]')].find(e=>visible(e) && e.querySelector('[role="menuitemradio"]'));
      return menu;
    }, 'Model choices did not appear', 5000);
  }
  const modelRows = menu => [...menu.querySelectorAll('[role="menuitemradio"]')].filter(visible).map(e => ({element:e,name:clean(e.innerText),selected:e.getAttribute('aria-checked')==='true',available:e.getAttribute('aria-disabled')!=='true' && !e.disabled}));
  const closeMenu = menu => menu.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',bubbles:true}));

  let searchSession = null;
  // Observe only search responses while this service owns a search session.
  // Request credentials and headers are neither copied nor retained.
  let searchObserverInstalled = false;
  function installSearchObserver() {
    if (searchObserverInstalled) return;
    searchObserverInstalled = true;
    const originalFetch = window.fetch.bind(window);
    window.fetch = function(input, init) {
      let query = null;
      try {
        const url = typeof input === 'string' ? input : input?.url;
        if (url && new URL(url,location.href).pathname === '/backend-api/global/search' && typeof init?.body === 'string') query = JSON.parse(init.body);
      } catch {}
      const session = searchSession;
      const matches = session && query?.query === session.query;
      return originalFetch(input, init).then(response => {
        if (matches) {
          const key = query.cursor ?? '';
          void response.clone().json().then(body => {
            if (searchSession !== session) return;
            if (!response.ok || !Array.isArray(body.items) || !(body.cursor === null || typeof body.cursor === 'string') || typeof body.partial_results !== 'boolean') throw new Error('Unexpected search response: HTTP ' + response.status);
            const items = body.items.filter(i=>i.source_type==='conversation').map(i=> {
              if(typeof i.payload?.conversation_id!=='string'||typeof i.title!=='string') throw new Error('Invalid conversation search result');
              return {id:i.payload.conversation_id,title:i.title,snippet:typeof i.snippet==='string'?i.snippet:null};
            });
            if(items.length>100) throw new Error('Search page exceeds supported result bound');
            session.pages.set(key,{items,nextCursor:body.cursor,partialResults:body.partial_results});
            while(session.pages.size>12) session.pages.delete(session.pages.keys().next().value);
          }).catch(error=>{ if(searchSession===session) session.errors.set(key,String(error.message||error)); });
        }
        return response;
      });
    };
  }
  const searchInput = () => one('[role="dialog"] input[role="combobox"]');
  const resultLinks = () => [...document.querySelectorAll('[role="dialog"] a[role="option"][href]')].filter(visible);
  const resultLink = id => resultLinks().find(e=>new URL(e.href).pathname==='/c/'+id);
  async function searchPage(args) {
    await waitFor(()=>{const e=composer();return e&&e.id!=='pending-home-input'?e:null;},'ChatGPT is still showing its startup placeholder',8000);
    installSearchObserver();
    const query = args.query.trim();
    if(!query) throw new Error('A nonempty search query is required');
    const key=args.cursor??'';
    if(key && (!searchSession || searchSession.query!==query || ![...searchSession.pages.values()].some(p=>p.nextCursor===key))) throw new Error('Search cursor is stale or belongs to another query; start a new search');
    if(!key && (!searchSession || searchSession.query!==query)) searchSession={query,pages:new Map(),errors:new Map()};
    if(!searchInput()) {
      if(!one('button[aria-label="Search"]')) one('button[aria-label="Show sidebar"]')?.click();
      const button=await waitFor(()=>one('button[aria-label="Search"]'),'Search button unavailable',4000);
      button.click();
    }
    const input=await waitFor(searchInput,'Search input did not become ready',6000).catch(error=>{const controls=[...document.querySelectorAll('input')].map(e=>({role:e.getAttribute('role'),placeholder:e.getAttribute('placeholder'),visible:visible(e)}));throw new Error(error.message+'; controls='+JSON.stringify(controls)+'; dialogs='+document.querySelectorAll('[role="dialog"]').length+'; path='+location.pathname+'; state='+document.readyState+'; searchButtons='+document.querySelectorAll('button[aria-label="Search"]').length+'; composer='+!!composer());});
    if(key && input.value!==query) throw new Error('Search panel changed; restart this query');
    if(!key && input.value!==query) {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,query);
      input.dispatchEvent(new Event('input',{bubbles:true}));
    }
    if(key && !searchSession.pages.has(key)) {
      const panel=one('[role="dialog"] [role="tabpanel"]');
      if(!panel) throw new Error('Search results panel unavailable');
      panel.scrollTop=panel.scrollHeight;
      panel.dispatchEvent(new Event('scroll',{bubbles:true}));
    }
    const page=await waitFor(()=> {
      if(searchSession.errors.has(key)) throw new Error(searchSession.errors.get(key));
      return searchSession.pages.get(key);
    },'No fresh page-owned search response; close and reopen the service before retrying',12000);
    if(page.nextCursor===key) throw new Error('Search source did not advance its cursor');
    return {...page,items:page.items.map(i=>({...i,url:resultLink(i.id)?.href??null}))};
  }

  window.ox.install(({action}) => {
    action('getInterfaceState',{async invoke(){return {path:location.pathname,readyState:document.readyState,visibility:document.visibilityState,focused:document.hasFocus(),composer:!!composer(),composerKind:composer() ? composer().tagName+':'+(composer().getAttribute('aria-label')||'')+':'+(composer().id||'') : (document.querySelector('textarea[id^="pending-"]')?.id || 'unavailable'),composerControls:[...(composer()?.closest('form')?.querySelectorAll('button')||[])].map(e=>e.getAttribute('aria-label')||e.getAttribute('data-testid')||e.type),modelCandidates:[...document.querySelectorAll('button,[role=button]')].filter(e=>visible(e)&&/^(ChatGPT|GPT-|Auto$|Instant$|Thinking$|Pro$|Choose model|Select model)/.test(clean(e.innerText))).slice(0,8).map(e=>clean(e.innerText).slice(0,80)),dialogs:document.querySelectorAll('[role="dialog"]').length,inputs:document.querySelectorAll('input').length,viewport:innerWidth+'x'+innerHeight,controls:[...document.querySelectorAll('button[aria-label]')].filter(e=>/^(Search|Show sidebar|Hide sidebar|Select ChatGPT model|Close global search|Log in)$/.test(e.getAttribute('aria-label'))).map(e=>({label:e.getAttribute('aria-label'),visible:visible(e),disabled:!!e.disabled||e.getAttribute('aria-disabled')==='true',expanded:e.getAttribute('aria-expanded')}))};}});
    action('searchConversations',{async invoke(args){return searchPage(args);}});
    action('openSearchConversation',{async invoke(args){
      if(!searchSession || ![...searchSession.pages.values()].some(p=>p.items.some(i=>i.id===args.conversationId))) throw new Error('Search for this conversation first');
      if(searchInput()?.value!==searchSession.query) throw new Error('Search panel changed; search again');
      const link=await waitFor(()=>resultLink(args.conversationId),'Result is not loaded in the search panel',4000);
      const target=new URL(link.href).pathname;const previous=roleNodes();link.click();
      await waitFor(()=>location.pathname===target&&!searchInput()&&messages().length&&(!previous.length||roleNodes().some(e=>!previous.includes(e))),'Selected conversation did not finish loading',12000);
      return {url:pageUrl(),conversationRef:reference()};
    }});
    action('openConversation',{async invoke(args){
      await waitFor(composer,'ChatGPT is not ready');
      one('button[aria-label="Show sidebar"]')?.click();
      const rows = () => [...document.querySelectorAll('[role="button"][aria-label]')].filter(e=>visible(e)&&e.getAttribute('aria-label')===args.title&&e.querySelector('button[aria-label="Chat actions"]'));
      await waitFor(()=>rows().length,'Chat not found in loaded sidebar',5000);
      const matches=rows();if(matches.length!==1)throw new Error('Ambiguous chat title; refusing to choose');
      const before=location.pathname;const already=matches[0].getAttribute('aria-current')==='page';matches[0].click();
      await waitFor(()=>location.pathname.startsWith('/c/')&&(already||location.pathname!==before)&&messages().length,'Conversation did not finish loading',10000);
      return {url:pageUrl(),conversationRef:reference()};
    }});
    action('getSignInUrl',{async invoke(){return {url:'https://chatgpt.com/auth/login'};}});
    action('getSignInState',{async invoke(){return {signedIn:!!(await identity())};}});
    action('getCurrentUser',{async invoke(){const j=await identity();if(!j)throw new Error('Sign in to ChatGPT');return {id:j.id,name:typeof j.name==='string'?j.name:null,email:typeof j.email==='string'?j.email:null};}});
    action('chat',{async invoke(args){return send(args.message,true);}});
    action('continueChat',{async invoke(args){if(args.conversationRef!==reference())throw new Error('Stale conversation reference; read the current conversation first');if(!messages().length)throw new Error('No loaded conversation to continue');return send(args.message,false);}});
    action('getCurrentConversation',{async invoke(args){await waitFor(composer,'ChatGPT conversation is not ready');const all=messages(),limit=args.limit??50;return {conversationRef:reference(),url:pageUrl(),messages:all.slice(-limit),renderedOnly:true,truncated:all.length>limit};}});
    action('listModels',{async invoke(){const menu=await modelMenu();const items=modelRows(menu).map(({element,...item})=>item);closeMenu(menu);if(!items.length)throw new Error('No model choices available');return {items,nextCursor:null};}});
    action('selectModel',{async invoke(args){let menu=await modelMenu();const row=modelRows(menu).find(r=>r.name===args.name);if(!row || !row.available){closeMenu(menu);throw new Error('Requested model is unavailable');}if(!row.selected)row.element.click();else closeMenu(menu);menu=await modelMenu();const selected=modelRows(menu).find(r=>r.name===args.name)?.selected===true;closeMenu(menu);if(!selected)throw new Error('Model selection was not confirmed; no retry performed');return {name:args.name,selected};}});
  });
})();
