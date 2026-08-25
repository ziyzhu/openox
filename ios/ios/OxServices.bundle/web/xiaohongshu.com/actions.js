(() => {
  // service-sdk/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  // services/builtin/web/xiaohongshu.com/actions.ts
  var install = ({ action, log }) => {
    const ORIGIN = "https://www.xiaohongshu.com";
    const numText = (v) => {
      const s = String(v ?? "").trim();
      return s && /\d/.test(s) ? s : "0";
    };
    const noteIdOf = (input) => {
      const m = String(input || "").match(/\/(?:explore|note|search_result|discovery\/item)\/([a-f0-9]{24})|\/user\/profile\/[^/?#]+\/([a-f0-9]{24})/i);
      return m ? m[1] || m[2] || "" : "";
    };
    const noteIdToDate = (input) => {
      const id = noteIdOf(input);
      if (!id)
        return "";
      const ts = parseInt(id.slice(0, 8), 16);
      if (!ts || ts < 1e9 || ts > 4000000000)
        return "";
      return new Date((ts + 8 * 3600) * 1000).toISOString().slice(0, 10);
    };
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const waitFor = async (pred, { timeoutMs = 1e4, intervalMs = 100 } = {}) => {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const v = pred();
        if (v)
          return v;
        await sleep(intervalMs);
      }
      throw new Error("waitFor timeout");
    };
    const getStore = (id) => {
      const pinia = document.querySelector("#app")?.__vue_app__?.config?.globalProperties?.$pinia;
      return pinia?._s?.get(id) ?? null;
    };
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
    action("getSignInUrl", { async invoke() {
      return { url: `${ORIGIN}/login` };
    } });
    action("getSignInState", {
      async invoke() {
        try {
          const response = await fetch(`${ORIGIN}/notification`, {
            method: "HEAD",
            credentials: "include",
            redirect: "follow",
            cache: "no-store"
          });
          const url = new URL(response.url);
          const signedOut = response.redirected && url.origin === ORIGIN && url.pathname === "/login";
          const signedIn = !response.redirected && url.origin === ORIGIN && url.pathname === "/notification";
          log(`getSignInState: status=${response.status} redirected=${response.redirected} path=${url.pathname}`);
          if (!signedIn && !signedOut)
            throw new Error("unexpected authentication response");
          return { signedIn };
        } catch (e) {
          log("getSignInState: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
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
        author: card.user?.nickname || card.user?.nickName || "",
        authorUrl: uid ? `${ORIGIN}/user/profile/${uid}` : "",
        likes: numText(card.interactInfo?.likedCount),
        cover: card.cover?.urlDefault || card.cover?.urlPre || "",
        url: token ? `${ORIGIN}/explore/${id}?xsec_token=${encodeURIComponent(token)}&xsec_source=` : `${ORIGIN}/explore/${id}`
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
          const seen = new Set;
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
        } catch (e) {
          log("listFeed: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    const scrollUntil = async ({
      container,
      countRows,
      target,
      maxRounds = 12
    }) => {
      const scroller = container ?? document.scrollingElement ?? document.documentElement;
      let last = countRows();
      if (last >= target)
        return last;
      let plateau = 0;
      for (let i = 0;i < maxRounds; i++) {
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
          to = setTimeout(() => {
            ob.disconnect();
            resolve();
          }, 2500);
        });
        const next = countRows();
        if (next >= target)
          return next;
        if (next === last) {
          if (++plateau >= 2)
            return next;
        } else {
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
        publishedAt: noteIdToDate(url)
      };
    };
    const collectNoteCards = (limit) => {
      const items = [];
      const seen = new Set;
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
      const ob = new MutationObserver(() => {
        if (pred()) {
          ob.disconnect();
          resolve(true);
        }
      });
      ob.observe(document.body, { childList: true, subtree: true });
      setTimeout(() => {
        ob.disconnect();
        resolve(pred());
      }, timeoutMs);
    });
    const searchQuery = () => {
      let value = new URL(location.href).searchParams.get("keyword") || "";
      for (let i = 0;i < 2; i++) {
        try {
          const decoded = decodeURIComponent(value);
          if (decoded === value)
            break;
          value = decoded;
        } catch {
          break;
        }
      }
      return value;
    };
    const searchChannelTab = (label) => Array.from(document.querySelectorAll(".channel, [class*='channel']")).find((channel) => channel.textContent?.trim() === label);
    const noteChannelTab = () => searchChannelTab("笔记");
    const userChannelTab = () => searchChannelTab("用户");
    const noteSignature = () => collectNoteCards(10).map((item) => item.url).join(`
`);
    let searchQueue = Promise.resolve();
    const serializeSearch = (operation) => {
      const result = searchQueue.then(operation, operation);
      searchQueue = result.then(() => {
        return;
      }, () => {
        return;
      });
      return result;
    };
    const openNoteSearch = async (query) => {
      const alreadyLoaded = location.pathname === "/search_result_ai" && searchQuery() === query;
      if (alreadyLoaded) {
        if (visibleSearchCount() === 0)
          noteChannelTab()?.click();
        const rendered2 = await waitForRender(() => visibleSearchCount() > 0);
        if (!rendered2)
          throw new Error(`search results never rendered: ${pageContext()}`);
        return;
      }
      const previousFirst = collectSearchNotes()[0] ?? null;
      const previousSignature = noteSignature();
      const keyword = encodeURIComponent(encodeURIComponent(query));
      spaNavigate(`/search_result_ai?keyword=${keyword}&source=web_explore_feed`);
      const rendered = await waitForRender(() => {
        const rows = collectSearchNotes().filter(isVisible);
        if (searchQuery() !== query || rows.length === 0)
          return false;
        return rows[0] !== previousFirst || noteSignature() !== previousSignature;
      });
      if (!rendered)
        throw new Error(`search results never rendered: ${pageContext()}`);
    };
    action("searchNotes", {
      invoke({ query, limit = 20 } = {}) {
        return serializeSearch(async () => {
          try {
            if (!query)
              throw new Error("searchNotes requires a query");
            await openNoteSearch(String(query));
            if (visibleSearchCount() < limit) {
              await scrollUntil({ container: null, countRows: visibleSearchCount, target: limit });
            }
            return { items: collectNoteCards(limit), nextCursor: null };
          } catch (e) {
            log("searchNotes: " + (e?.message ?? String(e)));
            throw e;
          }
        });
      }
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
            const userCards = () => Array.from(document.querySelectorAll(".user-list-item")).filter((item) => isVisible(item));
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
            const seen = new Set;
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
              const descText = Array.from(card.querySelectorAll(".user-desc, .user-desc-box")).map((e) => cleanText(e.textContent)).join(" ");
              items.push({
                userId: uid,
                nickname: cleanText(card.querySelector(".user-name")?.textContent),
                redId: (descText.match(/红书号[:：]\s*(\S+)/) || ["", ""])[1],
                fans: (descText.match(/粉丝[・·:：\s]*([\d.]+\s*[万千亿]?)/) || ["", ""])[1].replace(/\s+/g, ""),
                avatar: img?.currentSrc || img?.src || "",
                url: `${ORIGIN}/user/profile/${uid}`
              });
            }
            return { items, nextCursor: null };
          } catch (e) {
            log("searchUsers: " + (e?.message ?? String(e)));
            throw e;
          }
        });
      }
    });
    const userIdOf = (input) => {
      const s = String(input || "");
      const m = s.match(/\/user\/profile\/([0-9a-f]{24})/i) || s.match(/^\s*([0-9a-f]{24})\s*$/i);
      return m ? m[1] : "";
    };
    const onProfile = (uid) => new RegExp(`/user/profile/${uid}(?:[/?#]|$)`).test(location.pathname);
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
      } catch (e) {
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
          const notesOf = () => (getStore("user")?.notes || []).flat();
          try {
            await waitFor(() => notesOf().length > 0, { timeoutMs: 6000 });
          } catch {}
          let plateau = 0;
          const deadline = Date.now() + 8000;
          while (notesOf().length < limit && Date.now() < deadline) {
            const before = notesOf().length;
            window.scrollTo(0, document.body.scrollHeight);
            await sleep(700);
            if (notesOf().length === before) {
              if (++plateau >= 3)
                break;
            } else
              plateau = 0;
          }
          const items = [];
          const seen = new Set;
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
        } catch (e) {
          log("listUserNotes: " + (e?.message ?? String(e)));
          throw e;
        }
      }
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
          for (const it of data.interactions || []) {
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
            url: `${ORIGIN}/user/profile/${uid}`
          };
        } catch (e) {
          log("getUserProfile: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("listTrending", {
      async invoke({ limit = 10 } = {}) {
        try {
          const read = () => {
            const s = getStore("search");
            const q = s?.queryTrendingInfo?.queries;
            const arr2 = Array.isArray(q) && q.length ? q : s?.suggestions;
            return Array.isArray(arr2) && arr2.length ? arr2 : null;
          };
          let arr = read();
          if (!arr) {
            if (!/^\/explore/.test(location.pathname))
              spaNavigate("/explore");
            arr = await waitFor(read, { timeoutMs: 6000 });
          }
          const items = [];
          const seen = new Set;
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
        } catch (e) {
          log("listTrending: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    const goToNote = (rawUrl) => {
      if (!rawUrl)
        throw new Error("note url is required");
      const id = noteIdOf(rawUrl);
      if (!id)
        throw new Error(`unrecognised note url: ${rawUrl}`);
      let token = "";
      try {
        token = new URL(rawUrl, ORIGIN).searchParams.get("xsec_token")?.trim() ?? "";
      } catch {}
      if (!token)
        throw new Error(`note url missing xsec_token: ${rawUrl}`);
      if (!location.pathname.includes(id))
        spaNavigate(rawUrl);
      return id;
    };
    const waitForNoteDom = async (timeoutMs = 1e4) => {
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
    action("getNote", {
      async invoke({ url } = {}) {
        try {
          const id = goToNote(String(url));
          await waitForNoteDom();
          const title = cleanText(document.querySelector("#detail-title, .title")?.textContent);
          const desc = cleanText(document.querySelector("#detail-desc, .desc, .note-text")?.textContent);
          const author = cleanText(document.querySelector(".username, .author-wrapper .name")?.textContent);
          const barOf = () => document.querySelector(".engage-bar, .interact-container");
          const bar = await waitFor(() => {
            const b = barOf();
            return b && /\d/.test(b.querySelector(".like-wrapper .count")?.textContent || "") ? b : null;
          }, { timeoutMs: 4000 }).catch(() => barOf());
          const countAt = (sel) => {
            const s = cleanText(bar?.querySelector(sel)?.textContent);
            return /^\d/.test(s) ? s : "0";
          };
          const tags = [];
          document.querySelectorAll('#detail-desc a.tag, #detail-desc a[href*="search_result"]').forEach((el) => {
            const t = cleanText(el.textContent);
            if (t)
              tags.push(t);
          });
          if (!title && !author)
            throw new Error("note page rendered without title or author");
          return {
            id,
            title,
            author,
            authorUrl: "",
            content: desc,
            likes: countAt(".like-wrapper .count"),
            collects: countAt(".collect-wrapper .count"),
            comments: countAt(".chat-wrapper .count"),
            tags,
            cover: "",
            url: String(url)
          };
        } catch (e) {
          log("getNote: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
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
          const seen = new Set;
          const push = (type, u) => {
            const v = (u || "").trim();
            if (!v || seen.has(v))
              return;
            seen.add(v);
            items.push({ type, url: v });
          };
          for (const img of note.imageList || []) {
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
            items
          };
        } catch (e) {
          log("getNoteMedia: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
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
      const mul = unit === "w" || unit === "万" ? 1e4 : 1000;
      return Math.round(n * mul);
    };
    action("listComments", {
      async invoke({ url, limit = 20 } = {}) {
        try {
          if (!url)
            throw new Error("listComments requires a note url");
          goToNote(String(url));
          await waitForNoteDom();
          const scroller = document.querySelector(".note-scroller") || document.querySelector(".container");
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
                replyTo: author
              });
            }
          }
          return { items, nextCursor: null };
        } catch (e) {
          log("listComments: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
  };
  var actions_default = install;

  // service-sdk/action-runtime.ts
  var patternMatches = (pattern, value) => {
    pattern.lastIndex = 0;
    const matched = pattern.test(value);
    pattern.lastIndex = 0;
    return matched;
  };
  function installFetchCapture(target) {
    const registrations = new Set;
    const recent = [];
    const matching = (url) => Array.from(registrations).filter((registration) => patternMatches(registration.pattern, url));
    const settle = (matched, result) => {
      for (const registration of matched) {
        if (!registrations.delete(registration))
          continue;
        clearTimeout(registration.timeout);
        if ("error" in result)
          registration.reject(result.error);
        else
          registration.resolve(result.value);
      }
    };
    const canReplay = (url) => {
      try {
        const page = new URL(target.location.href);
        const request = new URL(url, page);
        return request.hostname === page.hostname && /^\/(?:api|web_api)\//.test(request.pathname);
      } catch {
        return false;
      }
    };
    const capture = (url, read) => {
      const matched = matching(url);
      const replayable = canReplay(url);
      if (matched.length === 0 && !replayable)
        return;
      const value = read();
      if (replayable) {
        const entry = { url, value };
        recent.push(entry);
        while (recent.length > 32)
          recent.shift();
        value.catch(() => {
          const index = recent.indexOf(entry);
          if (index >= 0)
            recent.splice(index, 1);
        });
      }
      if (matched.length === 0)
        return;
      value.then((value2) => settle(matched, { value: value2 }), (error) => settle(matched, {
        error: new Error(`captured ${url} returned invalid JSON: ${String(error?.message ?? error)}`)
      }));
    };
    target.oxFetchCapture = (pattern, options) => {
      if (options?.replayLatest) {
        for (let index = recent.length - 1;index >= 0; index--) {
          if (patternMatches(pattern, recent[index].url))
            return recent[index].value;
        }
      }
      return new Promise((resolve, reject) => {
        const timeoutMs = options?.timeoutMs ?? 1e4;
        const registration = {};
        registration.pattern = pattern;
        registration.resolve = resolve;
        registration.reject = reject;
        registration.timeout = setTimeout(() => {
          if (!registrations.delete(registration))
            return;
          reject(new Error(`fetch capture timed out after ${timeoutMs}ms for ${pattern}`));
        }, timeoutMs);
        registrations.add(registration);
      });
    };
    const originalFetch = target.fetch.bind(target);
    target.fetch = (input, init) => originalFetch(input, init).then((response) => {
      const url = input instanceof Request ? input.url : String(input);
      capture(url, () => response.clone().json());
      return response;
    });
    const XHR = target.XMLHttpRequest;
    if (!XHR)
      return;
    const urls = new WeakMap;
    const originalOpen = XHR.prototype.open;
    const originalSend = XHR.prototype.send;
    XHR.prototype.open = function(...args) {
      urls.set(this, String(args[1] ?? ""));
      return originalOpen.apply(this, args);
    };
    XHR.prototype.send = function(...args) {
      this.addEventListener("loadend", () => {
        const url = urls.get(this) ?? this.responseURL;
        capture(url, async () => {
          if (this.responseType === "json")
            return this.response;
          return JSON.parse(this.responseText);
        });
      }, { once: true });
      return originalSend.apply(this, args);
    };
  }
  function installService(domain, installer) {
    installFetchCapture(window);
    const log = (msg) => {
      try {
        window.webkit?.messageHandlers?.oxConsole?.postMessage({
          level: "log",
          msg: `[service:${domain}] ${msg}`
        });
      } catch {}
    };
    const retryFetch = async (input, init, opts) => {
      const retries = opts?.retries ?? 3;
      const delay = opts?.delay ?? 400;
      const factor = opts?.factor ?? 2;
      const url = typeof input === "string" ? input : input.url;
      for (let attempt = 0;; attempt++) {
        try {
          const response = await window.fetch(input, init);
          const retryable = response.status === 408 || response.status === 429 || response.status >= 500 && response.status <= 599;
          if (response.ok || !retryable || attempt >= retries)
            return response;
          log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}, url=${url}`);
        } catch (error) {
          const message = String(error?.message ?? "");
          const retryable = message.includes("Load failed") || message.includes("NetworkError") || message.includes("Failed to fetch");
          if (!retryable || attempt >= retries)
            throw error;
          log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}, url=${url}`);
        }
        await new Promise((resolve) => setTimeout(resolve, delay * Math.pow(factor, attempt)));
      }
    };
    const actions = new Map;
    const action = (name, definition) => {
      if (actions.has(name))
        throw new Error(`duplicate action: ${name}`);
      if (typeof definition?.invoke !== "function")
        throw new Error(`action ${name} has no invoke function`);
      actions.set(name, definition.invoke);
    };
    try {
      installer({ action, retryFetch, log });
    } catch (error) {
      log(`service installer threw: ${String(error?.stack ?? error?.message ?? error)}`);
      throw error;
    }
    const invoke = async (name, args) => {
      const handler = actions.get(name);
      if (!handler)
        throw new Error(`unknown action: ${name}`);
      try {
        return await handler(args ?? {});
      } catch (error) {
        log(`action ${JSON.stringify(name)} threw: ${String(error?.stack ?? error?.message ?? error)}`);
        throw new Error(`action ${JSON.stringify(name)} failed: ${String(error?.message ?? error)}`);
      }
    };
    const runtime = {
      callServiceAction: (name, args) => invoke(name, args)
    };
    window.ox = runtime;
  }

  installService("xiaohongshu.com", actions_default);
})();
