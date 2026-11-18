function createEmbeddedAutomation({ timeout = 5000 } = {}) {
  const normalize = value => String(value ?? "").replace(/\s+/g, " ").trim();
  const matches = (actual, expected, exact = false) => exact
    ? normalize(actual) === normalize(expected)
    : normalize(actual).toLowerCase().includes(normalize(expected).toLowerCase());
  const visible = element => {
    if (!element.isConnected || element.closest('[hidden], [inert], [aria-hidden="true"]')) return false;
    for (let node = element; node?.nodeType === 1; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
    }
    return element.getClientRects().length > 0;
  };
  const disabled = element => element.matches(":disabled") || !!element.closest('[aria-disabled="true"], [inert]');
  const label = element => {
    const ids = element.getAttribute("aria-labelledby");
    if (ids) {
      const text = normalize(ids.split(/\s+/).map(id => element.ownerDocument.getElementById(id)?.textContent ?? "").join(" "));
      if (text) return text;
    }
    if (element.hasAttribute("aria-label")) return normalize(element.getAttribute("aria-label"));
    if (element.labels?.length) return normalize(Array.from(element.labels, item => item.textContent).join(" "));
    if (element.tagName === "IMG") return normalize(element.getAttribute("alt"));
    if (element.tagName === "INPUT" && ["submit", "reset", "button"].includes(element.type)) return normalize(element.value);
    return normalize(element.getAttribute("title") || (["INPUT", "TEXTAREA", "SELECT"].includes(element.tagName) ? "" : element.textContent));
  };
  const role = element => {
    const explicit = element.getAttribute("role")?.trim().split(/\s+/)[0];
    if (explicit) return explicit;
    const tag = element.tagName;
    if (tag === "INPUT") {
      const type = element.type;
      if (["button", "submit", "reset", "image"].includes(type)) return "button";
      if (["checkbox", "radio"].includes(type)) return type;
      if (type === "range") return "slider";
      if (type === "number") return "spinbutton";
      if (type === "search") return "searchbox";
      if (["text", "email", "tel", "url"].includes(type)) return "textbox";
      return "";
    }
    if (tag === "A") return element.hasAttribute("href") ? "link" : "";
    if (tag === "SELECT") return element.multiple || element.size > 1 ? "listbox" : "combobox";
    if (/^H[1-6]$/.test(tag)) return "heading";
    return ({ BUTTON: "button", TEXTAREA: "textbox", OPTION: "option", IMG: "img", UL: "list", OL: "list", LI: "listitem", TABLE: "table", TR: "row", TD: "cell", TH: "columnheader", DIALOG: "dialog", MAIN: "main", NAV: "navigation" })[tag] ?? "";
  };
  const duration = value => {
    const ms = value ?? timeout;
    if (!Number.isFinite(ms) || ms < 0 || ms > 30000) throw new Error("Automation timeout must be between 0 and 30000 ms");
    return ms;
  };
  duration(timeout);
  const pause = () => new Promise(resolve => setTimeout(resolve, 25));
  const locator = (resolve, description) => {
    const unique = () => {
      const elements = resolve();
      if (elements.length > 1) throw new Error(`Strict locator matched ${elements.length} elements: ${description}`);
      return elements[0];
    };
    const wait = async (predicate, options = {}) => {
      const deadline = Date.now() + duration(options.timeout);
      for (;;) {
        const element = unique();
        if (predicate(element)) return element;
        if (Date.now() >= deadline) throw new Error(`Locator condition timed out: ${description}`);
        await pause();
      }
    };
    const actionable = options => wait(element => element && visible(element) && !disabled(element), options);
    const clickElement = element => {
      element.scrollIntoView({ block: "center", inline: "center" });
      const rect = element.getBoundingClientRect();
      const hit = element.ownerDocument.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
      if (!hit || hit !== element && !element.contains(hit)) throw new Error(`Locator is obscured: ${description}`);
      if (!element.isConnected || disabled(element)) throw new Error(`Locator became unavailable: ${description}`);
      element.click();
    };
    const api = {
      ...queries(() => resolve()),
      filter({ hasText }) {
        if (typeof hasText !== "string") throw new Error("filter requires a string hasText");
        return locator(() => resolve().filter(element => matches(element.textContent, hasText)), `${description}.filter`);
      },
      nth(index) {
        if (!Number.isSafeInteger(index) || index < 0) throw new Error("nth requires a nonnegative integer");
        return locator(() => resolve().slice(index, index + 1), `${description}.nth(${index})`);
      },
      first() { return api.nth(0); },
      last() { return locator(() => resolve().slice(-1), `${description}.last()`); },
      async count() { return resolve().length; },
      async isVisible() { const element = unique(); return !!element && visible(element); },
      async waitFor({ state = "visible", ...options } = {}) {
        if (!["attached", "detached", "visible", "hidden"].includes(state)) throw new Error("Unsupported locator state");
        await wait(element => state === "attached" ? !!element : state === "detached" ? !element : state === "visible" ? !!element && visible(element) : !element || !visible(element), options);
      },
      async innerText(options) { return (await wait(element => !!element, options)).innerText; },
      async textContent(options) { return (await wait(element => !!element, options)).textContent; },
      async getAttribute(name, options) { return (await wait(element => !!element, options)).getAttribute(name); },
      async allTextContents() { return resolve().map(element => element.textContent ?? ""); },
      async click(options) { clickElement(await actionable(options)); },
      async fill(value, options) {
        if (typeof value !== "string") throw new Error("fill requires a string");
        const element = await actionable(options);
        if (element.readOnly) throw new Error(`Locator is read-only: ${description}`);
        if (element.tagName === "INPUT" && !["text", "email", "password", "search", "tel", "url", "number"].includes(element.type)) throw new Error("Unsupported input type for fill");
        const view = element.ownerDocument.defaultView;
        const prototype = element.tagName === "INPUT" ? view.HTMLInputElement.prototype : element.tagName === "TEXTAREA" ? view.HTMLTextAreaElement.prototype : null;
        element.focus();
        if (prototype) Object.getOwnPropertyDescriptor(prototype, "value").set.call(element, value);
        else if (element.isContentEditable) element.textContent = value;
        else throw new Error("fill requires an input, textarea, or contenteditable element");
        element.dispatchEvent(new view.Event("input", { bubbles: true }));
        element.dispatchEvent(new view.Event("change", { bubbles: true }));
      },
      async check(options) { await api.setChecked(true, options); },
      async uncheck(options) { await api.setChecked(false, options); },
      async setChecked(checked, options) {
        if (typeof checked !== "boolean") throw new Error("setChecked requires a boolean");
        const element = await actionable(options);
        if (element.tagName !== "INPUT" || !["checkbox", "radio"].includes(element.type)) throw new Error("setChecked requires a checkbox or radio input");
        if (element.checked === checked) return;
        clickElement(element);
        if (element.checked !== checked) throw new Error("Checked state unverified after dispatch; inspect before retrying");
      },
      async selectOption(value, options) {
        const values = Array.isArray(value) ? value : [value];
        if (values.some(item => typeof item !== "string")) throw new Error("selectOption accepts string values only");
        const element = await actionable(options);
        if (element.tagName !== "SELECT" || !element.multiple && values.length !== 1) throw new Error("Invalid selectOption target or values");
        const selected = Array.from(element.options).filter(option => values.includes(option.value));
        if (values.some(value => !selected.some(option => option.value === value)) || selected.some(option => option.disabled || option.parentElement?.disabled)) throw new Error("Select option is missing or disabled");
        for (const option of element.options) option.selected = values.includes(option.value);
        const view = element.ownerDocument.defaultView;
        element.dispatchEvent(new view.Event("input", { bubbles: true }));
        element.dispatchEvent(new view.Event("change", { bubbles: true }));
        return selected.map(option => option.value);
      },
    };
    return api;
  };
  function queries(roots) {
    const find = predicate => [...new Set(roots().flatMap(root => Array.from(root.querySelectorAll("*"))))].filter(predicate);
    return {
      locator(selector) { return locator(() => [...new Set(roots().flatMap(root => Array.from(root.querySelectorAll(selector))))], "css locator"); },
      getByRole(expected, { name, exact = false, includeHidden = false } = {}) {
        return locator(() => find(element => role(element) === expected && (includeHidden || visible(element)) && (name === undefined || matches(label(element), name, exact))), `role=${expected}`);
      },
      getByLabel(text, { exact = false } = {}) {
        return locator(() => find(element => element.matches("input, textarea, select, button, [contenteditable], [aria-label], [aria-labelledby]") && matches(label(element), text, exact)), "label locator");
      },
      getByText(text, { exact = false } = {}) {
        return locator(() => find(element => !element.matches("script, style, head, title") && matches(element.textContent, text, exact)
          && !Array.from(element.children).some(child => matches(child.textContent, text, exact))), "text locator");
      },
      getByPlaceholder(text, { exact = false } = {}) {
        return locator(() => find(element => element.hasAttribute("placeholder") && matches(element.getAttribute("placeholder"), text, exact)), "placeholder locator");
      },
      getByTestId(value) { return locator(() => find(element => element.getAttribute("data-testid") === value), "test id locator"); },
    };
  }
  return queries(() => [document]);
}

