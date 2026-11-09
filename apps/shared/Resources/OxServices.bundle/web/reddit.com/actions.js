window.ox.install(({action}) => {
 action('listSessions',{async invoke(){const end=Date.now()+12000;while(Date.now()<end){const links=Array.from(document.querySelectorAll('a[href]'));const login=links.find(a=>new URL(a.href,location.href).pathname==='/login/' && /log in/i.test(a.innerText));if(login || (location.pathname.startsWith('/login') && document.querySelector('#login-password-visibility-toggle')))return [];if(document.querySelector('shreddit-post')) break;await new Promise(r=>setTimeout(r,200));}throw new Error('Reddit account identity discovery is not yet verified. Preserve login and inspect account controls before enabling protected actions.');}});
 const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();

const usable = element => {
  if (!element || element.disabled || element.readOnly || element.type === "hidden") return false;
  if (element.closest("[hidden], [aria-hidden='true'], [inert]")) return false;
  const style = getComputedStyle(element);
  return style.display !== "none" && style.visibility !== "hidden";
};

const waitForStep = async (detectors, timeout = 15000) => {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    for (const [kind, detect] of Object.entries(detectors)) {
      const match = detect();
      if (match) return { kind, match };
    }
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  return { kind: "unknown", match: null };
};

const typeInto = (field, value) => {
  field.focus();
  field.select?.();
  if (!document.execCommand("insertText", false, value) || field.value !== value) {
    Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value").set.call(field, value);
    field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
  }
  field.dispatchEvent(new Event("change", { bubbles: true }));
};

const pageError = (root = document) => [...root.querySelectorAll("[role='alert'], [aria-live='assertive'], [aria-live='polite']")]
  .filter(usable)
  .map(element => cleanText(element.innerText))
  .filter(Boolean)
  .join(" | ")
  .slice(0, 200);
const redditActive=e=>{if(!usable(e))return false;for(let a=e,n=0;a&&n<40;n++){const s=getComputedStyle(a);if(s.display==='none'||s.visibility==='hidden'||a.hidden||a.getAttribute('aria-hidden')==='true')return false;a=a.assignedSlot||a.parentElement||a.getRootNode()?.host;}return true;};
const redditLoginStep=async()=>waitForStep({challenge:()=>[...document.querySelectorAll('faceplate-form#login-app-otp,faceplate-form#login-backup-otp,input[autocomplete="one-time-code"],iframe[src*="captcha"]')].find(redditActive),credentials:()=>{const root=document.querySelector('faceplate-form#login'),userHost=root?.querySelector('#login-username'),passwordHost=root?.querySelector('#login-password'),username=userHost?.shadowRoot?.querySelector('input[name="username"]'),password=passwordHost?.shadowRoot?.querySelector('input[name="password"]'),submit=root?[...root.querySelectorAll('button')].find(e=>cleanText(e.textContent)==='Log In'):null;return redditActive(userHost)&&redditActive(passwordHost)&&redditActive(username)&&redditActive(password)&&submit?{root,username,password,submit}:null;}});
action('login',{async invoke(input,context){const step=await redditLoginStep();if(step.kind==='unknown'&&!input?.account)throw Error('Reddit sign-in controls did not become ready.');if(step.kind!=='credentials')return null;if(!input?.account||input.account.serviceID!=='web:reddit.com')return null;if(pageError(step.match.root))throw Error('Reddit sign-in reports an error; stopped without retrying.');const account=await context.secret(input.account);typeInto(step.match.username,account.username);typeInto(step.match.password,account.password);const ready=await waitForStep({submit:()=>redditActive(step.match.submit)?step.match.submit:null},5000);if(ready.kind!=='submit')throw Error('Reddit login button unavailable.');ready.match.click();return null;}});
const clean = s => (s || '').replace(/\s+/g, ' ').trim();
  function postPath(raw) {
    let u;
    try { u = new URL(raw); } catch { throw Error('Invalid Reddit post URL'); }
    if (u.origin !== 'https://www.reddit.com' || !/^\/r\/[A-Za-z0-9_]+\/comments\/[a-z0-9]+(?:\/[^/?#]*)?\/?$/.test(u.pathname) || u.search || u.hash) throw Error('Expected a public www.reddit.com post permalink');
    return u.pathname;
  }
  async function page(path, kind) {
    const r = await fetch(path, { credentials: 'include' });
    const u = new URL(r.url);
    if (u.origin !== 'https://www.reddit.com' || u.pathname !== path.split('?')[0]) throw Error('Reddit redirected ' + kind + ' request');
    if (!r.ok) throw Error('Reddit ' + kind + ' HTTP ' + r.status);
    const html = await r.text();
    const d = new DOMParser().parseFromString(html, 'text/html');
    if (!d.body) throw Error('Reddit ' + kind + ' HTML unavailable');
    if (!d.querySelector('shreddit-post, [data-testid="sdui-post-unit"], [data-testid="search-error-message"]') && /you.ve been blocked by network security|verify you are human/i.test(d.body.textContent || '')) throw Error('Reddit blocked ' + kind + ' request');
    return d;
  }
  async function post(raw) {
    const path = postPath(raw), d = await page(path, 'post');
    const p = d.querySelector('shreddit-post[view-context="CommentsPage"]');
    if (!p || !/^t3_[a-z0-9]+$/.test(p.id || '') || !clean(p.getAttribute('post-title'))) throw Error('Reddit post missing or unreadable');
    if (p.getAttribute('permalink')?.split('/comments/')[1]?.split('/')[0] !== path.split('/comments/')[1]?.split('/')[0]) throw Error('Reddit post ID mismatch');
    return {d,p};
  }
  action('search', { async invoke(input) {
    if (input.cursor !== undefined) throw Error('Reddit search continuation is unsupported');
    const q = clean(input.query), limit = input.limit ?? 10;
    if (!q) throw Error('Search query required');
    const d = await page('/search/?q=' + encodeURIComponent(q) + '&type=posts', 'search');
    const cards = [...d.querySelectorAll('[data-testid="sdui-post-unit"]')];
    if (!cards.length) {
      const empty = d.querySelector('[data-testid="search-error-message"]');
      if (empty && /couldn.t find any results/i.test(empty.textContent || '')) return { items: [], nextCursor: null, scope: 'public Reddit posts', coverage: 'unknown' };
      throw Error('Reddit search results unavailable or blocked');
    }
    const items = cards.slice(0, limit).map(c => {
      const a = c.querySelector('a[data-testid="post-title-text"]');
      if (!a || !clean(a.textContent)) throw Error('Reddit search result malformed');
      const url = new URL(a.getAttribute('href'), 'https://www.reddit.com');
      postPath(url.href);
      const id = (a.id || '').match(/^search-post-title-t3_([a-z0-9]+)$/)?.[1];
      return {title: clean(a.textContent),url: url.href,snippet: clean(a.nextElementSibling?.textContent).slice(0,400) || null,...(id ? {id:'t3_'+id} : {})};
    });
    return {items,nextCursor:null,scope:'public Reddit posts',coverage:'unknown'};
  }});
  action('getPost', { async invoke(input) {
    const {p} = await post(input.url);
    return {id:p.id,title:clean(p.getAttribute('post-title')),url:new URL(p.getAttribute('permalink'), 'https://www.reddit.com').href,subreddit:p.getAttribute('subreddit-prefixed-name') || '',author:p.getAttribute('author') || '',body:clean(p.querySelector('[data-post-click-location="text-body"]')?.textContent) || null,commentCount:Number(p.getAttribute('comment-count') || 0)};
  }});
  action('listComments', { async invoke(input) {
    if (input.cursor !== undefined) throw Error('Reddit comment continuation is unsupported');
    const {d,p} = await post(input.url), limit = input.limit ?? 10;
    const nodes = [...d.querySelectorAll('template[for]')].flatMap(t => [...t.content.querySelectorAll('shreddit-comment[thingid]')]).filter(c => c.getAttribute('postid') === p.id && c.getAttribute('aria-hidden') !== 'true');
    if (!nodes.length && Number(p.getAttribute('comment-count') || 0) > 0) throw Error('Reddit comments unavailable or blocked');
    const items = nodes.slice(0, limit).map(c => {
      const body = clean(c.querySelector('[slot="comment"]')?.textContent);
      if (!body || !/^t1_[a-z0-9]+$/.test(c.getAttribute('thingid') || '')) throw Error('Reddit comment malformed');
      return {id:c.getAttribute('thingid'),author:c.getAttribute('author') || '',body:body.slice(0,10000),depth:Number(c.getAttribute('depth') || 0),url:new URL(c.getAttribute('permalink'), 'https://www.reddit.com').href};
    });
    return {items,nextCursor:null};
  }});
});
