(() => {
  // service-sdk/action-lib.ts
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

  // services/builtin/web/linkedin.com/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const requireCsrf = () => {
      const t = cookie("JSESSIONID");
      if (!t)
        throw new Error("Not signed in to LinkedIn (no JSESSIONID cookie). Sign in first.");
      return t.replace(/"/g, "");
    };
    const headers = (accept) => ({
      accept,
      "csrf-token": requireCsrf(),
      "x-restli-protocol-version": "2.0.0",
      "x-li-lang": "en_US"
    });
    const NORMALIZED = "application/vnd.linkedin.normalized+json+2.1";
    const GRAPHQL = "application/graphql";
    const apiGet = async (path, accept) => {
      const r = await retryFetch(path, { credentials: "include", headers: headers(accept) });
      const text = await r.text();
      let json;
      try {
        json = JSON.parse(text);
      } catch {
        throw new Error(`${path.split("?")[0]}: non-JSON response (HTTP ${r.status}) — session may have expired`);
      }
      if (!r.ok)
        throw new Error(`${path.split("?")[0]}: HTTP ${r.status}`);
      return json;
    };
    const gqlUrl = (gateway, queryId, variables) => `/voyager/api/${gateway}/graphql?queryId=${queryId}&variables=${variables}`;
    const enc = (urn) => encodeURIComponent(urn);
    const QUERY = {
      conversations: "messengerConversations.0d5e6781bbee71c3e51c8843c6519f48"
    };
    const threadIdOf = (convUrn) => {
      const m = convUrn.match(/,([^,)]+)\)$/);
      if (!m)
        throw new Error("could not parse a thread id from the conversation URN");
      return m[1];
    };
    const HTML_ENTITIES = {
      "&amp;": "&",
      "&lt;": "<",
      "&gt;": ">",
      "&quot;": '"',
      "&#39;": "'",
      "&nbsp;": " "
    };
    const stripHtml = (html) => String(html || "").replace(/<\/p>|<br\s*\/?>/gi, `
`).replace(/<[^>]+>/g, "").replace(/&[a-z#0-9]+;/gi, (m) => HTML_ENTITIES[m.toLowerCase()] ?? m).replace(/[ \t]+/g, " ").replace(/\n{3,}/g, `

`).trim();
    const idFromUrn = (urn) => {
      const s = String(urn ?? "");
      const m = s.match(/[^:]+$/);
      return m ? m[0] : "";
    };
    const vectorUrl = (img, width) => {
      const v = img?.displayImageReference?.vectorImage || img;
      const arts = v?.artifacts;
      if (!v?.rootUrl || !Array.isArray(arts) || !arts.length)
        return "";
      let best = arts[0];
      for (const a of arts) {
        if (Math.abs((a.width || 0) - width) < Math.abs((best.width || 0) - width))
          best = a;
      }
      return v.rootUrl + (best.fileIdentifyingUrlPathSegment || "");
    };
    const profileVanity = (raw) => {
      const s = String(raw ?? "").trim();
      const m = s.match(/\/in\/([^/?#]+)/);
      const v = (m ? m[1] : s).replace(/^@+/, "");
      if (!v)
        throw new Error("publicId is required (a LinkedIn vanity name or profile URL)");
      return v;
    };
    const year = (d) => d?.year ? Number(d.year) : null;
    const positionRow = (p) => ({
      title: p?.title || "",
      company: p?.companyName || "",
      startYear: year(p?.dateRange?.start),
      endYear: year(p?.dateRange?.end)
    });
    const educationRow = (e) => ({
      school: e?.schoolName || "",
      degree: e?.degreeName || "",
      field: e?.fieldOfStudy || "",
      startYear: year(e?.dateRange?.start),
      endYear: year(e?.dateRange?.end)
    });
    const participantName = (p) => {
      const pt = p?.participantType || {};
      if (pt.member) {
        return `${pt.member.firstName?.text || ""} ${pt.member.lastName?.text || ""}`.trim();
      }
      if (pt.organization)
        return pt.organization.name?.text || "";
      if (pt.agent)
        return pt.agent.title?.text || "";
      return "";
    };
    const nameMapOf = (participants) => {
      const map = {};
      for (const p of participants || []) {
        const urn = p?.hostIdentityUrn;
        const name = participantName(p);
        if (urn && name)
          map[urn] = name;
      }
      return map;
    };
    const senderName = (m, nameMap) => participantName(m?.sender) || nameMap[m?.sender?.hostIdentityUrn || ""] || "";
    const messageText = (m) => m?.body?.text || m?.renderContentFallbackText || "";
    const messageRow = (m, nameMap = {}) => ({
      id: String(m?.backendUrn || m?.entityUrn || ""),
      sender: senderName(m, nameMap),
      subject: m?.subject || "",
      text: messageText(m),
      deliveredAt: Number(m?.deliveredAt) || 0
    });
    const conversationRow = (c) => {
      const nameMap = nameMapOf(c?.conversationParticipants);
      const participants = (c?.conversationParticipants || []).map(participantName).filter(Boolean);
      const last = c?.messages?.elements?.[0];
      return {
        id: String(c?.entityUrn || ""),
        title: c?.title || participants.join(", "),
        participants,
        unreadCount: Number(c?.unreadCount) || 0,
        read: Boolean(c?.read),
        groupChat: Boolean(c?.groupChat),
        lastActivityAt: Number(c?.lastActivityAt) || 0,
        lastMessage: last ? messageRow(last, nameMap) : null,
        url: c?.conversationUrl || ""
      };
    };
    const includedByUrn = (included) => {
      const map = {};
      for (const x of included || [])
        if (x?.entityUrn)
          map[x.entityUrn] = x;
      return map;
    };
    const eventSender = (from, byUrn) => {
      if (!from)
        return "";
      const mp = from.miniProfile || byUrn[from["*miniProfile"] || ""];
      if (mp && (mp.firstName || mp.lastName)) {
        return `${mp.firstName || ""} ${mp.lastName || ""}`.trim();
      }
      if (from.alternateName)
        return from.alternateName;
      const mc = from.miniCompany || byUrn[from["*miniCompany"] || ""];
      return mc?.name || "";
    };
    const eventRow = (ev, byUrn) => {
      const ec = ev?.eventContent || {};
      const text = ec.body || stripHtml(ec.attributedBody?.text);
      return {
        id: String(ev?.dashEntityUrn || ev?.entityUrn || ""),
        sender: eventSender(byUrn[ev?.["*from"] || ""] || ev?.from, byUrn),
        subject: ec.subject || "",
        text,
        deliveredAt: Number(ev?.createdAt) || 0
      };
    };
    const attr = (a) => a?.text || "";
    const searchType = (urn = "") => {
      if (/company/.test(urn))
        return "company";
      if (/member|fsd_profile/.test(urn))
        return "person";
      if (/\bgroup/.test(urn))
        return "group";
      if (/job/.test(urn))
        return "job";
      if (/school/.test(urn))
        return "school";
      if (/course/i.test(urn))
        return "course";
      return urn.split(":")[2] || "other";
    };
    const searchRow = (er) => ({
      type: searchType(er?.trackingUrn || er?.entityUrn || ""),
      title: attr(er?.title),
      subtitle: attr(er?.primarySubtitle),
      detail: attr(er?.secondarySubtitle),
      summary: attr(er?.summary),
      url: String(er?.navigationUrl || "").split("?")[0],
      urn: er?.trackingUrn || ""
    });
    const jobIdOf = (urn = "") => (urn.match(/(\d+)\s*$/) || [, ""])[1] || "";
    const jobRow = (c) => {
      const urn = c?.jobPostingUrn || c?.["*jobPosting"] || c?.entityUrn || "";
      const jobId = jobIdOf(urn);
      return {
        jobId,
        title: attr(c?.title),
        company: attr(c?.primaryDescription),
        location: attr(c?.secondaryDescription),
        url: jobId ? `https://www.linkedin.com/jobs/view/${jobId}/` : ""
      };
    };
    const postRow = (u, byUrn) => {
      const urn = u?.updateMetadata?.urn || u?.entityUrn || "";
      const sd = byUrn[u?.["*socialDetail"] || ""] || u?.socialDetail;
      const counts = byUrn[sd?.["*totalSocialActivityCounts"] || ""] || {};
      return {
        author: u?.actor?.name?.text || "",
        headline: u?.actor?.description?.text || u?.actor?.subDescription?.text || "",
        text: u?.commentary?.text?.text || "",
        likes: Number(counts.numLikes) || 0,
        comments: Number(counts.numComments) || 0,
        url: urn ? `https://www.linkedin.com/feed/update/${urn}/` : "",
        urn
      };
    };
    let cachedMe = null;
    const fetchMe = async () => {
      if (cachedMe)
        return cachedMe;
      const json = await apiGet("/voyager/api/me", NORMALIZED);
      const data = json?.data || {};
      const miniUrn = data["*miniProfile"] || "";
      const mini = (json?.included || []).find((x) => x?.entityUrn === miniUrn || String(x?.$type || "").endsWith("MiniProfile"));
      if (!mini)
        throw new Error("Could not resolve the signed-in member profile");
      const memberId = idFromUrn(mini.entityUrn);
      cachedMe = {
        memberId,
        mailboxUrn: `urn:li:fsd_profile:${memberId}`,
        profile: {
          name: `${mini.firstName || ""} ${mini.lastName || ""}`.trim(),
          firstName: mini.firstName || "",
          lastName: mini.lastName || "",
          headline: mini.occupation || "",
          publicIdentifier: mini.publicIdentifier || "",
          memberUrn: mini.entityUrn || "",
          plainId: String(data.plainId ?? ""),
          premiumSubscriber: Boolean(data.premiumSubscriber),
          profileUrl: mini.publicIdentifier ? `https://www.linkedin.com/in/${mini.publicIdentifier}/` : "",
          photoUrl: vectorUrl(mini.picture, 200)
        }
      };
      return cachedMe;
    };
    const PROFILE_DECO = "com.linkedin.voyager.dash.deco.identity.profile.FullProfileWithEntities-101";
    action("getSignInUrl", { async invoke() {
      return { url: "https://www.linkedin.com/login" };
    } });
    action("getSignInState", {
      async invoke() {
        try {
          if (!cookie("JSESSIONID"))
            return { signedIn: false };
          const json = await apiGet("/voyager/api/me", NORMALIZED);
          return { signedIn: Boolean(json?.data?.plainId) };
        } catch (e) {
          log(`linkedin getSignInState probe failed: ${String(e?.message ?? e)}`);
          throw e;
        }
      }
    });
    action("getMe", {
      async invoke() {
        return (await fetchMe()).profile;
      }
    });
    action("getProfile", {
      async invoke({ publicId } = {}) {
        const vanity = profileVanity(publicId);
        const json = await apiGet(`/voyager/api/identity/dash/profiles?q=memberIdentity&memberIdentity=${encodeURIComponent(vanity)}&decorationId=${PROFILE_DECO}`, NORMALIZED);
        const included = json?.included || [];
        const profile = included.find((x) => String(x?.$type || "").endsWith("profile.Profile"));
        if (!profile)
          throw new Error(`LinkedIn member @${vanity} not found`);
        const geoUrn = profile.geoLocation?.geoUrn;
        const geo = geoUrn && included.find((x) => x?.entityUrn === geoUrn);
        const location = profile.locationName || geo?.defaultLocalizedName || "";
        const positions = included.filter((x) => String(x?.$type || "").endsWith("profile.Position")).map(positionRow).sort((a, b) => (b.startYear || 0) - (a.startYear || 0));
        const educations = included.filter((x) => String(x?.$type || "").endsWith("profile.Education")).map(educationRow).sort((a, b) => (b.startYear || 0) - (a.startYear || 0));
        return {
          name: `${profile.firstName || ""} ${profile.lastName || ""}`.trim(),
          firstName: profile.firstName || "",
          lastName: profile.lastName || "",
          headline: profile.headline || "",
          summary: profile.summary || "",
          location,
          publicIdentifier: profile.publicIdentifier || vanity,
          premium: Boolean(profile.premium),
          influencer: Boolean(profile.influencer),
          profileUrl: `https://www.linkedin.com/in/${profile.publicIdentifier || vanity}/`,
          photoUrl: vectorUrl(profile.profilePicture, 200),
          positions,
          educations
        };
      }
    });
    action("listConversations", {
      async invoke() {
        const { mailboxUrn } = await fetchMe();
        const json = await apiGet(gqlUrl("voyagerMessagingGraphQL", QUERY.conversations, `(mailboxUrn:${enc(mailboxUrn)})`), GRAPHQL);
        const root = json?.data?.messengerConversationsBySyncToken;
        const elements = root?.elements || [];
        return {
          items: elements.map(conversationRow),
          nextCursor: null
        };
      }
    });
    action("getConversation", {
      async invoke({ id, cursor, limit } = {}) {
        const convUrn = String(id ?? "").trim();
        if (!convUrn.startsWith("urn:li:msg_conversation:")) {
          throw new Error("id must be a conversation URN from listConversations");
        }
        const count = Math.min(Math.max(Number(limit) || 20, 1), 50);
        const qs = new URLSearchParams({ count: String(count) });
        if (cursor)
          qs.set("createdBefore", String(Number(cursor)));
        const json = await apiGet(`/voyager/api/messaging/conversations/${enc(threadIdOf(convUrn))}/events?${qs.toString()}`, NORMALIZED);
        const byUrn = includedByUrn(json?.included);
        const urns = json?.data?.["*elements"] || [];
        const elements = urns.map((u) => byUrn[u]).filter(Boolean).sort((a, b) => (Number(a?.createdAt) || 0) - (Number(b?.createdAt) || 0));
        const items = elements.map((ev) => eventRow(ev, byUrn));
        const oldest = items.length ? items[0].deliveredAt : 0;
        return {
          items,
          nextCursor: items.length >= count && oldest ? String(oldest) : null
        };
      }
    });
    const SEARCH_DECO = "com.linkedin.voyager.dash.deco.search.SearchClusterCollection-185";
    const JOBS_DECO = "com.linkedin.voyager.dash.deco.jobs.search.JobSearchCardsCollection-207";
    action("search", {
      async invoke({ query, cursor, limit } = {}) {
        const q = String(query ?? "").trim();
        if (!q)
          throw new Error("query is required");
        const count = Math.min(Math.max(Number(limit) || 10, 1), 25);
        const start = cursor ? Number(cursor) : 0;
        const json = await apiGet(`/voyager/api/search/dash/clusters?decorationId=${SEARCH_DECO}&origin=GLOBAL_SEARCH_HEADER&q=all` + `&query=(keywords:${encodeURIComponent(q)},flagshipSearchIntent:SEARCH_SRP)&start=${start}&count=${count}`, NORMALIZED);
        const items = (json?.included || []).filter((x) => String(x?.$type || "").endsWith("EntityResultViewModel")).map(searchRow).filter((r) => r.title);
        return { items, nextCursor: items.length ? String(start + count) : null };
      }
    });
    action("searchJobs", {
      async invoke({ query, location, cursor, limit } = {}) {
        const q = String(query ?? "").trim();
        if (!q)
          throw new Error("query is required");
        const count = Math.min(Math.max(Number(limit) || 10, 1), 25);
        const start = cursor ? Number(cursor) : 0;
        const loc = String(location ?? "").trim();
        const queryParts = [`origin:JOB_SEARCH_PAGE_QUERY_EXPANSION`, `keywords:${encodeURIComponent(q)}`];
        if (loc)
          queryParts.push(`locationFallback:${encodeURIComponent(loc)}`);
        const json = await apiGet(`/voyager/api/voyagerJobsDashJobCards?decorationId=${JOBS_DECO}&q=jobSearch` + `&query=(${queryParts.join(",")})&start=${start}&count=${count}`, NORMALIZED);
        const items = (json?.included || []).filter((x) => String(x?.$type || "").endsWith("JobPostingCard")).map(jobRow).filter((r) => r.title && r.jobId);
        return { items, nextCursor: items.length >= count ? String(start + count) : null };
      }
    });
    action("listFeed", {
      async invoke({ cursor, limit } = {}) {
        const count = Math.min(Math.max(Number(limit) || 10, 1), 25);
        const start = cursor ? Number(cursor) : 0;
        const json = await apiGet(`/voyager/api/feed/updatesV2?commentsCount=0&count=${count}&q=chronFeed&start=${start}`, NORMALIZED);
        const included = json?.included || [];
        const byUrn = includedByUrn(included);
        const items = included.filter((x) => String(x?.$type || "").endsWith("render.UpdateV2")).map((u) => postRow(u, byUrn)).filter((r) => r.author || r.text);
        return { items, nextCursor: items.length ? String(start + count) : null };
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

  installService("linkedin.com", actions_default);
})();