const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();

window.ox.install(({ action }) => {
    action('getConversation',{async invoke({id,limit=100}){
        const end=Date.now()+12000;let root=null;
        while(Date.now()<end){
            const active=document.querySelector('.xhs-im-conv-item--active');
            if(active?.getAttribute('data-conv-id')===id){root=document.querySelector('.xhs-im-msg-list');if(root?.querySelector('.chat-item'))break;}
            await new Promise(r=>setTimeout(r,150));
        }
        if(!root?.querySelector('.chat-item')||document.querySelector('.xhs-im-conv-item--active')?.getAttribute('data-conv-id')!==id)throw Error('Requested conversation is not verified open with rendered message rows');
        let timeLabel='';const rows=[];
        for(const e of root.children){
            if(e.classList.contains('xhs-im-msg-list__time-divider')){timeLabel=cleanText(e.textContent);continue;}
            if(!e.classList.contains('chat-item'))continue;
            rows.push({id:e.getAttribute('data-message-id')||'',direction:e.querySelector('.chat-item__content--right')?'outgoing':e.querySelector('.chat-item__content--left')?'incoming':e.querySelector('.chat-item__pure')?'system':'unknown',text:cleanText(e.querySelector('.xhs-im-bubble__text,.xhs-im-bubble__unsupported-text')?.textContent||e.textContent),timeLabel,contentType:e.getAttribute('data-content-type')||'',unsupported:!!e.querySelector('.xhs-im-bubble__unsupported')});
        }
        return {id,name:cleanText(document.querySelector('.xhs-im-chat-window__header-name')?.textContent),items:rows.slice(-Math.min(200,Math.max(1,Number(limit)||100))),nextCursor:null,coverage:'rendered_message_turns_only; preceding_history_pagination_not_established; unsupported_media_not_interpreted'};
    }});

    action('openConversation',{async invoke({id}){
        if(!/^[a-fA-F0-9]{24}$/.test(id))throw Error('Invalid conversation ID');
        const automation=createEmbeddedAutomation({timeout:8000});
        await automation.locator('.xhs-im-conv-item[data-conv-id="'+id+'"]').click();
        return {requested:true,id};
    }});

    action('listInbox', {async invoke(args){
        const end=Date.now()+15000;let list=null,rows=[];
        while(Date.now()<end){
            list=document.querySelector('.xhs-im-conv-list__scroll');
            rows=[...document.querySelectorAll('.xhs-im-conv-item[data-conv-id]')];
            if(list&&rows.length)break;
            if(/安全验证|Security Verification/.test(document.body?.innerText||''))throw Error('XHS security verification required');
            await new Promise(r=>setTimeout(r,200));
        }
        if(!list||!rows.length)throw Error('XHS conversation list did not become ready; an empty inbox cannot be inferred');
        return {items:rows.slice(0,Math.min(30,Math.max(1,Number(args.limit)||20))).map(e=>({id:e.getAttribute('data-conv-id')||'',kind:e.getAttribute('data-conv-kind')||'',name:cleanText(e.querySelector('.xhs-im-conv-item__name')?.textContent),preview:cleanText(e.querySelector('.xhs-im-conv-item__summary-text')?.textContent),timeLabel:cleanText(e.querySelector('.xhs-im-conv-item__time')?.textContent)})),nextCursor:null,coverage:'loaded_private_conversation_previews_only; threads not opened; sender direction, unread state, older unloaded conversations, and requests not established'};
    }});

    const ORIGIN = "https://www.xiaohongshu.com";
    const numText = (v) => {
        const s = String(v ?? "").trim();
        return s && /\d/.test(s) ? s : "0";
    };
    const noteIdOf = (input) => {
        const m = String(input || "").match(/\/(?:explore|note|search_result|discovery\/item)\/([a-f0-9]{24})|\/user\/profile\/[^/?#]+\/([a-f0-9]{24})/i);
        return m ? (m[1] || m[2] || "") : "";
    };
    const noteIdToDate = (input) => {
        const id = noteIdOf(input);
        if (!id)
            return "";
        const ts = parseInt(id.slice(0, 8), 16);
        if (!ts || ts < 1_000_000_000 || ts > 4_000_000_000)
            return "";
        return new Date((ts + 8 * 3600) * 1000).toISOString().slice(0, 10);
    };
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const waitFor = async (pred, { timeoutMs = 10000, intervalMs = 100 } = {}) => {
        const deadline = Date.now() + timeoutMs;
        while (Date.now() < deadline) {
            const v = pred();
            if (v)
                return v;
            await sleep(intervalMs);
        }
        throw new Error("waitFor timeout");
    };
    // xhs mounts under #app. If a future build relocates the root we'll see the
    // action fail loudly instead of paying for a full-DOM probe on every read.
    const getStore = (id) => {
        const pinia = document.querySelector("#app")
            ?.__vue_app__?.config?.globalProperties?.$pinia;
        return pinia?._s?.get(id) ?? null;
    };
    // SPA-internal navigation. The throwaway `_=` defeats Vue Router's
    // same-URL no-op detection so the route handler always re-fires.
    const spaNavigate = (dest) => {
        const url = dest.startsWith("http") ? dest : ORIGIN + dest;
        const sep = url.includes("?") ? "&" : "?";
        history.pushState({}, "", url + sep + "_=" + Date.now());
        window.dispatchEvent(new PopStateEvent("popstate"));
    };
    const pageProblem = () => {
        if (location.pathname === "/404")
            return "not found";
        if (/\/website-login\/error/.test(location.href) || /error_code=/.test(location.search)) {
            return "sign-in failed";
        }
        if (/Security Verification|account security|安全验证/.test(document.body?.innerText || "")) {
            return "security verification required";
        }
        return "";
    };
    const xhsErrored = () => !!pageProblem();
    const pageContext = () => {
        const problem = pageProblem();
        return `${location.href} (${document.title || "no title"})${problem ? `: ${problem}` : ""}`;
    };
    action('login', { async invoke() {
            const destination = `${ORIGIN}/login`;
            if (location.href !== new URL(destination, location.href).href)
                location.assign(destination);
            return null;
        } });
    action('listSessions', { async invoke() {
            const r = await fetch(ORIGIN + '/notification', { credentials: 'include', cache: 'no-store' });
            if (!r.ok)
                throw Error('Xiaohongshu account HTTP ' + r.status);
            const u = new URL(r.url);
            if (u.origin !== ORIGIN)
                throw Error('Unexpected account origin');
            if (u.pathname === '/login')
                return [];
            if (u.pathname !== '/notification')
                throw Error('Unclassified account route');
            const d = new DOMParser().parseFromString(await r.text(), 'text/html');
            const me = [...d.querySelectorAll('a[href]')].find(a => /^(我|Me)$/.test(a.textContent.trim()) && /\/user\/profile\/[a-f0-9]{24}/i.test(a.getAttribute('href') || ''));
            const id = me?.getAttribute('href')?.match(/\/user\/profile\/([a-f0-9]{24})/i)?.[1];
            if (!id)
                throw Error('Xiaohongshu current account identity unavailable');
            return [{ id, label: id, url: ORIGIN + '/notification' }];
        } });
    const buildFeedItem = (entry) => {
        const card = entry?.noteCard || {};
        const id = entry?.id;
        if (!id)
            return null;
        const uid = card.user?.userId || "";
        const token = entry?.xsecToken || "";
        return {
            id,
            title: card.displayTitle || card.title || "",
            type: card.type || "",
            // Both `nickname` and `nickName` are real Pinia field variants on xhs
            // (per opencli's feed.js); not a snake-case alternate.
            author: card.user?.nickname || card.user?.nickName || "",
            authorUrl: uid ? `${ORIGIN}/user/profile/${uid}` : "",
            likes: numText(card.interactInfo?.likedCount),
            cover: card.cover?.urlDefault || card.cover?.urlPre || "",
            url: token
                ? `${ORIGIN}/explore/${id}?xsec_token=${encodeURIComponent(token)}&xsec_source=`
                : `${ORIGIN}/explore/${id}`,
        };
    };
    action("listFeed", {
        async invoke({ limit = 20 } = {}) {
            try {
                if (!/^\/explore/.test(location.pathname))
                    spaNavigate("/explore");
                const feeds = await waitFor(() => {
                    const arr = getStore("feed")?.feeds;
                    return Array.isArray(arr) && arr.length > 0 ? arr : null;
                });
                const items = [];
                const seen = new Set();
                for (const entry of feeds) {
                    if (items.length >= limit)
                        break;
                    const item = buildFeedItem(entry);
                    if (!item || seen.has(item.id))
                        continue;
                    seen.add(item.id);
                    items.push(item);
                }
                if (items.length === 0)
                    throw new Error("feed store yielded no items");
                return { items, nextCursor: null };
            }
            catch (e) {
                console.log("listFeed: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    // Scroll a container (or window) to its bottom and wait for new rows via a
    // MutationObserver. Stops at the target, or after two consecutive plateaus,
    // or after maxRounds.
    const scrollUntil = async ({ container, countRows, target, maxRounds = 12, }) => {
        const scroller = container ?? document.scrollingElement ?? document.documentElement;
        let last = countRows();
        if (last >= target)
            return last;
        let plateau = 0;
        for (let i = 0; i < maxRounds; i++) {
            const prevHeight = scroller.scrollHeight;
            if (container)
                container.scrollTop = container.scrollHeight;
            else
                window.scrollTo(0, document.body.scrollHeight);
            await new Promise((resolve) => {
                let to;
                const ob = new MutationObserver(() => {
                    if (scroller.scrollHeight > prevHeight) {
                        clearTimeout(to);
                        ob.disconnect();
                        setTimeout(resolve, 200);
                    }
                });
                ob.observe(document.body, { childList: true, subtree: true });
                to = setTimeout(() => { ob.disconnect(); resolve(); }, 2500);
            });
            const next = countRows();
            if (next >= target)
                return next;
            if (next === last) {
                if (++plateau >= 2)
                    return next;
            }
            else {
                plateau = 0;
                last = next;
            }
        }
        return countRows();
    };
    const collectSearchNotes = () => {
        const sections = new Set(Array.from(document.querySelectorAll("section.note-item")));
        for (const a of document.querySelectorAll('a[href*="/search_result/"], a[href*="/explore/"]')) {
            const s = a.closest("section");
            if (s)
                sections.add(s);
        }
        return Array.from(sections);
    };
    const isVisible = (el) => {
        if (el.classList.contains("query-note-item"))
            return false;
        const r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0)
            return false;
        const cs = getComputedStyle(el);
        return cs.display !== "none" && cs.visibility !== "hidden";
    };
    const visibleSearchCount = () => collectSearchNotes().filter(isVisible).length;
    const normalizeHref = (href) => {
        if (!href)
            return "";
        if (/^https?:\/\//.test(href))
            return href;
        if (href.startsWith("/"))
            return ORIGIN + href;
        return "";
    };
    // A rendered note card (search results, a profile's note grid). xhs renders
    // ~4 anchors per card: the bare `/explore/<id>` one has no query string; the
    // cover/title anchors carry `xsec_token`. Pick whichever anchor has the token,
    // since downstream getNote requires it. On a profile the cover anchor is
    // `/user/profile/<uid>/<noteid>?xsec_token=` — noteIdOf handles that shape too.
    const noteIdHrefRe = /\/(?:explore|search_result|discovery\/item)\/[a-f0-9]{24}|\/user\/profile\/[^/?#]+\/[a-f0-9]{24}/i;
    const noteCardFromSection = (el) => {
        const candidates = el.querySelectorAll('a.cover.mask, a.title, a[href*="/search_result/"], a[href*="/explore/"], a[href*="/user/profile/"]');
        let detail = null;
        for (const a of candidates) {
            const href = a.getAttribute("href") || "";
            if (!noteIdHrefRe.test(href))
                continue;
            if (/[?&]xsec_token=/.test(href)) {
                detail = a;
                break;
            }
            if (!detail)
                detail = a;
        }
        const url = normalizeHref(detail?.getAttribute("href") || "");
        if (!url)
            return null;
        const titleEl = el.querySelector(".title, .note-title, a.title, .footer .title span");
        let title = cleanText(titleEl?.textContent);
        if (!title)
            title = cleanText(detail?.querySelector("span")?.textContent);
        const nameEl = el.querySelector("a.author .name, .author-name, .nick-name, .name");
        const authorLink = el.querySelector('a.author, a[href*="/user/profile/"]:not(.cover)');
        const likesEl = el.querySelector(".count, .like-count, .like-wrapper .count");
        const coverImg = el.querySelector("a.cover img, .cover img, img");
        return {
            title,
            author: cleanText(nameEl?.textContent),
            authorUrl: normalizeHref(authorLink?.getAttribute("href") || ""),
            likes: cleanText(likesEl?.textContent) || "0",
            cover: coverImg?.currentSrc || coverImg?.src || "",
            url,
            publishedAt: noteIdToDate(url),
        };
    };
    const collectNoteCards = (limit) => {
        const items = [];
        const seen = new Set();
        for (const el of collectSearchNotes()) {
            if (items.length >= limit)
                break;
            if (!isVisible(el))
                continue;
            const item = noteCardFromSection(el);
            if (!item || seen.has(item.url))
                continue;
            seen.add(item.url);
            items.push(item);
        }
        return items;
    };
    const waitForRender = (pred, timeoutMs = 6000) => new Promise((resolve) => {
        if (pred()) {
            resolve(true);
            return;
        }
        const ob = new MutationObserver(() => { if (pred()) {
            ob.disconnect();
            resolve(true);
        } });
        ob.observe(document.body, { childList: true, subtree: true });
        setTimeout(() => { ob.disconnect(); resolve(pred()); }, timeoutMs);
    });
    const searchQuery = () => {
        let value = new URL(location.href).searchParams.get("keyword") || "";
        for (let i = 0; i < 2; i++) {
            try {
                const decoded = decodeURIComponent(value);
                if (decoded === value)
                    break;
                value = decoded;
            }
            catch {
                break;
            }
        }
        return value;
    };
    const searchChannelTab = (label) => Array.from(document.querySelectorAll(".channel, [class*='channel']")).find((channel) => channel.textContent?.trim() === label);
    const noteChannelTab = () => searchChannelTab("笔记");
    const userChannelTab = () => searchChannelTab("用户");
    const noteSignature = () => collectNoteCards(10).map((item) => item.url).join("\n");
    let searchQueue = Promise.resolve();
    const serializeSearch = (operation) => {
        const result = searchQueue.then(operation, operation);
        searchQueue = result.then(() => undefined, () => undefined);
        return result;
    };
    const openNoteSearch = async (query) => {
        const ready = () => {
            const store = getStore("search");
            if (location.pathname !== "/search_result_ai" || searchQuery() !== query ||
                store?.searchContext?.keyword !== query || store?.state !== "success" || !Array.isArray(store?.feeds)) return false;
            const ids = new Set(store.feeds.map(item => item.id));
            const cards = collectNoteCards(50);
            return cards.length > 0 && cards.every(item => ids.has(noteIdOf(item.url)));
        };
        const alreadyLoaded = location.pathname === "/search_result_ai" && searchQuery() === query;
        if (!alreadyLoaded) {
            const keyword = encodeURIComponent(encodeURIComponent(query));
            spaNavigate(`/search_result_ai?keyword=${keyword}&source=web_explore_feed`);
        }
        const deadline = Date.now() + 15000;
        while (Date.now() < deadline) {
            const problem = pageProblem();
            if (problem) throw new Error("Xiaohongshu search blocked: " + problem);
            if (ready()) return;
            await sleep(150);
        }
        throw new Error("Xiaohongshu search did not produce query-matched, loaded results; stale feed cards were not returned.");
    };
    action("search", {
        invoke({ query, limit = 10, cursor } = {}) {
            return serializeSearch(async () => {
                try {
                    if (!query?.trim()) throw new Error("Search query must not be blank");
                    if (cursor) throw new Error("Xiaohongshu note search does not expose continuation");
                    await openNoteSearch(String(query));
                    if (visibleSearchCount() < limit) {
                        await scrollUntil({ container: null, countRows: visibleSearchCount, target: limit });
                    }
                    return {
                        items: collectNoteCards(limit).map(item => ({ title: item.title || item.author || "笔记", url: item.url, snippet: null, data: item })),
                        nextCursor: null,
                        scope: "Notes",
                        coverage: "unknown",
                    };
                }
                catch (e) {
                    console.log("search failed");
                    throw e;
                }
            });
        },
    });
    action("searchUsers", {
        invoke({ query, limit = 20 } = {}) {
            return serializeSearch(async () => {
                try {
                    if (!query)
                        throw new Error("searchUsers requires a query");
                    await openNoteSearch(String(query));
                    const tab = await waitFor(userChannelTab, { timeoutMs: 6000 }).catch(() => null);
                    if (!tab)
                        throw new Error(`search tabs never rendered: ${pageContext()}`);
                    tab.click();
                    const userCards = () => Array.from(document.querySelectorAll(".user-list-item"))
                        .filter((item) => isVisible(item));
                    const countUsers = () => userCards().length;
                    const rendered = await waitForRender(() => countUsers() > 0);
                    if (!rendered) {
                        if (xhsErrored())
                            throw new Error(pageContext());
                        return { items: [], nextCursor: null };
                    }
                    if (countUsers() < limit) {
                        await scrollUntil({ container: null, countRows: countUsers, target: limit });
                    }
                    const items = [];
                    const seen = new Set();
                    for (const card of userCards()) {
                        if (items.length >= limit)
                            break;
                        const a = card.querySelector('a[href*="/user/profile/"]');
                        const url = normalizeHref(a?.getAttribute("href") || "");
                        const uid = userIdOf(url);
                        if (!uid || seen.has(uid))
                            continue;
                        seen.add(uid);
                        const img = card.querySelector("img#user-image, .user-image");
                        const descText = Array.from(card.querySelectorAll(".user-desc, .user-desc-box"))
                            .map((e) => cleanText(e.textContent)).join(" ");
                        items.push({
                            userId: uid,
                            nickname: cleanText(card.querySelector(".user-name")?.textContent),
                            redId: (descText.match(/红书号[:：]\s*(\S+)/) || ["", ""])[1],
                            fans: (descText.match(/粉丝[・·:：\s]*([\d.]+\s*[万千亿]?)/) || ["", ""])[1].replace(/\s+/g, ""),
                            avatar: img?.currentSrc || img?.src || "",
                            url: `${ORIGIN}/user/profile/${uid}`,
                        });
                    }
                    return { items, nextCursor: null };
                }
                catch (e) {
                    console.log("searchUsers: " + (e?.message ?? String(e)));
                    throw e;
                }
            });
        },
    });
    const userIdOf = (input) => {
        const s = String(input || "");
        const m = s.match(/\/user\/profile\/([0-9a-f]{24})/i) || s.match(/^\s*([0-9a-f]{24})\s*$/i);
        return m ? m[1] : "";
    };
    const onProfile = (uid) => new RegExp(`/user/profile/${uid}(?:[/?#]|$)`).test(location.pathname);
    // Navigate to a profile and wait for *its* data to land. The user store keeps
    // the previously-viewed profile's basicInfo/notes until the next fetch
    // resolves, and nothing in the payload carries the uid — so when we actually
    // navigate we null those fields first and gate on basicInfo repopulating,
    // otherwise a back-to-back call reads the prior profile.
    const goToProfile = async (uid) => {
        if (!onProfile(uid)) {
            const u = getStore("user");
            if (u) {
                if (u.userPageData)
                    u.userPageData.basicInfo = null;
                u.notes = [];
            }
            spaNavigate(`/user/profile/${uid}`);
        }
        try {
            return await waitFor(() => {
                if (xhsErrored())
                    throw new Error(pageContext());
                const upd = getStore("user")?.userPageData;
                return upd?.basicInfo?.nickname ? upd : null;
            }, { timeoutMs: 8000 });
        }
        catch (e) {
            // Fail fast with a useful message instead of letting the caller's later
            // waits compound toward the 30s debug-WS timeout.
            if (/waitFor timeout/.test(String(e?.message))) {
                throw new Error(`profile did not load: ${pageContext()}`);
            }
            throw e;
        }
    };
    action("listUserNotes", {
        async invoke({ url, limit = 20 } = {}) {
            try {
                const uid = userIdOf(String(url));
                if (!uid)
                    throw new Error(`unrecognised profile url or id: ${url}`);
                await goToProfile(uid);
                // The profile grid is virtualized (the DOM holds ~1 card), so read the
                // store. Its entries share the home-feed shape, so buildFeedItem applies.
                // The first page lands shortly after basicInfo and more pages lazy-load
                // on scroll, so poll the store (scrolling to nudge it) until we hit the
                // target or it plateaus — scrollUntil keys off DOM growth a virtualized
                // grid never produces.
                // user.notes is row-grouped (an array of rows, each holding the note
                // entries in that masonry row), so flatten to the home-feed entry shape.
                const notesOf = () => (getStore("user")?.notes || []).flat();
                // First page lands a beat after basicInfo; wait for it before
                // plateau-detecting (a genuinely empty profile just times out to []).
                try {
                    await waitFor(() => notesOf().length > 0, { timeoutMs: 6000 });
                }
                catch { }
                let plateau = 0;
                const deadline = Date.now() + 8000;
                while (notesOf().length < limit && Date.now() < deadline) {
                    const before = notesOf().length;
                    window.scrollTo(0, document.body.scrollHeight);
                    await sleep(700);
                    if (notesOf().length === before) {
                        if (++plateau >= 3)
                            break;
                    }
                    else
                        plateau = 0;
                }
                const items = [];
                const seen = new Set();
                for (const entry of notesOf()) {
                    if (items.length >= limit)
                        break;
                    const item = buildFeedItem(entry);
                    if (!item || seen.has(item.id))
                        continue;
                    seen.add(item.id);
                    items.push(item);
                }
                return { items, nextCursor: null };
            }
            catch (e) {
                console.log("listUserNotes: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("getUserProfile", {
        async invoke({ url } = {}) {
            try {
                const uid = userIdOf(String(url));
                if (!uid)
                    throw new Error(`unrecognised profile url or id: ${url}`);
                const data = await goToProfile(uid);
                const info = data.basicInfo || {};
                const stat = {};
                for (const it of (data.interactions || [])) {
                    if (it?.type)
                        stat[it.type] = numText(it.count);
                }
                return {
                    userId: uid,
                    nickname: cleanText(info.nickname),
                    desc: cleanText(info.desc),
                    redId: String(info.redId ?? ""),
                    ipLocation: cleanText(info.ipLocation),
                    avatar: info.images || info.imageb || "",
                    follows: stat.follows ?? "0",
                    fans: stat.fans ?? "0",
                    liked: stat.interaction ?? "0",
                    url: `${ORIGIN}/user/profile/${uid}`,
                };
            }
            catch (e) {
                console.log("getUserProfile: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    // Trending/suggested queries ride the search store's queryTrendingInfo, which
    // the explore search box populates. No dedicated navigation if it's already
    // loaded; otherwise nudge /explore and wait for it.
    action("listTrending", {
        async invoke({ limit = 10 } = {}) {
            try {
                const read = () => {
                    const s = getStore("search");
                    const q = s?.queryTrendingInfo?.queries;
                    const arr = Array.isArray(q) && q.length ? q : s?.suggestions;
                    return Array.isArray(arr) && arr.length ? arr : null;
                };
                let arr = read();
                if (!arr) {
                    if (!/^\/explore/.test(location.pathname))
                        spaNavigate("/explore");
                    arr = await waitFor(read, { timeoutMs: 6000 });
                }
                const items = [];
                const seen = new Set();
                for (const q of arr) {
                    if (items.length >= limit)
                        break;
                    const query = cleanText(q?.text || q?.searchWord || q?.title);
                    if (!query || seen.has(query))
                        continue;
                    seen.add(query);
                    items.push({ query });
                }
                return { items };
            }
            catch (e) {
                console.log("listTrending: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    // xhs's note APIs are gated by an xsec_token. Without it the SPA falls
    // through to /404 (error_code=300031) before any signed POST fires, so the
    // only useful failure mode is to reject the input up front. Pass the full
    // URL from listFeed/listSearchResults/listComments output — those carry the
    // token in the query string.
    const goToNote = (rawUrl) => {
        if (!rawUrl)
            throw new Error("note url is required");
        const id = noteIdOf(rawUrl);
        if (!id)
            throw new Error(`unrecognised note url: ${rawUrl}`);
        let token = "";
        try {
            token = new URL(rawUrl, ORIGIN).searchParams.get("xsec_token")?.trim() ?? "";
        }
        catch { }
        if (!token)
            throw new Error(`note url missing xsec_token: ${rawUrl}`);
        if (!location.pathname.includes(id))
            spaNavigate(rawUrl);
        return id;
    };
    const waitForNoteDom = async (timeoutMs = 10000) => {
        const deadline = Date.now() + timeoutMs;
        while (Date.now() < deadline) {
            if (document.querySelector("#detail-title, .interact-container"))
                return;
            if (xhsErrored())
                throw new Error(pageContext());
            await sleep(120);
        }
        throw new Error(`note page did not render: ${pageContext()}`);
    };
    // Title/body/counts come from the DOM — opencli's note.js proves this is
    // the stable signal for note details.
    action("getNote", {
        async invoke({ url } = {}) {
            try {
                const id = goToNote(String(url));
                const note = await waitFor(() => {
                    if (xhsErrored()) throw new Error('Note page blocked or unavailable');
                    const n = getStore("note")?.noteDetailMap?.[id]?.note;
                    return n?.noteId === id && typeof n.desc === "string" && n.user?.userId ? n : null;
                }, { timeoutMs: 12000 });
                const info = note.interactInfo || {};
                return {
                    id: note.noteId,
                    title: cleanText(note.title),
                    author: cleanText(note.user.nickname || note.user.nickName),
                    authorUrl: ORIGIN + '/user/profile/' + note.user.userId,
                    content: cleanText(note.desc),
                    likes: numText(info.likedCount),
                    collects: numText(info.collectedCount),
                    comments: numText(info.commentCount),
                    tags: (note.tagList || []).map(t => cleanText(t.name)).filter(Boolean),
                    cover: note.imageList?.[0]?.urlDefault || note.imageList?.[0]?.urlPre || '',
                    url: String(url),
                };
            }
            catch (e) {
                console.log("getNote: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    // Media is the one place the store beats DOM: imageList preserves carousel
    // order, and video.media.stream exposes per-codec master URLs the DOM lacks.
    action("getNoteMedia", {
        async invoke({ url } = {}) {
            try {
                const id = goToNote(String(url));
                const note = await waitFor(() => {
                    if (xhsErrored())
                        throw new Error(pageContext());
                    const entry = getStore("note")?.noteDetailMap?.[id];
                    const n = entry?.note || entry;
                    return n && typeof n === "object" ? n : null;
                });
                const items = [];
                const seen = new Set();
                const push = (type, u) => {
                    const v = (u || "").trim();
                    if (!v || seen.has(v))
                        return;
                    seen.add(v);
                    items.push({ type, url: v });
                };
                for (const img of (note.imageList || [])) {
                    push("image", img?.urlDefault || img?.urlPre || img?.url);
                }
                const streams = note.video?.media?.stream;
                if (streams && typeof streams === "object") {
                    for (const codec of Object.values(streams)) {
                        if (!Array.isArray(codec))
                            continue;
                        for (const s of codec)
                            push("video", s?.masterUrl);
                    }
                }
                if (items.length === 0)
                    throw new Error(`no media on ${url}`);
                return {
                    id: note.noteId || id,
                    title: cleanText(note.title),
                    author: cleanText(note.user?.nickname || note.user?.nickName),
                    items,
                };
            }
            catch (e) {
                console.log("getNoteMedia: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    // Parses xhs like-count text: "1,234", "1.2w" (10k), "2.5万", "123+".
    const parseLikeText = (raw) => {
        const s = String(raw ?? "").replace(/\s+/g, "");
        if (!s)
            return 0;
        const integerRe = /^(?:\d+|\d{1,3}(?:[,，]\d{3})+)\+?$/u;
        const shortRe = /^((?:\d+|\d{1,3}(?:[,，]\d{3})+)(?:\.\d+)?)([wWkK万千])\+?$/u;
        if (integerRe.test(s))
            return Number(s.replace(/[,+，]/g, "")) || 0;
        const m = s.match(shortRe);
        if (!m)
            return 0;
        const n = Number(m[1].replace(/[,，]/g, ""));
        if (!Number.isFinite(n))
            return 0;
        const unit = m[2].toLowerCase();
        const mul = unit === "w" || unit === "万" ? 10000 : 1000;
        return Math.round(n * mul);
    };
    action("listComments", {
        async invoke({ url, limit = 20 } = {}) {
            try {
                if (!url)
                    throw new Error("listComments requires a note url");
                goToNote(String(url));
                await waitForNoteDom();
                // Comments lazy-load into an inner overflow container; window-level
                // scrolling does nothing on a note page.
                const scroller = document.querySelector(".note-scroller") ||
                    document.querySelector(".container");
                const countParents = () => document.querySelectorAll(".parent-comment").length;
                await scrollUntil({ container: scroller, countRows: countParents, target: limit });
                const items = [];
                for (const p of document.querySelectorAll(".parent-comment")) {
                    if (items.length >= limit)
                        break;
                    const item = p.querySelector(".comment-item");
                    if (!item)
                        continue;
                    const author = cleanText(item.querySelector(".author-wrapper .name, .user-name")?.textContent);
                    const text = cleanText(item.querySelector(".content, .note-text")?.textContent);
                    if (!text)
                        continue;
                    const likes = parseLikeText(item.querySelector(".count")?.textContent);
                    const time = cleanText(item.querySelector(".date, .time")?.textContent);
                    items.push({ author, text, likes, time, isReply: false, replyTo: "" });
                    for (const sub of p.querySelectorAll(".reply-container .comment-item-sub, .sub-comment-list .comment-item")) {
                        if (items.length >= limit)
                            break;
                        const sAuthor = cleanText(sub.querySelector(".name, .user-name")?.textContent);
                        const sText = cleanText(sub.querySelector(".content, .note-text")?.textContent);
                        if (!sText)
                            continue;
                        const sLikes = parseLikeText(sub.querySelector(".count")?.textContent);
                        const sTime = cleanText(sub.querySelector(".date, .time")?.textContent);
                        items.push({
                            author: sAuthor,
                            text: sText,
                            likes: sLikes,
                            time: sTime,
                            isReply: true,
                            replyTo: author,
                        });
                    }
                }
                return { items, nextCursor: null };
            }
            catch (e) {
                console.log("listComments: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
});
