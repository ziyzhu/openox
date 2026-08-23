(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  // services/builtin/web/mp.weixin.qq.com/actions.ts
  var ARTICLE_PATH = /^\/s\/[A-Za-z0-9_-]+$/;
  var IMAGE_HOST = "mmbiz.qpic.cn";
  var BLOCK_TAGS = new Set([
    "address",
    "article",
    "aside",
    "blockquote",
    "div",
    "figcaption",
    "figure",
    "footer",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "li",
    "main",
    "ol",
    "p",
    "pre",
    "section",
    "table",
    "tbody",
    "td",
    "th",
    "thead",
    "tr",
    "ul"
  ]);
  var SKIPPED_TAGS = new Set(["button", "canvas", "noscript", "script", "style", "svg"]);
  var articleUrl = (value) => {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname !== "mp.weixin.qq.com" || !ARTICLE_PATH.test(url.pathname)) {
      throw new Error("getArticle requires a shared https://mp.weixin.qq.com/s/ article URL");
    }
    url.hash = "";
    return url;
  };
  var imageUrl = (element) => {
    const raw = element?.getAttribute("data-src") || element?.getAttribute("src") || element?.getAttribute("content") || "";
    if (!raw)
      return null;
    try {
      const url = new URL(raw, "https://mp.weixin.qq.com/");
      if (url.hostname !== IMAGE_HOST)
        return null;
      url.protocol = "https:";
      return url.href;
    } catch {
      return null;
    }
  };
  var positiveInteger = (...values) => {
    for (const value of values) {
      const number = Number.parseFloat(value ?? "");
      if (Number.isFinite(number) && number > 0)
        return Math.round(number);
    }
    return null;
  };
  var articleText = (root, indexes) => {
    const render = (node) => {
      if (node.nodeType === 3)
        return node.textContent ?? "";
      if (node.nodeType !== 1)
        return "";
      const element = node;
      const tag = element.tagName.toLowerCase();
      if (SKIPPED_TAGS.has(tag))
        return "";
      if (tag === "img") {
        const index = indexes.get(element);
        return index ? `

[Image ${index}]

` : "";
      }
      if (tag === "br")
        return `
`;
      const content = [...element.childNodes].map(render).join("");
      if (tag === "li")
        return `
- ${content}
`;
      return BLOCK_TAGS.has(tag) ? `
${content}
` : content;
    };
    return render(root).replace(/\u00a0/g, " ").replace(/[ \t]+/g, " ").replace(/ *\n */g, `
`).replace(/\n{3,}/g, `

`).trim();
  };
  var install = ({ action, retryFetch }) => {
    action("getArticle", {
      async invoke({ url: inputUrl }) {
        const requestedUrl = articleUrl(inputUrl);
        const response = await retryFetch(requestedUrl.href, { credentials: "include" });
        if (!response.ok)
          throw new Error(`getArticle: HTTP ${response.status}`);
        const document2 = new DOMParser().parseFromString(await response.text(), "text/html");
        const contentElement = document2.querySelector("#js_content");
        const title = cleanText(document2.querySelector("#activity-name")?.textContent || document2.querySelector('meta[property="og:title"]')?.content);
        if (!contentElement || !title) {
          throw new Error("getArticle: article content is unavailable or requires verification");
        }
        const indexes = new Map;
        const images = [...contentElement.querySelectorAll("img")].flatMap((element) => {
          const source = imageUrl(element);
          if (!source)
            return [];
          const index = indexes.size + 1;
          indexes.set(element, index);
          return [{
            index,
            url: source,
            alt: cleanText(element.getAttribute("alt")) || null,
            width: positiveInteger(element.getAttribute("data-width"), element.getAttribute("data-w"), element.getAttribute("width")),
            height: positiveInteger(element.getAttribute("data-height"), element.getAttribute("data-h"), element.getAttribute("height"))
          }];
        });
        const coverImageUrl = imageUrl(document2.querySelector('meta[property="og:image"]'));
        return {
          title,
          accountName: cleanText(document2.querySelector("#js_name")?.textContent),
          publishedAt: cleanText(document2.querySelector("#publish_time")?.textContent),
          summary: cleanText(document2.querySelector('meta[property="og:description"]')?.content),
          url: requestedUrl.href,
          coverImageUrl,
          content: articleText(contentElement, indexes),
          images
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

  installService("mp.weixin.qq.com", actions_default);
})();
