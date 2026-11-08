window.ox.install(({action}) => {
 action('listSessions',{async invoke(){const end=Date.now()+12000;while(Date.now()<end){const links=Array.from(document.querySelectorAll('a[href]'));const login=links.find(a=>new URL(a.href,location.href).pathname==='/login/' && /log in/i.test(a.innerText));if(login || (location.pathname.startsWith('/login') && document.querySelector('#login-password-visibility-toggle')))return [];if(document.querySelector('shreddit-post')) break;await new Promise(r=>setTimeout(r,200));}throw new Error('Reddit account identity discovery is not yet verified. Preserve login and inspect account controls before enabling protected actions.');}});
 action('login',{async invoke(){const end=Date.now()+12000;while(Date.now()<end){if(location.pathname.startsWith('/login') && document.querySelector('#login-password-visibility-toggle'))return null;await new Promise(r=>setTimeout(r,200));}throw new Error('Reddit login controls did not load; user sign-in was not prepared.');}});
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
