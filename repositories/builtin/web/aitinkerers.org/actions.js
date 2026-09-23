window.ox.install(1, ({ action, lib, log }) => {
  const clean = (v, max = 12000) => String(v || '').replace(/\s+/g, ' ').trim().slice(0, max);
  const sameSite = (url) => { const u = new URL(url, location.href); if (!/(^|\.)aitinkerers\.org$/.test(u.hostname)) throw new Error('URL must be on aitinkerers.org'); return u.href; };
  action('readPost', { async invoke(args) {
    const url = sameSite(args.url); const r = await fetch(url, { credentials: 'include', cache: 'no-store' }); if (!r.ok) throw new Error('Post request failed: ' + r.status);
    const html = await r.text(); const doc = new DOMParser().parseFromString(html, 'text/html'); const main = doc.querySelector('article') || doc.querySelector('main') || doc.body;
    const meta = (n) => doc.querySelector('meta[name="'+n+'"]')?.content || null; const title = clean(doc.querySelector('h1')?.textContent || doc.title, 300);
    const header = clean(main.querySelector('header')?.innerText, 500); const by = clean(main.querySelector('a[href*="/users/"], .author, [class*="author"]')?.textContent, 200) || (header.match(/(?:^|\n)([^\n]+)\s+—\s+[^\n]+/)||[])[1] || null;
    const date = clean(main.querySelector('time')?.getAttribute('datetime') || main.querySelector('time')?.textContent, 100) || (header.match(/\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}\b/)||[])[0] || null;
    return { url, title, author: by, publishedAt: date, description: meta('description'), text: clean(main.innerText, 12000) };
  }});
  action('searchPosts', { async invoke(args) {
    const r = await fetch('https://aitinkerers.org/events', { credentials: 'include', cache: 'no-store' }); if (!r.ok) throw new Error('Post listing request failed: ' + r.status);
    const doc = new DOMParser().parseFromString(await r.text(), 'text/html'); const q = clean(args.query, 200).toLowerCase(); const limit = args.limit || 10; const seen = new Set(); const items = [];
    for (const a of doc.querySelectorAll('article a[href*="/p/"]')) { const url = new URL(a.href, 'https://aitinkerers.org/').href; const title = clean(a.textContent, 300); if (!title || seen.has(url)) continue; const card = a.closest('article, li, section, div') || a; const excerpt = clean(card.textContent, 500); if ((title+' '+excerpt).toLowerCase().includes(q)) { seen.add(url); items.push({url,title,excerpt}); if (items.length >= limit) break; } }
    log({ action: 'searchPosts', phase: 'complete', resultCount: items.length }); return {items, nextCursor:null};
  }});
  action('getSignInUrl', { async invoke() { return {url:'https://aitinkerers.org/signin'}; }});
  action('getSignInState', { async invoke() {
    const r = await fetch('https://aitinkerers.org/signin', { credentials:'include', cache:'no-store' }); if (!r.ok) throw new Error('Sign-in state request failed: '+r.status); const t = await r.text();
    if (t.includes('Get a 4-digit code sent to your email')) return {signedIn:false};
    const pageTitle = (t.match(/<title[^>]*>([^<]*)/i)||[])[1] || ''; if (pageTitle && !/Sign In to AI Tinkerers/i.test(pageTitle)) return {signedIn:true};
    throw new Error('Unclassified sign-in response');
  }});
});