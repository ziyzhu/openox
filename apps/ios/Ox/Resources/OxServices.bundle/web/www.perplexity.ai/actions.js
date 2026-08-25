window.ox.install(1, ({ action, retryFetch, log }) => {
    const ORIGIN = "https://www.perplexity.ai";
    const VERSION = "2.18";
    const SUPPORTED_BLOCKS = [
        "answer_modes",
        "media_items",
        "knowledge_cards",
        "inline_entity_cards",
        "place_widgets",
        "finance_widgets",
        "sports_widgets",
        "news_widgets",
        "shopping_widgets",
        "jobs_widgets",
        "search_result_widgets",
        "inline_images",
        "inline_assets",
        "placeholder_cards",
        "diff_blocks",
        "inline_knowledge_cards",
        "entity_group_v2",
        "refinement_filters",
        "canvas_mode",
        "maps_preview",
        "answer_tabs",
        "price_comparison_widgets",
        "preserve_latex",
        "generic_onboarding_widgets",
        "in_context_suggestions",
        "pending_followups",
        "inline_claims",
        "unified_assets",
        "workflow_steps",
        "workflow_widgets",
        "navigation_results",
        "background_agents",
    ];
    const fetchJson = async (url, init = {}) => {
        const response = await retryFetch(url, { credentials: "include", ...init });
        const text = await response.text();
        if (!response.ok)
            throw new Error(`Perplexity returned HTTP ${response.status}`);
        try {
            return JSON.parse(text);
        }
        catch {
            throw new Error("Perplexity returned an unreadable response");
        }
    };
    const getSession = () => fetchJson(`${ORIGIN}/api/auth/session`);
    const accountHeaders = async () => {
        const session = await getSession();
        const id = session?.user?.id;
        if (!id)
            throw new Error("Not signed in to Perplexity");
        return { "x-pplx-account": String(id) };
    };
    const requestHeaders = (url, reason, extra = {}) => ({
        "x-app-apiclient": "default",
        "x-app-apiversion": VERSION,
        "x-perplexity-request-endpoint": url,
        "x-perplexity-request-reason": reason,
        "x-perplexity-request-try-number": "1",
        "x-request-id": crypto.randomUUID(),
        ...extra,
    });
    const threadEndpoint = (id, cursor, limit) => {
        const params = new URLSearchParams({
            with_parent_info: "true",
            with_schematized_response: "true",
            version: VERSION,
            source: "default",
            limit: String(limit),
            offset: cursor || "0",
            from_first: cursor ? "false" : "true",
        });
        for (const block of SUPPORTED_BLOCKS) {
            if (block !== "diff_blocks" && block !== "workflow_widgets") {
                params.append("supported_block_use_cases", block);
            }
        }
        return `${ORIGIN}/rest/thread/${encodeURIComponent(id)}?${params}`;
    };
    const sourcesFrom = (blocks) => {
        const found = new Map();
        for (const block of blocks || []) {
            const groups = [
                block?.web_result_block?.web_results,
                block?.sources_mode_block?.web_results,
                block?.navigation_block?.web_results,
            ];
            for (const group of groups) {
                for (const item of Array.isArray(group) ? group : []) {
                    const url = typeof item?.url === "string" ? item.url : "";
                    if (!url || found.has(url))
                        continue;
                    found.set(url, {
                        title: typeof item?.name === "string" ? item.name : "",
                        url,
                        snippet: typeof item?.snippet === "string" ? item.snippet : "",
                    });
                }
            }
        }
        return [...found.values()];
    };
    const placesFrom = (blocks) => {
        const places = blocks
            ?.flatMap((block) => block?.maps_mode_block?.places || [])
            .filter((place) => place && typeof place.name === "string") || [];
        return places.map((place) => ({
            name: place.name,
            url: typeof place.url === "string" ? place.url : "",
            address: Array.isArray(place.address) ? place.address.filter((value) => typeof value === "string").join(", ") : "",
            rating: Number.isFinite(place.rating) ? place.rating : null,
            numReviews: Number.isInteger(place.num_reviews) ? place.num_reviews : null,
            priceRange: typeof place.price_range === "string" ? place.price_range : null,
            isOpen: typeof place.is_open === "boolean" ? place.is_open : null,
            phone: typeof place.phone === "string" ? place.phone : null,
        }));
    };
    const answerFrom = (record, threadId) => {
        const blocks = Array.isArray(record?.blocks) ? record.blocks : [];
        const answerBlock = blocks.find((block) => typeof block?.markdown_block?.answer === "string");
        const id = String(record?.uuid || record?.frontend_uuid || "");
        const resolvedThreadId = String(threadId || record?.backend_uuid || record?.thread_url_slug || "");
        return {
            id,
            threadId: resolvedThreadId,
            query: typeof record?.query_str === "string" ? record.query_str : "",
            answer: answerBlock?.markdown_block?.answer || "",
            sources: sourcesFrom(blocks),
            places: placesFrom(blocks),
            relatedQueries: Array.isArray(record?.related_queries)
                ? record.related_queries.filter((value) => typeof value === "string")
                : [],
            status: typeof record?.status === "string" ? record.status : "",
            createdAt: typeof record?.entry_created_datetime === "string" ? record.entry_created_datetime : null,
            url: resolvedThreadId ? `${ORIGIN}/search/${encodeURIComponent(resolvedThreadId)}` : ORIGIN,
        };
    };
    const parseEventStream = (text) => {
        const messages = text
            .split(/\r?\n/)
            .filter((line) => line.startsWith("data: "))
            .map((line) => {
            try {
                return JSON.parse(line.slice(6));
            }
            catch {
                return null;
            }
        })
            .filter(Boolean);
        const final = messages.findLast((message) => message?.final_sse_message === true)
            || messages.findLast((message) => message?.text_completed === true)
            || messages.findLast((message) => message?.backend_uuid);
        if (!final)
            throw new Error("Perplexity did not return a completed answer");
        return final;
    };
    action("getSignInUrl", {
        async invoke() {
            return { url: `${ORIGIN}/login` };
        },
    });
    action("getSignInState", {
        async invoke() {
            const session = await getSession();
            const signedIn = !!session?.user?.id;
            log(`getSignInState signedIn=${signedIn}`);
            return { signedIn };
        },
    });
    action("askQuestion", {
        async invoke({ query }) {
            const frontendId = crypto.randomUUID();
            const contextId = crypto.randomUUID();
            const session = await getSession();
            const accountId = session?.user?.id;
            const endpoint = `${ORIGIN}/rest/sse/perplexity_ask`;
            const language = navigator.language || "en-US";
            const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
            const headers = requestHeaders(endpoint, "ask-query-state-provider", {
                Accept: "text/event-stream",
                "Content-Type": "application/json",
                ...(accountId ? { "x-pplx-account": String(accountId) } : {}),
            });
            const response = await fetch(endpoint, {
                method: "POST",
                credentials: "include",
                headers,
                body: JSON.stringify({
                    params: {
                        attachments: [],
                        language,
                        timezone,
                        search_focus: "internet",
                        sources: ["web"],
                        frontend_uuid: frontendId,
                        mode: "copilot",
                        model_preference: "turbo",
                        is_related_query: false,
                        is_sponsored: false,
                        frontend_context_uuid: contextId,
                        prompt_source: "user",
                        query_source: "home",
                        is_incognito: false,
                        local_search_enabled: false,
                        use_schematized_api: true,
                        send_back_text_in_streaming_api: false,
                        supported_block_use_cases: SUPPORTED_BLOCKS,
                        client_coordinates: null,
                        mentions: [],
                        dsl_query: query,
                        skip_search_enabled: true,
                        is_nav_suggestions_disabled: false,
                        source: "default",
                        always_search_override: false,
                        override_no_search: false,
                        client_search_results_cache_key: frontendId,
                        should_ask_for_mcp_tool_confirmation: true,
                        supports_tool_approval_modal: true,
                        browser_agent_allow_once_from_toggle: false,
                        force_enable_browser_agent: false,
                        supported_features: ["browser_agent_permission_banner_v1.1"],
                        extended_context: false,
                        version: VERSION,
                    },
                    query_str: query,
                }),
            });
            const text = await response.text();
            if (!response.ok)
                throw new Error(`Perplexity returned HTTP ${response.status}`);
            const streamed = answerFrom(parseEventStream(text));
            const threadUrl = threadEndpoint(streamed.threadId, undefined, 10);
            const thread = await fetchJson(threadUrl, {
                headers: requestHeaders(threadUrl, "search-components", {
                    ...(accountId ? { "x-pplx-account": String(accountId) } : {}),
                }),
            });
            const entry = Array.isArray(thread?.entries)
                ? thread.entries.find((candidate) => candidate?.uuid === streamed.id) || thread.entries.at(-1)
                : null;
            const answer = entry ? answerFrom(entry, streamed.threadId) : streamed;
            log(`askQuestion status=${answer.status} sources=${answer.sources.length} places=${answer.places.length}`);
            return answer;
        },
    });
    action("listThreads", {
        async invoke() {
            const endpoint = `${ORIGIN}/rest/thread/list_recent?exclude_asi=false&version=${VERSION}&source=default`;
            const headers = requestHeaders(endpoint, "sidebar-v3", await accountHeaders());
            const data = await fetchJson(endpoint, { headers });
            if (!Array.isArray(data))
                throw new Error("Perplexity returned an unexpected thread list");
            const items = data
                .filter((thread) => typeof thread?.uuid === "string")
                .map((thread) => ({
                id: thread.uuid,
                title: typeof thread.title === "string" ? thread.title : "",
                unread: thread.unread === true,
                status: typeof thread.status === "string" ? thread.status : null,
                answerPreview: typeof thread.answer_preview === "string" ? thread.answer_preview : null,
                url: `${ORIGIN}/search/${encodeURIComponent(thread.uuid)}`,
            }));
            log(`listThreads items=${items.length}`);
            return { items, nextCursor: null };
        },
    });
    action("getThread", {
        async invoke({ id, cursor, limit = 10 }) {
            const endpoint = threadEndpoint(id, cursor, limit);
            const headers = requestHeaders(endpoint, "search-components", await accountHeaders());
            const data = await fetchJson(endpoint, { headers });
            if (data?.status !== "success" || !Array.isArray(data?.entries)) {
                throw new Error("Perplexity returned an unexpected thread");
            }
            const metadata = data.thread_metadata || {};
            const result = {
                id,
                title: typeof metadata.title === "string" ? metadata.title : "",
                createdAt: typeof metadata.created_at === "string" ? metadata.created_at : null,
                updatedAt: typeof metadata.updated_at === "string" ? metadata.updated_at : null,
                entries: data.entries.map((entry) => answerFrom(entry, id)),
                nextCursor: data.next_cursor == null ? null : String(data.next_cursor),
                url: `${ORIGIN}/search/${encodeURIComponent(id)}`,
            };
            log(`getThread entries=${result.entries.length} next=${result.nextCursor !== null}`);
            return result;
        },
    });
});
