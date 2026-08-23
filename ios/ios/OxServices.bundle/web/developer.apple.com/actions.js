(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/developer.apple.com/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const ORIGIN = "https://developer.apple.com";
    const DATA = `${ORIGIN}/tutorials/data`;
    const normalizePath = (path, namespace) => {
      let normalized = String(path).trim();
      normalized = normalized.replace(/^https?:\/\/developer\.apple\.com/i, "");
      normalized = normalized.replace(/^\/?tutorials\/data\//i, "");
      normalized = normalized.split(/[?#]/, 1)[0] ?? "";
      normalized = normalized.replace(/\.json$/i, "").replace(/^\/+|\/+$/g, "");
      if (!new RegExp(`^${namespace}(?:/|$)`, "i").test(normalized))
        normalized = `${namespace}/${normalized}`;
      return normalized;
    };
    const dataUrl = (path) => {
      return `${DATA}/${normalizePath(path, "documentation")}.json`;
    };
    const tutorialDataUrl = (path) => `${DATA}/${normalizePath(path, "tutorials")}.json`;
    const webUrl = (path) => `${ORIGIN}/${path.replace(/^\/+/, "")}`;
    const fetchJson = async (url) => {
      const r = await retryFetch(url, { credentials: "omit", headers: { Accept: "application/json" } });
      if (r.status >= 400)
        throw new Error(`HTTP ${r.status} for ${url}`);
      const text = await r.text();
      try {
        return JSON.parse(text);
      } catch {
        throw new Error(`Non-JSON response (HTTP ${r.status}) for ${url}`);
      }
    };
    const fetchDocument = async (url) => {
      const r = await retryFetch(url, { credentials: "omit", headers: { Accept: "text/html" } });
      if (r.status >= 400)
        throw new Error(`HTTP ${r.status} for ${url}`);
      return new DOMParser().parseFromString(await r.text(), "text/html");
    };
    const decodeEntities = (value) => String(value ?? "").replace(/&#(x?[0-9a-f]+);/gi, (_, code) => {
      const radix = code[0]?.toLowerCase() === "x" ? 16 : 10;
      return String.fromCodePoint(Number.parseInt(radix === 16 ? code.slice(1) : code, radix));
    }).replace(/&(amp|quot|apos|lt|gt|nbsp);/gi, (_, name) => ({
      amp: "&",
      quot: '"',
      apos: "'",
      lt: "<",
      gt: ">",
      nbsp: " "
    })[name.toLowerCase()] ?? "");
    const forumPath = (path) => path.startsWith("/forums/") || path === "/forums" ? path : `/forums/${path.replace(/^\/+/, "")}`;
    const forumDestination = (path) => {
      const url = new URL(/^https?:\/\//i.test(path) ? path : forumPath(path), ORIGIN);
      return {
        path: `${url.pathname}${url.search}${url.hash}`,
        url: url.href
      };
    };
    const forumNextCursor = (doc) => {
      const href = doc.querySelector("a.next-page[href]")?.getAttribute("href");
      if (!href)
        return null;
      return new URL(href, `${ORIGIN}/forums/`).searchParams.get("page");
    };
    const forumItems = (doc) => [...doc.querySelectorAll(".content-list-wrapper.desktop-view article.article-entry")].map((entry) => {
      const link = entry.querySelector("[data-action='post-title'][href]");
      const href = link?.getAttribute("href") ?? "";
      const destination = forumDestination(href);
      const parsedUrl = new URL(destination.url);
      const titleNode = link?.querySelector("span.underline, span.reply-title:last-child");
      const title = cleanText(titleNode?.textContent ?? link?.textContent).replace(/^Reply to\s+/i, "");
      const stats = entry.querySelector(".article-stats");
      const stat = (selector) => {
        const value = cleanText(stats?.querySelector(selector)?.textContent);
        return value || null;
      };
      const threadId = parsedUrl.pathname.match(/\/thread\/(\d+)/)?.[1] ?? "";
      return {
        id: entry.getAttribute("value") ?? "",
        kind: link?.classList.contains("reply-title") ? "reply" : "post",
        threadId,
        answerId: parsedUrl.searchParams.get("answerId"),
        title,
        excerpt: cleanText(entry.querySelector(".excerpt")?.textContent),
        topic: cleanText(entry.querySelector("a.topic")?.textContent) || null,
        subtopic: cleanText(entry.querySelector("a.subtopic")?.textContent) || null,
        tags: [...entry.querySelectorAll("a.tag")].map((tag) => cleanText(tag.textContent)).filter(Boolean),
        replies: stat(".replies"),
        boosts: stat(".votes"),
        views: stat(".views"),
        activity: stat(".timestamp"),
        answered: !!entry.querySelector(".action-icons.answered"),
        appleRecommended: !!entry.querySelector(".action-icons.apple-recommended"),
        ...destination
      };
    });
    const forumPostText = (element) => {
      if (!element)
        return "";
      const nodes = [...element.childNodes ?? []];
      const text = nodes.length ? nodes.map((node) => {
        if (node.nodeType === 3)
          return node.textContent ?? "";
        const child = node;
        return child.tagName === "BR" ? `
` : child.innerText ?? child.textContent ?? "";
      }).join(`
`) : element.innerText;
      return text.replace(/\r/g, "").replace(/[ \t]+\n/g, `
`).replace(/\n{3,}/g, `

`).trim();
    };
    const forumPost = (element, originalAuthor) => {
      const timestamp = Number.parseInt(element.getAttribute("data-timestamp") ?? "", 10);
      const author = element.getAttribute("data-authorname") ?? "";
      const authorPath = element.getAttribute("data-author-link");
      return {
        id: element.getAttribute("data-post-id") ?? "",
        kind: (element.getAttribute("data-post-type") ?? "").toLowerCase(),
        author,
        authorUrl: authorPath ? forumDestination(authorPath).url : null,
        createdAt: Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : null,
        body: forumPostText(element.querySelector("[data-action='content-post-body-content']")),
        originalPoster: author === originalAuthor,
        appleEmployee: element.querySelector("[data-action='author-name']")?.getAttribute("data-author-apple-employee") === "true",
        accepted: !!element.querySelector(".top-answer-badge.solved, .accepted-answer, .action-icons.answered, [data-solved='true']"),
        appleRecommended: !!element.querySelector(".apple-recommended-badge, .apple-recommended, [data-recommended='true']")
      };
    };
    const forumThreadStats = (question) => {
      const stats = new Map;
      for (const item of question.querySelectorAll(".content-post-metadata .post-info")) {
        const label = cleanText(item.querySelector(".post-info-title")?.textContent).toLowerCase();
        if (!label || stats.has(label))
          continue;
        const value = cleanText(item.textContent).slice(label.length).trim();
        stats.set(label, value);
      }
      return {
        replies: stats.get("replies") ?? null,
        boosts: stats.get("boosts") ?? null,
        views: stats.get("views") ?? null,
        participants: stats.get("participants") ?? null
      };
    };
    const inlineText = (nodes, refs) => (nodes ?? []).map((n) => {
      switch (n?.type) {
        case "text":
          return n.text ?? "";
        case "codeVoice":
          return `\`${n.code ?? ""}\``;
        case "emphasis":
        case "strong":
          return inlineText(n.inlineContent, refs);
        case "reference":
          return n.overridingTitle ?? refs[n.identifier]?.title ?? (/^https?:\/\//.test(n.identifier ?? "") ? n.identifier : "");
        case "link":
          return n.title ?? n.url ?? "";
        case "image":
          return "";
        default:
          return n?.inlineContent ? inlineText(n.inlineContent, refs) : n?.text ?? "";
      }
    }).join("");
    const blockText = (blocks, refs) => (blocks ?? []).map((b) => {
      switch (b?.type) {
        case "heading":
          return `${"#".repeat(Math.min(6, b.level ?? 2))} ${b.text ?? ""}`;
        case "paragraph":
          return inlineText(b.inlineContent, refs);
        case "codeListing":
          return "```" + (b.syntax ?? "") + `
` + (b.code ?? []).join(`
`) + "\n```";
        case "unorderedList":
          return (b.items ?? []).map((it) => `- ${blockText(it.content, refs)}`).join(`
`);
        case "orderedList":
          return (b.items ?? []).map((it, i) => `${i + 1}. ${blockText(it.content, refs)}`).join(`
`);
        case "aside":
          return `> ${b.name ? `${b.name}: ` : ""}${blockText(b.content, refs)}`;
        case "termList":
          return (b.items ?? []).map((it) => `${inlineText(it.term?.inlineContent, refs)}: ${blockText(it.definition?.content, refs)}`).join(`
`);
        default:
          if (b?.inlineContent)
            return inlineText(b.inlineContent, refs);
          if (b?.columns)
            return blockText(b.columns.flatMap((column) => column.content ?? []), refs);
          if (b?.content)
            return blockText(b.content, refs);
          return "";
      }
    }).filter(Boolean).join(`

`);
    const asset = (identifier, refs) => {
      if (!identifier)
        return null;
      const ref = refs[identifier];
      const variant = (ref?.variants ?? []).find((item) => item.traits?.includes("light")) ?? ref?.variants?.[0];
      if (!variant?.url)
        return null;
      return { url: variant.url, alt: ref?.alt ?? "" };
    };
    const tutorialDestination = (node, refs) => {
      if (!node)
        return null;
      const ref = refs[node.identifier] ?? {};
      const destination = ref.url ?? node.destination;
      if (!destination)
        return null;
      const path = destination.replace(/^https?:\/\/developer\.apple\.com\/?/i, "").replace(/^\//, "");
      return {
        title: ref.title ?? node.overridingTitle ?? node.title ?? "",
        path,
        url: webUrl(path)
      };
    };
    const declarationText = (doc) => {
      const decls = (doc.primaryContentSections ?? []).find((s) => s.kind === "declarations");
      if (!decls)
        return "";
      return (decls.declarations ?? []).map((d) => (d.tokens ?? []).map((t) => t.text ?? "").join("")).join(`
`);
    };
    const refToTopic = (ref) => ({
      title: ref?.title ?? "",
      abstract: ref?.abstract ? inlineText(ref.abstract, {}) : null,
      path: (ref?.url ?? "").replace(/^\//, "")
    });
    action("listTechnologies", {
      async invoke() {
        const doc = await fetchJson(`${DATA}/documentation/technologies.json`);
        const refs = doc.references ?? {};
        const items = [];
        for (const section of doc.sections ?? []) {
          if (section.kind !== "technologies")
            continue;
          for (const group of section.groups ?? []) {
            for (const tech of group.technologies ?? []) {
              const ref = refs[tech.destination?.identifier];
              const url = ref?.url ?? "";
              items.push({
                name: tech.title ?? ref?.title ?? "",
                abstract: ref?.abstract ? inlineText(ref.abstract, refs) : null,
                group: group.name ?? null,
                path: url.replace(/^\//, ""),
                url: url ? webUrl(url) : ""
              });
            }
          }
        }
        log(`listTechnologies: ${items.length} frameworks`);
        return { items, nextCursor: null };
      }
    });
    action("getDocumentation", {
      async invoke({ path }) {
        if (!path)
          throw new Error("path is required");
        const url = dataUrl(path);
        const docPath = url.slice(DATA.length).replace(/\.json$/, "");
        const doc = await fetchJson(url);
        const refs = doc.references ?? {};
        const meta = doc.metadata ?? {};
        const content = (doc.primaryContentSections ?? []).find((s) => s.kind === "content");
        const params = (doc.primaryContentSections ?? []).find((s) => s.kind === "parameters");
        const topics = (doc.topicSections ?? []).map((sec) => ({
          title: sec.title ?? "",
          items: (sec.identifiers ?? []).map((id) => refToTopic(refs[id])).filter((t) => t.title)
        }));
        const parameters = (params?.parameters ?? []).map((p) => ({
          name: p.name ?? "",
          description: blockText(p.content, refs)
        }));
        return {
          title: meta.title ?? "",
          kind: meta.roleHeading ?? meta.symbolKind ?? meta.role ?? "",
          abstract: doc.abstract ? inlineText(doc.abstract, refs) : null,
          platforms: (meta.platforms ?? []).map((p) => ({
            name: p.name,
            introducedAt: p.introducedAt ?? null,
            beta: !!p.beta
          })),
          declaration: declarationText(doc) || null,
          parameters,
          discussion: content ? blockText(content.content, refs) : "",
          topics,
          url: `${ORIGIN}${docPath}`
        };
      }
    });
    action("listTutorials", {
      async invoke() {
        const doc = await fetchJson(`${DATA}/tutorials/develop-in-swift.json`);
        const refs = doc.references ?? {};
        const hero = (doc.sections ?? []).find((section) => section.kind === "hero");
        const items = (doc.sections ?? []).flatMap((section) => {
          if (section.kind !== "volume")
            return [];
          return (section.chapters ?? []).flatMap((chapter) => (chapter.tutorials ?? []).map((identifier) => {
            const ref = refs[identifier] ?? {};
            const path = (ref.url ?? "").replace(/^\//, "");
            return {
              title: ref.title ?? "",
              kind: ref.kind ?? ref.role ?? "",
              abstract: ref.abstract ? inlineText(ref.abstract, refs) : null,
              volume: section.name ?? "",
              chapter: chapter.name ?? "",
              path,
              url: path ? webUrl(path) : ""
            };
          }));
        });
        const resources = (doc.sections ?? []).flatMap((section) => {
          if (section.kind !== "resources")
            return [];
          return (section.tiles ?? []).map((tile) => ({
            title: tile.title ?? "",
            description: blockText(tile.content, refs),
            url: tile.action?.destination ?? ""
          }));
        });
        log(`listTutorials: ${items.length} tutorials`);
        return {
          title: doc.metadata?.title ?? hero?.title ?? "",
          abstract: hero?.content ? blockText(hero.content, refs) : null,
          items,
          resources,
          nextCursor: null
        };
      }
    });
    action("getTutorial", {
      async invoke({ path }) {
        if (!path)
          throw new Error("path is required");
        const normalizedPath = normalizePath(path, "tutorials");
        const doc = await fetchJson(tutorialDataUrl(path));
        const refs = doc.references ?? {};
        const hero = (doc.sections ?? []).find((section) => section.kind === "hero");
        const article = (doc.sections ?? []).find((section) => section.kind === "articleBody");
        const taskSection = (doc.sections ?? []).find((section) => section.kind === "tasks");
        const assessmentSection = (doc.sections ?? []).find((section) => section.kind === "assessments");
        const callToAction = (doc.sections ?? []).find((section) => section.kind === "callToAction");
        const tasks = (taskSection?.tasks ?? []).map((task) => ({
          title: task.title ?? "",
          introduction: blockText(task.contentSection, refs),
          steps: (task.stepsSection ?? []).map((step) => {
            const codeRef = refs[step.code];
            const media = asset(step.media, refs);
            const preview = asset(step.runtimePreview, refs);
            return {
              instruction: blockText(step.content, refs),
              caption: blockText(step.caption, refs),
              code: Array.isArray(codeRef?.content) ? codeRef.content.join(`
`) : null,
              mediaUrl: media?.url ?? null,
              mediaAlt: media?.alt ?? null,
              previewUrl: preview?.url ?? null
            };
          })
        }));
        const assessments = (assessmentSection?.assessments ?? []).map((assessment) => ({
          question: blockText(assessment.title, refs),
          choices: (assessment.choices ?? []).map((choice) => ({
            text: blockText(choice.content, refs),
            correct: !!choice.isCorrect,
            justification: blockText(choice.justification, refs)
          }))
        }));
        return {
          title: doc.metadata?.title ?? hero?.title ?? "",
          kind: doc.metadata?.role ?? doc.kind ?? "",
          category: doc.metadata?.category ?? null,
          abstract: hero?.content ? blockText(hero.content, refs) : null,
          content: article ? blockText(article.content, refs) : "",
          tasks,
          assessments,
          next: tutorialDestination(callToAction?.action, refs),
          url: webUrl(normalizedPath)
        };
      }
    });
    action("searchSymbols", {
      async invoke({ framework, query, limit }) {
        if (!framework)
          throw new Error("framework is required");
        if (!query)
          throw new Error("query is required");
        const slug = framework.toLowerCase().replace(/^\/?(documentation\/)?/, "").replace(/\/+$/, "");
        const index = await fetchJson(`${DATA}/index/${slug}`);
        const roots = index.interfaceLanguages?.swift ?? index.interfaceLanguages?.occ ?? [];
        const q = query.toLowerCase();
        const cap = Math.max(1, Math.min(limit ?? 50, 200));
        const items = [];
        const walk = (node) => {
          if (items.length >= cap)
            return;
          if (node?.path && node?.type !== "groupMarker" && (node.title ?? "").toLowerCase().includes(q)) {
            items.push({
              title: node.title,
              type: node.type ?? "",
              path: node.path.replace(/^\//, ""),
              url: webUrl(node.path)
            });
          }
          for (const child of node?.children ?? [])
            walk(child);
        };
        for (const root of roots)
          walk(root);
        log(`searchSymbols ${slug} "${query}": ${items.length} hits`);
        return { items, nextCursor: null };
      }
    });
    action("listForumTopics", {
      async invoke() {
        const doc = await fetchDocument(`${ORIGIN}/forums/topics`);
        const raw = doc.querySelector("#topics-data")?.textContent?.trim();
        if (!raw)
          throw new Error("listForumTopics: missing topic data");
        const roots = JSON.parse(raw.replace(/\\&quot;/g, '"'));
        const items = [];
        const visit = (node, parentId, level) => {
          const sourcePath = node.url ? forumPath(node.url) : null;
          items.push({
            id: String(node.id ?? ""),
            title: decodeEntities(node.title ?? node.name),
            description: decodeEntities(node.description),
            slug: String(node.slug ?? ""),
            path: sourcePath,
            url: sourcePath ? new URL(sourcePath, ORIGIN).href : null,
            parentId,
            level
          });
          for (const child of node.children ?? [])
            visit(child, String(node.id ?? ""), level + 1);
        };
        for (const root of roots)
          visit(root, null, 0);
        log(`listForumTopics: ${items.length} topics and subtopics`);
        return { items, nextCursor: null };
      }
    });
    action("listForumPosts", {
      async invoke({ cursor, sortBy = "activity", sortOrder = "desc" } = {}) {
        const page = pageCursor(cursor, 1);
        const params = new URLSearchParams({ sortBy, sortOrder, contentFilterBy: "questions" });
        if (page > 1)
          params.set("page", String(page));
        const doc = await fetchDocument(`${ORIGIN}/forums/allPosts?${params}`);
        const items = forumItems(doc);
        log(`listForumPosts page ${page}: ${items.length} items`);
        return { items, nextCursor: forumNextCursor(doc) };
      }
    });
    action("searchForumPosts", {
      async invoke({ query, cursor, sortBy = "relevance" }) {
        if (!query)
          throw new Error("query is required");
        const page = pageCursor(cursor, 1);
        const params = new URLSearchParams({ q: query, sortBy });
        if (page > 1)
          params.set("page", String(page));
        const doc = await fetchDocument(`${ORIGIN}/forums/search?${params}`);
        const items = forumItems(doc);
        log(`searchForumPosts "${query}" page ${page}: ${items.length} hits`);
        return { items, nextCursor: forumNextCursor(doc) };
      }
    });
    action("getForumThread", {
      async invoke({ id, cursor, answerId }) {
        if (!id)
          throw new Error("id is required");
        const params = new URLSearchParams;
        if (answerId)
          params.set("answerId", answerId);
        else if (pageCursor(cursor, 1) > 1)
          params.set("page", String(pageCursor(cursor, 1)));
        const requestedUrl = `${ORIGIN}/forums/thread/${encodeURIComponent(id)}${params.size ? `?${params}` : ""}`;
        const doc = await fetchDocument(requestedUrl);
        const question = doc.querySelector("section.content-post.question");
        if (!question)
          throw new Error(`getForumThread: no thread found for id ${id}`);
        const originalAuthor = question.getAttribute("data-authorname") ?? "";
        const pagination = doc.querySelector("nav.pagination");
        const canonicalPath = doc.querySelector("link[rel='canonical']")?.getAttribute("href") ?? requestedUrl;
        const destination = forumDestination(canonicalPath);
        return {
          id,
          title: cleanText(doc.querySelector("h1[data-action='post-title']")?.textContent),
          topic: cleanText(doc.querySelector(".thread-container a.topic")?.textContent) || null,
          subtopic: cleanText(doc.querySelector(".thread-container a.subtopic")?.textContent) || null,
          tags: [...doc.querySelectorAll(".thread-container a.tag")].map((tag) => cleanText(tag.textContent)).filter(Boolean),
          question: forumPost(question, originalAuthor),
          replies: [...doc.querySelectorAll(".answers section.content-post.answer")].map((reply) => forumPost(reply, originalAuthor)),
          stats: forumThreadStats(question),
          currentPage: Number.parseInt(pagination?.getAttribute("data-current-page") ?? "1", 10) || 1,
          totalPages: Number.parseInt(pagination?.getAttribute("data-total-pages") ?? "1", 10) || 1,
          nextCursor: forumNextCursor(doc),
          ...destination
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

  installService("developer.apple.com", actions_default);
})();
