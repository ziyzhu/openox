window.ox.install(({ action: register }) => {
    const handlers = {};
    const action = (id, spec) => { handlers[id] = spec.invoke; register(id, spec); };
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
        const response = await fetch(url, { credentials: "include", cache: "no-store", signal: AbortSignal.timeout(8000), ...init });
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
    const getSession = async () => {
        const data = await fetchJson(ORIGIN + '/api/auth/session', {cache:'no-store'});
        if (data && typeof data === 'object' && !Array.isArray(data)) {
            if (typeof data.user?.id === 'string' && data.user.id.length) return data;
            if (Object.keys(data).length === 0) return data;
        }
        throw new Error('Unexpected Perplexity session response');
    };
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
            return { url: `${ORIGIN}/auth/signin` };
        },
    });
    action("getSignInState", {
        async invoke() {
            const session = await getSession();
            const signedIn = !!session?.user?.id;
            console.log(`getSignInState signedIn=${signedIn}`);
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
            console.log(`askQuestion status=${answer.status} sources=${answer.sources.length} places=${answer.places.length}`);
            return answer;
        },
    });
    action("searchConversations", {async invoke({query}) {if(!query.trim())throw new Error('Search query must not be blank');const j=await fetchJson(ORIGIN+'/rest/perplexity_ask/graphql',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({operationName:'CommandPaletteTypeaheadSearchRelayQuery',variables:{query},extensions:{persistedQuery:{version:1,sha256Hash:'e36e392682ac1cec902667d8091ef3d7bc609d9aae6092313926cfe825eca763'}}})});const edges=j.data?.viewer?.typeaheadSearch?.edges;if(j.errors||!Array.isArray(edges))throw new Error('Unexpected Perplexity history-search response');const items=edges.filter(e=>e.node?.type==='SEARCH_THREAD').map(e=>{const n=e.node,o=n.object;if(o?.__typename!=='Thread'||typeof o.entryId!=='string'||typeof o.threadSlug!=='string'||typeof n.title!=='string')throw new Error('Invalid history search result');return {id:o.entryId,title:n.title,url:ORIGIN+'/search/'+encodeURIComponent(o.threadSlug)};});return {items,nextCursor:null,scope:'ranked-typeahead',complete:false};}});
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
            console.log(`listThreads items=${items.length}`);
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
            const stableCursor = value => {
                try { const d=JSON.parse(value); const canonical=x=>x&&typeof x==='object'?(Array.isArray(x)?x.map(canonical):Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])]))):x; return JSON.stringify(canonical(d)); } catch { return String(value); }
            };
            if(cursor && data.next_cursor!=null && stableCursor(cursor)===stableCursor(data.next_cursor))throw new Error('Perplexity pagination stalled; refusing to repeat the same page');
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
            console.log(`getThread entries=${result.entries.length} next=${result.nextCursor !== null}`);
            return result;
        },
    });
    const pause = ms => new Promise(r => setTimeout(r,ms));
    const wait = async (fn, ms=7000) => { const end=Date.now()+ms; do { const v=fn(); if(v)return v; await pause(100); }while(Date.now()<end); throw new Error('Perplexity interface not ready'); };
    const currentId = () => location.pathname.startsWith('/search/') ? decodeURIComponent(location.pathname.slice(8)) : null;
    const route = async id => {
        const path=id?'/search/'+encodeURIComponent(id):'/';
        if(location.pathname!==path){const old=document.querySelector('.prose');history.pushState({},'',path);window.dispatchEvent(new PopStateEvent('popstate'));if(old)await wait(()=>!old.isConnected);}
        await wait(()=>location.pathname===path && document.querySelector('#ask-input[data-lexical-editor="true"]'));
        if(id) await wait(()=>document.querySelector('.prose'));
        else await wait(()=>!document.querySelector('.prose'));
    };
    action('getCurrentUser',{async invoke(){const s=await getSession();if(!s.user)throw new Error('Not signed in');return {id:s.user.id,name:typeof s.user.name==='string'?s.user.name:null,email:typeof s.user.email==='string'?s.user.email:null};}});
    action('listConversations',{async invoke(){return handlers.listThreads({});}});
    action('getConversation',{async invoke(args){return handlers.getThread(args);}});
    action('openConversation',{async invoke({id}){const result=await handlers.getThread({id,limit:10});await route(id);return result;}});
    action('getCurrentConversation',{async invoke(){await wait(()=>document.querySelector('#ask-input'));const id=currentId();return {conversation:id?await handlers.getThread({id,limit:20}):null};}});
    action('listModels',{async invoke(){const d=await fetchJson(ORIGIN+'/rest/models/config/v2?version='+VERSION+'&source=default');if(!d.models||typeof d.models!=='object')throw new Error('Unexpected model catalog');return {items:Object.entries(d.models).filter(([id,m])=>m.mode==='search').map(([id,m])=>({id,name:m.label||id,availability:'catalog-only'})),nextCursor:null};}});
    const send = async (message,id) => {
        await route(id);
        const before = id ? await handlers.getThread({id,limit:20}) : null;
        if(before?.nextCursor)throw new Error('Sending to threads longer than the read window is not supported');
        const old = new Set(before?.entries.map(e=>e.id)||[]);
        const editor=document.querySelector('#ask-input');
        if(editor.textContent.trim())throw new Error('Composer has an existing draft; refusing to overwrite');
        editor.focus();
        const selection=getSelection();const range=document.createRange();range.selectNodeContents(editor);selection.removeAllRanges();selection.addRange(range);
        if(!document.execCommand('insertText',false,message))throw new Error('Unable to insert message');
        await wait(()=>editor.textContent.trim()===message.trim(),2000);
        const button=await wait(()=>{const b=document.querySelector('button[aria-label="Submit"]');return b&&!b.disabled?b:null;},2000);
        button.click();
        const end=Date.now()+14000;let matched=null;let target=id;
        do {
            await pause(700);target=currentId();
            if(!target || (id&&target!==id))continue;
            let t;
            try { t=await handlers.getThread({id:target,limit:20}); } catch(error) {
                if(String(error.message).includes('HTTP 404'))continue;
                throw new Error('Submission outcome uncertain; inspect conversation before retrying. '+error.message);
            }
            matched=t.entries.find(e=>!old.has(e.id)&&e.query.trim()===message.trim())||null;
            if(matched)return {submissionConfirmed:true,status:matched.answer?'reply-available':'pending',conversationId:target,url:t.url,entry:matched};
        }while(Date.now()<end);
        return {submissionConfirmed:false,status:'unconfirmed',conversationId:target||null,url:location.href,entry:null};
    };
    action('chat',{async invoke({message}){return send(message,null);}});
    action('continueChat',{async invoke({id,message}){return send(message,id);}});

});
