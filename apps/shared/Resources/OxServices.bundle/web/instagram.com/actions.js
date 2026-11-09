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
    action('login', { async invoke() {
        const visible = e => !!e && e.getClientRects().length > 0;
        const ready = () => [...document.querySelectorAll('input[type=password]')].some(visible) && [...document.querySelectorAll('button,[role=button],input[type=submit]')].some(e => visible(e) && (e.type === 'submit' || /^log in$/i.test(e.innerText.trim())));
        const findSwitch = () => [...document.querySelectorAll('[role=button]')].find(e => visible(e) && e.innerText.trim() === 'Switch accounts');
        const deadline = Date.now() + 18000;
        let openedMenu = false, openedSwitch = false, openedAnother = false;
        while (Date.now() < deadline) {
            const picker = [...document.querySelectorAll('[role=dialog]')].find(e => visible(e) && [...e.querySelectorAll('[role=button],button,a')].some(c => visible(c) && c.innerText.trim() === 'Log into an Existing Account'));
            if (ready() || picker) return null;
            const another = [...document.querySelectorAll('[role=button],button,a')].find(e => visible(e) && e.innerText.trim() === 'Use another profile');
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
    } });
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
            const own=headings.find(e=>e.innerText.trim()===session.label);
            const businessTabs=[...document.querySelectorAll('[role=tab]')].map(e=>e.innerText.trim());
            if(own&&(headings.some(e=>e.innerText.trim()==='Messages')||(businessTabs.includes('Primary')&&businessTabs.includes('General'))))return own;
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
