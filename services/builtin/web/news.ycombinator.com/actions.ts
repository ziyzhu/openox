import type { ActionInstaller } from "../action.ts";
import { pageCursor } from "../../../action-lib.ts";

const install: ActionInstaller = ({ action, retryFetch }) => {
  const fetchDoc = async (path: string) => {
    const html = await (await retryFetch(path, { credentials: "include" })).text();
    return new DOMParser().parseFromString(html, "text/html");
  };

  const FEED_PATHS: Record<string, string> = {
    top: "/news",
    new: "/newest",
    best: "/best",
    ask: "/ask",
    show: "/show",
    jobs: "/jobs",
    front: "/front",
  };

  const parseRow = (row: Element) => {
    const id = row.id;
    const titleEl = row.querySelector<HTMLAnchorElement>(".titleline a");
    const sitebit = row.querySelector<HTMLElement>(".sitestr");
    const sub = row.nextElementSibling?.querySelector(".subtext");
    const score = parseInt(sub?.querySelector<HTMLElement>(".score")?.innerText ?? "0", 10) || 0;
    const author = sub?.querySelector<HTMLElement>(".hnuser")?.innerText ?? "";
    const age = sub?.querySelector<HTMLElement>(".age")?.innerText ?? "";
    const links = [...(sub?.querySelectorAll("a") ?? [])];
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
      score, author, age, comments, hidden,
    };
  };

  const parseComments = (root: ParentNode) => {
    return [...root.querySelectorAll("tr.athing.comtr")].map((row) => {
      const id = row.id;
      const indentTd = row.querySelector("td.ind");
      const indentAttr = indentTd?.getAttribute("indent");
      const imgWidth = indentTd?.querySelector("img")?.getAttribute("width");
      const level = indentAttr != null
        ? parseInt(indentAttr, 10) || 0
        : Math.round((parseInt(imgWidth || "0", 10) || 0) / 40);
      const author = row.querySelector<HTMLElement>(".hnuser")?.innerText ?? "";
      const age = row.querySelector<HTMLElement>(".age")?.innerText ?? "";
      const text = row.querySelector<HTMLElement>(".commtext")?.innerText ?? "";
      return { id, author, level, age, text, parentId: null as string | null };
    }).map((c, i, arr) => {
      if (c.level === 0) return c;
      for (let j = i - 1; j >= 0; j--) {
        if (arr[j].level === c.level - 1) { c.parentId = arr[j].id; break; }
      }
      return c;
    });
  };

  const probeSignedIn = async () => {
    const doc = await fetchDoc("/news");
    return !!doc.querySelector("#me");
  };

  const storyFromRow = (row: Element) => {
    const r = parseRow(row);
    return {
      id: r.id, title: r.title, url: r.url, externalUrl: r.externalUrl,
      domain: r.domain, score: r.score, author: r.author, age: r.age,
      comments: r.comments, hidden: false,
    };
  };

  action("getSignInUrl", {
    async invoke() {
      return { url: "https://news.ycombinator.com/login" };
    },
  });

  action("getSignInState", {
    async invoke() {
      return { signedIn: await probeSignedIn() };
    },
  });

  action("getCurrentUser", {
    async invoke() {
      const doc = await fetchDoc("/news");
      const me = doc.querySelector<HTMLElement>("#me");
      const karmaEl = doc.querySelector<HTMLElement>("#karma");
      const user = me?.innerText?.trim();
      if (!user) throw new Error("getCurrentUser: requires sign-in");
      const karma = karmaEl ? parseInt(karmaEl.innerText, 10) : NaN;
      if (!Number.isFinite(karma)) throw new Error("getCurrentUser: missing karma");
      return { user, karma };
    },
  });

  action("listStories", {
    async invoke({ feed = "top", limit = 30, cursor } = {}) {
      const path = FEED_PATHS[feed] ?? FEED_PATHS.top;
      const page = pageCursor(cursor, 1);
      const doc = await fetchDoc(`${path}${page > 1 ? `?p=${page}` : ""}`);
      const items = [...doc.querySelectorAll("tr.athing")].slice(0, limit).map(parseRow);
      const nextCursor = items.length === limit ? String(page + 1) : null;
      return { items, nextCursor };
    },
  });

  action("getStory", {
    async invoke({ id }) {
      const doc = await fetchDoc(`/item?id=${encodeURIComponent(id)}`);
      const row = doc.querySelector("tr.athing");
      if (!row) throw new Error(`getStory: no story found for id ${id}`);
      return storyFromRow(row);
    },
  });

  action("getPost", {
    async invoke({ id }) {
      const doc = await fetchDoc(`/item?id=${encodeURIComponent(id)}`);
      const row = doc.querySelector("tr.athing.submission") || doc.querySelector("tr.athing");
      if (!row) throw new Error(`getPost: no post found for id ${id}`);
      const story = parseRow(row);
      const comments = parseComments(doc);
      return { story, comments };
    },
  });

  action("createComment", {
    async invoke({ parentId, text }) {
      const doc = await fetchDoc("reply?id=" + parentId);
      const form = doc.querySelector("form[action='comment']");
      if (!form) return { ok: false };
      const body = new URLSearchParams();
      for (const input of form.querySelectorAll<HTMLInputElement>("input[type=hidden]")) {
        body.set(input.name, input.value);
      }
      body.set("text", text);
      const res = await fetch("comment", { method: "POST", credentials: "include", body });
      return { ok: res.ok };
    },
  });

  action("getUser", {
    async invoke({ username }) {
      const doc = await fetchDoc(`/user?id=${encodeURIComponent(username)}`);
      const findRow = (label: string) => {
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
      if (!Number.isFinite(karma)) throw new Error(`getUser: no profile for ${username}`);
      const createdText = findRow("created:")?.innerText.trim() || "";
      const aboutEl = findRow("about:");
      return {
        username: userText,
        karma,
        created: createdText,
        about: aboutEl ? aboutEl.innerHTML.trim() : "",
      };
    },
  });
};

export default install;
