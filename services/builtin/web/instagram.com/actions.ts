import type { ActionInstaller } from "../action.ts";
import { cookie } from "../../../action-lib.ts";

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  // Instagram's web client app id — the same constant shipped in Polaris'
  // bundle and required on every /api/v1 call. It identifies the web app, not
  // the user (user auth = sessionid cookie + csrftoken CSRF header), and has
  // been stable for years, so it's safe to bake in.
  //
  // Everything here hits the REST /api/v1 surface rather than /api/graphql:
  // the GraphQL POST endpoints gate on the page's comet session params
  // (fb_dtsg/jazoest/__spin_*/__hs) which can't be replayed without scraping
  // the whole bootstrap blob, whereas /api/v1 only needs the app id + cookies.
  const IG_APP_ID = "936619743392459";
  const ASBD_ID = "359341";

  // csrftoken is a JS-readable cookie on instagram.com (not httpOnly) and is
  // echoed back as the x-csrftoken header on every authed request.
  const requireCsrf = (): string => {
    const t = cookie("csrftoken");
    if (!t) throw new Error("Not signed in to instagram.com (no csrftoken cookie). Sign in first.");
    return t;
  };

  const headers = (post = false): Record<string, string> => {
    const h: Record<string, string> = {
      "x-ig-app-id": IG_APP_ID,
      "x-asbd-id": ASBD_ID,
      "x-csrftoken": requireCsrf(),
      "x-requested-with": "XMLHttpRequest",
    };
    if (post) h["content-type"] = "application/x-www-form-urlencoded";
    return h;
  };

  const stripGuard = (text: string): string => text.replace(/^for\s*\(;;\);/, "");

  const apiCall = async (path: string, init?: RequestInit): Promise<any> => {
    const r = await retryFetch(path, { credentials: "include", ...init });
    const text = stripGuard(await r.text());
    let json: any;
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

  const apiGet = (path: string) => apiCall(path, { headers: headers() });
  const apiPost = (path: string, body: Record<string, string>) =>
    apiCall(path, { method: "POST", headers: headers(true), body: new URLSearchParams(body).toString() });

  // Resolve an Instagram shortcode (the /p/<code>/ token) to its numeric media
  // pk via base64 bignum decode — /api/v1/media/<pk>/ needs the pk.
  const SHORTCODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const shortcodeToPk = (code: string): string => {
    let n = 0n;
    for (const ch of code) {
      const idx = SHORTCODE_ALPHABET.indexOf(ch);
      if (idx < 0) throw new Error(`Invalid shortcode character: ${JSON.stringify(ch)}`);
      n = n * 64n + BigInt(idx);
    }
    return n.toString();
  };

  const parseMediaId = (input: string): string => {
    const s = String(input || "").trim();
    if (/^\d+$/.test(s)) return s;
    const m = s.match(/\/(?:p|reel|reels|tv)\/([A-Za-z0-9_-]+)/) || s.match(/^([A-Za-z0-9_-]{5,})$/);
    if (m) return shortcodeToPk(m[1]);
    throw new Error(`Invalid media id, shortcode, or URL: ${JSON.stringify(input)}`);
  };

  const normalizeUsername = (raw: string | undefined | null): string => {
    const s = String(raw ?? "").trim().replace(/^@+/, "").toLowerCase();
    if (!/^[a-z0-9_.]{1,30}$/.test(s)) {
      throw new Error(`Invalid Instagram username: ${JSON.stringify(raw)}`);
    }
    return s;
  };

  const profileCache: Record<string, any> = {};
  const fetchProfile = async (username: string): Promise<any> => {
    const u = normalizeUsername(username);
    if (profileCache[u]) return profileCache[u];
    const json = await apiGet(`/api/v1/users/web_profile_info/?username=${encodeURIComponent(u)}`);
    const user = json?.data?.user;
    if (!user) throw new Error(`Instagram user @${u} not found`);
    profileCache[u] = user;
    return user;
  };

  // The posts/reels feeds key off the numeric user pk, not the handle.
  const resolveUserId = async (username: string): Promise<string> => {
    const id = (await fetchProfile(username)).id;
    if (!id) throw new Error(`Could not resolve a user id for @${normalizeUsername(username)}`);
    return String(id);
  };

  const bestUrl = (versions: any): string => {
    const c = versions?.candidates;
    return Array.isArray(c) && c.length ? c[0].url : "";
  };

  const mediaRow = (node: any): any => {
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
        is_verified: Boolean(owner?.is_verified),
      },
    };
  };

  const userRow = (u: any): any => ({
    pk: String(u?.pk ?? u?.id ?? ""),
    username: u?.username || "",
    full_name: u?.full_name || "",
    is_verified: Boolean(u?.is_verified),
    profile_pic_url: u?.profile_pic_url || "",
  });

  // Explore's grid nests media unpredictably (one_by_two_item.clips.items[],
  // fill_items[], layout_content.medias[]). Rather than track every layout,
  // walk the tree and collect anything that looks like a media node.
  const collectMedia = (root: any): any[] => {
    const out: any[] = [];
    const seen = new Set<string>();
    const recurse = (v: any) => {
      if (!v || typeof v !== "object") return;
      if (Array.isArray(v)) {
        for (const x of v) recurse(x);
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
      for (const x of Object.values(v)) recurse(x);
    };
    recurse(root);
    return out;
  };

  action("getSignInUrl", { async invoke() { return { url: "https://www.instagram.com/accounts/login/" }; } });

  action("getSignInState", {
    async invoke() {
      // sessionid is httpOnly and unreadable from JS; ds_user_id is set
      // alongside it on login and IS JS-readable, so it's the login signal.
      return { signedIn: Boolean(cookie("ds_user_id")) };
    },
  });

  action("getProfile", {
    async invoke({ username }: { username?: string } = {}) {
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
        url: `https://www.instagram.com/${u.username || ""}/`,
      };
    },
  });

  action("listUserPosts", {
    async invoke({ username, cursor, limit }: { username?: string; cursor?: string; limit?: number } = {}) {
      const id = await resolveUserId(username || "");
      const count = Math.min(Math.max(Number(limit) || 12, 1), 50);
      const qs = new URLSearchParams({ count: String(count) });
      if (cursor) qs.set("max_id", cursor);
      const json = await apiGet(`/api/v1/feed/user/${id}/?${qs.toString()}`);
      return {
        items: (json?.items || []).map(mediaRow),
        nextCursor: json?.more_available ? json?.next_max_id || null : null,
      };
    },
  });

  action("listUserReels", {
    async invoke({ username, cursor, limit }: { username?: string; cursor?: string; limit?: number } = {}) {
      const id = await resolveUserId(username || "");
      const page_size = Math.min(Math.max(Number(limit) || 12, 1), 50);
      const body: Record<string, string> = {
        target_user_id: id,
        page_size: String(page_size),
        include_feed_video: "true",
      };
      if (cursor) body.max_id = cursor;
      const json = await apiPost(`/api/v1/clips/user/`, body);
      return {
        items: (json?.items || []).map(mediaRow),
        nextCursor: json?.paging_info?.more_available ? json?.paging_info?.max_id || null : null,
      };
    },
  });

  action("getPost", {
    async invoke({ id }: { id?: string } = {}) {
      const pk = parseMediaId(id || "");
      const json = await apiGet(`/api/v1/media/${pk}/info/`);
      const item = json?.items?.[0];
      if (!item) throw new Error(`media ${pk} not found`);
      return mediaRow(item);
    },
  });

  action("listPostComments", {
    async invoke({ id, cursor }: { id?: string; cursor?: string } = {}) {
      const pk = parseMediaId(id || "");
      const qs = new URLSearchParams({ can_support_threading: "true", permalink_enabled: "false" });
      if (cursor) qs.set("min_id", cursor);
      const json = await apiGet(`/api/v1/media/${pk}/comments/?${qs.toString()}`);
      return {
        items: (json?.comments || []).map((c: any) => ({
          id: String(c?.pk ?? ""),
          text: c?.text || "",
          username: c?.user?.username || "",
          like_count: Number(c?.comment_like_count) || 0,
          reply_count: Number(c?.child_comment_count) || 0,
          created_at: Number(c?.created_at) || 0,
        })),
        nextCursor: json?.has_more_comments ? json?.next_min_id || null : null,
      };
    },
  });

  action("searchUsers", {
    async invoke({ query }: { query?: string; cursor?: string; limit?: number } = {}) {
      const q = String(query ?? "").trim();
      if (!q) throw new Error("query is required");
      const json = await apiGet(`/api/v1/web/search/topsearch/?context=blended&query=${encodeURIComponent(q)}`);
      return {
        items: (json?.users || []).map((x: any) => userRow(x.user || x)),
        nextCursor: null,
      };
    },
  });

  action("listExplore", {
    async invoke({ cursor }: { cursor?: string; limit?: number } = {}) {
      const qs = new URLSearchParams({
        include_fixed_destinations: "true",
        is_nonpersonalized_explore: "false",
        is_prefetch: "false",
        module: "explore_popular",
        omit_cover_media: "false",
        max_id: cursor || "0",
      });
      const json = await apiGet(`/api/v1/discover/web/explore_grid/?${qs.toString()}`);
      return {
        items: collectMedia(json?.sectional_items || json?.items || []),
        nextCursor: json?.more_available ? json?.next_max_id || null : null,
      };
    },
  });
};

export default install;
