{
  const __oxRuntime = window.ox;
  const __oxRuntimeCallServiceAction = __oxRuntime.callServiceAction;
  let __oxLegacyCall;
  try {
(() => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const clean = value => String(value || '').replace(/[\u200b-\u200d\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  const hash = value => { let h = 2166136261; for (const ch of String(value)) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619); } return (h >>> 0).toString(36); };
  const visible = el => !!el && !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const waitFor = async (fn, label, timeout = 12000) => { const end = Date.now() + timeout; let value; while (Date.now() < end) { value = fn(); if (value) return value; await sleep(150); } throw new Error(label + ': timed out'); };
  const ensureRoute = kind => { const ok = location.hostname === 'outlook.live.com' && location.pathname.startsWith(kind === 'mail' ? '/mail' : '/calendar'); if (!ok) throw new Error(kind + ': Outlook application route is not ready'); };
  const authSignal = async () => { const r = await fetch('/mail/', { credentials: 'include', redirect: 'manual', cache: 'no-store', headers: { accept: 'text/html' } }); if (r.status !== 200 || r.type !== 'basic' || new URL(r.url).hostname !== 'outlook.live.com') return false; const t = await r.text(); if (!/owa\.mailindex|owaIsAuthenticated|webpackChunkOwa/.test(t)) throw new Error('getSignInState: unexpected Outlook shell response'); return Object.keys(localStorage).some(k => /^msal\.3\.account\.keys$/i.test(k)) && Object.keys(localStorage).some(k => /^msal\.3\|.*\|idtoken\|/i.test(k)); };
  const expandFolderGroups = () => { for(const el of document.querySelectorAll('[role="treeitem"][aria-expanded="false"]')){ if(visible(el)) el.click(); } };
  const folderRows = () => [...document.querySelectorAll('[role="treeitem"][data-folder-name], [role="treeitem"][data-folder-id], [role="treeitem"]')].filter(visible).filter(e=>e.dataset.folderName||e.dataset.folderId||/inbox|drafts|sent|archive|deleted|junk/i.test(clean(e.getAttribute('aria-label')||e.innerText)));
  const folderKey = el => clean(el?.dataset?.folderName||el?.dataset?.folderId||el?.getAttribute('aria-label')||el?.innerText).split(/[\n,]/)[0].toLowerCase();
  const findFolder = key => folderRows().find(e=>{ const k=folderKey(e), text=clean(e.innerText).toLowerCase(); return k===key || k.startsWith(key+' ') || text===key || text.startsWith(key+' '); });
  const waitForFolderPane = async (target, label) => {
    const key=target?clean(target).toLowerCase():null;
    if(!key) await waitFor(()=>document.querySelector('[role="main"]'),'listFolders mail shell',18000);
    let rows=folderRows();
    if(!rows.length){
      const button=[...document.querySelectorAll('button')].find(e=>/show navigation pane/i.test(e.getAttribute('aria-label')||''));
      if(button) button.click();
    }
    expandFolderGroups();
    if(!key) return waitFor(()=>{ expandFolderGroups(); const current=folderRows(); if(current.length)return current; const pane=[...document.querySelectorAll('[role="tree"], nav, [aria-label*="folder" i]')].find(visible); return pane&&!/loading/i.test(clean(pane.getAttribute('aria-busy')||''))?{rows:[]}:null; },label+' folder readiness',18000).then(v=>Array.isArray(v)?v:v.rows);
    return waitFor(()=>{ expandFolderGroups(); const current=folderRows(); if(!current.length)return null; const direct=findFolder(key); if(direct)return direct; if(key==='inbox'){ const inbox=[...document.querySelectorAll('[data-folder-name], [data-folder-id], [role="treeitem"], a, button')].filter(visible).find(e=>/^inbox(?:\b|\s)/i.test(clean(e.dataset?.folderName||e.dataset?.folderId||e.getAttribute('aria-label')||e.innerText))); if(inbox)return inbox; } return null; },label+' folder readiness',18000);
  };
  const messageRows = () => [...document.querySelectorAll('[role="option"][data-convid]')].filter(visible);
  const messageListState = () => {
    const list=document.querySelector('[role="listbox"]');
    const rows=messageRows();
    const empty=[...document.querySelectorAll('[role="main"] [role="status"], [role="main"] [aria-live], [role="main"]')].filter(visible).find(e=>/no (messages|items)|nothing (in|to) (show|display)|folder is empty/i.test(clean(e.innerText)));
    return list&&(rows.length||empty)?{list,rows,empty:!!empty}:null;
  };
  const parseMessageRow = el => { const lines=(el.innerText||'').split(/\n+/).map(clean).filter(Boolean); const label=clean(el.getAttribute('aria-label')); const id=el.dataset.convid || ''; const isUnread=/\bunread\b/i.test(label); const sender=lines.find(x=>!(/^[A-Z]{1,3}$/.test(x)||/^(Unread|Read)$/i.test(x)))||''; const subject=lines.find((x,i)=>i>lines.indexOf(sender)&&!(/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b|^\d{1,2}:\d{2}/i.test(x)))||''; const receivedText=lines.find(x=>/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b|^\d{1,2}:\d{2}/i.test(x))||''; const preview=lines.filter(x=>x!==sender&&x!==subject&&x!==receivedText&&!/^[A-Z]{1,3}$/.test(x)).slice(-1)[0]||''; return {id,conversationId:id,subject,sender,receivedText,isUnread,preview}; };
  const selectFolder = async id => { const key=clean(id||'inbox').toLowerCase(); if(key==='inbox' && /\/mail\/?(?:inbox)?\/?$/i.test(location.pathname)){ const ready=await waitFor(messageListState,'listMessages inbox message list',18000); if(ready)return; } const row=await waitForFolderPane(key,'listMessages'); if(row.getAttribute('aria-selected')!=='true') row.click(); await waitFor(()=>{ const selected=findFolder(key)||row; if(selected.getAttribute('aria-selected')!=='true' && key!=='inbox')return null; return messageListState(); },'listMessages selected folder and message list',18000); };
  const pageItems = (items, cursor, limit) => { const offset=cursor?Number(cursor):0; if(!Number.isInteger(offset)||offset<0) throw new Error('cursor: invalid'); const slice=items.slice(offset,offset+limit); return {items:slice,nextCursor:offset+slice.length<items.length?String(offset+slice.length):null}; };
  const openMessage = async id => { ensureRoute('mail'); let row=messageRows().find(e=>e.dataset.convid===id); if(!row){ location.href='/mail/inbox/id/'+encodeURIComponent(id); } else row.click(); await waitFor(()=>document.querySelector('[role="main"] [aria-label="Email message"], [role="main"] [aria-label="Message body"]'),'getMessage'); return document.querySelector('[role="main"]'); };
  const parseEventEl = el => { const label=clean(el.getAttribute('aria-label')); const text=clean(el.innerText); const raw=label||text; const id=el.dataset.itemid||el.dataset.itemId||el.getAttribute('data-item-id')||hash(raw); const tm=raw.match(/((?:\d{1,2}:\d{2}\s*(?:AM|PM)).*?(?:\d{1,2}:\d{2}\s*(?:AM|PM)))/i); return {id,subject:text||raw.split(',')[0]||'',startText:tm?tm[1].split(/\s+to\s+/i)[0]:'',endText:tm&&/\s+to\s+/i.test(tm[1])?tm[1].split(/\s+to\s+/i)[1]:'',location:'',allDay:/all day/i.test(raw)}; };
  const actions = {
    async getSignInUrl(){ return {url:'https://outlook.live.com/mail/'}; },
    async getSignInState(){ return {signedIn:await authSignal()}; },
    async listFolders(){ ensureRoute('mail'); const rows=await waitForFolderPane(null,'listFolders'); const seen=new Set(); const items=[]; for(const el of rows){const id=clean(el.dataset.folderName).toLowerCase(); if(!id||seen.has(id))continue; seen.add(id); const text=clean(el.innerText); const name=clean((el.innerText||'').split(/\n+/).map(clean).find(x=>x&&/[A-Za-z0-9]/.test(x)&&!/^\d+\s*unread$/i.test(x))||id); const m=text.match(/(\d+)\s*unread/i); items.push({id,name,unreadCount:m?Number(m[1]):null});} return {items,nextCursor:null}; },
    async listMessages(args={}){ ensureRoute('mail'); await selectFolder(args.folderId||'inbox'); const state=await waitFor(messageListState,'listMessages usable fresh message list',18000); const items=state.rows.map(parseMessageRow); return pageItems(items,args.cursor??null,args.limit??25); },
    async searchMessages(args={}){ ensureRoute('mail'); await waitFor(()=>document.querySelector('input[aria-label*="Search for email" i]'),'searchMessages search box'); const q=clean(args.query); if(!q)throw new Error('searchMessages: query is required'); const input=document.querySelector('input[aria-label*="Search for email" i]'); if(!input)throw new Error('searchMessages: search box unavailable'); input.focus(); input.value=q; input.dispatchEvent(new Event('input',{bubbles:true})); input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true})); await sleep(1200); await waitFor(()=>document.querySelector('[role="listbox"]'),'searchMessages'); return pageItems(messageRows().map(parseMessageRow),args.cursor??null,args.limit??25); },
    async getMessage(args={}){ const main=await openMessage(args.id); const subject=clean(main.querySelector('[role="heading"]')?.innerText); const msg=main.querySelector('[aria-label="Email message"]')||main; const sender=clean(msg.querySelector('[aria-label^="From:"]')?.getAttribute('aria-label')).replace(/^From:\s*/i,'')||clean(msg.querySelector('[role="heading"]')?.innerText); const recipients=[...msg.querySelectorAll('[aria-label^="To:"]')].map(e=>clean(e.getAttribute('aria-label')).replace(/^To:\s*/i,'')).filter(Boolean); const receivedText=clean(msg.querySelector('[data-testid="SentReceivedSavedTime"]')?.innerText); const bodyText=clean(msg.querySelector('[aria-label="Message body"]')?.innerText); const attachmentNames=[...msg.querySelectorAll('[aria-label*="attachment" i]')].map(e=>clean(e.getAttribute('aria-label')||e.innerText)).filter(Boolean); return {id:String(args.id),subject,sender,recipients,receivedText,bodyText,attachmentNames}; },
    async listCalendars(){ ensureRoute('calendar'); await waitFor(()=>document.querySelector('[role="option"], input[type="checkbox"], [role="checkbox"]'),'listCalendars'); const candidates=[...document.querySelectorAll('[role="option"], input[type="checkbox"], [role="checkbox"]')].filter(visible).filter(e=>/calendar/i.test(clean(e.getAttribute('aria-label')||e.innerText))); const seen=new Set(); const items=[]; for(const e of candidates){const name=clean(e.getAttribute('aria-label')||e.innerText).replace(/^[^A-Za-z0-9]+/,''); if(!name||seen.has(name))continue; seen.add(name); items.push({id:hash(name),name,selected:e.checked===true||e.getAttribute('aria-selected')==='true'||e.getAttribute('aria-checked')==='true'});} return {items,nextCursor:null}; },
    async listEvents(args={}){ ensureRoute('calendar'); await waitFor(()=>document.querySelector('[role="main"]'),'listEvents calendar'); const start=new Date(args.start), end=new Date(args.end); if(!Number.isFinite(+start)||!Number.isFinite(+end)||start>=end)throw new Error('listEvents: invalid date range'); const events=[...document.querySelectorAll('[role="button"]')].filter(visible).filter(e=>{const s=clean(e.getAttribute('aria-label')||e.innerText); return s&&!/New event|Go to|Jump to|Calendar|month|week|date selection/i.test(s)&&(/\d{1,2}:\d{2}\s*(AM|PM)/i.test(s)||/all day/i.test(s));}).map(parseEventEl); return pageItems(events,args.cursor??null,args.limit??50); },
    async getEvent(args={}){ ensureRoute('calendar'); const id=String(args.id||''); const event=[...document.querySelectorAll('[role="button"]')].filter(visible).find(e=>(e.dataset.itemid||e.dataset.itemId||e.getAttribute('data-item-id')||hash(clean(e.getAttribute('aria-label')||e.innerText)))===id); if(!event)throw new Error('getEvent: event is not visible'); event.click(); await sleep(600); const pane=[...document.querySelectorAll('[role="dialog"], [role="main"], [role="complementary"]')].filter(visible).slice(-1)[0]; if(!pane)throw new Error('getEvent: details unavailable'); const text=clean(pane.innerText); const subject=clean(pane.querySelector('[role="heading"]')?.innerText)||clean(event.innerText)||clean(event.getAttribute('aria-label')).split(',')[0]; const timeText=clean([...pane.querySelectorAll('*')].find(e=>/\d{1,2}:\d{2}\s*(AM|PM)/i.test(clean(e.innerText)))?.innerText); const location=clean(pane.querySelector('[aria-label*="location" i]')?.innerText||pane.querySelector('[aria-label*="location" i]')?.getAttribute('aria-label')); const organizer=clean(pane.querySelector('[aria-label*="organizer" i]')?.innerText); const attendees=[...pane.querySelectorAll('[aria-label*="attendee" i]')].map(e=>clean(e.innerText||e.getAttribute('aria-label'))).filter(Boolean); return {id,subject,timeText,location,organizer,attendees,bodyText:text.slice(0,8000)}; }
  };
  window.ox={async callServiceAction(name,args={}){if(!Object.prototype.hasOwnProperty.call(actions,name))throw new Error('unknown action: '+name);try{return await actions[name](args||{});}catch(e){throw new Error(name+': '+(e&&e.message?e.message:String(e)));}}};
})();

    if (typeof window.ox?.callServiceAction === "function") {
      __oxLegacyCall = window.ox.callServiceAction.bind(window.ox);
    }
  } finally {
    window.ox = __oxRuntime;
    __oxRuntime.callServiceAction = __oxRuntimeCallServiceAction;
  }
  if (typeof __oxLegacyCall !== "function") throw new Error("legacy service dispatcher is unavailable");
  window.ox.install(1, ({ action }) => {
  action("getSignInUrl", { async invoke(args) { return __oxLegacyCall("getSignInUrl", args); } });
  action("getSignInState", { async invoke(args) { return __oxLegacyCall("getSignInState", args); } });
  action("listFolders", { async invoke(args) { return __oxLegacyCall("listFolders", args); } });
  action("listMessages", { async invoke(args) { return __oxLegacyCall("listMessages", args); } });
  action("searchMessages", { async invoke(args) { return __oxLegacyCall("searchMessages", args); } });
  action("getMessage", { async invoke(args) { return __oxLegacyCall("getMessage", args); } });
  action("listCalendars", { async invoke(args) { return __oxLegacyCall("listCalendars", args); } });
  action("listEvents", { async invoke(args) { return __oxLegacyCall("listEvents", args); } });
  action("getEvent", { async invoke(args) { return __oxLegacyCall("getEvent", args); } });
  });
}
