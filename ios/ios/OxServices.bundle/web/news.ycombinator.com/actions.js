(() => {
  // services/action-lib.ts
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/news.ycombinator.com/actions.ts
  var install = ({ action, retryFetch }) => {
    const fetchDoc = async (path) => {
      const html = await (await retryFetch(path, { credentials: "include" })).text();
      return new DOMParser().parseFromString(html, "text/html");
    };
    const FEED_PATHS = {
      top: "/news",
      new: "/newest",
      best: "/best",
      ask: "/ask",
      show: "/show",
      jobs: "/jobs",
      front: "/front"
    };
    const parseRow = (row) => {
      const id = row.id;
      const titleEl = row.querySelector(".titleline a");
      const sitebit = row.querySelector(".sitestr");
      const sub = row.nextElementSibling?.querySelector(".subtext");
      const score = parseInt(sub?.querySelector(".score")?.innerText ?? "0", 10) || 0;
      const author = sub?.querySelector(".hnuser")?.innerText ?? "";
      const age = sub?.querySelector(".age")?.innerText ?? "";
      const links = [...sub?.querySelectorAll("a") ?? []];
      const cmtsEl = links.find((a) => /comment|discuss/i.test(a.innerText));
      const comments = parseInt((cmtsEl?.innerText ?? "").replace(/\D/g, ""), 10) || 0;
      const hidden = !!links.find((a) => /^un-?hide$/i.test(a.innerText));
      const url = titleEl?.href ?? "";
      const domain = sitebit?.innerText ?? "";
      const externalUrl = url && domain ? url : null;
      return {
        id,
        title: titleEl?.innerText ?? "",
        url,
        externalUrl,
        domain,
        score,
        author,
        age,
        comments,
        hidden
      };
    };
    const parseComments = (root) => {
      return [...root.querySelectorAll("tr.athing.comtr")].map((row) => {
        const id = row.id;
        const indentTd = row.querySelector("td.ind");
        const indentAttr = indentTd?.getAttribute("indent");
        const imgWidth = indentTd?.querySelector("img")?.getAttribute("width");
        const level = indentAttr != null ? parseInt(indentAttr, 10) || 0 : Math.round((parseInt(imgWidth || "0", 10) || 0) / 40);
        const author = row.querySelector(".hnuser")?.innerText ?? "";
        const age = row.querySelector(".age")?.innerText ?? "";
        const text = row.querySelector(".commtext")?.innerText ?? "";
        return { id, author, level, age, text, parentId: null };
      }).map((c, i, arr) => {
        if (c.level === 0)
          return c;
        for (let j = i - 1;j >= 0; j--) {
          if (arr[j].level === c.level - 1) {
            c.parentId = arr[j].id;
            break;
          }
        }
        return c;
      });
    };
    const probeSignedIn = async () => {
      const doc = await fetchDoc("/news");
      return !!doc.querySelector("#me");
    };
    const storyFromRow = (row) => {
      const r = parseRow(row);
      return {
        id: r.id,
        title: r.title,
        url: r.url,
        externalUrl: r.externalUrl,
        domain: r.domain,
        score: r.score,
        author: r.author,
        age: r.age,
        comments: r.comments,
        hidden: false
      };
    };
    action("getSignInUrl", {
      async invoke() {
        return { url: "https://news.ycombinator.com/login" };
      }
    });
    action("getSignInState", {
      async invoke() {
        return { signedIn: await probeSignedIn() };
      }
    });
    action("getCurrentUser", {
      async invoke() {
        const doc = await fetchDoc("/news");
        const me = doc.querySelector("#me");
        const karmaEl = doc.querySelector("#karma");
        const user = me?.innerText?.trim();
        if (!user)
          throw new Error("getCurrentUser: requires sign-in");
        const karma = karmaEl ? parseInt(karmaEl.innerText, 10) : NaN;
        if (!Number.isFinite(karma))
          throw new Error("getCurrentUser: missing karma");
        return { user, karma };
      }
    });
    action("listStories", {
      async invoke({ feed = "top", limit = 30, cursor } = {}) {
        const path = FEED_PATHS[feed] ?? FEED_PATHS.top;
        const page = pageCursor(cursor, 1);
        const doc = await fetchDoc(`${path}${page > 1 ? `?p=${page}` : ""}`);
        const items = [...doc.querySelectorAll("tr.athing")].slice(0, limit).map(parseRow);
        const nextCursor = items.length === limit ? String(page + 1) : null;
        return { items, nextCursor };
      }
    });
    action("getStory", {
      async invoke({ id }) {
        const doc = await fetchDoc(`/item?id=${encodeURIComponent(id)}`);
        const row = doc.querySelector("tr.athing");
        if (!row)
          throw new Error(`getStory: no story found for id ${id}`);
        return storyFromRow(row);
      }
    });
    action("getPost", {
      async invoke({ id }) {
        const doc = await fetchDoc(`/item?id=${encodeURIComponent(id)}`);
        const row = doc.querySelector("tr.athing.submission") || doc.querySelector("tr.athing");
        if (!row)
          throw new Error(`getPost: no post found for id ${id}`);
        const story = parseRow(row);
        const comments = parseComments(doc);
        return { story, comments };
      }
    });
    action("createComment", {
      async invoke({ parentId, text }) {
        const doc = await fetchDoc("reply?id=" + parentId);
        const form = doc.querySelector("form[action='comment']");
        if (!form)
          return { ok: false };
        const body = new URLSearchParams;
        for (const input of form.querySelectorAll("input[type=hidden]")) {
          body.set(input.name, input.value);
        }
        body.set("text", text);
        const res = await fetch("comment", { method: "POST", credentials: "include", body });
        return { ok: res.ok };
      }
    });
    action("getUser", {
      async invoke({ username }) {
        const doc = await fetchDoc(`/user?id=${encodeURIComponent(username)}`);
        const findRow = (label) => {
          for (const tr of doc.querySelectorAll("tr")) {
            const td = tr.querySelector("td");
            if (td && td.innerText.trim().toLowerCase() === label) {
              return tr.querySelectorAll("td")[1];
            }
          }
          return null;
        };
        const userText = findRow("user:")?.innerText.trim() || username;
        const karmaText = findRow("karma:")?.innerText.trim() || "";
        const karma = parseInt(karmaText, 10);
        if (!Number.isFinite(karma))
          throw new Error(`getUser: no profile for ${username}`);
        const createdText = findRow("created:")?.innerText.trim() || "";
        const aboutEl = findRow("about:");
        return {
          username: userText,
          karma,
          created: createdText,
          about: aboutEl ? aboutEl.innerHTML.trim() : ""
        };
      }
    });
  };
  var actions_default = install;

  // services/action-runtime.ts
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

  installService("news.ycombinator.com", actions_default);
})();
