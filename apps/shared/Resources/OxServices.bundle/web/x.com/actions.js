const retryFetch = async (input, init, options) => {
  const retries = options?.retries ?? 3;
  const delay = options?.delay ?? 400;
  const factor = options?.factor ?? 2;
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await window.fetch(input, init);
      const retryable = response.status === 408 || response.status === 429
        || (response.status >= 500 && response.status <= 599);
      if (response.ok || !retryable || attempt >= retries) return response;
      console.log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}`);
    } catch (error) {
      const message = String(error?.message ?? "");
      const retryable = message.includes("Load failed")
        || message.includes("NetworkError")
        || message.includes("Failed to fetch");
      if (!retryable || attempt >= retries) throw error;
      console.log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}`);
    }
    await new Promise(resolve => setTimeout(resolve, delay * Math.pow(factor, attempt)));
  }
};

const extractArticleBody = (articleResults) => {
    const mediaById = new Map();
    const mediaEntities = Array.isArray(articleResults?.media_entities) ? articleResults.media_entities : [];
    for (const media of mediaEntities) {
        const id = String(media?.media_id ?? media?.id ?? "");
        const url = media?.media_info?.original_img_url;
        if (id && typeof url === "string" && url)
            mediaById.set(id, url);
    }
    const entityMap = new Map();
    const entities = articleResults?.content_state?.entityMap;
    const entityEntries = Array.isArray(entities)
        ? entities.map((entry) => [String(entry?.key ?? ""), entry?.value])
        : Object.entries(entities || {});
    for (const [key, value] of entityEntries)
        entityMap.set(key, value);
    const parts = [];
    const media_urls = [];
    let ordered = 0;
    const blocks = Array.isArray(articleResults?.content_state?.blocks) ? articleResults.content_state.blocks : [];
    for (const block of blocks) {
        const type = block?.type || "unstyled";
        if (type === "atomic") {
            for (const range of block?.entityRanges || []) {
                const entity = entityMap.get(String(range?.key ?? ""));
                if (entity?.type !== "MEDIA")
                    continue;
                for (const item of entity?.data?.mediaItems || []) {
                    const url = mediaById.get(String(item?.mediaId ?? ""));
                    if (url)
                        media_urls.push(url);
                }
            }
            continue;
        }
        const text = block?.text || "";
        if (!text)
            continue;
        if (type !== "ordered-list-item")
            ordered = 0;
        if (type === "header-one")
            parts.push("# " + text);
        else if (type === "header-two")
            parts.push("## " + text);
        else if (type === "header-three")
            parts.push("### " + text);
        else if (type === "blockquote")
            parts.push("> " + text);
        else if (type === "unordered-list-item")
            parts.push("- " + text);
        else if (type === "ordered-list-item") {
            ordered++;
            parts.push(ordered + ". " + text);
        }
        else if (type === "code-block")
            parts.push("```\n" + text + "\n```");
        else
            parts.push(text);
    }
    const coverUrl = articleResults?.cover_media?.media_info?.original_img_url;
    return {
        content: parts.join("\n\n"),
        cover_image_url: typeof coverUrl === "string" && coverUrl ? coverUrl : null,
        media_urls,
    };
};
window.ox.install(({ action }) => {
    // X's public app-level bearer for the official web client — the same
    // constant shipped in x.com's own main.<hash>.js, required on every
    // /i/api/graphql call even for cookie-authed sessions. It identifies the
    // app, not the user (user auth = auth_token cookie + ct0 CSRF header), and
    // has been stable since ~2019, so unlike the queryIds below it is safe to
    // bake in rather than scrape from the live bundle.
    const BEARER = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";
    // Every queryId is read live from the current x.com bundle (see
    // `scrapeOperationFromBundle`) — they rotate on each Twitter deploy, so a
    // baked snapshot would silently go stale. These feature sets are the only
    // baked fallback, used when a scraped op module omits its `featureSwitches`.
    const FALLBACK_TWEET_FEATURES = {
        rweb_video_screen_enabled: true,
        rweb_cashtags_enabled: true,
        profile_label_improvements_pcf_label_in_post_enabled: true,
        responsive_web_graphql_timeline_navigation_enabled: true,
        responsive_web_graphql_skip_user_profile_image_extensions_enabled: false,
        creator_subscriptions_tweet_preview_api_enabled: true,
        communities_web_enable_tweet_community_results_fetch: true,
        c9s_tweet_anatomy_moderator_badge_enabled: true,
        articles_preview_enabled: true,
        responsive_web_edit_tweet_api_enabled: true,
        graphql_is_translatable_rweb_tweet_is_translatable_enabled: true,
        view_counts_everywhere_api_enabled: true,
        longform_notetweets_consumption_enabled: true,
        responsive_web_twitter_article_tweet_consumption_enabled: true,
        freedom_of_speech_not_reach_fetch_enabled: true,
        standardized_nudges_misinfo: true,
        tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled: true,
        longform_notetweets_rich_text_read_enabled: true,
        responsive_web_grok_image_annotation_enabled: true,
        responsive_web_grok_imagine_annotation_enabled: true,
        responsive_web_grok_analysis_button_from_backend: true,
        responsive_web_enhance_cards_enabled: false,
        rweb_conversational_replies_downvote_enabled: false,
    };
    const FALLBACK_USER_FEATURES = {
        hidden_profile_subscriptions_enabled: true,
        profile_label_improvements_pcf_label_in_post_enabled: true,
        responsive_web_graphql_exclude_directive_enabled: true,
        verified_phone_label_enabled: false,
        subscriptions_verification_info_is_identity_verified_enabled: true,
        subscriptions_verification_info_verified_since_enabled: true,
        highlights_tweets_tab_ui_enabled: true,
        responsive_web_twitter_article_notes_tab_enabled: true,
        subscriptions_feature_can_gift_premium: true,
        creator_subscriptions_tweet_preview_api_enabled: true,
        responsive_web_graphql_skip_user_profile_image_extensions_enabled: false,
        responsive_web_graphql_timeline_navigation_enabled: true,
    };
    const opCache = {};
    const quotedKeys = (raw) => raw ? Array.from(raw.matchAll(/"([^"]+)"/g)).map((m) => m[1]) : [];
    const keysToFlags = (keys) => Object.fromEntries(keys.map((k) => [k, true]));
    // Every op is emitted into the bundle as a webpack module of the shape
    // {queryId:"..",operationName:"..",operationType:"..",metadata:{
    // featureSwitches:[..],fieldToggles:[..]}}. One pass harvests them all, so a
    // single fetch of main.<hash>.js (which carries ~150 ops) resolves nearly
    // everything in one shot and the rest come from their named lazy chunks.
    const OP_MODULE_RE = /queryId:"([A-Za-z0-9_-]+)",operationName:"([A-Za-z0-9_]+)",operationType:"\w+",metadata:\{featureSwitches:\[([^\]]*)\],fieldToggles:\[([^\]]*)\]\}/g;
    const harvestOps = (text) => {
        let m;
        let count = 0;
        OP_MODULE_RE.lastIndex = 0;
        while ((m = OP_MODULE_RE.exec(text))) {
            const [, queryId, name, feats, toggles] = m;
            if (opCache[name])
                continue;
            opCache[name] = {
                queryId,
                features: keysToFlags(quotedKeys(feats)),
                fieldToggles: keysToFlags(quotedKeys(toggles)),
            };
            count++;
        }
        return count;
    };
    // The service worker precaches every split chunk, so /sw.js is the
    // authoritative manifest of the current build — it lists chunks the page
    // hasn't lazily loaded (Bookmarks/Notifications) which document.scripts and
    // resource timing miss. Fetched once per service lifetime.
    let manifestUrls = null;
    const fetchManifestUrls = async () => {
        if (manifestUrls)
            return manifestUrls;
        try {
            const sw = await (await fetch("/sw.js")).text();
            manifestUrls = Array.from(new Set(Array.from(sw.matchAll(/https?:\/\/\S*?client-web\/[A-Za-z0-9_~.-]+\.js/g)).map((m) => m[0])));
        }
        catch {
            manifestUrls = [];
        }
        return manifestUrls;
    };
    // main.<hash>.js carries ~150 ops; the rest live in lazily-split chunks.
    // Rank so the entry bundle is scanned first, then chunks whose filename
    // hints at the operation, then the timeline loaders/shared chunks where
    // queries like Bookmarks hide (clustered in *card*/*timeline* loaders), then
    // everything else — so even the worst-case op is found in a few batches.
    const rankFor = (url, opHint) => {
        const file = (url.split("/").pop() || "").toLowerCase();
        if (/^main\.[0-9a-f]+\.js$/.test(file))
            return 0;
        if (opHint && file.includes(opHint))
            return 1;
        if (/^(loader|shared~).*(card|timeline)/.test(file))
            return 2;
        if (/^(loader|shared~|bundle)\./.test(file))
            return 3;
        return 4;
    };
    const candidateScripts = (operationName, manifest) => {
        const opHint = operationName.toLowerCase().replace(/timeline$/, "");
        const dom = Array.from(document.querySelectorAll("script[src]"))
            .map((s) => s.src);
        const timing = performance.getEntriesByType("resource")
            .map((r) => r.name);
        return Array.from(new Set([...dom, ...timing, ...manifest].filter((u) => u && u.endsWith(".js"))))
            .sort((a, b) => rankFor(a, opHint) - rankFor(b, opHint));
    };
    const scrapeOperationFromBundle = async (operationName) => {
        const urls = candidateScripts(operationName, await fetchManifestUrls());
        const BATCH = 8;
        for (let i = 0; i < urls.length && !opCache[operationName]; i += BATCH) {
            const texts = await Promise.all(urls.slice(i, i + BATCH).map(async (url) => {
                try {
                    return await (await fetch(url)).text();
                }
                catch {
                    return "";
                }
            }));
            for (const text of texts)
                if (text.includes('operationName:"'))
                    harvestOps(text);
        }
        const hit = opCache[operationName];
        if (hit)
            console.log(`x.com: scraped ${operationName}=${hit.queryId} from live bundle`);
        return hit ?? null;
    };
    const resolveOperation = async (operationName, baselineFeatures) => {
        if (opCache[operationName])
            return opCache[operationName];
        const found = await scrapeOperationFromBundle(operationName);
        if (!found)
            throw new Error(`x.com: could not resolve a live queryId for ${operationName} from the bundle`);
        const features = Object.keys(found.features).length > 0 ? found.features : baselineFeatures;
        const op = { queryId: found.queryId, features, fieldToggles: found.fieldToggles };
        opCache[operationName] = op;
        return op;
    };
    const resolveTweetOp = (op) => resolveOperation(op, FALLBACK_TWEET_FEATURES);
    const resolveUserOp = (op) => resolveOperation(op, FALLBACK_USER_FEATURES);
    const getCt0 = () => {
        const m = document.cookie.match(/(?:^|;\s*)ct0=([^;]+)/);
        return m ? decodeURIComponent(m[1]) : null;
    };
    const authHeaders = (ct0, post = false) => {
        const h = {
            Authorization: "Bearer " + decodeURIComponent(BEARER),
            "X-Csrf-Token": ct0,
            "X-Twitter-Auth-Type": "OAuth2Session",
            "X-Twitter-Active-User": "yes",
            "X-Twitter-Client-Language": (navigator.language || "en").split("-")[0] || "en",
        };
        if (post)
            h["Content-Type"] = "application/json";
        return h;
    };
    const requireCt0 = () => {
        const ct0 = getCt0();
        if (!ct0)
            throw new Error("Not signed in to x.com (no ct0 cookie). Sign in first.");
        return ct0;
    };
    const normalizeHandle = (raw) => {
        const s = String(raw ?? "").trim().replace(/^@+/, "");
        if (!s)
            return "";
        if (!/^[A-Za-z0-9_]{1,15}$/.test(s)) {
            throw new Error(`Invalid X handle: ${JSON.stringify(raw)} (expected 1-15 letters/digits/underscore)`);
        }
        return s;
    };
    const parseTweetId = (input) => {
        const s = String(input || "").trim();
        if (/^\d+$/.test(s))
            return s;
        const m = s.match(/\/(?:status|article)\/(\d+)/);
        if (m)
            return m[1];
        throw new Error(`Invalid tweet id or URL: ${JSON.stringify(input)}`);
    };
    const fetchOwnHandle = async () => {
        const ct0 = getCt0();
        if (!ct0)
            return null;
        try {
            const op = await resolveUserOp("Viewer");
            const d = await graphqlGet(op, "Viewer", { withCommunitiesMemberships: true }, ct0);
            if (d?.__http_error) {
                console.log(`fetchOwnHandle: Viewer HTTP ${d.__http_error}`);
                return null;
            }
            const u = d?.data?.viewer?.user_results?.result;
            const handle = u?.legacy?.screen_name || u?.core?.screen_name || "";
            return handle || null;
        }
        catch (e) {
            console.log("fetchOwnHandle: " + (e?.message ?? String(e)));
            return null;
        }
    };
    const extractMedia = (legacy) => {
        const media = legacy?.extended_entities?.media || legacy?.entities?.media;
        if (!Array.isArray(media) || media.length === 0)
            return { has_media: false, media_urls: [] };
        const urls = [];
        for (const m of media) {
            if (!m)
                continue;
            if (m.type === "video" || m.type === "animated_gif") {
                const variants = m.video_info?.variants || [];
                const mp4 = variants.find((v) => v?.content_type === "video/mp4");
                const url = mp4?.url || m.media_url_https;
                if (url)
                    urls.push(url);
            }
            else if (m.media_url_https) {
                urls.push(m.media_url_https);
            }
        }
        return { has_media: urls.length > 0, media_urls: urls };
    };
    const extractCard = (tweet) => {
        const cardLegacy = tweet?.card?.legacy;
        if (!cardLegacy)
            return null;
        const bindings = Array.isArray(cardLegacy.binding_values) ? cardLegacy.binding_values : [];
        const byKey = new Map();
        for (const b of bindings) {
            if (b && typeof b.key === "string")
                byKey.set(b.key, b.value);
        }
        const str = (key) => {
            const v = byKey.get(key);
            return typeof v?.string_value === "string" && v.string_value.length > 0 ? v.string_value : null;
        };
        const img = (key) => {
            const v = byKey.get(key);
            const u = v?.image_value?.url;
            return typeof u === "string" && u.length > 0 ? u : null;
        };
        const title = str("title");
        const description = str("description");
        const domainBinding = str("domain");
        const cardUrlBinding = str("card_url");
        const image_url = img("thumbnail_image_large") || img("photo_image_full_size_large") || img("summary_photo_image_large");
        const urlEntities = Array.isArray(tweet?.legacy?.entities?.urls) ? tweet.legacy.entities.urls : [];
        const matched = cardUrlBinding
            ? urlEntities.find((e) => e?.url === cardUrlBinding || e?.expanded_url === cardUrlBinding)
            : undefined;
        const url = (typeof matched?.expanded_url === "string" && matched.expanded_url) || cardUrlBinding;
        let domain = domainBinding;
        if (!domain && url) {
            try {
                domain = new URL(url).hostname;
            }
            catch { }
        }
        if (!url && !title && !description)
            return null;
        return {
            name: cardLegacy.name,
            title: title,
            description: description,
            image_url: image_url,
            url: url,
            domain: domain,
        };
    };
    const extractQuotedTweet = (tweet) => {
        const legacy = tweet?.legacy;
        if (!legacy?.is_quote_status)
            return null;
        const q = tweet?.quoted_status_result?.result ?? tweet?.legacy?.quoted_status_result?.result;
        if (!q)
            return null;
        const qTw = q.tweet || q;
        if (!qTw || typeof qTw !== "object")
            return null;
        const qLegacy = qTw.legacy && typeof qTw.legacy === "object" ? qTw.legacy : {};
        if (typeof qTw.rest_id !== "string" || !qTw.rest_id.trim())
            return null;
        const qUser = qTw.core?.user_results?.result;
        const qScreen = qUser?.legacy?.screen_name?.trim?.() ||
            qUser?.core?.screen_name?.trim?.() ||
            "";
        if (!qScreen || !/^[A-Za-z0-9_]{1,15}$/.test(qScreen))
            return null;
        const qName = qUser?.legacy?.name || qUser?.core?.name || "";
        const qNoteText = qTw.note_tweet?.note_tweet_results?.result?.text;
        const qText = (typeof qNoteText === "string" && qNoteText) || qLegacy.full_text || "";
        const qMedia = extractMedia(qLegacy);
        return {
            id: qTw.rest_id,
            author: qScreen,
            name: qName,
            text: qText,
            created_at: qLegacy.created_at || "",
            url: `https://x.com/${qScreen}/status/${qTw.rest_id}`,
            has_media: qMedia.has_media,
            media_urls: qMedia.media_urls,
        };
    };
    const tweetRow = (result, seen) => {
        if (!result)
            return null;
        const tw = result.__typename === "TweetWithVisibilityResults" && result.tweet ? result.tweet : (result.tweet || result);
        const legacy = tw.legacy || {};
        if (!tw.rest_id || seen.has(tw.rest_id))
            return null;
        seen.add(tw.rest_id);
        const user = tw.core?.user_results?.result;
        const screen = user?.legacy?.screen_name || user?.core?.screen_name || "unknown";
        const name = user?.legacy?.name || user?.core?.name || "";
        const noteText = tw.note_tweet?.note_tweet_results?.result?.text;
        const isRT = Boolean(legacy.retweeted_status_result || (typeof legacy.full_text === "string" && legacy.full_text.startsWith("RT @")));
        const media = extractMedia(legacy);
        return {
            id: tw.rest_id,
            author: screen,
            name,
            text: noteText || legacy.full_text || "",
            likes: Number(legacy.favorite_count) || 0,
            retweets: Number(legacy.retweet_count) || 0,
            replies: Number(legacy.reply_count) || 0,
            views: Number(tw.views?.count) || 0,
            is_retweet: isRT,
            created_at: legacy.created_at || "",
            url: `https://x.com/${screen}/status/${tw.rest_id}`,
            has_media: media.has_media,
            media_urls: media.media_urls,
            card: extractCard(tw),
            quoted_tweet: extractQuotedTweet(tw),
        };
    };
    const walkInstructions = (instructions, visit) => {
        let nextCursor = null;
        const recurse = (value) => {
            if (!value || typeof value !== "object")
                return;
            if (value.type === "TimelinePinEntry")
                return;
            if ((value.entryType === "TimelineTimelineCursor" || value.__typename === "TimelineTimelineCursor") &&
                (value.cursorType === "Bottom" || value.cursorType === "ShowMore") &&
                value.value) {
                nextCursor = value.value;
            }
            visit(value);
            if (Array.isArray(value)) {
                for (const v of value)
                    recurse(v);
                return;
            }
            for (const child of Object.values(value))
                if (child && typeof child === "object")
                    recurse(child);
        };
        recurse(instructions);
        return { nextCursor };
    };
    const buildGraphqlUrl = (queryId, operation, variables, features, fieldToggles) => {
        const parts = [`variables=${encodeURIComponent(JSON.stringify(variables))}`];
        if (features && Object.keys(features).length > 0) {
            parts.push(`features=${encodeURIComponent(JSON.stringify(features))}`);
        }
        if (fieldToggles && Object.keys(fieldToggles).length > 0) {
            parts.push(`fieldToggles=${encodeURIComponent(JSON.stringify(fieldToggles))}`);
        }
        return `/i/api/graphql/${queryId}/${operation}?${parts.join("&")}`;
    };
    const fetchJson = async (url, init) => {
        const r = await fetch(url, init);
        if (!r.ok)
            return { __http_error: r.status };
        return r.json();
    };
    const graphqlGet = (op, operation, variables, ct0) => fetchJson(buildGraphqlUrl(op.queryId, operation, variables, op.features, op.fieldToggles), {
        headers: authHeaders(ct0),
        credentials: "include",
    });
    const graphqlPost = (op, operation, variables, ct0) => fetchJson(`/i/api/graphql/${op.queryId}/${operation}`, {
        method: "POST",
        headers: authHeaders(ct0, true),
        credentials: "include",
        body: JSON.stringify({ variables, features: op.features, queryId: op.queryId, ...(Object.keys(op.fieldToggles).length ? { fieldToggles: op.fieldToggles } : {}) }),
    });
    const lookupUserId = async (screen, ct0) => {
        const op = await resolveUserOp("UserByScreenName");
        const d = await graphqlGet(op, "UserByScreenName", { screen_name: screen, withSafetyModeUserFields: true }, ct0);
        if (d?.__http_error)
            throw new Error(`UserByScreenName HTTP ${d.__http_error} for @${screen} (queryId may be stale)`);
        const id = d?.data?.user?.result?.rest_id;
        if (!id)
            throw new Error(`X user @${screen} not found`);
        return String(id);
    };
    const resolveTargetHandle = async (input) => {
        const h = normalizeHandle(input);
        if (h)
            return h;
        const own = await fetchOwnHandle();
        if (!own)
            throw new Error("Could not detect logged-in x.com user (no AppTabBar handle in /home)");
        return own;
    };
    action("getSignInUrl", { async invoke() { return { url: "https://x.com/i/flow/login" }; } });
    action("getSignInState", {
        async invoke() {
            const ct0 = getCt0();
            if (!ct0)
                return { signedIn: false };
            const own = await fetchOwnHandle();
            return { signedIn: !!own };
        },
    });
    action("getProfile", {
        async invoke({ username } = {}) {
            const ct0 = requireCt0();
            const screen = await resolveTargetHandle(username);
            const op = await resolveUserOp("UserByScreenName");
            const d = await graphqlGet(op, "UserByScreenName", { screen_name: screen, withSafetyModeUserFields: true }, ct0);
            if (d?.__http_error)
                throw new Error(`getProfile HTTP ${d.__http_error} for @${screen} (queryId may be stale)`);
            const result = d?.data?.user?.result;
            if (!result)
                throw new Error(`X user @${screen} not found`);
            const legacy = result.legacy || {};
            const core = result.core || {};
            const expanded = legacy.entities?.url?.urls?.[0]?.expanded_url || "";
            return {
                screen_name: core.screen_name || legacy.screen_name || screen,
                name: core.name || legacy.name || "",
                bio: legacy.description || "",
                location: legacy.location || "",
                url: expanded,
                followers: Number(legacy.followers_count) || 0,
                following: Number(legacy.friends_count) || 0,
                tweets: Number(legacy.statuses_count) || 0,
                likes: Number(legacy.favourites_count) || 0,
                verified: Boolean(result.is_blue_verified || legacy.verified),
                created_at: legacy.created_at || "",
            };
        },
    });
    action("getTweet", {
        async invoke({ tweetId }) {
            const ct0 = requireCt0();
            const id = parseTweetId(tweetId);
            const op = await resolveTweetOp("TweetResultByRestId");
            const vars = { tweetId: id, withCommunity: true, includePromotedContent: false, withVoice: true };
            const data = await graphqlGet(op, "TweetResultByRestId", vars, ct0);
            if (data?.__http_error)
                throw new Error(`getTweet HTTP ${data.__http_error} for post ${id} (not found or queryId stale)`);
            const result = data?.data?.tweetResult?.result;
            if (!result)
                throw new Error(`getTweet: post ${id} not found`);
            const row = tweetRow(result, new Set());
            if (!row)
                throw new Error(`getTweet: post ${id} could not be parsed`);
            return row;
        },
    });
    const collectTweets = async (startCursor, limit, fetchPage, selectInstructions, errLabel) => {
        const rows = [];
        const seen = new Set();
        let cursor = startCursor;
        let lastCursor = null;
        for (let page = 0; page < 20 && rows.length < limit; page++) {
            const count = Math.min(100, limit - rows.length + 10);
            const data = await fetchPage(cursor, count);
            if (data?.__http_error) {
                if (rows.length === 0)
                    throw new Error(`${errLabel}: HTTP ${data.__http_error} (queryId may be stale)`);
                break;
            }
            const instructions = selectInstructions(data) || [];
            const beforeLen = rows.length;
            const { nextCursor } = walkInstructions(instructions, (n) => {
                if (n.tweet_results?.result) {
                    const row = tweetRow(n.tweet_results.result, seen);
                    if (row)
                        rows.push(row);
                }
            });
            lastCursor = nextCursor;
            if (rows.length === beforeLen)
                break;
            if (!nextCursor || nextCursor === cursor)
                break;
            cursor = nextCursor;
        }
        return { items: rows.slice(0, limit), nextCursor: rows.length >= limit ? lastCursor : null };
    };
    action("listTweets", {
        async invoke({ username, cursor: startCursor, limit = 20 } = {}) {
            const ct0 = requireCt0();
            const screen = await resolveTargetHandle(username);
            const userId = await lookupUserId(screen, ct0);
            const op = await resolveTweetOp("UserTweets");
            return await collectTweets(startCursor ?? null, limit, (cursor, count) => {
                const vars = { userId, count, includePromotedContent: false, withQuickPromoteEligibilityTweetFields: true, withVoice: true };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlGet(op, "UserTweets", vars, ct0);
            }, (d) => d?.data?.user?.result?.timeline_v2?.timeline?.instructions ||
                d?.data?.user?.result?.timeline?.timeline?.instructions ||
                [], `listTweets @${screen}`);
        },
    });
    const listUserTimeline = async (operation, username, startCursor, limit) => {
        const ct0 = requireCt0();
        const screen = await resolveTargetHandle(username);
        const userId = await lookupUserId(screen, ct0);
        const op = await resolveTweetOp(operation);
        return await collectTweets(startCursor ?? null, limit, (cursor, count) => {
            const vars = { userId, count, includePromotedContent: false, withCommunity: true, withClientEventToken: false, withBirdwatchNotes: false, withVoice: true };
            if (cursor)
                vars.cursor = cursor;
            return graphqlGet(op, operation, vars, ct0);
        }, (d) => d?.data?.user?.result?.timeline_v2?.timeline?.instructions ||
            d?.data?.user?.result?.timeline?.timeline?.instructions ||
            [], `${operation} @${screen}`);
    };
    action("listUserReplies", {
        async invoke({ username, cursor: startCursor, limit = 20 } = {}) {
            return await listUserTimeline("UserRepliesTimeline", username, startCursor, limit);
        },
    });
    action("listUserMedia", {
        async invoke({ username, cursor: startCursor, limit = 20 } = {}) {
            return await listUserTimeline("UserVideoTimeline", username, startCursor, limit);
        },
    });
    action("searchTweets", {
        async invoke({ query, product = "top", from, has, exclude, cursor: startCursor, limit = 15 }) {
            const ct0 = requireCt0();
            const parts = [String(query || "").trim()];
            if (from)
                parts.push(`from:${normalizeHandle(from)}`);
            if (has)
                parts.push(`filter:${has}`);
            if (exclude) {
                const map = {
                    replies: "-filter:replies",
                    retweets: "-filter:nativeretweets",
                    media: "-filter:media",
                    links: "-filter:links",
                };
                if (map[exclude])
                    parts.push(map[exclude]);
            }
            const rawQuery = parts.filter(Boolean).join(" ");
            if (!rawQuery)
                throw new Error("searchTweets: empty query");
            const productMap = { top: "Top", live: "Latest", photos: "Photos", videos: "Videos" };
            const gqlProduct = productMap[product] || "Top";
            const op = await resolveTweetOp("SearchTimeline");
            return await collectTweets(startCursor ?? null, limit, (cursor, count) => {
                const vars = {
                    rawQuery,
                    count,
                    querySource: "typed_query",
                    product: gqlProduct,
                    withGrokTranslatedBio: true,
                    withQuickPromoteEligibilityTweetFields: false,
                };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlPost(op, "SearchTimeline", vars, ct0);
            }, (d) => d?.data?.search_by_raw_query?.search_timeline?.timeline?.instructions || [], `searchTweets ${JSON.stringify(rawQuery)}`);
        },
    });
    action("listTimeline", {
        async invoke({ type = "for-you", cursor: startCursor, limit = 20 } = {}) {
            const ct0 = requireCt0();
            const isFollowing = type === "following";
            const operation = isFollowing ? "HomeLatestTimeline" : "HomeTimeline";
            const op = await resolveTweetOp(operation);
            return await collectTweets(startCursor ?? null, limit, (cursor, count) => {
                const vars = {
                    count,
                    includePromotedContent: false,
                    requestContext: "launch",
                    withCommunity: true,
                    seenTweetIds: [],
                };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlPost(op, operation, vars, ct0);
            }, (d) => d?.data?.home?.home_timeline_urt?.instructions || [], `listTimeline ${type}`);
        },
    });
    action("listThread", {
        async invoke({ tweetId, cursor: startCursor, limit = 50 }) {
            const ct0 = requireCt0();
            const id = parseTweetId(tweetId);
            const op = await resolveTweetOp("TweetDetail");
            const rows = [];
            const seen = new Set();
            let cursor = startCursor ?? null;
            let lastCursor = null;
            for (let pageNum = 0; pageNum < 5 && rows.length < limit; pageNum++) {
                const vars = {
                    focalTweetId: id,
                    referrer: "tweet",
                    with_rux_injections: false,
                    includePromotedContent: false,
                    rankingMode: "Recency",
                    withCommunity: true,
                    withQuickPromoteEligibilityTweetFields: true,
                    withBirdwatchNotes: true,
                    withVoice: true,
                };
                if (cursor)
                    vars.cursor = cursor;
                const data = await graphqlGet(op, "TweetDetail", vars, ct0);
                if (data?.__http_error) {
                    if (rows.length === 0)
                        throw new Error(`listThread HTTP ${data.__http_error} for tweet ${id} (not found or queryId stale)`);
                    break;
                }
                const instructions = data?.data?.threaded_conversation_with_injections_v2?.instructions ||
                    data?.data?.tweetResult?.result?.timeline?.instructions ||
                    [];
                const before = rows.length;
                const { nextCursor } = walkInstructions(instructions, (n) => {
                    const result = n.tweet_results?.result;
                    if (!result)
                        return;
                    const tw = result.tweet || result;
                    const legacy = tw.legacy || {};
                    if (!tw.rest_id || seen.has(tw.rest_id))
                        return;
                    seen.add(tw.rest_id);
                    const u = tw.core?.user_results?.result;
                    const screen = u?.legacy?.screen_name || u?.core?.screen_name || "unknown";
                    const name = u?.legacy?.name || u?.core?.name || "";
                    const noteText = tw.note_tweet?.note_tweet_results?.result?.text;
                    const media = extractMedia(legacy);
                    rows.push({
                        id: tw.rest_id,
                        author: screen,
                        name,
                        text: noteText || legacy.full_text || "",
                        likes: Number(legacy.favorite_count) || 0,
                        retweets: Number(legacy.retweet_count) || 0,
                        replies: Number(legacy.reply_count) || 0,
                        in_reply_to: legacy.in_reply_to_status_id_str || null,
                        created_at: legacy.created_at || "",
                        url: `https://x.com/${screen}/status/${tw.rest_id}`,
                        has_media: media.has_media,
                        media_urls: media.media_urls,
                        card: extractCard(tw),
                        quoted_tweet: extractQuotedTweet(tw),
                    });
                });
                lastCursor = nextCursor;
                if (rows.length === before)
                    break;
                if (!nextCursor || nextCursor === cursor)
                    break;
                cursor = nextCursor;
            }
            return { items: rows.slice(0, limit), nextCursor: rows.length >= limit ? lastCursor : null };
        },
    });
    action("listTrending", {
        async invoke() {
            try {
                const ct0 = requireCt0();
                const op = await resolveTweetOp("ExplorePage");
                const data = await graphqlGet(op, "ExplorePage", { cursor: "" }, ct0);
                if (data?.__http_error) {
                    throw new Error(`ExplorePage HTTP ${data.__http_error} (queryId may be stale)`);
                }
                const instructions = data?.data?.explore_page?.body?.initialTimeline?.timeline?.timeline?.instructions ?? [];
                const trends = [];
                for (const ins of instructions) {
                    for (const ent of ins?.entries ?? []) {
                        const entryId = ent?.entryId ?? "";
                        // Top-of-page story cells are not trends; skip them and promos.
                        if (!entryId.startsWith("trend-"))
                            continue;
                        const ic = ent?.content?.itemContent;
                        const topic = (ic?.name ?? "").toString().trim();
                        if (!topic)
                            continue;
                        const category = (ic?.trend_metadata?.domain_context ?? "").toString().trim();
                        trends.push({ rank: trends.length + 1, topic, category });
                    }
                }
                return { items: trends, nextCursor: null };
            }
            catch (e) {
                console.log("listTrending: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("listBookmarks", {
        async invoke({ cursor: startCursor, limit = 20 } = {}) {
            const ct0 = requireCt0();
            const op = await resolveTweetOp("Bookmarks");
            return await collectTweets(startCursor ?? null, limit, (cursor, count) => {
                const vars = { count, includePromotedContent: false };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlGet(op, "Bookmarks", vars, ct0);
            }, (d) => d?.data?.bookmark_timeline_v2?.timeline?.instructions ||
                d?.data?.bookmark_timeline?.timeline?.instructions ||
                [], "listBookmarks");
        },
    });
    action("listLikes", {
        async invoke({ username, cursor: startCursor, limit = 20 } = {}) {
            const ct0 = requireCt0();
            const screen = await resolveTargetHandle(username);
            const userId = await lookupUserId(screen, ct0);
            const op = await resolveTweetOp("Likes");
            return await collectTweets(startCursor ?? null, limit, (cursor, count) => {
                const vars = { userId, count, includePromotedContent: false, withClientEventToken: false, withBirdwatchNotes: false, withVoice: true };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlGet(op, "Likes", vars, ct0);
            }, (d) => d?.data?.user?.result?.timeline_v2?.timeline?.instructions ||
                d?.data?.user?.result?.timeline?.timeline?.instructions ||
                [], `listLikes @${screen}`);
        },
    });
    const userRow = (result) => {
        if (!result || result.__typename !== "User")
            return null;
        const core = result.core || {};
        const legacy = result.legacy || {};
        return {
            screen_name: core.screen_name || legacy.screen_name || "unknown",
            name: core.name || legacy.name || "",
            bio: legacy.description || result.profile_bio?.description || "",
            followers: Number(legacy.followers_count || legacy.normal_followers_count) || null,
        };
    };
    const collectUsers = async (startCursor, limit, fetchPage, errLabel, selectInstructions) => {
        const rows = [];
        const seen = new Set();
        let cursor = startCursor;
        let lastCursor = null;
        for (let page = 0; page < 20 && rows.length < limit; page++) {
            const count = Math.min(50, limit - rows.length + 10);
            const data = await fetchPage(cursor, count);
            if (data?.__http_error) {
                if (rows.length === 0)
                    throw new Error(`${errLabel}: HTTP ${data.__http_error} (queryId may be stale or list private)`);
                break;
            }
            const instructions = selectInstructions ? (selectInstructions(data) || []) : (
                data?.data?.user?.result?.timeline_v2?.timeline?.instructions ||
                data?.data?.user?.result?.timeline?.timeline?.instructions ||
                []);
            const before = rows.length;
            const { nextCursor } = walkInstructions(instructions, (n) => {
                if (n.user_results?.result) {
                    const u = userRow(n.user_results.result);
                    if (u && !seen.has(u.screen_name)) {
                        seen.add(u.screen_name);
                        rows.push(u);
                    }
                }
            });
            lastCursor = nextCursor;
            if (rows.length === before)
                break;
            if (!nextCursor || nextCursor === cursor)
                break;
            cursor = nextCursor;
        }
        return { items: rows.slice(0, limit), nextCursor: rows.length >= limit ? lastCursor : null };
    };
    action("listVerifiedFollowers", {
        async invoke({ username, cursor: startCursor, limit = 50 } = {}) {
            const ct0 = requireCt0();
            const screen = await resolveTargetHandle(username);
            const userId = await lookupUserId(screen, ct0);
            const op = await resolveTweetOp("BlueVerifiedFollowers");
            return await collectUsers(startCursor ?? null, limit, (cursor, count) => {
                const vars = { userId, count, includePromotedContent: false };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlGet(op, "BlueVerifiedFollowers", vars, ct0);
            }, `listVerifiedFollowers @${screen}`);
        },
    });
    action("listFollowers", {
        async invoke({ username, cursor: startCursor, limit = 50 } = {}) {
            const ct0 = requireCt0();
            const screen = await resolveTargetHandle(username);
            const userId = await lookupUserId(screen, ct0);
            const op = await resolveTweetOp("Followers");
            return await collectUsers(startCursor ?? null, limit, (cursor, count) => {
                const vars = { userId, count, includePromotedContent: false, withGrokTranslatedBio: true };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlPost(op, "Followers", vars, ct0);
            }, `listFollowers @${screen}`);
        },
    });
    action("listFollowing", {
        async invoke({ username, cursor: startCursor, limit = 50 } = {}) {
            const ct0 = requireCt0();
            const screen = await resolveTargetHandle(username);
            const userId = await lookupUserId(screen, ct0);
            const op = await resolveTweetOp("Following");
            return await collectUsers(startCursor ?? null, limit, (cursor, count) => {
                const vars = { userId, count, includePromotedContent: false, withClientEventToken: false, withBirdwatchNotes: false, withVoice: true, withV2Timeline: true };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlGet(op, "Following", vars, ct0);
            }, `listFollowing @${screen}`);
        },
    });
    action("searchUsers", {
        async invoke({ query, cursor: startCursor, limit = 20 }) {
            const ct0 = requireCt0();
            const rawQuery = String(query || "").trim();
            if (!rawQuery)
                throw new Error("searchUsers: empty query");
            const op = await resolveTweetOp("SearchTimeline");
            return await collectUsers(startCursor ?? null, limit, (cursor, count) => {
                const vars = { rawQuery, count, querySource: "typed_query", product: "People", withGrokTranslatedBio: true, withQuickPromoteEligibilityTweetFields: false };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlPost(op, "SearchTimeline", vars, ct0);
            }, `searchUsers ${JSON.stringify(rawQuery)}`, (d) => d?.data?.search_by_raw_query?.search_timeline?.timeline?.instructions || []);
        },
    });
    action("listNotifications", {
        async invoke({ cursor: startCursor, limit = 20 } = {}) {
            const ct0 = requireCt0();
            const op = await resolveTweetOp("NotificationsTimeline");
            const vars = { count: Math.min(100, Math.max(20, limit + 10)), includePromotedContent: false };
            if (startCursor)
                vars.cursor = startCursor;
            const data = await graphqlGet(op, "NotificationsTimeline", vars, ct0);
            if (data?.__http_error)
                throw new Error(`listNotifications HTTP ${data.__http_error} (queryId may be stale)`);
            const instructions = data?.data?.viewer?.notification_all_list?.timeline?.instructions ||
                data?.data?.viewer?.timeline_response?.timeline?.instructions ||
                data?.data?.viewer_v2?.user_results?.result?.notification_timeline?.timeline?.instructions ||
                data?.data?.timeline?.instructions ||
                [];
            const out = [];
            const seen = new Set();
            const processItem = (itemContent, entryId) => {
                if (!itemContent)
                    return;
                const item = itemContent?.notification_results?.result || itemContent?.tweet_results?.result || itemContent;
                let actionText = "Notification";
                let author = "unknown";
                let text = "";
                let urlStr = "";
                if (item.__typename === "TimelineNotification") {
                    text = item.rich_message?.text || item.message?.text || "";
                    const from = item.template?.from_users?.[0]?.user_results?.result;
                    author = from?.core?.screen_name || from?.legacy?.screen_name || "unknown";
                    urlStr = item.notification_url?.url || "";
                    actionText = item.notification_icon || "Activity";
                    const target = item.template?.target_objects?.[0]?.tweet_results?.result;
                    if (target) {
                        const tt = target.note_tweet?.note_tweet_results?.result?.text || target.legacy?.full_text || "";
                        text += text && tt ? " | " + tt : tt;
                        if (!urlStr)
                            urlStr = `https://x.com/i/status/${target.rest_id}`;
                    }
                }
                else if (item.__typename === "TweetNotification") {
                    const tw = item.tweet_result?.result;
                    const u = tw?.core?.user_results?.result;
                    author = u?.core?.screen_name || u?.legacy?.screen_name || "unknown";
                    text = tw?.note_tweet?.note_tweet_results?.result?.text || tw?.legacy?.full_text || item.message?.text || "";
                    actionText = "Mention/Reply";
                    urlStr = `https://x.com/i/status/${tw?.rest_id}`;
                }
                else if (item.__typename === "Tweet") {
                    const u = item.core?.user_results?.result;
                    author = u?.core?.screen_name || u?.legacy?.screen_name || "unknown";
                    text = item.note_tweet?.note_tweet_results?.result?.text || item.legacy?.full_text || "";
                    actionText = "Mention";
                    urlStr = `https://x.com/i/status/${item.rest_id}`;
                }
                const id = String(item.id || item.rest_id || entryId);
                if (seen.has(id))
                    return;
                seen.add(id);
                out.push({ id, action: actionText, author, text, url: urlStr || "https://x.com/notifications" });
            };
            const { nextCursor } = walkInstructions(instructions, () => { });
            for (const inst of instructions) {
                for (const entry of inst.entries || []) {
                    if (typeof entry?.entryId === "string" && entry.entryId.startsWith("notification-")) {
                        processItem(entry.content?.itemContent, entry.entryId);
                        continue;
                    }
                    for (const sub of entry?.content?.items || []) {
                        processItem(sub.item?.itemContent, sub.entryId || entry.entryId);
                    }
                }
            }
            const windowed = out.slice(0, limit);
            return { items: windowed, nextCursor: windowed.length >= limit ? nextCursor : null };
        },
    });
    action("listMentions", {
        async invoke({ cursor: startCursor, limit = 20 } = {}) {
            const ct0 = requireCt0();
            const op = await resolveTweetOp("NotificationsTimeline");
            return await collectTweets(startCursor ?? null, limit, (cursor, count) => {
                const vars = { timeline_type: "Mentions", count };
                if (cursor)
                    vars.cursor = cursor;
                return graphqlGet(op, "NotificationsTimeline", vars, ct0);
            }, (d) => d?.data?.viewer?.notification_mentions_list?.timeline?.instructions ||
                d?.data?.viewer?.notification_all_list?.timeline?.instructions ||
                d?.data?.viewer?.timeline_response?.timeline?.instructions ||
                d?.data?.viewer_v2?.user_results?.result?.notification_timeline?.timeline?.instructions ||
                d?.data?.timeline?.instructions ||
                [], "listMentions");
        },
    });
    const listRow = (value) => {
        const result = value?.list || value?.list_results?.result || value;
        if (!result || typeof result !== "object") return null;
        const id = String(result.rest_id || result.id_str || result.id || "");
        const name = String(result.name || "").trim();
        if (!/^\d+$/.test(id) || !name) return null;
        const ownerResult = result.user_results?.result || result.user || result.owner_results?.result || {};
        const owner = ownerResult.core?.screen_name || ownerResult.legacy?.screen_name || ownerResult.screen_name || "";
        return { id, name, description: String(result.description || ""), owner: String(owner), member_count: Number(result.member_count) || 0, subscriber_count: Number(result.subscriber_count) || 0, private: result.mode === "private", url: "https://x.com/i/lists/" + id };
    };
    const walkObjects = (root, visit) => {
        const seen = new Set();
        const walk = (value) => {
            if (!value || typeof value !== "object" || seen.has(value)) return;
            seen.add(value); visit(value);
            if (Array.isArray(value)) for (const item of value) walk(item);
            else for (const item of Object.values(value)) walk(item);
        };
        walk(root);
    };
    const getProfileRecord = async (screen, ct0) => {
        const op = await resolveUserOp("UserByScreenName");
        const d = await graphqlGet(op, "UserByScreenName", { screen_name: screen, withSafetyModeUserFields: true }, ct0);
        if (d?.__http_error) throw new Error("getCurrentUser HTTP " + d.__http_error + " for @" + screen);
        const result = d?.data?.user?.result;
        if (!result) throw new Error("X user @" + screen + " not found");
        const legacy = result.legacy || {}; const core = result.core || {};
        return { screen_name: core.screen_name || legacy.screen_name || screen, name: core.name || legacy.name || "", bio: legacy.description || "", location: legacy.location || "", url: legacy.entities?.url?.urls?.[0]?.expanded_url || "", followers: Number(legacy.followers_count) || 0, following: Number(legacy.friends_count) || 0, tweets: Number(legacy.statuses_count) || 0, likes: Number(legacy.favourites_count) || 0, verified: Boolean(result.is_blue_verified || legacy.verified), created_at: legacy.created_at || "" };
    };
    action("getCurrentUser", { async invoke() { const ct0 = requireCt0(); const screen = await resolveTargetHandle(); return await getProfileRecord(screen, ct0); } });
    action("getVideo", {
        async invoke({ tweetId }) {
            const ct0 = requireCt0(); const id = parseTweetId(tweetId); const op = await resolveTweetOp("TweetResultByRestId");
            const data = await graphqlGet(op, "TweetResultByRestId", { tweetId: id, withCommunity: true, includePromotedContent: false, withVoice: true }, ct0);
            if (data?.__http_error) throw new Error("getVideo HTTP " + data.__http_error + " for post " + id);
            const result = data?.data?.tweetResult?.result; const tw = result?.tweet || result;
            if (!tw) throw new Error("getVideo: post " + id + " not found");
            const tweet = tweetRow(result, new Set()); if (!tweet) throw new Error("getVideo: post " + id + " could not be parsed");
            const media = [...(tw.legacy?.extended_entities?.media || []), ...(tw.legacy?.entities?.media || [])];
            const video = media.find((x) => x?.type === "video" || x?.type === "animated_gif");
            if (!video) throw new Error("getVideo: post " + id + " has no video");
            const variants = []; const urls = new Set();
            for (const v of video.video_info?.variants || []) if (v?.url && !urls.has(v.url)) { urls.add(v.url); variants.push({ url: v.url, content_type: String(v.content_type || ""), bitrate: Number.isFinite(v.bitrate) ? v.bitrate : null }); }
            return { tweet, duration_ms: Number.isFinite(video.video_info?.duration_millis) ? video.video_info.duration_millis : null, aspect_ratio: Array.isArray(video.video_info?.aspect_ratio) ? video.video_info.aspect_ratio.slice(0, 2).map(Number) : [0, 0], poster_url: video.media_url_https || null, variants };
        },
    });
    action("listUserHighlights", { async invoke({ username, cursor: startCursor, limit = 20 } = {}) { return await listUserTimeline("UserHighlightsTweets", username, startCursor, limit); } });
    action("listUserArticles", { async invoke({ username, cursor: startCursor, limit = 20 } = {}) { return await listUserTimeline("UserArticlesTweets", username, startCursor, limit); } });
    action("listLists", {
        async invoke({ username, kind = "all", cursor, limit = 20 } = {}) {
            const ct0 = requireCt0(); const screen = await resolveTargetHandle(username); let apiPath;
            if (kind === "owned") apiPath = "/i/api/1.1/lists/ownerships.json?screen_name=" + encodeURIComponent(screen) + "&count=" + limit;
            else if (kind === "member") apiPath = "/i/api/1.1/lists/memberships.json?screen_name=" + encodeURIComponent(screen) + "&count=" + limit;
            else apiPath = "/i/api/1.1/lists/list.json?screen_name=" + encodeURIComponent(screen);
            if (cursor && kind !== "all") apiPath += "&cursor=" + encodeURIComponent(cursor);
            const data = await fetchJson(apiPath, { headers: authHeaders(ct0), credentials: "include" });
            if (data?.__http_error) throw new Error("listLists HTTP " + data.__http_error + " for @" + screen);
            const source = Array.isArray(data) ? data : (Array.isArray(data?.lists) ? data.lists : []);
            const items = source.map(listRow).filter(Boolean).slice(0, limit); const next = kind === "all" ? null : String(data?.next_cursor_str || "0");
            return { items, nextCursor: next && next !== "0" ? next : null };
        },
    });
    action("getList", {
        async invoke({ listId }) {
            const ct0 = requireCt0(); const id = String(listId || "");
            const data = await fetchJson("/i/api/1.1/lists/show.json?list_id=" + encodeURIComponent(id), { headers: authHeaders(ct0), credentials: "include" });
            if (data?.__http_error) throw new Error("getList HTTP " + data.__http_error + " for List " + id);
            const row = listRow(data); if (!row) throw new Error("getList: List " + id + " not found or unsupported"); return row;
        },
    });
    action("getListTimeline", {
        async invoke({ listId, cursor: startCursor, limit = 20 }) {
            const ct0 = requireCt0(); const id = String(listId); const op = await resolveTweetOp("ListLatestTweetsTimeline");
            return await collectTweets(startCursor ?? null, limit, (cursor, count) => { const vars = { listId: id, count }; if (cursor) vars.cursor = cursor; return graphqlGet(op, "ListLatestTweetsTimeline", vars, ct0); }, (d) => d?.data?.list?.tweets_timeline?.timeline?.instructions || d?.data?.list?.tweets_timeline?.instructions || d?.data || [], "getListTimeline " + id);
        },
    });
    action("listListMembers", {
        async invoke({ listId, cursor: startCursor, limit = 50 }) {
            const ct0 = requireCt0(); const id = String(listId); const op = await resolveTweetOp("ListMembers");
            return await collectUsers(startCursor ?? null, limit, (cursor, count) => { const vars = { listId: id, count }; if (cursor) vars.cursor = cursor; return graphqlGet(op, "ListMembers", vars, ct0); }, "listListMembers " + id, (d) => d?.data || []);
        },
    });
    const communityRow = (root, expectedId) => {
        let hit = null;
        walkObjects(root, (value) => { if (hit) return; const id = String(value.rest_id || value.id_str || ""); const name = String(value.name || value.title || "").trim(); if (id && name && (!expectedId || id === expectedId) && (value.member_count != null || value.members_count != null || value.__typename === "Community")) hit = value; });
        if (!hit) return null; const id = String(hit.rest_id || hit.id_str);
        return { id, name: String(hit.name || hit.title || ""), description: String(hit.description || hit.purpose || ""), member_count: Number(hit.member_count ?? hit.members_count) || 0, created_at: String(hit.created_at || ""), url: "https://x.com/i/communities/" + id, join_policy: String(hit.join_policy || hit.join_policy_type || hit.access || "") };
    };
    action("listCommunities", {
        async invoke({ cursor: startCursor, limit = 20 } = {}) {
            const ct0 = requireCt0();
            const op = { queryId: "Niv8SWd6ikTjIEqpVh394w", features: {}, fieldToggles: {} };
            const vars = { count: Math.min(100, Math.max(limit, 20)) };
            if (startCursor) vars.cursor = startCursor;
            const data = await graphqlGet(op, "CommunityDiscoveryTimeline", vars, ct0);
            if (data?.__http_error) throw new Error("listCommunities HTTP " + data.__http_error);
            const items = []; const seen = new Set();
            walkObjects(data?.data, (value) => { const row = communityRow(value); if (row && !seen.has(row.id) && items.length < limit) { seen.add(row.id); items.push(row); } });
            const cursor = walkInstructions(data?.data, () => {}).nextCursor;
            return { items, nextCursor: cursor && cursor !== startCursor ? cursor : null };
        },
    });
    action("getCommunity", {
        async invoke({ communityId }) {
            const ct0 = requireCt0(); const id = String(communityId); const op = { queryId: "uBpODvS60xZ1q2L88d-W2A", features: { c9s_list_members_action_api_enabled: false, c9s_superc9s_indication_enabled: false }, fieldToggles: {} };
            const data = await graphqlGet(op, "CommunityQuery", { communityId: id }, ct0); if (data?.__http_error) throw new Error("getCommunity HTTP " + data.__http_error + " for Community " + id);
            const row = communityRow(data?.data, id); if (!row) throw new Error("getCommunity: Community " + id + " not found or response unsupported"); return row;
        },
    });
    action("getCommunityTimeline", {
        async invoke({ communityId, cursor: startCursor, limit = 20 }) {
            const ct0 = requireCt0(); const id = String(communityId); const op = await resolveTweetOp("CommunityTweetsTimeline");
            return await collectTweets(startCursor ?? null, limit, (cursor, count) => { const vars = { communityId: id, count, rankingMode: "Recency" }; if (cursor) vars.cursor = cursor; return graphqlGet(op, "CommunityTweetsTimeline", vars, ct0); }, (d) => d?.data || [], "getCommunityTimeline " + id);
        },
    });
    action("listCommunityMembers", {
        async invoke({ communityId, cursor: startCursor, limit = 50 }) {
            const ct0 = requireCt0(); const id = String(communityId); const op = await resolveTweetOp("CommunityAboutTimeline");
            return await collectUsers(startCursor ?? null, limit, (cursor, count) => { const vars = { communityId: id, count }; if (cursor) vars.cursor = cursor; return graphqlGet(op, "CommunityAboutTimeline", vars, ct0); }, "listCommunityMembers " + id, (d) => d?.data || []);
        },
    });
    const parseSpaceId = (raw) => { const value = String(raw || "").trim(); const match = value.match(/\/i\/spaces\/([A-Za-z0-9_-]+)/); const id = match ? match[1] : value; if (!/^[A-Za-z0-9_-]+$/.test(id)) throw new Error("Invalid X Space id or URL: " + JSON.stringify(raw)); return id; };
    const spaceRow = (root, expectedId) => {
        let hit = null;
        walkObjects(root, (value) => { if (hit) return; const meta = value.metadata || value; const id = String(meta.rest_id || meta.id || ""); if (id && (!expectedId || id === expectedId) && (meta.state || meta.title) && (value.metadata || meta.creator_results || meta.creator)) hit = meta; });
        if (!hit) return null; const id = String(hit.rest_id || hit.id); const creator = hit.creator_results?.result || hit.creator || {}; const host = creator.core?.screen_name || creator.legacy?.screen_name || creator.screen_name || "";
        const iso = (value) => value == null ? null : (typeof value === "number" || /^\d+$/.test(String(value)) ? new Date(Number(value)).toISOString() : String(value));
        return { id, title: String(hit.title || ""), state: String(hit.state || ""), host: String(host), participant_count: Number(hit.total_live_listeners ?? hit.participant_count ?? hit.total_participants) || 0, started_at: iso(hit.started_at), scheduled_at: iso(hit.scheduled_start), ended_at: iso(hit.ended_at), url: "https://x.com/i/spaces/" + id };
    };
    const fetchSpaceById = async (id, ct0) => {
        const op = { queryId: "fYAuJHiY3TmYdBmrRtIKhA", features: {}, fieldToggles: {} };
        const vars = { id, isMetatagsQuery: false, withReplays: true, withListeners: true };
        const data = await graphqlGet(op, "AudioSpaceById", vars, ct0);
        if (data?.__http_error) throw new Error("getSpace HTTP " + data.__http_error + " for Space " + id);
        const row = spaceRow(data?.data, id);
        if (!row) throw new Error("getSpace: Space " + id + " not found or response unsupported");
        return row;
    };
    action("listSpaces", {
        async invoke({ query = "", filter = "top", limit = 20 } = {}) {
            const ct0 = requireCt0();
            const rawQuery = (String(query || "").trim() + " filter:spaces").trim();
            const op = await resolveTweetOp("SearchTimeline");
            const search = await collectTweets(null, Math.min(100, Math.max(limit * 3, 20)), (cursor, count) => graphqlPost(op, "SearchTimeline", { rawQuery, count, querySource: "typed_query", product: filter === "top" ? "Top" : "Latest", withGrokTranslatedBio: true, withQuickPromoteEligibilityTweetFields: false, ...(cursor ? { cursor } : {}) }, ct0), (d) => d?.data?.search_by_raw_query?.search_timeline?.timeline?.instructions || [], "listSpaces");
            const ids = [];
            for (const tweet of search.items) {
                const match = String(tweet.card?.url || "").match(/\/i\/spaces\/([A-Za-z0-9_-]+)/);
                if (match && !ids.includes(match[1])) ids.push(match[1]);
                if (ids.length >= limit * 2) break;
            }
            const items = [];
            for (const id of ids) {
                try {
                    const row = await fetchSpaceById(id, ct0);
                    const state = row.state.toLowerCase();
                    if (filter === "live" && state !== "running") continue;
                    if (filter === "upcoming" && !["notstarted", "prepublished"].includes(state)) continue;
                    items.push(row);
                    if (items.length >= limit) break;
                }
                catch (error) { console.log("listSpaces detail " + id + ": " + (error?.message || error)); }
            }
            return { items, nextCursor: null };
        },
    });
    action("getSpace", { async invoke({ spaceId }) { const ct0 = requireCt0(); return await fetchSpaceById(parseSpaceId(spaceId), ct0); } });
    action("getTweetAnalytics", {
        async invoke({ tweetId, from, to }) {
            const ct0 = requireCt0(); const id = parseTweetId(tweetId);
            let createdMs;
            try { createdMs = Number((BigInt(id) >> 22n) + 1288834974657n); }
            catch { throw new Error("getTweetAnalytics: invalid post id"); }
            const fromDate = from ? new Date(from) : new Date(Math.floor(createdMs / 3600000) * 3600000);
            const toDate = to ? new Date(to) : new Date();
            if (!Number.isFinite(fromDate.getTime()) || !Number.isFinite(toDate.getTime()) || fromDate >= toDate) throw new Error("getTweetAnalytics: invalid time range");
            const first48 = new Date(fromDate.getTime() + 48 * 3600000);
            const op = { queryId: "vnwexpl0q33_Bky-SROVww", features: { responsive_web_tweet_analytics_m3_enabled: false }, fieldToggles: {} };
            const vars = { restId: id, from_time: fromDate.toISOString(), to_time: toDate.toISOString(), first_48_hours_time: first48.toISOString(), requested_organic_metrics: ["DetailExpands", "Engagements", "Follows", "Impressions", "LinkClicks", "ProfileVisits"], requested_promoted_metrics: ["DetailExpands", "Engagements", "Follows", "Impressions", "LinkClicks", "ProfileVisits", "CostPerFollower"] };
            const data = await graphqlGet(op, "TweetActivityQuery", vars, ct0);
            if (data?.__http_error) throw new Error("getTweetAnalytics HTTP " + data.__http_error + " for post " + id);
            const result = data?.data?.tweet_result_by_rest_id?.result;
            if (!result) throw new Error("getTweetAnalytics: analytics unavailable for post " + id + " (it may not belong to the signed-in account)");
            const metrics = {};
            for (const row of result.datapoints_grid || []) metrics[row.metric_type] = Number(row.metric_value) || 0;
            let videoViews = 0; walkObjects(result.video || [], (value) => { if (/video.*view/i.test(String(value.metric_type || ""))) videoViews += Number(value.metric_value) || 0; });
            return { tweetId: id, impressions: metrics.Impressions || 0, engagements: metrics.Engagements || 0, detail_expands: metrics.DetailExpands || 0, profile_visits: metrics.ProfileVisits || 0, link_clicks: metrics.LinkClicks || 0, follows: metrics.Follows || 0, video_views: videoViews, from: fromDate.toISOString(), to: toDate.toISOString() };
        },
    });
    action("getAccountAnalytics", {
        async invoke() {
            const deadline = Date.now() + 8000;
            let text = "";
            while (Date.now() < deadline) {
                text = String(document.body?.innerText || "");
                if (/Account overview/i.test(text) || /Detailed engagement metrics/i.test(text)) break;
                await new Promise((resolve) => setTimeout(resolve, 200));
            }
            if (!/Analytics/i.test(text)) throw new Error("getAccountAnalytics: X analytics page did not become ready");
            const blocked = text.match(/Detailed engagement metrics[^\n.]*(?:[.]|\n|$)/i);
            if (blocked) return { available: false, reason: blocked[0].trim(), period: null, impressions: null, engagements: null, profile_visits: null, followers_change: null };
            const parseNumber = (label) => {
                const patterns = [new RegExp(label + "\\s*\\n\\s*([+-]?[0-9.,]+[KMB]?)", "i"), new RegExp("([+-]?[0-9.,]+[KMB]?)\\s*\\n\\s*" + label, "i")];
                for (const re of patterns) { const m = text.match(re); if (!m) continue; const raw = m[1].replace(/,/g, "").toUpperCase(); const factor = raw.endsWith("K") ? 1e3 : raw.endsWith("M") ? 1e6 : raw.endsWith("B") ? 1e9 : 1; const value = Number(raw.replace(/[KMB]$/, "")); if (Number.isFinite(value)) return Math.round(value * factor); }
                return null;
            };
            const period = text.match(/(?:Last|Past)\s+\d+\s+days?/i)?.[0] || null;
            const result = { available: true, reason: null, period, impressions: parseNumber("Impressions"), engagements: parseNumber("Engagements"), profile_visits: parseNumber("Profile visits"), followers_change: parseNumber("New followers") };
            if (Object.values(result).slice(2).every((x) => x == null)) throw new Error("getAccountAnalytics: analytics layout is unsupported");
            return result;
        },
    });
    action("getArticle", {
        async invoke({ tweetId }) {
            const ct0 = requireCt0();
            const id = parseTweetId(tweetId);
            const op = await resolveTweetOp("TweetResultByRestId");
            const vars = { tweetId: id, withCommunity: false, includePromotedContent: false, withVoice: false };
            const data = await graphqlGet(op, "TweetResultByRestId", vars, ct0);
            if (data?.__http_error)
                throw new Error(`getArticle HTTP ${data.__http_error} for tweet ${id} (not found or queryId stale)`);
            const result = data?.data?.tweetResult?.result;
            if (!result)
                throw new Error(`getArticle: tweet ${id} not found`);
            const tw = result.tweet || result;
            const legacy = tw.legacy || {};
            const u = tw.core?.user_results?.result;
            const screen = u?.legacy?.screen_name || u?.core?.screen_name || "unknown";
            const articleResults = tw.article?.article_results?.result;
            const tweetUrl = `https://x.com/${screen}/status/${id}`;
            if (!articleResults) {
                const noteText = tw.note_tweet?.note_tweet_results?.result?.text;
                if (noteText)
                    return {
                        title: "(Note Tweet)",
                        author: screen,
                        content: noteText,
                        url: tweetUrl,
                        cover_image_url: null,
                        media_urls: [],
                    };
                throw new Error(`getArticle: tweet ${id} has no long-form article or note content`);
            }
            const title = articleResults.title || "(Untitled)";
            const article = extractArticleBody(articleResults);
            return {
                title,
                author: screen,
                content: article.content || legacy.full_text || "",
                url: tweetUrl,
                cover_image_url: article.cover_image_url,
                media_urls: article.media_urls,
            };
        },
    });
});
