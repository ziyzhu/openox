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

  // services/builtin/web/instagram.com/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const IG_APP_ID = "936619743392459";
    const ASBD_ID = "359341";
    const requireCsrf = () => {
      const t = cookie("csrftoken");
      if (!t)
        throw new Error("Not signed in to instagram.com (no csrftoken cookie). Sign in first.");
      return t;
    };
    const headers = (post = false) => {
      const h = {
        "x-ig-app-id": IG_APP_ID,
        "x-asbd-id": ASBD_ID,
        "x-csrftoken": requireCsrf(),
        "x-requested-with": "XMLHttpRequest"
      };
      if (post)
        h["content-type"] = "application/x-www-form-urlencoded";
      return h;
    };
    const stripGuard = (text) => text.replace(/^for\s*\(;;\);/, "");
    const apiCall = async (path, init) => {
      const r = await retryFetch(path, { credentials: "include", ...init });
      const text = stripGuard(await r.text());
      let json;
      try {
        json = JSON.parse(text);
      } catch {
        throw new Error(`${path}: non-JSON response (HTTP ${r.status}) — session may have expired`);
      }
      if (!r.ok || json?.status === "fail") {
        throw new Error(`${path}: ${json?.message || `HTTP ${r.status}`}`);
      }
      return json;
    };
    const apiGet = (path) => apiCall(path, { headers: headers() });
    const apiPost = (path, body) => apiCall(path, { method: "POST", headers: headers(true), body: new URLSearchParams(body).toString() });
    const SHORTCODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const shortcodeToPk = (code) => {
      let n = 0n;
      for (const ch of code) {
        const idx = SHORTCODE_ALPHABET.indexOf(ch);
        if (idx < 0)
          throw new Error(`Invalid shortcode character: ${JSON.stringify(ch)}`);
        n = n * 64n + BigInt(idx);
      }
      return n.toString();
    };
    const parseMediaId = (input) => {
      const s = String(input || "").trim();
      if (/^\d+$/.test(s))
        return s;
      const m = s.match(/\/(?:p|reel|reels|tv)\/([A-Za-z0-9_-]+)/) || s.match(/^([A-Za-z0-9_-]{5,})$/);
      if (m)
        return shortcodeToPk(m[1]);
      throw new Error(`Invalid media id, shortcode, or URL: ${JSON.stringify(input)}`);
    };
    const normalizeUsername = (raw) => {
      const s = String(raw ?? "").trim().replace(/^@+/, "").toLowerCase();
      if (!/^[a-z0-9_.]{1,30}$/.test(s)) {
        throw new Error(`Invalid Instagram username: ${JSON.stringify(raw)}`);
      }
      return s;
    };
    const profileCache = {};
    const fetchProfile = async (username) => {
      const u = normalizeUsername(username);
      if (profileCache[u])
        return profileCache[u];
      const json = await apiGet(`/api/v1/users/web_profile_info/?username=${encodeURIComponent(u)}`);
      const user = json?.data?.user;
      if (!user)
        throw new Error(`Instagram user @${u} not found`);
      profileCache[u] = user;
      return user;
    };
    const resolveUserId = async (username) => {
      const id = (await fetchProfile(username)).id;
      if (!id)
        throw new Error(`Could not resolve a user id for @${normalizeUsername(username)}`);
      return String(id);
    };
    const bestUrl = (versions) => {
      const c = versions?.candidates;
      return Array.isArray(c) && c.length ? c[0].url : "";
    };
    const mediaRow = (node) => {
      const m = node?.media || node;
      const owner = m?.user || m?.owner || {};
      const videoUrl = Array.isArray(m?.video_versions) && m.video_versions.length ? m.video_versions[0].url : "";
      return {
        id: String(m?.pk ?? m?.id ?? ""),
        code: m?.code || "",
        url: m?.code ? `https://www.instagram.com/p/${m.code}/` : "",
        caption: m?.caption?.text || "",
        taken_at: Number(m?.taken_at) || 0,
        media_type: Number(m?.media_type) || 0,
        product_type: m?.product_type || "",
        is_video: Boolean(videoUrl),
        like_count: Number(m?.like_count) || 0,
        comment_count: Number(m?.comment_count) || 0,
        view_count: Number(m?.play_count ?? m?.view_count) || 0,
        image_url: bestUrl(m?.image_versions2),
        video_url: videoUrl,
        accessibility_caption: m?.accessibility_caption || "",
        owner: {
          pk: String(owner?.pk ?? ""),
          username: owner?.username || "",
          full_name: owner?.full_name || "",
          is_verified: Boolean(owner?.is_verified)
        }
      };
    };
    const userRow = (u) => ({
      pk: String(u?.pk ?? u?.id ?? ""),
      username: u?.username || "",
      full_name: u?.full_name || "",
      is_verified: Boolean(u?.is_verified),
      profile_pic_url: u?.profile_pic_url || ""
    });
    const collectMedia = (root) => {
      const out = [];
      const seen = new Set;
      const recurse = (v) => {
        if (!v || typeof v !== "object")
          return;
        if (Array.isArray(v)) {
          for (const x of v)
            recurse(x);
          return;
        }
        if (v.pk && v.code && v.media_type !== undefined) {
          const id = String(v.pk);
          if (!seen.has(id)) {
            seen.add(id);
            out.push(mediaRow(v));
          }
          return;
        }
        for (const x of Object.values(v))
          recurse(x);
      };
      recurse(root);
      return out;
    };
    action("getSignInUrl", { async invoke() {
      return { url: "https://www.instagram.com/accounts/login/" };
    } });
    action("getSignInState", {
      async invoke() {
        return { signedIn: Boolean(cookie("ds_user_id")) };
      }
    });
    action("getProfile", {
      async invoke({ username } = {}) {
        const u = await fetchProfile(username || "");
        return {
          pk: String(u.id ?? ""),
          username: u.username || "",
          full_name: u.full_name || "",
          biography: u.biography || "",
          is_private: Boolean(u.is_private),
          is_verified: Boolean(u.is_verified),
          is_business: Boolean(u.is_business_account),
          follower_count: Number(u.edge_followed_by?.count) || 0,
          following_count: Number(u.edge_follow?.count) || 0,
          media_count: Number(u.edge_owner_to_timeline_media?.count) || 0,
          category: u.category_name || "",
          external_url: u.external_url || "",
          profile_pic_url: u.profile_pic_url_hd || u.profile_pic_url || "",
          url: `https://www.instagram.com/${u.username || ""}/`
        };
      }
    });
    action("listUserPosts", {
      async invoke({ username, cursor, limit } = {}) {
        const id = await resolveUserId(username || "");
        const count = Math.min(Math.max(Number(limit) || 12, 1), 50);
        const qs = new URLSearchParams({ count: String(count) });
        if (cursor)
          qs.set("max_id", cursor);
        const json = await apiGet(`/api/v1/feed/user/${id}/?${qs.toString()}`);
        return {
          items: (json?.items || []).map(mediaRow),
          nextCursor: json?.more_available ? json?.next_max_id || null : null
        };
      }
    });
    action("listUserReels", {
      async invoke({ username, cursor, limit } = {}) {
        const id = await resolveUserId(username || "");
        const page_size = Math.min(Math.max(Number(limit) || 12, 1), 50);
        const body = {
          target_user_id: id,
          page_size: String(page_size),
          include_feed_video: "true"
        };
        if (cursor)
          body.max_id = cursor;
        const json = await apiPost(`/api/v1/clips/user/`, body);
        return {
          items: (json?.items || []).map(mediaRow),
          nextCursor: json?.paging_info?.more_available ? json?.paging_info?.max_id || null : null
        };
      }
    });
    action("getPost", {
      async invoke({ id } = {}) {
        const pk = parseMediaId(id || "");
        const json = await apiGet(`/api/v1/media/${pk}/info/`);
        const item = json?.items?.[0];
        if (!item)
          throw new Error(`media ${pk} not found`);
        return mediaRow(item);
      }
    });
    action("listPostComments", {
      async invoke({ id, cursor } = {}) {
        const pk = parseMediaId(id || "");
        const qs = new URLSearchParams({ can_support_threading: "true", permalink_enabled: "false" });
        if (cursor)
          qs.set("min_id", cursor);
        const json = await apiGet(`/api/v1/media/${pk}/comments/?${qs.toString()}`);
        return {
          items: (json?.comments || []).map((c) => ({
            id: String(c?.pk ?? ""),
            text: c?.text || "",
            username: c?.user?.username || "",
            like_count: Number(c?.comment_like_count) || 0,
            reply_count: Number(c?.child_comment_count) || 0,
            created_at: Number(c?.created_at) || 0
          })),
          nextCursor: json?.has_more_comments ? json?.next_min_id || null : null
        };
      }
    });
    action("searchUsers", {
      async invoke({ query } = {}) {
        const q = String(query ?? "").trim();
        if (!q)
          throw new Error("query is required");
        const json = await apiGet(`/api/v1/web/search/topsearch/?context=blended&query=${encodeURIComponent(q)}`);
        return {
          items: (json?.users || []).map((x) => userRow(x.user || x)),
          nextCursor: null
        };
      }
    });
    action("listExplore", {
      async invoke({ cursor } = {}) {
        const qs = new URLSearchParams({
          include_fixed_destinations: "true",
          is_nonpersonalized_explore: "false",
          is_prefetch: "false",
          module: "explore_popular",
          omit_cover_media: "false",
          max_id: cursor || "0"
        });
        const json = await apiGet(`/api/v1/discover/web/explore_grid/?${qs.toString()}`);
        return {
          items: collectMedia(json?.sectional_items || json?.items || []),
          nextCursor: json?.more_available ? json?.next_max_id || null : null
        };
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

  installService("instagram.com", actions_default);
})();
