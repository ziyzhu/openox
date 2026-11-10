(() => {
const cookie = name => {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = document.cookie.match(new RegExp(`(?:^|;\\s*)${escaped}=([^;]*)`));
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return match[1];
  }
};

const retryFetch = async (input, init, options) => {
  const retries = options?.retries ?? 3;
  const delay = options?.delay ?? 400;
  const factor = options?.factor ?? 2;
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await window.fetch(input, init);
      const retryable = response.status === 408 || response.status === 429
        || (response.status >= 500 && response.status <= 599);
      if (response.ok || !retryable || attempt >= retries) return response;
      console.log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}`);
    } catch (error) {
      const message = String(error?.message ?? "");
      const retryable = message.includes("Load failed")
        || message.includes("NetworkError")
        || message.includes("Failed to fetch");
      if (!retryable || attempt >= retries) throw error;
      console.log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}`);
    }
    await new Promise(resolve => setTimeout(resolve, delay * Math.pow(factor, attempt)));
  }
};

window.ox.install(({ action }) => {
    // Instagram's web client app id — the same constant shipped in Polaris'
    // bundle and required on every /api/v1 call. It identifies the web app, not
    // the user (user auth = sessionid cookie + csrftoken CSRF header), and has
    // been stable for years, so it's safe to bake in.
    //
    // Everything here hits the REST /api/v1 surface rather than /api/graphql:
    // the GraphQL POST endpoints gate on the page's comet session params
    // (fb_dtsg/jazoest/__spin_*/__hs) which can't be replayed without scraping
    // the whole bootstrap blob, whereas /api/v1 only needs the app id + cookies.
    const IG_APP_ID = "936619743392459";
    const ASBD_ID = "359341";
    // csrftoken is a JS-readable cookie on instagram.com (not httpOnly) and is
    // echoed back as the x-csrftoken header on every authed request.
    const requireCsrf = () => {
        const t = cookie("csrftoken");
        if (!t)
            throw new Error("Not signed in to instagram.com (no csrftoken cookie). Sign in first.");
        return t;
    };
    const headers = (post = false) => {
        const h = {
            "x-ig-app-id": IG_APP_ID,
            "x-asbd-id": ASBD_ID,
            "x-csrftoken": requireCsrf(),
            "x-requested-with": "XMLHttpRequest",
        };
        if (post)
            h["content-type"] = "application/x-www-form-urlencoded";
        return h;
    };
    const stripGuard = (text) => text.replace(/^for\s*\(;;\);/, "");
    const apiCall = async (path, init) => {
        const r = await retryFetch(path, { credentials: "include", ...init });
        const text = stripGuard(await r.text());
        let json;
        try {
            json = JSON.parse(text);
        }
        catch {
            throw new Error(`${path}: non-JSON response (HTTP ${r.status}) — session may have expired`);
        }
        if (!r.ok || json?.status === "fail") {
            throw new Error(`${path}: ${json?.message || `HTTP ${r.status}`}`);
        }
        return json;
    };
    const apiGet = (path) => apiCall(path, { headers: headers() });
    const apiPost = (path, body) => apiCall(path, { method: "POST", headers: headers(true), body: new URLSearchParams(body).toString() });
    // Resolve an Instagram shortcode (the /p/<code>/ token) to its numeric media
    // pk via base64 bignum decode — /api/v1/media/<pk>/ needs the pk.
    const SHORTCODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const shortcodeToPk = (code) => {
        let n = 0n;
        for (const ch of code) {
            const idx = SHORTCODE_ALPHABET.indexOf(ch);
            if (idx < 0)
                throw new Error(`Invalid shortcode character: ${JSON.stringify(ch)}`);
            n = n * 64n + BigInt(idx);
        }
        return n.toString();
    };
    const parseMediaId = (input) => {
        const s = String(input || "").trim();
        if (/^\d+$/.test(s))
            return s;
        const m = s.match(/\/(?:p|reel|reels|tv)\/([A-Za-z0-9_-]+)/) || s.match(/^([A-Za-z0-9_-]{5,})$/);
        if (m)
            return shortcodeToPk(m[1]);
        throw new Error(`Invalid media id, shortcode, or URL: ${JSON.stringify(input)}`);
    };
    const normalizeUsername = (raw) => {
        const s = String(raw ?? "").trim().replace(/^@+/, "").toLowerCase();
        if (!/^[a-z0-9_.]{1,30}$/.test(s)) {
            throw new Error(`Invalid Instagram username: ${JSON.stringify(raw)}`);
        }
        return s;
    };
    const profileCache = {};
    const fetchProfile = async (username) => {
        const u = normalizeUsername(username);
        if (profileCache[u])
            return profileCache[u];
        const json = await apiGet(`/api/v1/users/web_profile_info/?username=${encodeURIComponent(u)}`);
        const user = json?.data?.user;
        if (!user)
            throw new Error(`Instagram user @${u} not found`);
        profileCache[u] = user;
        return user;
    };
    // The posts/reels feeds key off the numeric user pk, not the handle.
    const resolveUserId = async (username) => {
        const id = (await fetchProfile(username)).id;
        if (!id)
            throw new Error(`Could not resolve a user id for @${normalizeUsername(username)}`);
        return String(id);
    };
    const bestUrl = (versions) => {
        const c = versions?.candidates;
        return Array.isArray(c) && c.length ? c[0].url : "";
    };
    const mediaRow = (node) => {
        const m = node?.media || node;
        const owner = m?.user || m?.owner || {};
        const videoUrl = Array.isArray(m?.video_versions) && m.video_versions.length ? m.video_versions[0].url : "";
        return {
            id: String(m?.pk ?? m?.id ?? ""),
            code: m?.code || "",
            url: m?.code ? `https://www.instagram.com/p/${m.code}/` : "",
            caption: m?.caption?.text || "",
            taken_at: Number(m?.taken_at) || 0,
            media_type: Number(m?.media_type) || 0,
            product_type: m?.product_type || "",
            is_video: Boolean(videoUrl),
            like_count: Number(m?.like_count) || 0,
            comment_count: Number(m?.comment_count) || 0,
            view_count: Number(m?.play_count ?? m?.view_count) || 0,
            image_url: bestUrl(m?.image_versions2),
            video_url: videoUrl,
            accessibility_caption: m?.accessibility_caption || "",
            owner: {
                pk: String(owner?.pk ?? ""),
                username: owner?.username || "",
                full_name: owner?.full_name || "",
                is_verified: Boolean(owner?.is_verified),
            },
        };
    };
    const userRow = (u) => ({
        pk: String(u?.pk ?? u?.id ?? ""),
        username: u?.username || "",
        full_name: u?.full_name || "",
        is_verified: Boolean(u?.is_verified),
        profile_pic_url: u?.profile_pic_url || "",
    });
    // Explore's grid nests media unpredictably (one_by_two_item.clips.items[],
    // fill_items[], layout_content.medias[]). Rather than track every layout,
    // walk the tree and collect anything that looks like a media node.
    const collectMedia = (root) => {
        const out = [];
        const seen = new Set();
        const recurse = (v) => {
            if (!v || typeof v !== "object")
                return;
            if (Array.isArray(v)) {
                for (const x of v)
                    recurse(x);
                return;
            }
            if (v.pk && v.code && v.media_type !== undefined) {
                const id = String(v.pk);
                if (!seen.has(id)) {
                    seen.add(id);
                    out.push(mediaRow(v));
                }
                return;
            }
            for (const x of Object.values(v))
                recurse(x);
        };
        recurse(root);
        return out;
    };
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
const instagramChoice=label=>[...document.querySelectorAll('[role="button"],button,a')].find(e=>usable(e)&&cleanText(e.textContent)===label);
const instagramLoginStep=async()=>waitForStep({challenge:()=>[...document.querySelectorAll('input[autocomplete="one-time-code"],iframe[src*="captcha"]')].find(usable),credentials:()=>{const username=document.querySelector('input[name="username"]'),password=document.querySelector('input[name="password"]'),root=username?.closest('form'),submit=root?.querySelector('button[type="submit"]');return usable(username)&&usable(password)&&submit&&root?.contains(password)?{username,password,submit,root}:null;},existingAccount:()=>{const d=document.querySelector('[role="dialog"]');return d?[...d.querySelectorAll('[role="button"],button,a')].find(e=>usable(e)&&cleanText(e.textContent)==='Log into an Existing Account'):null;},switchAccounts:()=>instagramChoice('Switch accounts'),menu:()=>[...document.querySelectorAll('a')].find(e=>usable(e)&&e.querySelector('[aria-label="Settings"]'))});
const prepareInstagramLogin=async()=>{
        const visible = usable;
        const ready = () => [...document.querySelectorAll('input[type=password]')].filter(visible).some(password => {
            const root=password.closest('form')||password.closest('[role=dialog]');
            const username=[...root?.querySelectorAll('input[name=username]')||[]].find(visible);
            const submit=root?.querySelector('button[type=submit],input[type=submit]');
            if(!username||!submit||submit.closest('[hidden],[aria-hidden=true],[inert]'))return false;
            const style=getComputedStyle(submit);
            return style.display!=='none'&&style.visibility!=='hidden';
        });
        const findSwitch = () => [...document.querySelectorAll('[role=button]')].find(e => visible(e) && e.textContent.trim() === 'Switch accounts');
        const deadline = Date.now() + 18000;
        let openedMenu = false, openedSwitch = false, openedAnother = false;
        while (Date.now() < deadline) {
            const picker = [...document.querySelectorAll('[role=dialog]')].find(e => visible(e) && [...e.querySelectorAll('[role=button],button,a')].some(c => visible(c) && c.textContent.trim() === 'Log into an Existing Account'));
            if (ready() || picker) return null;
            const another = [...document.querySelectorAll('[role=button],button,a')].find(e => visible(e) && e.textContent.trim() === 'Use another profile');
            if (another && !openedAnother) { another.click(); openedAnother = true; }
            const switcher = findSwitch();
            if (switcher && !openedSwitch) { switcher.click(); openedSwitch = true; }
            else if (!openedMenu && !openedSwitch) {
                const menu = [...document.querySelectorAll('a')].find(e => visible(e) && e.querySelector('[aria-label=Settings]'));
                if (menu) { menu.click(); openedMenu = true; }
            }
            await new Promise(resolve => setTimeout(resolve, 200));
        }
        throw Error('Instagram sign-in controls did not appear; account switching was not completed.');
    };
action('login',{async invoke(input,context){if(!input?.account)return prepareInstagramLogin();const step=await instagramLoginStep();if(step.kind==='unknown'&&!input?.account)throw Error('Instagram sign-in controls not ready; automatic login stopped.');if(input.account.serviceID!=='web:instagram.com')return null;if(step.kind==='menu'){step.match.click();await waitForStep({switchAccounts:()=>instagramChoice('Switch accounts')});return null;}if(step.kind==='switchAccounts'){step.match.click();await waitForStep({existingAccount:()=>instagramChoice('Log into an Existing Account')});return null;}if(step.kind==='existingAccount'){step.match.click();await waitForStep({password:()=>document.querySelector('input[name="password"]')});return null;}if(step.kind!=='credentials')return null;if(pageError(step.match.root))throw Error('Instagram sign-in reports an error; stopped without retrying.');const account=await context.secret(input.account);typeInto(step.match.username,account.username);typeInto(step.match.password,account.password);const ready=await waitForStep({submit:()=>usable(step.match.submit)?step.match.submit:null},5000);if(ready.kind!=='submit')throw Error('Instagram login button unavailable.');ready.match.click();return null;}});
const discoverAuthenticatedSessions = async () => {
            const r = await fetch('/', { credentials: 'include', cache: 'no-store' });
            if (!r.ok)
                throw Error('Instagram account HTTP ' + r.status);
            const u = new URL(r.url);
            if (u.origin !== 'https://www.instagram.com')
                throw Error('Unexpected Instagram origin');
            if (u.pathname.startsWith('/accounts/login'))
                return [];
            const d = new DOMParser().parseFromString(await r.text(), 'text/html');
            const pending = [...d.scripts].filter(s => s.type === 'application/json' && s.textContent.includes('PolarisViewer')).map(s => JSON.parse(s.textContent));
            const viewers = [];
            while (pending.length) {
                const node = pending.pop();
                if (Array.isArray(node) && node[0] === 'PolarisViewer')
                    viewers.push(node[2]);
                else if (node && typeof node === 'object')
                    pending.push(...Object.values(node));
            }
            if (viewers.length !== 1)
                throw Error('Instagram current account identity unavailable');
            const viewer = viewers[0];
            if (viewer?.data === null && viewer.id === null)
                return [];
            if (typeof viewer?.id !== 'string' || !/^[1-9][0-9]+$/.test(viewer.id) || viewer.data?.id !== viewer.id)
                throw Error('Instagram current account identity unavailable');
            return [{ id: viewer.id, label: viewer.data.username || viewer.id, url: 'https://www.instagram.com/' }];

    };
    action('listSessions', { invoke: discoverAuthenticatedSessions });
    action('logout', { async invoke(args) {
        const sessions=await discoverAuthenticatedSessions();if(sessions.length!==1)throw Error('A single authenticated Instagram account is required.');const session=sessions[0];
        const r = await fetch('/', {credentials:'include',cache:'no-store'});
        if(!r.ok) throw Error('Cannot verify current account before sign-out.');
        const d = new DOMParser().parseFromString(await r.text(),'text/html');
        const pending=[...d.scripts].filter(s=>s.type==='application/json' && s.textContent.includes('PolarisViewer')).map(s=>JSON.parse(s.textContent));
        const viewers=[];
        while(pending.length){const n=pending.pop();if(Array.isArray(n)&&n[0]==='PolarisViewer')viewers.push(n[2]);else if(n&&typeof n==='object')pending.push(...Object.values(n));}
        if(viewers.length!==1 || viewers[0]?.id!==session.id)throw Error('Current account changed; sign-out stopped.');
        const visible=e=>!!e && e.getClientRects().length>0;
        const close=[...document.querySelectorAll('[role=dialog] [role=button], [role=dialog] button')].find(e=>visible(e)&&e.querySelector('[aria-label=Close]'));
        if(close)close.click();
        const deadline=Date.now()+12000;let opened=false;
        while(Date.now()<deadline){
          const targets=[...document.querySelectorAll('[role=button]')].filter(e=>visible(e)&&e.innerText.trim()==='Log out');
          if(targets.length===1){await inboxIdentity(session);targets[0].click();return {requested:true};}
          if(!opened){const menu=[...document.querySelectorAll('a')].find(e=>visible(e)&&e.querySelector('[aria-label=Settings]'));if(menu){menu.click();opened=true;}}
          await new Promise(resolve=>setTimeout(resolve,200));
        }
        throw Error('Instagram Log out control was not available; no logout click was made.');
    } });
    const inboxIdentity = async session => {
        if(!session?.id || !session?.label)throw Error('Select an authenticated Instagram account.');
        const r=await fetch('/',{credentials:'include',cache:'no-store'});
        if(!r.ok)throw Error('Instagram identity HTTP '+r.status);
        const d=new DOMParser().parseFromString(await r.text(),'text/html');
        const pending=[...d.scripts].filter(s=>s.type==='application/json'&&s.textContent.includes('PolarisViewer')).map(s=>JSON.parse(s.textContent));const viewers=[];
        while(pending.length){const n=pending.pop();if(Array.isArray(n)&&n[0]==='PolarisViewer')viewers.push(n[2]);else if(n&&typeof n==='object')pending.push(...Object.values(n));}
        if(viewers.length!==1||viewers[0]?.id!==session.id||viewers[0]?.data?.username!==session.label)throw Error('Instagram account changed; action stopped.');
    };
    const waitInbox = async session => {
        const end=Date.now()+20000;
        while(Date.now()<end){
            const headings=[...document.querySelectorAll('h1,h2,[role=heading]')];
            const own=headings.find(e=>cleanText(e.textContent)===session.label);
            const businessTabs=[...document.querySelectorAll('[role=tab]')].map(e=>cleanText(e.textContent));
            if(own&&(headings.some(e=>cleanText(e.textContent)==='Messages')||(businessTabs.includes('Primary')&&businessTabs.includes('General'))))return own;
            await new Promise(r=>setTimeout(r,200));
        }
        throw Error('Instagram inbox did not load for the selected account.');
    };
    action('listInbox',{async invoke(args){
        const sessions=await discoverAuthenticatedSessions();if(sessions.length!==1)throw Error('A single authenticated Instagram account is required.');const session=sessions[0];
        await inboxIdentity(session);await waitInbox(session);
        const close=[...document.querySelectorAll('[role=dialog] [role=button], [role=dialog] button')].find(e=>e.querySelector('[aria-label=Close]'));
        if(close)close.click();
        const end=Date.now()+12000;let rows=[];
        while(Date.now()<end){
          const sample=[...document.querySelectorAll('[role=button]')].find(e=>e.querySelector('img')&&e.innerText.includes('·'));
          if(sample){let container=sample.parentElement;for(let i=0;container&&i<7;i++,container=container.parentElement){if(container.querySelectorAll('[role=button]').length>1&&!container.querySelector('h1,h2,[role=heading]')){rows=[...container.querySelectorAll('[role=button]')].filter(e=>e.querySelector('img')&&e.innerText.trim());break;}}}
          if(rows.length)break;
          await new Promise(r=>setTimeout(r,200));
        }
        if(!rows.length)throw Error('No verified conversation list was found; an empty inbox cannot be inferred.');
        const limit=Math.min(30,Math.max(1,Number(args.limit)||20));
        const items=rows.slice(0,limit).map(e=>{const lines=e.innerText.split('\n').map(s=>s.trim()).filter(Boolean);return {title:lines[0]||'',preview:lines.slice(1).join(' ')};});
        await inboxIdentity(session);
        return {account:session.label,items,nextCursor:null,coverage:'visible_recent_previews_only; tab='+([...document.querySelectorAll('[role=tab]')].find(e=>e.getAttribute('aria-selected')==='true')?.innerText.trim()||'inbox')+'; older messages, other tabs, thread details, and requests not checked'};
    }});
    action('switchAccount',{async invoke({username}){
        const sessions=await discoverAuthenticatedSessions();if(sessions.length!==1)throw Error('A single authenticated Instagram account is required.');const session=sessions[0];
        await inboxIdentity(session);const own=await waitInbox(session);const target=normalizeUsername(username);
        if(target===session.label)return {requested:false,username:target};
        const picker=own.closest('[role=button]');if(!picker)throw Error('Account picker button unavailable.');
        if(![...document.querySelectorAll('[role=dialog]')].some(e=>e.innerText.includes('Log into an Existing Account')))picker.click();
        const end=Date.now()+8000;
        while(Date.now()<end){
          const nodes=[...document.querySelectorAll('[role=dialog] [role=button]')].filter(e=>!e.closest('[aria-hidden=true],[inert]')&&e.innerText.trim()===target&&!([...e.querySelectorAll('[role=button]')].some(c=>c.innerText.trim()===target)));
          if(nodes.length===1){await inboxIdentity(session);nodes[0].click();return {requested:true,username:target};}
          await new Promise(r=>setTimeout(r,200));
        }
        const labels=[...document.querySelectorAll('[role=dialog] [role=button]')].map(e=>e.innerText.trim()).filter(t=>/^[A-Za-z0-9_.]{1,30}$/.test(t));throw Error('Account selection unavailable or ambiguous. Available account controls: '+[...new Set(labels)].join(', '));
    }});

    action('listStoryTray',{async invoke({limit=30}){const end=Date.now()+18000;while(Date.now()<end){const rows=[...document.querySelectorAll('[aria-label^="Story by "]')];if(rows.length)return {items:rows.slice(0,limit).map(e=>({username:(e.getAttribute('aria-label').match(/^Story by (.*), (?:not seen|seen)$/)||[])[1]||e.innerText.trim(),id:e.getAttribute('aria-label'),latest:null,seen:null})),nextCursor:null};await new Promise(r=>setTimeout(r,200));}throw Error('Story tray controls did not load; coverage unavailable.');}});
    action('viewStory',{async invoke({username}){const end=Date.now()+18000;let target;while(Date.now()<end){target=[...document.querySelectorAll('[role="button"],button')].find(e=>(e.getAttribute('aria-label')||'').startsWith('Story by '+username+', '));if(target)break;await new Promise(r=>setTimeout(r,200));}if(!target)throw Error('Requested account is not in the loaded story buttons; no view opened.');target.click();const deadline=Date.now()+18000;let confirmed=false;while(Date.now()<deadline){if(location.pathname.startsWith('/stories/'+username+'/')){const confirmation=[...document.querySelectorAll('button,[role=button],a')].find(e=>usable(e)&&e.textContent.trim()==='View story');if(confirmation&&!confirmed){confirmation.click();confirmed=true;}const ready=!!document.querySelector('[aria-label="Pause"],[aria-label="Play"],[placeholder^="Reply to"]');const imgs=[...document.images].filter(e=>e.naturalWidth>300&&e.naturalHeight>300&&usable(e));const vids=[...document.querySelectorAll('video')].filter(usable);if(ready&&!document.body.innerText.includes('View as ')&&document.body.innerText.trim().startsWith(username+'\n')&&(imgs.length||vids.length)){const pause=[...document.querySelectorAll('[aria-label="Pause"]')].map(e=>e.closest('button,[role="button"]')).find(Boolean);if(pause)pause.click();vids.forEach(v=>v.pause());return {url:location.href,text:(document.querySelector('main')?.innerText||document.body.innerText).slice(0,5000),images:imgs.map(e=>({url:e.currentSrc||e.src,alt:e.alt||''})),video:vids.length>0};}}await new Promise(r=>setTimeout(r,100));}throw Error('Story view was requested but rendered media could not be verified. Inspect current state before retrying.');}});
    action('getStoryPage',{async invoke(){return {url:location.href,text:document.body.innerText.slice(-6000),controls:[...document.querySelectorAll('[aria-label]')].map(e=>e.getAttribute('aria-label')).slice(-50),images:[...document.images].filter(e=>e.naturalWidth>300&&usable(e)).map(e=>({url:e.currentSrc||e.src,alt:e.alt||'',width:e.clientWidth,height:e.clientHeight}))};}});
    action('confirmStoryView',{async invoke(){if(!location.pathname.startsWith('/stories/'))throw Error('Not a story page');const end=Date.now()+15000;let clicked=false;while(Date.now()<end){const b=[...document.querySelectorAll('button,[role=button],a')].find(e=>usable(e)&&e.textContent.trim()==='View story');if(b&&!clicked){b.click();clicked=true;}const images=[...document.images].filter(e=>e.naturalWidth>300&&usable(e));if(clicked&&!document.body.innerText.includes('View as ')&&(images.length||document.querySelector('[aria-label="Video player"]'))){document.querySelector('video')?.pause();const pause=document.querySelector('[aria-label="Pause"]')?.closest('button,[role=button]');if(pause)pause.click();return {url:location.href,text:document.body.innerText.slice(-6000),controls:[...document.querySelectorAll('[aria-label]')].map(e=>e.getAttribute('aria-label')).slice(-50),images:images.map(e=>({url:e.currentSrc||e.src,alt:e.alt||'',width:e.clientWidth,height:e.clientHeight}))};}await new Promise(r=>setTimeout(r,150));}throw Error('Story confirmation outcome uncertain; do not repeat without inspection');}});
    action("getProfile", {
        async invoke({ username } = {}) {
            const u = await fetchProfile(username || "");
            return {
                pk: String(u.id ?? ""),
                username: u.username || "",
                full_name: u.full_name || "",
                biography: u.biography || "",
                is_private: Boolean(u.is_private),
                is_verified: Boolean(u.is_verified),
                is_business: Boolean(u.is_business_account),
                follower_count: Number(u.edge_followed_by?.count) || 0,
                following_count: Number(u.edge_follow?.count) || 0,
                media_count: Number(u.edge_owner_to_timeline_media?.count) || 0,
                category: u.category_name || "",
                external_url: u.external_url || "",
                profile_pic_url: u.profile_pic_url_hd || u.profile_pic_url || "",
                url: `https://www.instagram.com/${u.username || ""}/`,
            };
        },
    });
    action("listUserPosts", {
        async invoke({ username, cursor, limit } = {}) {
            const id = await resolveUserId(username || "");
            const count = Math.min(Math.max(Number(limit) || 12, 1), 50);
            const qs = new URLSearchParams({ count: String(count) });
            if (cursor)
                qs.set("max_id", cursor);
            const json = await apiGet(`/api/v1/feed/user/${id}/?${qs.toString()}`);
            return {
                items: (json?.items || []).map(mediaRow),
                nextCursor: json?.more_available ? json?.next_max_id || null : null,
            };
        },
    });
    action("listUserReels", {
        async invoke({ username, cursor, limit } = {}) {
            const id = await resolveUserId(username || "");
            const page_size = Math.min(Math.max(Number(limit) || 12, 1), 50);
            const body = {
                target_user_id: id,
                page_size: String(page_size),
                include_feed_video: "true",
            };
            if (cursor)
                body.max_id = cursor;
            const json = await apiPost(`/api/v1/clips/user/`, body);
            return {
                items: (json?.items || []).map(mediaRow),
                nextCursor: json?.paging_info?.more_available ? json?.paging_info?.max_id || null : null,
            };
        },
    });
    action("getPost", {
        async invoke({ id } = {}) {
            const pk = parseMediaId(id || "");
            const json = await apiGet(`/api/v1/media/${pk}/info/`);
            const item = json?.items?.[0];
            if (!item)
                throw new Error(`media ${pk} not found`);
            return mediaRow(item);
        },
    });
    action("listPostComments", {
        async invoke({ id, cursor } = {}) {
            const pk = parseMediaId(id || "");
            const qs = new URLSearchParams({ can_support_threading: "true", permalink_enabled: "false" });
            if (cursor)
                qs.set("min_id", cursor);
            const json = await apiGet(`/api/v1/media/${pk}/comments/?${qs.toString()}`);
            return {
                items: (json?.comments || []).map((c) => ({
                    id: String(c?.pk ?? ""),
                    text: c?.text || "",
                    username: c?.user?.username || "",
                    like_count: Number(c?.comment_like_count) || 0,
                    reply_count: Number(c?.child_comment_count) || 0,
                    created_at: Number(c?.created_at) || 0,
                })),
                nextCursor: json?.has_more_comments ? json?.next_min_id || null : null,
            };
        },
    });
    action("searchUsers", {
        async invoke({ query } = {}) {
            const q = String(query ?? "").trim();
            if (!q)
                throw new Error("query is required");
            const json = await apiGet(`/api/v1/web/search/topsearch/?context=blended&query=${encodeURIComponent(q)}`);
            return {
                items: (json?.users || []).map((x) => userRow(x.user || x)),
                nextCursor: null,
            };
        },
    });
    action("listExplore", {
        async invoke({ cursor } = {}) {
            const qs = new URLSearchParams({
                include_fixed_destinations: "true",
                is_nonpersonalized_explore: "false",
                is_prefetch: "false",
                module: "explore_popular",
                omit_cover_media: "false",
                max_id: cursor || "0",
            });
            const json = await apiGet(`/api/v1/discover/web/explore_grid/?${qs.toString()}`);
            return {
                items: collectMedia(json?.sectional_items || json?.items || []),
                nextCursor: json?.more_available ? json?.next_max_id || null : null,
            };
        },
    });
});

})();
