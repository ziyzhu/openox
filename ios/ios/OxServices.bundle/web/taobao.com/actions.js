(() => {
  // services/action-lib.ts
  function cookie(name) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = document.cookie.match(new RegExp(`(?:^|;\\s*)${escaped}=([^;]*)`));
    if (!match)
      return null;
    try {
      return decodeURIComponent(match[1]);
    } catch {
      return match[1];
    }
  }

  // services/builtin/web/taobao.com/actions.ts
  var install = ({ action, log }) => {
    const ORIGIN = "https://www.taobao.com";
    const cleanText = (v) => String(v ?? "").replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
    const httpsUrl = (u) => {
      const s = String(u ?? "").trim();
      if (!s)
        return "";
      if (s.startsWith("//"))
        return "https:" + s;
      return s.replace(/^http:\/\//, "https://");
    };
    const mtop = async (api, v, data, method = "request") => {
      const sdk = window.lib?.mtop;
      if (!sdk?.[method])
        throw new Error(`taobao mtop SDK unavailable on ${location.href}`);
      let r;
      try {
        r = await sdk[method]({ api, v, data, dataType: "json", type: "GET" });
      } catch (rej) {
        throw new Error(`mtop ${api}: ${rej?.ret?.[0] ?? rej?.message ?? JSON.stringify(rej)}`);
      }
      const ret = String(r?.ret?.[0] ?? "");
      if (!/^SUCCESS/i.test(ret))
        throw new Error(`mtop ${api}: ${ret || "no ret"}`);
      return r?.data ?? {};
    };
    action("getSignInUrl", { async invoke() {
      return { url: "https://login.taobao.com" };
    } });
    action("getSignInState", {
      async invoke() {
        try {
          return { signedIn: !!cookie("unb") || !!cookie("tracknick") };
        } catch (e) {
          log("getSignInState: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    const searchData = (query, page) => ({
      appId: "34385",
      params: JSON.stringify({
        schemaType: "auction",
        isEnterSrpSearch: "true",
        searchDoorFrom: "srp",
        search_action: "initiative",
        sversion: "13.6",
        style: "list",
        m: "pc",
        page,
        n: 48,
        q: query,
        qSource: "url",
        tab: "all",
        pageSize: 48,
        sort: "_coefp"
      })
    });
    const mapItem = (it) => {
      const id = String(it?.item_id ?? "");
      if (!id)
        return null;
      return {
        id,
        title: cleanText(it.title),
        price: cleanText(it.priceShow?.price ?? it.price),
        originalPrice: cleanText(it.price),
        sales: cleanText(it.realSales),
        shop: cleanText(it.nick),
        location: cleanText(it.procity),
        image: httpsUrl(it.pic_path),
        url: `https://item.taobao.com/item.htm?id=${id}`
      };
    };
    action("searchItems", {
      async invoke({ query, cursor, limit = 20 } = {}) {
        try {
          if (!query)
            throw new Error("searchItems requires a query");
          const page = cursor ? parseInt(cursor, 10) || 1 : 1;
          const data = await mtop("mtop.relationrecommend.wirelessrecommend.recommend", "2.0", searchData(String(query), page));
          const arr = Array.isArray(data.itemsArray) ? data.itemsArray : [];
          const items = arr.map(mapItem).filter(Boolean).slice(0, limit);
          if (items.length === 0)
            throw new Error(`search yielded no items for "${query}"`);
          const totalPage = parseInt(data.mainInfo?.totalPage ?? "0", 10);
          const nextCursor = !totalPage || page < totalPage ? String(page + 1) : null;
          return { items, nextCursor };
        } catch (e) {
          log("searchItems: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    const itemIdOf = (input) => {
      const m = String(input || "").match(/[?&]id=(\d+)/) || String(input || "").match(/(\d{8,})/);
      return m ? m[1] : "";
    };
    action("getItem", {
      async invoke({ id } = {}) {
        try {
          const itemId = itemIdOf(String(id));
          if (!itemId)
            throw new Error(`unrecognised item id or url: ${id}`);
          const data = await mtop("mtop.taobao.detail.getdetail", "6.0", { itemNumId: itemId, exParams: JSON.stringify({ id: itemId }) }, "antiCreepRequest");
          const it = data.item || {};
          let price = "";
          try {
            price = JSON.parse(data.apiStack?.[0]?.value ?? "{}")?.price?.price?.priceText ?? "";
          } catch {}
          return {
            id: String(it.itemId ?? itemId),
            title: cleanText(it.title),
            price: cleanText(price),
            favorites: String(it.favcount ?? ""),
            comments: String(it.commentCount ?? ""),
            skuText: cleanText(it.skuText),
            images: (it.images || []).map(httpsUrl).filter(Boolean),
            url: `https://item.taobao.com/item.htm?id=${itemId}`
          };
        } catch (e) {
          log("getItem: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("getMe", {
      async invoke() {
        try {
          const d = await mtop("mtop.user.getUserSimple", "1.0", {});
          return {
            userId: String(d.userNumId ?? ""),
            nick: cleanText(d.nick),
            displayNick: cleanText(d.displayNick)
          };
        } catch (e) {
          log("getMe: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("getCartCount", {
      async invoke() {
        try {
          const d = await mtop("mtop.trade.queryBagCount", "1.0", { cartFrom: "main_site", extStatus: 0, netType: 0 });
          return { count: parseInt(String(d.count ?? "0"), 10) || 0 };
        } catch (e) {
          log("getCartCount: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("isFavorited", {
      async invoke({ id } = {}) {
        try {
          const itemId = itemIdOf(String(id));
          if (!itemId)
            throw new Error(`unrecognised item id or url: ${id}`);
          const d = await mtop("mtop.taobao.mercury.checkCollect", "1.0", { ids: JSON.stringify([itemId]), type: "1" });
          return { id: itemId, favorited: !!d.result?.[itemId] };
        } catch (e) {
          log("isFavorited: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    const mapQuestion = (q) => ({
      question: cleanText(q.questionTitle),
      answerCount: parseInt(String(q.answerCount ?? "0"), 10) || 0,
      answers: (q.topAnswerList || []).map((a) => ({ text: cleanText(a.answerTitle), date: cleanText(a.gmtCreateStr) })).filter((a) => a.text)
    });
    action("listItemQuestions", {
      async invoke({ id, cursor, limit = 10 } = {}) {
        try {
          const itemId = itemIdOf(String(id));
          if (!itemId)
            throw new Error(`unrecognised item id or url: ${id}`);
          const page = cursor ? parseInt(cursor, 10) || 1 : 1;
          const d = await mtop("mtop.taobao.wdj.list.merge.search", "1.0", {
            itemId,
            page,
            pageSize: Math.min(limit, 20),
            type: "mix_group",
            tagId: "",
            extraInfo: JSON.stringify({ searchText: "" }),
            ecode: 0,
            biz: "pc"
          }, "antiCreepRequest");
          const items = (d.questionList || []).map(mapQuestion).slice(0, limit);
          const nextCursor = d.hasNext ? String(page + 1) : null;
          return { items, nextCursor };
        } catch (e) {
          log("listItemQuestions: " + (e?.message ?? String(e)));
          throw e;
        }
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

  installService("taobao.com", actions_default);
})();
