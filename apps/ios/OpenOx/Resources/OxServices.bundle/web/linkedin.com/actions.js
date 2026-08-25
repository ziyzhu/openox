window.ox.install(1, ({ action, retryFetch, log, lib }) => {
    const { cookie } = lib;
    // LinkedIn's CSRF token is the JSESSIONID cookie value with its surrounding
    // quotes stripped (e.g. cookie `"ajax:123"` -> header `ajax:123`). The cookie
    // is JS-readable; li_at (the real session credential) is httpOnly and never
    // touched here — the WebView forwards it automatically via credentials.
    const requireCsrf = () => {
        const t = cookie("JSESSIONID");
        if (!t)
            throw new Error("Not signed in to LinkedIn (no JSESSIONID cookie). Sign in first.");
        return t.replace(/"/g, "");
    };
    // The two Voyager surfaces disagree only on the Accept type: the classic
    // /voyager/api/* endpoints answer in normalized+json, the messaging GraphQL
    // gateway answers in plain graphql json.
    const headers = (accept) => ({
        accept,
        "csrf-token": requireCsrf(),
        "x-restli-protocol-version": "2.0.0",
        "x-li-lang": "en_US",
    });
    const NORMALIZED = "application/vnd.linkedin.normalized+json+2.1";
    const GRAPHQL = "application/graphql";
    const apiGet = async (path, accept) => {
        const r = await retryFetch(path, { credentials: "include", headers: headers(accept) });
        const text = await r.text();
        let json;
        try {
            json = JSON.parse(text);
        }
        catch {
            throw new Error(`${path.split("?")[0]}: non-JSON response (HTTP ${r.status}) — session may have expired`);
        }
        if (!r.ok)
            throw new Error(`${path.split("?")[0]}: HTTP ${r.status}`);
        return json;
    };
    // Voyager variable strings keep their structural (key:value,...) syntax
    // literal while percent-encoding each URN value; the whole queryId+variables
    // pair is assembled by hand so URLSearchParams can't re-encode the parens.
    const gqlUrl = (gateway, queryId, variables) => `/voyager/api/${gateway}/graphql?queryId=${queryId}&variables=${variables}`;
    const enc = (urn) => encodeURIComponent(urn);
    const QUERY = {
        conversations: "messengerConversations.0d5e6781bbee71c3e51c8843c6519f48",
    };
    // The conversation URN is urn:li:msg_conversation:(<mailbox>,<threadId>); the
    // classic REST events endpoint keys off just the <threadId> tail.
    const threadIdOf = (convUrn) => {
        const m = convUrn.match(/,([^,)]+)\)$/);
        if (!m)
            throw new Error("could not parse a thread id from the conversation URN");
        return m[1];
    };
    const HTML_ENTITIES = {
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&#39;": "'", "&nbsp;": " ",
    };
    const stripHtml = (html) => String(html || "")
        .replace(/<\/p>|<br\s*\/?>/gi, "\n")
        .replace(/<[^>]+>/g, "")
        .replace(/&[a-z#0-9]+;/gi, (m) => HTML_ENTITIES[m.toLowerCase()] ?? m)
        .replace(/[ \t]+/g, " ")
        .replace(/\n{3,}/g, "\n\n")
        .trim();
    const idFromUrn = (urn) => {
        const s = String(urn ?? "");
        const m = s.match(/[^:]+$/);
        return m ? m[0] : "";
    };
    // A profile picture is a VectorImage: rootUrl + the path segment of whichever
    // rendered artifact is closest to the requested width. /me exposes it as a
    // bare VectorImage; the dash profile wraps it in displayImageReference.
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
    const year = (d) => (d?.year ? Number(d.year) : null);
    const positionRow = (p) => ({
        title: p?.title || "",
        company: p?.companyName || "",
        startYear: year(p?.dateRange?.start),
        endYear: year(p?.dateRange?.end),
    });
    const educationRow = (e) => ({
        school: e?.schoolName || "",
        degree: e?.degreeName || "",
        field: e?.fieldOfStudy || "",
        startYear: year(e?.dateRange?.start),
        endYear: year(e?.dateRange?.end),
    });
    // Both conversation participants and message senders are MessagingParticipant
    // objects: a member, an organization, or an agent, each carrying its own name
    // shape under participantType.
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
    // A message's `sender` is a thin participant (only hostIdentityUrn) in the
    // inbox preview but a fully-named one in the thread view. Build a
    // hostIdentityUrn -> name map from whatever named participants are at hand so
    // the thin senders resolve too.
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
        deliveredAt: Number(m?.deliveredAt) || 0,
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
            url: c?.conversationUrl || "",
        };
    };
    // A thread's events come back normalized: data["*elements"] are Event URNs
    // resolved out of `included`, and each Event's `*from` points to a
    // MessagingMember (miniProfile) or MessagingCompany (alternateName) there too.
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
            deliveredAt: Number(ev?.createdAt) || 0,
        };
    };
    const attr = (a) => a?.text || "";
    // A search hit's kind is encoded in its tracking URN (urn:li:company:..,
    // urn:li:member:.., urn:li:group:.., urn:li:fsd_jobPosting:..).
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
        urn: er?.trackingUrn || "",
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
            url: jobId ? `https://www.linkedin.com/jobs/view/${jobId}/` : "",
        };
    };
    // Engagement lives two pointers away: UpdateV2.*socialDetail -> SocialDetail
    // .*totalSocialActivityCounts -> SocialActivityCounts.
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
            urn,
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
                photoUrl: vectorUrl(mini.picture, 200),
            },
        };
        return cachedMe;
    };
    const PROFILE_DECO = "com.linkedin.voyager.dash.deco.identity.profile.FullProfileWithEntities-101";
    action("getSignInUrl", { async invoke() { return { url: "https://www.linkedin.com/login" }; } });
    action("getSignInState", {
        async invoke() {
            try {
                if (!cookie("JSESSIONID"))
                    return { signedIn: false };
                const json = await apiGet("/voyager/api/me", NORMALIZED);
                return { signedIn: Boolean(json?.data?.plainId) };
            }
            catch (e) {
                log(`linkedin getSignInState probe failed: ${String(e?.message ?? e)}`);
                throw e;
            }
        },
    });
    action("getMe", {
        async invoke() {
            return (await fetchMe()).profile;
        },
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
            const positions = included
                .filter((x) => String(x?.$type || "").endsWith("profile.Position"))
                .map(positionRow)
                .sort((a, b) => (b.startYear || 0) - (a.startYear || 0));
            const educations = included
                .filter((x) => String(x?.$type || "").endsWith("profile.Education"))
                .map(educationRow)
                .sort((a, b) => (b.startYear || 0) - (a.startYear || 0));
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
                educations,
            };
        },
    });
    action("listConversations", {
        async invoke() {
            const { mailboxUrn } = await fetchMe();
            const json = await apiGet(gqlUrl("voyagerMessagingGraphQL", QUERY.conversations, `(mailboxUrn:${enc(mailboxUrn)})`), GRAPHQL);
            const root = json?.data?.messengerConversationsBySyncToken;
            const elements = root?.elements || [];
            return {
                items: elements.map(conversationRow),
                nextCursor: null,
            };
        },
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
            const elements = urns
                .map((u) => byUrn[u])
                .filter(Boolean)
                .sort((a, b) => (Number(a?.createdAt) || 0) - (Number(b?.createdAt) || 0));
            const items = elements.map((ev) => eventRow(ev, byUrn));
            const oldest = items.length ? items[0].deliveredAt : 0;
            return {
                items,
                nextCursor: items.length >= count && oldest ? String(oldest) : null,
            };
        },
    });
    // Voyager query strings (q=..,query=(..)) keep their structural punctuation
    // literal, so they're spliced into the URL raw rather than via URLSearchParams.
    const SEARCH_DECO = "com.linkedin.voyager.dash.deco.search.SearchClusterCollection-185";
    const JOBS_DECO = "com.linkedin.voyager.dash.deco.jobs.search.JobSearchCardsCollection-207";
    action("search", {
        async invoke({ query, cursor, limit } = {}) {
            const q = String(query ?? "").trim();
            if (!q)
                throw new Error("query is required");
            const count = Math.min(Math.max(Number(limit) || 10, 1), 25);
            const start = cursor ? Number(cursor) : 0;
            const json = await apiGet(`/voyager/api/search/dash/clusters?decorationId=${SEARCH_DECO}&origin=GLOBAL_SEARCH_HEADER&q=all` +
                `&query=(keywords:${encodeURIComponent(q)},flagshipSearchIntent:SEARCH_SRP)&start=${start}&count=${count}`, NORMALIZED);
            const items = (json?.included || [])
                .filter((x) => String(x?.$type || "").endsWith("EntityResultViewModel"))
                .map(searchRow)
                .filter((r) => r.title);
            return { items, nextCursor: items.length ? String(start + count) : null };
        },
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
            const json = await apiGet(`/voyager/api/voyagerJobsDashJobCards?decorationId=${JOBS_DECO}&q=jobSearch` +
                `&query=(${queryParts.join(",")})&start=${start}&count=${count}`, NORMALIZED);
            const items = (json?.included || [])
                .filter((x) => String(x?.$type || "").endsWith("JobPostingCard"))
                .map(jobRow)
                .filter((r) => r.title && r.jobId);
            return { items, nextCursor: items.length >= count ? String(start + count) : null };
        },
    });
    action("listFeed", {
        async invoke({ cursor, limit } = {}) {
            const count = Math.min(Math.max(Number(limit) || 10, 1), 25);
            const start = cursor ? Number(cursor) : 0;
            const json = await apiGet(`/voyager/api/feed/updatesV2?commentsCount=0&count=${count}&q=chronFeed&start=${start}`, NORMALIZED);
            const included = json?.included || [];
            const byUrn = includedByUrn(included);
            const items = included
                .filter((x) => String(x?.$type || "").endsWith("render.UpdateV2"))
                .map((u) => postRow(u, byUrn))
                .filter((r) => r.author || r.text);
            return { items, nextCursor: items.length ? String(start + count) : null };
        },
    });
});
