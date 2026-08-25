import type { ActionInstaller } from "@openox/service-sdk/action";
import { cleanText, pageCursor } from "@openox/service-sdk/action-lib";

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const ORIGIN = "https://developer.apple.com";
  const DATA = `${ORIGIN}/tutorials/data`;

  const normalizePath = (path: string, namespace: "documentation" | "tutorials") => {
    let normalized = String(path).trim();
    normalized = normalized.replace(/^https?:\/\/developer\.apple\.com/i, "");
    normalized = normalized.replace(/^\/?tutorials\/data\//i, "");
    normalized = normalized.split(/[?#]/, 1)[0] ?? "";
    normalized = normalized.replace(/\.json$/i, "").replace(/^\/+|\/+$/g, "");
    if (!new RegExp(`^${namespace}(?:/|$)`, "i").test(normalized)) normalized = `${namespace}/${normalized}`;
    return normalized;
  };

  // "/documentation/foundation/unitconverter.json" from any of:
  // full URL, "/documentation/foo", "documentation/foo", or a bare "foundation/foo".
  const dataUrl = (path: string) => {
    return `${DATA}/${normalizePath(path, "documentation")}.json`;
  };

  const tutorialDataUrl = (path: string) =>
    `${DATA}/${normalizePath(path, "tutorials")}.json`;

  const webUrl = (path: string) =>
    `${ORIGIN}/${path.replace(/^\/+/, "")}`;

  const fetchJson = async (url: string) => {
    const r = await retryFetch(url, { credentials: "omit", headers: { Accept: "application/json" } });
    if (r.status >= 400) throw new Error(`HTTP ${r.status} for ${url}`);
    const text = await r.text();
    try {
      return JSON.parse(text);
    } catch {
      throw new Error(`Non-JSON response (HTTP ${r.status}) for ${url}`);
    }
  };

  const fetchDocument = async (url: string) => {
    const r = await retryFetch(url, { credentials: "omit", headers: { Accept: "text/html" } });
    if (r.status >= 400) throw new Error(`HTTP ${r.status} for ${url}`);
    return new DOMParser().parseFromString(await r.text(), "text/html");
  };

  const decodeEntities = (value: unknown) => String(value ?? "")
    .replace(/&#(x?[0-9a-f]+);/gi, (_, code: string) => {
      const radix = code[0]?.toLowerCase() === "x" ? 16 : 10;
      return String.fromCodePoint(Number.parseInt(radix === 16 ? code.slice(1) : code, radix));
    })
    .replace(/&(amp|quot|apos|lt|gt|nbsp);/gi, (_, name: string) => ({
      amp: "&",
      quot: '"',
      apos: "'",
      lt: "<",
      gt: ">",
      nbsp: " ",
    })[name.toLowerCase()] ?? "");

  const forumPath = (path: string) => path.startsWith("/forums/") || path === "/forums"
    ? path
    : `/forums/${path.replace(/^\/+/, "")}`;

  const forumDestination = (path: string) => {
    const url = new URL(/^https?:\/\//i.test(path) ? path : forumPath(path), ORIGIN);
    return {
      path: `${url.pathname}${url.search}${url.hash}`,
      url: url.href,
    };
  };

  const forumNextCursor = (doc: Document) => {
    const href = doc.querySelector<HTMLAnchorElement>("a.next-page[href]")?.getAttribute("href");
    if (!href) return null;
    return new URL(href, `${ORIGIN}/forums/`).searchParams.get("page");
  };

  const forumItems = (doc: Document) => [...doc.querySelectorAll<HTMLElement>(
    ".content-list-wrapper.desktop-view article.article-entry",
  )].map((entry) => {
    const link = entry.querySelector<HTMLAnchorElement>("[data-action='post-title'][href]");
    const href = link?.getAttribute("href") ?? "";
    const destination = forumDestination(href);
    const parsedUrl = new URL(destination.url);
    const titleNode = link?.querySelector("span.underline, span.reply-title:last-child");
    const title = cleanText(titleNode?.textContent ?? link?.textContent).replace(/^Reply to\s+/i, "");
    const stats = entry.querySelector(".article-stats");
    const stat = (selector: string) => {
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
      ...destination,
    };
  });

  const forumPostText = (element: Element | null) => {
    if (!element) return "";
    const nodes = [...((element as any).childNodes ?? [])] as ChildNode[];
    const text = nodes.length
      ? nodes.map((node) => {
        if (node.nodeType === 3) return node.textContent ?? "";
        const child = node as HTMLElement;
        return child.tagName === "BR" ? "\n" : child.innerText ?? child.textContent ?? "";
      }).join("\n")
      : (element as HTMLElement).innerText;
    return text.replace(/\r/g, "")
      .replace(/[ \t]+\n/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  };

  const forumPost = (element: Element, originalAuthor: string) => {
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
      appleRecommended: !!element.querySelector(".apple-recommended-badge, .apple-recommended, [data-recommended='true']"),
    };
  };

  const forumThreadStats = (question: Element) => {
    const stats = new Map<string, string>();
    for (const item of question.querySelectorAll(".content-post-metadata .post-info")) {
      const label = cleanText(item.querySelector(".post-info-title")?.textContent).toLowerCase();
      if (!label || stats.has(label)) continue;
      const value = cleanText(item.textContent).slice(label.length).trim();
      stats.set(label, value);
    }
    return {
      replies: stats.get("replies") ?? null,
      boosts: stats.get("boosts") ?? null,
      views: stats.get("views") ?? null,
      participants: stats.get("participants") ?? null,
    };
  };

  // DocC content is a tree of block nodes, each holding inline runs. `refs` is the
  // page's references map, used to resolve reference identifiers to their titles.
  const inlineText = (nodes: any[], refs: Record<string, any>): string =>
    (nodes ?? [])
      .map((n) => {
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
      })
      .join("");

  const blockText = (blocks: any[], refs: Record<string, any>): string =>
    (blocks ?? [])
      .map((b) => {
        switch (b?.type) {
          case "heading":
            return `${"#".repeat(Math.min(6, b.level ?? 2))} ${b.text ?? ""}`;
          case "paragraph":
            return inlineText(b.inlineContent, refs);
          case "codeListing":
            return "```" + (b.syntax ?? "") + "\n" + (b.code ?? []).join("\n") + "\n```";
          case "unorderedList":
            return (b.items ?? []).map((it: any) => `- ${blockText(it.content, refs)}`).join("\n");
          case "orderedList":
            return (b.items ?? []).map((it: any, i: number) => `${i + 1}. ${blockText(it.content, refs)}`).join("\n");
          case "aside":
            return `> ${b.name ? `${b.name}: ` : ""}${blockText(b.content, refs)}`;
          case "termList":
            return (b.items ?? [])
              .map((it: any) => `${inlineText(it.term?.inlineContent, refs)}: ${blockText(it.definition?.content, refs)}`)
              .join("\n");
          default:
            if (b?.inlineContent) return inlineText(b.inlineContent, refs);
            if (b?.columns) return blockText(b.columns.flatMap((column: any) => column.content ?? []), refs);
            if (b?.content) return blockText(b.content, refs);
            return "";
        }
      })
      .filter(Boolean)
      .join("\n\n");

  const asset = (identifier: string | null | undefined, refs: Record<string, any>) => {
    if (!identifier) return null;
    const ref = refs[identifier];
    const variant = (ref?.variants ?? []).find((item: any) => item.traits?.includes("light")) ?? ref?.variants?.[0];
    if (!variant?.url) return null;
    return { url: variant.url, alt: ref?.alt ?? "" };
  };

  const tutorialDestination = (node: any, refs: Record<string, any>) => {
    if (!node) return null;
    const ref = refs[node.identifier] ?? {};
    const destination = ref.url ?? node.destination;
    if (!destination) return null;
    const path = destination.replace(/^https?:\/\/developer\.apple\.com\/?/i, "").replace(/^\//, "");
    return {
      title: ref.title ?? node.overridingTitle ?? node.title ?? "",
      path,
      url: webUrl(path),
    };
  };

  const declarationText = (doc: any): string => {
    const decls = (doc.primaryContentSections ?? []).find((s: any) => s.kind === "declarations");
    if (!decls) return "";
    return (decls.declarations ?? [])
      .map((d: any) => (d.tokens ?? []).map((t: any) => t.text ?? "").join(""))
      .join("\n");
  };

  const refToTopic = (ref: any) => ({
    title: ref?.title ?? "",
    abstract: ref?.abstract ? inlineText(ref.abstract, {}) : null,
    path: (ref?.url ?? "").replace(/^\//, ""),
  });

  action("listTechnologies", {
    async invoke() {
      const doc = await fetchJson(`${DATA}/documentation/technologies.json`);
      const refs: Record<string, any> = doc.references ?? {};
      const items: any[] = [];
      for (const section of doc.sections ?? []) {
        if (section.kind !== "technologies") continue;
        for (const group of section.groups ?? []) {
          for (const tech of group.technologies ?? []) {
            const ref = refs[tech.destination?.identifier];
            const url = ref?.url ?? "";
            items.push({
              name: tech.title ?? ref?.title ?? "",
              abstract: ref?.abstract ? inlineText(ref.abstract, refs) : null,
              group: group.name ?? null,
              path: url.replace(/^\//, ""),
              url: url ? webUrl(url) : "",
            });
          }
        }
      }
      log(`listTechnologies: ${items.length} frameworks`);
      return { items, nextCursor: null };
    },
  });

  action("getDocumentation", {
    async invoke({ path }: { path: string }) {
      if (!path) throw new Error("path is required");
      const url = dataUrl(path);
      const docPath = url.slice(DATA.length).replace(/\.json$/, "");
      const doc = await fetchJson(url);
      const refs: Record<string, any> = doc.references ?? {};
      const meta = doc.metadata ?? {};

      const content = (doc.primaryContentSections ?? []).find((s: any) => s.kind === "content");
      const params = (doc.primaryContentSections ?? []).find((s: any) => s.kind === "parameters");

      const topics = (doc.topicSections ?? []).map((sec: any) => ({
        title: sec.title ?? "",
        items: (sec.identifiers ?? []).map((id: string) => refToTopic(refs[id])).filter((t: any) => t.title),
      }));

      const parameters = (params?.parameters ?? []).map((p: any) => ({
        name: p.name ?? "",
        description: blockText(p.content, refs),
      }));

      return {
        title: meta.title ?? "",
        kind: meta.roleHeading ?? meta.symbolKind ?? meta.role ?? "",
        abstract: doc.abstract ? inlineText(doc.abstract, refs) : null,
        platforms: (meta.platforms ?? []).map((p: any) => ({
          name: p.name,
          introducedAt: p.introducedAt ?? null,
          beta: !!p.beta,
        })),
        declaration: declarationText(doc) || null,
        parameters,
        discussion: content ? blockText(content.content, refs) : "",
        topics,
        url: `${ORIGIN}${docPath}`,
      };
    },
  });

  action("listTutorials", {
    async invoke() {
      const doc = await fetchJson(`${DATA}/tutorials/develop-in-swift.json`);
      const refs: Record<string, any> = doc.references ?? {};
      const hero = (doc.sections ?? []).find((section: any) => section.kind === "hero");
      const items = (doc.sections ?? []).flatMap((section: any) => {
        if (section.kind !== "volume") return [];
        return (section.chapters ?? []).flatMap((chapter: any) =>
          (chapter.tutorials ?? []).map((identifier: string) => {
            const ref = refs[identifier] ?? {};
            const path = (ref.url ?? "").replace(/^\//, "");
            return {
              title: ref.title ?? "",
              kind: ref.kind ?? ref.role ?? "",
              abstract: ref.abstract ? inlineText(ref.abstract, refs) : null,
              volume: section.name ?? "",
              chapter: chapter.name ?? "",
              path,
              url: path ? webUrl(path) : "",
            };
          }),
        );
      });
      const resources = (doc.sections ?? []).flatMap((section: any) => {
        if (section.kind !== "resources") return [];
        return (section.tiles ?? []).map((tile: any) => ({
          title: tile.title ?? "",
          description: blockText(tile.content, refs),
          url: tile.action?.destination ?? "",
        }));
      });
      log(`listTutorials: ${items.length} tutorials`);
      return {
        title: doc.metadata?.title ?? hero?.title ?? "",
        abstract: hero?.content ? blockText(hero.content, refs) : null,
        items,
        resources,
        nextCursor: null,
      };
    },
  });

  action("getTutorial", {
    async invoke({ path }: { path: string }) {
      if (!path) throw new Error("path is required");
      const normalizedPath = normalizePath(path, "tutorials");
      const doc = await fetchJson(tutorialDataUrl(path));
      const refs: Record<string, any> = doc.references ?? {};
      const hero = (doc.sections ?? []).find((section: any) => section.kind === "hero");
      const article = (doc.sections ?? []).find((section: any) => section.kind === "articleBody");
      const taskSection = (doc.sections ?? []).find((section: any) => section.kind === "tasks");
      const assessmentSection = (doc.sections ?? []).find((section: any) => section.kind === "assessments");
      const callToAction = (doc.sections ?? []).find((section: any) => section.kind === "callToAction");
      const tasks = (taskSection?.tasks ?? []).map((task: any) => ({
        title: task.title ?? "",
        introduction: blockText(task.contentSection, refs),
        steps: (task.stepsSection ?? []).map((step: any) => {
          const codeRef = refs[step.code];
          const media = asset(step.media, refs);
          const preview = asset(step.runtimePreview, refs);
          return {
            instruction: blockText(step.content, refs),
            caption: blockText(step.caption, refs),
            code: Array.isArray(codeRef?.content) ? codeRef.content.join("\n") : null,
            mediaUrl: media?.url ?? null,
            mediaAlt: media?.alt ?? null,
            previewUrl: preview?.url ?? null,
          };
        }),
      }));
      const assessments = (assessmentSection?.assessments ?? []).map((assessment: any) => ({
        question: blockText(assessment.title, refs),
        choices: (assessment.choices ?? []).map((choice: any) => ({
          text: blockText(choice.content, refs),
          correct: !!choice.isCorrect,
          justification: blockText(choice.justification, refs),
        })),
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
        url: webUrl(normalizedPath),
      };
    },
  });

  action("searchSymbols", {
    async invoke({ framework, query, limit }: { framework: string; query: string; limit?: number }) {
      if (!framework) throw new Error("framework is required");
      if (!query) throw new Error("query is required");
      const slug = framework.toLowerCase().replace(/^\/?(documentation\/)?/, "").replace(/\/+$/, "");
      const index = await fetchJson(`${DATA}/index/${slug}`);
      const roots: any[] = index.interfaceLanguages?.swift ?? index.interfaceLanguages?.occ ?? [];
      const q = query.toLowerCase();
      const cap = Math.max(1, Math.min(limit ?? 50, 200));
      const items: any[] = [];

      const walk = (node: any) => {
        if (items.length >= cap) return;
        if (node?.path && node?.type !== "groupMarker" && (node.title ?? "").toLowerCase().includes(q)) {
          items.push({
            title: node.title,
            type: node.type ?? "",
            path: node.path.replace(/^\//, ""),
            url: webUrl(node.path),
          });
        }
        for (const child of node?.children ?? []) walk(child);
      };
      for (const root of roots) walk(root);

      log(`searchSymbols ${slug} "${query}": ${items.length} hits`);
      return { items, nextCursor: null };
    },
  });

  action("listForumTopics", {
    async invoke() {
      const doc = await fetchDocument(`${ORIGIN}/forums/topics`);
      const raw = doc.querySelector("#topics-data")?.textContent?.trim();
      if (!raw) throw new Error("listForumTopics: missing topic data");
      const roots = JSON.parse(raw.replace(/\\&quot;/g, '"')) as any[];
      const items: any[] = [];
      const visit = (node: any, parentId: string | null, level: number) => {
        const sourcePath = node.url ? forumPath(node.url) : null;
        items.push({
          id: String(node.id ?? ""),
          title: decodeEntities(node.title ?? node.name),
          description: decodeEntities(node.description),
          slug: String(node.slug ?? ""),
          path: sourcePath,
          url: sourcePath ? new URL(sourcePath, ORIGIN).href : null,
          parentId,
          level,
        });
        for (const child of node.children ?? []) visit(child, String(node.id ?? ""), level + 1);
      };
      for (const root of roots) visit(root, null, 0);
      log(`listForumTopics: ${items.length} topics and subtopics`);
      return { items, nextCursor: null };
    },
  });

  action("listForumPosts", {
    async invoke({ cursor, sortBy = "activity", sortOrder = "desc" }: {
      cursor?: string;
      sortBy?: string;
      sortOrder?: string;
    } = {}) {
      const page = pageCursor(cursor, 1);
      const params = new URLSearchParams({ sortBy, sortOrder, contentFilterBy: "questions" });
      if (page > 1) params.set("page", String(page));
      const doc = await fetchDocument(`${ORIGIN}/forums/allPosts?${params}`);
      const items = forumItems(doc);
      log(`listForumPosts page ${page}: ${items.length} items`);
      return { items, nextCursor: forumNextCursor(doc) };
    },
  });

  action("searchForumPosts", {
    async invoke({ query, cursor, sortBy = "relevance" }: {
      query: string;
      cursor?: string;
      sortBy?: string;
    }) {
      if (!query) throw new Error("query is required");
      const page = pageCursor(cursor, 1);
      const params = new URLSearchParams({ q: query, sortBy });
      if (page > 1) params.set("page", String(page));
      const doc = await fetchDocument(`${ORIGIN}/forums/search?${params}`);
      const items = forumItems(doc);
      log(`searchForumPosts "${query}" page ${page}: ${items.length} hits`);
      return { items, nextCursor: forumNextCursor(doc) };
    },
  });

  action("getForumThread", {
    async invoke({ id, cursor, answerId }: { id: string; cursor?: string; answerId?: string }) {
      if (!id) throw new Error("id is required");
      const params = new URLSearchParams();
      if (answerId) params.set("answerId", answerId);
      else if (pageCursor(cursor, 1) > 1) params.set("page", String(pageCursor(cursor, 1)));
      const requestedUrl = `${ORIGIN}/forums/thread/${encodeURIComponent(id)}${params.size ? `?${params}` : ""}`;
      const doc = await fetchDocument(requestedUrl);
      const question = doc.querySelector("section.content-post.question");
      if (!question) throw new Error(`getForumThread: no thread found for id ${id}`);
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
        replies: [...doc.querySelectorAll(".answers section.content-post.answer")]
          .map((reply) => forumPost(reply, originalAuthor)),
        stats: forumThreadStats(question),
        currentPage: Number.parseInt(pagination?.getAttribute("data-current-page") ?? "1", 10) || 1,
        totalPages: Number.parseInt(pagination?.getAttribute("data-total-pages") ?? "1", 10) || 1,
        nextCursor: forumNextCursor(doc),
        ...destination,
      };
    },
  });
};

export default install;
