import type { ActionInstaller } from "../action.ts";
import { cleanText } from "../../../action-lib.ts";

const install: ActionInstaller = ({ action, log }) => {
  const ORIGIN = "https://www.xiaohongshu.com";

  const numText = (v: any) => {
    const s = String(v ?? "").trim();
    return s && /\d/.test(s) ? s : "0";
  };

  const noteIdOf = (input: string) => {
    const m = String(input || "").match(
      /\/(?:explore|note|search_result|discovery\/item)\/([a-f0-9]{24})|\/user\/profile\/[^/?#]+\/([a-f0-9]{24})/i,
    );
    return m ? (m[1] || m[2] || "") : "";
  };

  const noteIdToDate = (input: string) => {
    const id = noteIdOf(input);
    if (!id) return "";
    const ts = parseInt(id.slice(0, 8), 16);
    if (!ts || ts < 1_000_000_000 || ts > 4_000_000_000) return "";
    return new Date((ts + 8 * 3600) * 1000).toISOString().slice(0, 10);
  };

  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  const waitFor = async <T>(
    pred: () => T | null | undefined | false,
    { timeoutMs = 10000, intervalMs = 100 }: { timeoutMs?: number; intervalMs?: number } = {},
  ): Promise<T> => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const v = pred();
      if (v) return v as T;
      await sleep(intervalMs);
    }
    throw new Error("waitFor timeout");
  };

  // xhs mounts under #app. If a future build relocates the root we'll see the
  // action fail loudly instead of paying for a full-DOM probe on every read.
  const getStore = (id: string): any => {
    const pinia = (document.querySelector("#app") as any)
      ?.__vue_app__?.config?.globalProperties?.$pinia;
    return pinia?._s?.get(id) ?? null;
  };

  // SPA-internal navigation. The throwaway `_=` defeats Vue Router's
  // same-URL no-op detection so the route handler always re-fires.
  const spaNavigate = (dest: string) => {
    const url = dest.startsWith("http") ? dest : ORIGIN + dest;
    const sep = url.includes("?") ? "&" : "?";
    history.pushState({}, "", url + sep + "_=" + Date.now());
    window.dispatchEvent(new PopStateEvent("popstate"));
  };

  const pageProblem = () => {
    if (location.pathname === "/404") return "not found";
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

  action("getSignInUrl",  { async invoke() { return { url: `${ORIGIN}/login`   }; } });

  action("getSignInState", {
    async invoke() {
      try {
        const response = await fetch(`${ORIGIN}/notification`, {
          method: "HEAD",
          credentials: "include",
          redirect: "follow",
          cache: "no-store",
        });
        const url = new URL(response.url);
        const signedOut = response.redirected && url.origin === ORIGIN && url.pathname === "/login";
        const signedIn = !response.redirected && url.origin === ORIGIN && url.pathname === "/notification";
        log(`getSignInState: status=${response.status} redirected=${response.redirected} path=${url.pathname}`);
        if (!signedIn && !signedOut) throw new Error("unexpected authentication response");
        return { signedIn };
      } catch (e: any) {
        log("getSignInState: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  const buildFeedItem = (entry: any) => {
    const card = entry?.noteCard || {};
    const id = entry?.id;
    if (!id) return null;
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
    async invoke({ limit = 20 } = {} as any) {
      try {
        if (!/^\/explore/.test(location.pathname)) spaNavigate("/explore");
        const feeds: any[] = await waitFor(() => {
          const arr = getStore("feed")?.feeds;
          return Array.isArray(arr) && arr.length > 0 ? arr : null;
        });
        const items: any[] = [];
        const seen = new Set<string>();
        for (const entry of feeds) {
          if (items.length >= limit) break;
          const item = buildFeedItem(entry);
          if (!item || seen.has(item.id)) continue;
          seen.add(item.id);
          items.push(item);
        }
        if (items.length === 0) throw new Error("feed store yielded no items");
        return { items, nextCursor: null };
      } catch (e: any) {
        log("listFeed: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  // Scroll a container (or window) to its bottom and wait for new rows via a
  // MutationObserver. Stops at the target, or after two consecutive plateaus,
  // or after maxRounds.
  const scrollUntil = async ({
    container,
    countRows,
    target,
    maxRounds = 12,
  }: {
    container: HTMLElement | null;
    countRows: () => number;
    target: number;
    maxRounds?: number;
  }) => {
    const scroller = container ?? document.scrollingElement ?? document.documentElement;
    let last = countRows();
    if (last >= target) return last;
    let plateau = 0;
    for (let i = 0; i < maxRounds; i++) {
      const prevHeight = scroller.scrollHeight;
      if (container) container.scrollTop = container.scrollHeight;
      else window.scrollTo(0, document.body.scrollHeight);
      await new Promise<void>((resolve) => {
        let to: any;
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
      if (next >= target) return next;
      if (next === last) {
        if (++plateau >= 2) return next;
      } else {
        plateau = 0;
        last = next;
      }
    }
    return countRows();
  };

  const collectSearchNotes = (): HTMLElement[] => {
    const sections = new Set(
      Array.from(document.querySelectorAll("section.note-item")) as HTMLElement[],
    );
    for (const a of document.querySelectorAll(
      'a[href*="/search_result/"], a[href*="/explore/"]',
    )) {
      const s = (a as HTMLElement).closest("section");
      if (s) sections.add(s as HTMLElement);
    }
    return Array.from(sections);
  };

  const isVisible = (el: HTMLElement) => {
    if (el.classList.contains("query-note-item")) return false;
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el);
    return cs.display !== "none" && cs.visibility !== "hidden";
  };

  const visibleSearchCount = () => collectSearchNotes().filter(isVisible).length;

  const normalizeHref = (href: string | null | undefined) => {
    if (!href) return "";
    if (/^https?:\/\//.test(href)) return href;
    if (href.startsWith("/")) return ORIGIN + href;
    return "";
  };

  // A rendered note card (search results, a profile's note grid). xhs renders
  // ~4 anchors per card: the bare `/explore/<id>` one has no query string; the
  // cover/title anchors carry `xsec_token`. Pick whichever anchor has the token,
  // since downstream getNote requires it. On a profile the cover anchor is
  // `/user/profile/<uid>/<noteid>?xsec_token=` — noteIdOf handles that shape too.
  const noteIdHrefRe =
    /\/(?:explore|search_result|discovery\/item)\/[a-f0-9]{24}|\/user\/profile\/[^/?#]+\/[a-f0-9]{24}/i;
  const noteCardFromSection = (el: HTMLElement) => {
    const candidates = el.querySelectorAll(
      'a.cover.mask, a.title, a[href*="/search_result/"], a[href*="/explore/"], a[href*="/user/profile/"]',
    ) as NodeListOf<HTMLAnchorElement>;
    let detail: HTMLAnchorElement | null = null;
    for (const a of candidates) {
      const href = a.getAttribute("href") || "";
      if (!noteIdHrefRe.test(href)) continue;
      if (/[?&]xsec_token=/.test(href)) { detail = a; break; }
      if (!detail) detail = a;
    }
    const url = normalizeHref(detail?.getAttribute("href") || "");
    if (!url) return null;

    const titleEl = el.querySelector(".title, .note-title, a.title, .footer .title span");
    let title = cleanText(titleEl?.textContent);
    if (!title) title = cleanText(detail?.querySelector("span")?.textContent);

    const nameEl = el.querySelector("a.author .name, .author-name, .nick-name, .name");
    const authorLink = el.querySelector(
      'a.author, a[href*="/user/profile/"]:not(.cover)',
    ) as HTMLAnchorElement | null;
    const likesEl = el.querySelector(".count, .like-count, .like-wrapper .count");
    const coverImg = el.querySelector("a.cover img, .cover img, img") as HTMLImageElement | null;

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

  const collectNoteCards = (limit: number) => {
    const items: any[] = [];
    const seen = new Set<string>();
    for (const el of collectSearchNotes()) {
      if (items.length >= limit) break;
      if (!isVisible(el)) continue;
      const item = noteCardFromSection(el);
      if (!item || seen.has(item.url)) continue;
      seen.add(item.url);
      items.push(item);
    }
    return items;
  };

  const waitForRender = (pred: () => boolean, timeoutMs = 6000) =>
    new Promise<boolean>((resolve) => {
      if (pred()) { resolve(true); return; }
      const ob = new MutationObserver(() => { if (pred()) { ob.disconnect(); resolve(true); } });
      ob.observe(document.body, { childList: true, subtree: true });
      setTimeout(() => { ob.disconnect(); resolve(pred()); }, timeoutMs);
    });

  const searchQuery = () => {
    let value = new URL(location.href).searchParams.get("keyword") || "";
    for (let i = 0; i < 2; i++) {
      try {
        const decoded = decodeURIComponent(value);
        if (decoded === value) break;
        value = decoded;
      } catch {
        break;
      }
    }
    return value;
  };

  const searchChannelTab = (label: string) =>
    Array.from(document.querySelectorAll(".channel, [class*='channel']")).find(
      (channel) => channel.textContent?.trim() === label,
    ) as HTMLElement | undefined;

  const noteChannelTab = () => searchChannelTab("笔记");
  const userChannelTab = () =>
    searchChannelTab("用户");

  const noteSignature = () =>
    collectNoteCards(10).map((item) => item.url).join("\n");

  let searchQueue = Promise.resolve();
  const serializeSearch = <T>(operation: () => Promise<T>) => {
    const result = searchQueue.then(operation, operation);
    searchQueue = result.then(() => undefined, () => undefined);
    return result;
  };

  const openNoteSearch = async (query: string) => {
    const alreadyLoaded = location.pathname === "/search_result_ai" && searchQuery() === query;
    if (alreadyLoaded) {
      if (visibleSearchCount() === 0) noteChannelTab()?.click();
      const rendered = await waitForRender(() => visibleSearchCount() > 0);
      if (!rendered) throw new Error(`search results never rendered: ${pageContext()}`);
      return;
    }

    const previousFirst = collectSearchNotes()[0] ?? null;
    const previousSignature = noteSignature();
    const keyword = encodeURIComponent(encodeURIComponent(query));
    spaNavigate(`/search_result_ai?keyword=${keyword}&source=web_explore_feed`);
    const rendered = await waitForRender(() => {
      const rows = collectSearchNotes().filter(isVisible);
      if (searchQuery() !== query || rows.length === 0) return false;
      return rows[0] !== previousFirst || noteSignature() !== previousSignature;
    });
    if (!rendered) throw new Error(`search results never rendered: ${pageContext()}`);
  };

  action("searchNotes", {
    invoke({ query, limit = 20 } = {} as any) {
      return serializeSearch(async () => {
        try {
          if (!query) throw new Error("searchNotes requires a query");
          await openNoteSearch(String(query));
          if (visibleSearchCount() < limit) {
            await scrollUntil({ container: null, countRows: visibleSearchCount, target: limit });
          }
          return { items: collectNoteCards(limit), nextCursor: null };
        } catch (e: any) {
          log("searchNotes: " + (e?.message ?? String(e)));
          throw e;
        }
      });
    },
  });

  action("searchUsers", {
    invoke({ query, limit = 20 } = {} as any) {
      return serializeSearch(async () => {
        try {
          if (!query) throw new Error("searchUsers requires a query");
          await openNoteSearch(String(query));
          const tab = await waitFor(userChannelTab, { timeoutMs: 6000 }).catch(() => null);
          if (!tab) throw new Error(`search tabs never rendered: ${pageContext()}`);
          tab.click();

          const userCards = () =>
            Array.from(document.querySelectorAll(".user-list-item"))
              .filter((item) => isVisible(item as HTMLElement));
          const countUsers = () => userCards().length;
          const rendered = await waitForRender(() => countUsers() > 0);
          if (!rendered) {
            if (xhsErrored()) throw new Error(pageContext());
            return { items: [], nextCursor: null };
          }
          if (countUsers() < limit) {
            await scrollUntil({ container: null, countRows: countUsers, target: limit });
          }

          const items: any[] = [];
          const seen = new Set<string>();
          for (const card of userCards()) {
            if (items.length >= limit) break;
            const a = card.querySelector('a[href*="/user/profile/"]') as HTMLAnchorElement | null;
            const url = normalizeHref(a?.getAttribute("href") || "");
            const uid = userIdOf(url);
            if (!uid || seen.has(uid)) continue;
            seen.add(uid);
            const img = card.querySelector("img#user-image, .user-image") as HTMLImageElement | null;
            const descText = Array.from(card.querySelectorAll(".user-desc, .user-desc-box"))
              .map((e) => cleanText(e.textContent)).join(" ");
            items.push({
              userId: uid,
              nickname: cleanText(card.querySelector(".user-name")?.textContent),
              redId: (descText.match(/红书号[:：]\s*(\S+)/) || ["", ""])[1]!,
              fans: (descText.match(/粉丝[・·:：\s]*([\d.]+\s*[万千亿]?)/) || ["", ""])[1]!.replace(/\s+/g, ""),
              avatar: img?.currentSrc || img?.src || "",
              url: `${ORIGIN}/user/profile/${uid}`,
            });
          }
          return { items, nextCursor: null };
        } catch (e: any) {
          log("searchUsers: " + (e?.message ?? String(e)));
          throw e;
        }
      });
    },
  });

  const userIdOf = (input: string) => {
    const s = String(input || "");
    const m = s.match(/\/user\/profile\/([0-9a-f]{24})/i) || s.match(/^\s*([0-9a-f]{24})\s*$/i);
    return m ? m[1]! : "";
  };

  const onProfile = (uid: string) =>
    new RegExp(`/user/profile/${uid}(?:[/?#]|$)`).test(location.pathname);

  // Navigate to a profile and wait for *its* data to land. The user store keeps
  // the previously-viewed profile's basicInfo/notes until the next fetch
  // resolves, and nothing in the payload carries the uid — so when we actually
  // navigate we null those fields first and gate on basicInfo repopulating,
  // otherwise a back-to-back call reads the prior profile.
  const goToProfile = async (uid: string) => {
    if (!onProfile(uid)) {
      const u = getStore("user");
      if (u) {
        if (u.userPageData) u.userPageData.basicInfo = null;
        u.notes = [];
      }
      spaNavigate(`/user/profile/${uid}`);
    }
    try {
      return await waitFor(() => {
        if (xhsErrored()) throw new Error(pageContext());
        const upd = getStore("user")?.userPageData;
        return upd?.basicInfo?.nickname ? upd : null;
      }, { timeoutMs: 8000 });
    } catch (e: any) {
      // Fail fast with a useful message instead of letting the caller's later
      // waits compound toward the 30s debug-WS timeout.
      if (/waitFor timeout/.test(String(e?.message))) {
        throw new Error(`profile did not load: ${pageContext()}`);
      }
      throw e;
    }
  };

  action("listUserNotes", {
    async invoke({ url, limit = 20 } = {} as any) {
      try {
        const uid = userIdOf(String(url));
        if (!uid) throw new Error(`unrecognised profile url or id: ${url}`);
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
        try { await waitFor(() => notesOf().length > 0, { timeoutMs: 6000 }); } catch {}
        let plateau = 0;
        const deadline = Date.now() + 8000;
        while (notesOf().length < limit && Date.now() < deadline) {
          const before = notesOf().length;
          window.scrollTo(0, document.body.scrollHeight);
          await sleep(700);
          if (notesOf().length === before) { if (++plateau >= 3) break; }
          else plateau = 0;
        }
        const items: any[] = [];
        const seen = new Set<string>();
        for (const entry of notesOf()) {
          if (items.length >= limit) break;
          const item = buildFeedItem(entry);
          if (!item || seen.has(item.id)) continue;
          seen.add(item.id);
          items.push(item);
        }
        return { items, nextCursor: null };
      } catch (e: any) {
        log("listUserNotes: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  action("getUserProfile", {
    async invoke({ url } = {} as any) {
      try {
        const uid = userIdOf(String(url));
        if (!uid) throw new Error(`unrecognised profile url or id: ${url}`);
        const data: any = await goToProfile(uid);
        const info = data.basicInfo || {};
        const stat: Record<string, string> = {};
        for (const it of (data.interactions || []) as any[]) {
          if (it?.type) stat[it.type] = numText(it.count);
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
      } catch (e: any) {
        log("getUserProfile: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  // Trending/suggested queries ride the search store's queryTrendingInfo, which
  // the explore search box populates. No dedicated navigation if it's already
  // loaded; otherwise nudge /explore and wait for it.
  action("listTrending", {
    async invoke({ limit = 10 } = {} as any) {
      try {
        const read = (): any[] | null => {
          const s = getStore("search");
          const q = s?.queryTrendingInfo?.queries;
          const arr = Array.isArray(q) && q.length ? q : s?.suggestions;
          return Array.isArray(arr) && arr.length ? arr : null;
        };
        let arr = read();
        if (!arr) {
          if (!/^\/explore/.test(location.pathname)) spaNavigate("/explore");
          arr = await waitFor(read, { timeoutMs: 6000 });
        }
        const items: any[] = [];
        const seen = new Set<string>();
        for (const q of arr) {
          if (items.length >= limit) break;
          const query = cleanText(q?.text || q?.searchWord || q?.title);
          if (!query || seen.has(query)) continue;
          seen.add(query);
          items.push({ query });
        }
        return { items };
      } catch (e: any) {
        log("listTrending: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  // xhs's note APIs are gated by an xsec_token. Without it the SPA falls
  // through to /404 (error_code=300031) before any signed POST fires, so the
  // only useful failure mode is to reject the input up front. Pass the full
  // URL from listFeed/listSearchResults/listComments output — those carry the
  // token in the query string.
  const goToNote = (rawUrl: string) => {
    if (!rawUrl) throw new Error("note url is required");
    const id = noteIdOf(rawUrl);
    if (!id) throw new Error(`unrecognised note url: ${rawUrl}`);
    let token = "";
    try { token = new URL(rawUrl, ORIGIN).searchParams.get("xsec_token")?.trim() ?? ""; } catch {}
    if (!token) throw new Error(`note url missing xsec_token: ${rawUrl}`);
    if (!location.pathname.includes(id)) spaNavigate(rawUrl);
    return id;
  };

  const waitForNoteDom = async (timeoutMs = 10000) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (document.querySelector("#detail-title, .interact-container")) return;
      if (xhsErrored()) throw new Error(pageContext());
      await sleep(120);
    }
    throw new Error(`note page did not render: ${pageContext()}`);
  };

  // Title/body/counts come from the DOM — opencli's note.js proves this is
  // the stable signal for note details.
  action("getNote", {
    async invoke({ url } = {} as any) {
      try {
        const id = goToNote(String(url));
        await waitForNoteDom();
        const title = cleanText(document.querySelector("#detail-title, .title")?.textContent);
        const desc  = cleanText(document.querySelector("#detail-desc, .desc, .note-text")?.textContent);
        const author = cleanText(document.querySelector(".username, .author-wrapper .name")?.textContent);
        // Scope counts to the note's engagement bar (`.engage-bar`, older builds
        // `.interact-container`) so we don't pick up a comment's counters
        // (`.like-wrapper .count` also matches every comment row). The bar's
        // counts hydrate a beat after the title, so wait for the like count to
        // carry a digit (a genuine 0-like note just falls through after timeout).
        const barOf = () => document.querySelector(".engage-bar, .interact-container");
        const bar = await waitFor(() => {
          const b = barOf();
          return b && /\d/.test(b.querySelector(".like-wrapper .count")?.textContent || "") ? b : null;
        }, { timeoutMs: 4000 }).catch(() => barOf());
        const countAt = (sel: string) => {
          const s = cleanText(bar?.querySelector(sel)?.textContent);
          return /^\d/.test(s) ? s : "0";
        };
        const tags: string[] = [];
        document.querySelectorAll(
          '#detail-desc a.tag, #detail-desc a[href*="search_result"]',
        ).forEach((el) => {
          const t = cleanText(el.textContent);
          if (t) tags.push(t);
        });
        if (!title && !author) throw new Error("note page rendered without title or author");
        return {
          id,
          title,
          author,
          authorUrl: "",
          content: desc,
          likes:    countAt(".like-wrapper .count"),
          collects: countAt(".collect-wrapper .count"),
          comments: countAt(".chat-wrapper .count"),
          tags,
          cover: "",
          url: String(url),
        };
      } catch (e: any) {
        log("getNote: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  // Media is the one place the store beats DOM: imageList preserves carousel
  // order, and video.media.stream exposes per-codec master URLs the DOM lacks.
  action("getNoteMedia", {
    async invoke({ url } = {} as any) {
      try {
        const id = goToNote(String(url));
        const note: any = await waitFor(() => {
          if (xhsErrored()) throw new Error(pageContext());
          const entry = getStore("note")?.noteDetailMap?.[id];
          const n = entry?.note || entry;
          return n && typeof n === "object" ? n : null;
        });
        const items: { type: "image" | "video"; url: string }[] = [];
        const seen = new Set<string>();
        const push = (type: "image" | "video", u: string | undefined | null) => {
          const v = (u || "").trim();
          if (!v || seen.has(v)) return;
          seen.add(v);
          items.push({ type, url: v });
        };
        for (const img of (note.imageList || []) as any[]) {
          push("image", img?.urlDefault || img?.urlPre || img?.url);
        }
        const streams = note.video?.media?.stream;
        if (streams && typeof streams === "object") {
          for (const codec of Object.values(streams as Record<string, any[]>)) {
            if (!Array.isArray(codec)) continue;
            for (const s of codec) push("video", s?.masterUrl);
          }
        }
        if (items.length === 0) throw new Error(`no media on ${url}`);
        return {
          id: note.noteId || id,
          title: cleanText(note.title),
          author: cleanText(note.user?.nickname || note.user?.nickName),
          items,
        };
      } catch (e: any) {
        log("getNoteMedia: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  // Parses xhs like-count text: "1,234", "1.2w" (10k), "2.5万", "123+".
  const parseLikeText = (raw: any): number => {
    const s = String(raw ?? "").replace(/\s+/g, "");
    if (!s) return 0;
    const integerRe = /^(?:\d+|\d{1,3}(?:[,，]\d{3})+)\+?$/u;
    const shortRe = /^((?:\d+|\d{1,3}(?:[,，]\d{3})+)(?:\.\d+)?)([wWkK万千])\+?$/u;
    if (integerRe.test(s)) return Number(s.replace(/[,+，]/g, "")) || 0;
    const m = s.match(shortRe);
    if (!m) return 0;
    const n = Number(m[1]!.replace(/[,，]/g, ""));
    if (!Number.isFinite(n)) return 0;
    const unit = m[2]!.toLowerCase();
    const mul = unit === "w" || unit === "万" ? 10000 : 1000;
    return Math.round(n * mul);
  };

  action("listComments", {
    async invoke({ url, limit = 20 } = {} as any) {
      try {
        if (!url) throw new Error("listComments requires a note url");
        goToNote(String(url));
        await waitForNoteDom();

        // Comments lazy-load into an inner overflow container; window-level
        // scrolling does nothing on a note page.
        const scroller =
          (document.querySelector(".note-scroller") as HTMLElement | null) ||
          (document.querySelector(".container") as HTMLElement | null);
        const countParents = () => document.querySelectorAll(".parent-comment").length;
        await scrollUntil({ container: scroller, countRows: countParents, target: limit });

        const items: any[] = [];
        for (const p of document.querySelectorAll(".parent-comment")) {
          if (items.length >= limit) break;
          const item = p.querySelector(".comment-item");
          if (!item) continue;
          const author = cleanText(
            item.querySelector(".author-wrapper .name, .user-name")?.textContent,
          );
          const text = cleanText(item.querySelector(".content, .note-text")?.textContent);
          if (!text) continue;
          const likes = parseLikeText(item.querySelector(".count")?.textContent);
          const time = cleanText(item.querySelector(".date, .time")?.textContent);
          items.push({ author, text, likes, time, isReply: false, replyTo: "" });

          for (const sub of p.querySelectorAll(
            ".reply-container .comment-item-sub, .sub-comment-list .comment-item",
          )) {
            if (items.length >= limit) break;
            const sAuthor = cleanText(sub.querySelector(".name, .user-name")?.textContent);
            const sText = cleanText(sub.querySelector(".content, .note-text")?.textContent);
            if (!sText) continue;
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
      } catch (e: any) {
        log("listComments: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });
};

export default install;
