import type { ActionInstaller } from "../action.ts";

const API = "https://api.1point3acres.com";
const TRPC = "https://trpc.1point3acres.com/trpc";
const BBS = "https://www.1point3acres.com/bbs";

const install: ActionInstaller = ({ action, retryFetch, log }) => {

  const trpc = async (proc: string, json: unknown) => {
    const input = { "0": { json, meta: { values: { fids: ["undefined"] } } } };
    const url = `${TRPC}/${proc}?batch=1&input=${encodeURIComponent(JSON.stringify(input))}`;
    const res = await retryFetch(url, {
      credentials: "include",
      headers: { "x-trpc-source": "web", referer: "https://www.1point3acres.com/" },
    });
    if (!res.ok) throw new Error(`${proc}: HTTP ${res.status}`);
    const body = await res.json();
    const err = body?.[0]?.error;
    if (err) throw new Error(`${proc}: ${err?.json?.message ?? "trpc error"}`);
    return body?.[0]?.result?.data?.json ?? null;
  };

  const apiJson = async (path: string) => {
    const res = await retryFetch(`${API}${path}`, {
      credentials: "include",
      headers: { referer: "https://visa.1point3acres.com/" },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status} for ${path}`);
    return res.json();
  };

  const me = () => trpc("user.me", null);

  const threadFromApi = (t: any) => ({
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
    url: `${BBS}/thread-${t.tid}-1-1.html`,
  });

  const threadFromSearch = (t: any) => ({
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
    url: `${BBS}/thread-${t.tid}-1-1.html`,
  });

  action("getSignInUrl", {
    async invoke() {
      return { url: "https://auth.1point3acres.com/login" };
    },
  });

  action("getSignInState", {
    async invoke() {
      return { signedIn: !!(await me())?.uid };
    },
  });

  action("getCurrentUser", {
    async invoke() {
      const u = await me();
      if (!u?.uid) throw new Error("getCurrentUser: requires sign-in");
      return {
        uid: String(u.uid),
        username: u.username ?? "",
        group: u.grouptitle ?? "",
        credits: u.credits ?? 0,
        points: u.user_count?.extcredits1 ?? 0,
        isVip: !!u.isVip,
      };
    },
  });

  action("searchThreads", {
    async invoke({ query, type = "keywords", days = 365, cursor, limit = 20 } = {}) {
      if (!query) throw new Error("searchThreads: query is required");
      const offset = cursor ? parseInt(cursor, 10) || 0 : undefined;
      const json: any = { query, type, days, fids: null, direction: "forward" };
      if (offset) json.cursor = offset;
      const data = await trpc("search.search", json);
      const items = (data?.data ?? []).slice(0, limit).map(threadFromSearch);
      const next = data?.cursor;
      const nextCursor = items.length >= limit && next != null ? String(next) : null;
      return { items, nextCursor };
    },
  });

  action("listThreads", {
    async invoke({ fid, typeid, cursor, limit = 20 } = {}) {
      if (!fid) throw new Error("listThreads: fid is required");
      const pg = cursor ? Math.max(1, parseInt(cursor, 10) || 1) : 1;
      const q = new URLSearchParams({
        ps: String(limit),
        pg: String(pg),
        with_total: "1",
        includes: "summary,options",
        order: "time_desc",
      });
      if (typeid != null) q.set("typeid", String(typeid));
      const body = await apiJson(`/api/forums/${encodeURIComponent(fid)}/threads?${q}`);
      if (body?.errno && body.errno !== 0) throw new Error(body.msg || "api error");
      const items = (body?.threads ?? []).map(threadFromApi);
      const nextCursor = items.length >= limit ? String(pg + 1) : null;
      return { items, nextCursor };
    },
  });

  action("getThread", {
    async invoke({ tid, page = 1 }) {
      if (!tid) throw new Error("getThread: tid is required");
      const res = await retryFetch(`${BBS}/thread-${encodeURIComponent(tid)}-${page}-1.html`, {
        credentials: "include",
      });
      if (!res.ok) throw new Error(`getThread: HTTP ${res.status}`);
      const html = new TextDecoder("gbk").decode(await res.arrayBuffer());
      const doc = new DOMParser().parseFromString(html, "text/html");
      const subject = doc.querySelector("#thread_subject")?.textContent?.trim() ?? "";
      const posts = [...doc.querySelectorAll<HTMLElement>("[id^='postmessage_']")].map((msg) => {
        const pid = msg.id.replace("postmessage_", "");
        const author = doc.querySelector<HTMLElement>(`#favatar${pid} .pi`)?.innerText?.trim() ?? "";
        const dateEl = doc.querySelector<HTMLElement>(`#authorposton${pid} span[title], #authorposton${pid}`);
        const date = dateEl?.getAttribute("title") || dateEl?.innerText?.trim() || "";
        return { pid, author, date, content: msg.innerText.trim() };
      });
      const pages = [...doc.querySelectorAll<HTMLElement>(".pg a.last, .pgt a.last")]
        .map((a) => parseInt((a.innerText.match(/\d+/) ?? ["0"])[0], 10))
        .reduce((a, b) => Math.max(a, b), page);
      const nextCursor = page < pages ? String(page + 1) : null;
      return { tid: String(tid), subject, page, posts, nextCursor };
    },
  });

  action("getVisaBulletin", {
    async invoke() {
      const body = await apiJson(`/visa_tracker/greencard/visa_bulletin`);
      const d = body?.data ?? {};
      const region = (it: any, p: string) => ({
        actionDate: it[`${p}_action_date`] ?? null,
        filingDate: it[`${p}_filing_date`] ?? null,
      });
      const items = (d.items ?? []).map((it: any) => ({
        category: it.category,
        china: region(it, "cn"),
        india: region(it, "ind"),
        mexico: region(it, "mex"),
        philippines: region(it, "phl"),
        vietnam: region(it, "vnm"),
        restOfWorld: region(it, "row"),
      }));
      return { currentMonth: d.current_month ?? "", prevMonth: d.prev_month ?? "", items };
    },
  });

  action("getH1bRankings", {
    async invoke({ by = "companies", rankBy = "fillings" } = {}) {
      const path = { companies: "top-companies", cities: "top-cities", jobs: "top-jobs" }[by as string];
      if (!path) throw new Error(`getH1bRankings: unknown by '${by}'`);
      const body = await apiJson(`/visa_tracker/h1b/${path}?rank_by=${encodeURIComponent(rankBy)}`);
      const items = (body?.data ?? []).map((r: any) => ({
        name: r.key,
        count: r.doc_count ?? 0,
        avgSalary: r.avg_salary ?? 0,
      }));
      return { by, rankBy, items };
    },
  });
};

export default install;
