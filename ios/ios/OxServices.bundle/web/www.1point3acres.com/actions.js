(() => {
  // services/builtin/web/www.1point3acres.com/actions.ts
  var API = "https://api.1point3acres.com";
  var TRPC = "https://trpc.1point3acres.com/trpc";
  var BBS = "https://www.1point3acres.com/bbs";
  var install = ({ action, retryFetch, log }) => {
    const trpc = async (proc, json) => {
      const input = { "0": { json, meta: { values: { fids: ["undefined"] } } } };
      const url = `${TRPC}/${proc}?batch=1&input=${encodeURIComponent(JSON.stringify(input))}`;
      const res = await retryFetch(url, {
        credentials: "include",
        headers: { "x-trpc-source": "web", referer: "https://www.1point3acres.com/" }
      });
      if (!res.ok)
        throw new Error(`${proc}: HTTP ${res.status}`);
      const body = await res.json();
      const err = body?.[0]?.error;
      if (err)
        throw new Error(`${proc}: ${err?.json?.message ?? "trpc error"}`);
      return body?.[0]?.result?.data?.json ?? null;
    };
    const apiJson = async (path) => {
      const res = await retryFetch(`${API}${path}`, {
        credentials: "include",
        headers: { referer: "https://visa.1point3acres.com/" }
      });
      if (!res.ok)
        throw new Error(`HTTP ${res.status} for ${path}`);
      return res.json();
    };
    const me = () => trpc("user.me", null);
    const threadFromApi = (t) => ({
      tid: String(t.tid),
      subject: t.subject ?? "",
      summary: t.summary ?? "",
      author: t.author ?? "",
      forum: t.forum_name ?? "",
      fid: t.fid ?? null,
      threadType: t.thread_type ?? "",
      replies: t.replies ?? 0,
      views: t.views ?? 0,
      dateline: t.dateline ?? 0,
      lastpost: t.lastpost ?? 0,
      url: `${BBS}/thread-${t.tid}-1-1.html`
    });
    const threadFromSearch = (t) => ({
      tid: String(t.tid),
      subject: t.subject ?? "",
      summary: t.message ?? "",
      author: t.author ?? "",
      forum: t.forumName ?? "",
      fid: t.fid ?? null,
      threadType: "",
      replies: t.replies ?? 0,
      views: t.views ?? 0,
      dateline: t.dateline ?? 0,
      lastpost: t.dateline ?? 0,
      url: `${BBS}/thread-${t.tid}-1-1.html`
    });
    action("getSignInUrl", {
      async invoke() {
        return { url: "https://auth.1point3acres.com/login" };
      }
    });
    action("getSignInState", {
      async invoke() {
        return { signedIn: !!(await me())?.uid };
      }
    });
    action("getCurrentUser", {
      async invoke() {
        const u = await me();
        if (!u?.uid)
          throw new Error("getCurrentUser: requires sign-in");
        return {
          uid: String(u.uid),
          username: u.username ?? "",
          group: u.grouptitle ?? "",
          credits: u.credits ?? 0,
          points: u.user_count?.extcredits1 ?? 0,
          isVip: !!u.isVip
        };
      }
    });
    action("searchThreads", {
      async invoke({ query, type = "keywords", days = 365, cursor, limit = 20 } = {}) {
        if (!query)
          throw new Error("searchThreads: query is required");
        const offset = cursor ? parseInt(cursor, 10) || 0 : undefined;
        const json = { query, type, days, fids: null, direction: "forward" };
        if (offset)
          json.cursor = offset;
        const data = await trpc("search.search", json);
        const items = (data?.data ?? []).slice(0, limit).map(threadFromSearch);
        const next = data?.cursor;
        const nextCursor = items.length >= limit && next != null ? String(next) : null;
        return { items, nextCursor };
      }
    });
    action("listThreads", {
      async invoke({ fid, typeid, cursor, limit = 20 } = {}) {
        if (!fid)
          throw new Error("listThreads: fid is required");
        const pg = cursor ? Math.max(1, parseInt(cursor, 10) || 1) : 1;
        const q = new URLSearchParams({
          ps: String(limit),
          pg: String(pg),
          with_total: "1",
          includes: "summary,options",
          order: "time_desc"
        });
        if (typeid != null)
          q.set("typeid", String(typeid));
        const body = await apiJson(`/api/forums/${encodeURIComponent(fid)}/threads?${q}`);
        if (body?.errno && body.errno !== 0)
          throw new Error(body.msg || "api error");
        const items = (body?.threads ?? []).map(threadFromApi);
        const nextCursor = items.length >= limit ? String(pg + 1) : null;
        return { items, nextCursor };
      }
    });
    action("getThread", {
      async invoke({ tid, page = 1 }) {
        if (!tid)
          throw new Error("getThread: tid is required");
        const res = await retryFetch(`${BBS}/thread-${encodeURIComponent(tid)}-${page}-1.html`, {
          credentials: "include"
        });
        if (!res.ok)
          throw new Error(`getThread: HTTP ${res.status}`);
        const html = new TextDecoder("gbk").decode(await res.arrayBuffer());
        const doc = new DOMParser().parseFromString(html, "text/html");
        const subject = doc.querySelector("#thread_subject")?.textContent?.trim() ?? "";
        const posts = [...doc.querySelectorAll("[id^='postmessage_']")].map((msg) => {
          const pid = msg.id.replace("postmessage_", "");
          const author = doc.querySelector(`#favatar${pid} .pi`)?.innerText?.trim() ?? "";
          const dateEl = doc.querySelector(`#authorposton${pid} span[title], #authorposton${pid}`);
          const date = dateEl?.getAttribute("title") || dateEl?.innerText?.trim() || "";
          return { pid, author, date, content: msg.innerText.trim() };
        });
        const pages = [...doc.querySelectorAll(".pg a.last, .pgt a.last")].map((a) => parseInt((a.innerText.match(/\d+/) ?? ["0"])[0], 10)).reduce((a, b) => Math.max(a, b), page);
        const nextCursor = page < pages ? String(page + 1) : null;
        return { tid: String(tid), subject, page, posts, nextCursor };
      }
    });
    action("getVisaBulletin", {
      async invoke() {
        const body = await apiJson(`/visa_tracker/greencard/visa_bulletin`);
        const d = body?.data ?? {};
        const region = (it, p) => ({
          actionDate: it[`${p}_action_date`] ?? null,
          filingDate: it[`${p}_filing_date`] ?? null
        });
        const items = (d.items ?? []).map((it) => ({
          category: it.category,
          china: region(it, "cn"),
          india: region(it, "ind"),
          mexico: region(it, "mex"),
          philippines: region(it, "phl"),
          vietnam: region(it, "vnm"),
          restOfWorld: region(it, "row")
        }));
        return { currentMonth: d.current_month ?? "", prevMonth: d.prev_month ?? "", items };
      }
    });
    action("getH1bRankings", {
      async invoke({ by = "companies", rankBy = "fillings" } = {}) {
        const path = { companies: "top-companies", cities: "top-cities", jobs: "top-jobs" }[by];
        if (!path)
          throw new Error(`getH1bRankings: unknown by '${by}'`);
        const body = await apiJson(`/visa_tracker/h1b/${path}?rank_by=${encodeURIComponent(rankBy)}`);
        const items = (body?.data ?? []).map((r) => ({
          name: r.key,
          count: r.doc_count ?? 0,
          avgSalary: r.avg_salary ?? 0
        }));
        return { by, rankBy, items };
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

  installService("www.1point3acres.com", actions_default);
})();
