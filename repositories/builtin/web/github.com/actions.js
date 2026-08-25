window.ox.install(1, ({ action, retryFetch, log, lib }) => {
    const { pageCursor } = lib;
    const ORIGIN = "https://github.com";
    const decode = (s) => s
        .replace(/<\/?(em|mark)>/g, "")
        .replace(/&amp;/g, "&")
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"')
        .replace(/&#0?39;/g, "'")
        .replace(/&#x27;/g, "'");
    const fetchText = async (path, init = {}) => {
        const r = await retryFetch(path, { credentials: "include", ...init });
        return { status: r.status, text: await r.text(), headers: r.headers };
    };
    const parseJson = (path, status, text) => {
        if (status >= 400)
            throw new Error(`${path}: GitHub request failed (HTTP ${status})`);
        try {
            return JSON.parse(text);
        }
        catch {
            throw new Error(`${path}: non-JSON response (HTTP ${status}) — sign in to GitHub may have expired`);
        }
    };
    // GitHub's React data router returns clean JSON only when these headers are present.
    const VERIFIED_HEADERS = {
        "Accept": "application/json",
        "github-verified-fetch": "true",
        "x-requested-with": "XMLHttpRequest",
    };
    const fetchPayload = async (path) => {
        const { status, text } = await fetchText(path, { headers: VERIFIED_HEADERS });
        const json = parseJson(path, status, text);
        return json?.payload ?? json;
    };
    const fetchReactPageData = async (path) => {
        const headers = { ...VERIFIED_HEADERS, "GitHub-Is-React": "true" };
        const result = await fetchText(path, { headers });
        return { ...result, json: parseJson(path, result.status, result.text) };
    };
    const fetchDoc = async (path) => {
        const { status, text } = await fetchText(path);
        if (status >= 400)
            throw new Error(`${path}: GitHub request failed (HTTP ${status})`);
        return new DOMParser().parseFromString(text, "text/html");
    };
    const nextLink = (headers) => headers.get("link")?.match(/<([^>]+)>;\s*rel=["']?next["']?/i)?.[1] ?? null;
    const textOf = (element) => element?.textContent?.replace(/\s+/g, " ").trim() ?? "";
    const statusFrom = (element) => element?.querySelector("svg[aria-label]")?.getAttribute("aria-label")?.replace(/^This job\s+/i, "").replace(/:\s*$/, "").trim() ?? "";
    const searchPayload = async (type, query, cursor) => {
        const page = pageCursor(cursor, 1);
        const qs = new URLSearchParams({ q: query, type, p: String(page) });
        const { status, text } = await fetchText(`/search?${qs}`, { headers: { "Accept": "application/json" } });
        const payload = parseJson(`/search?${qs}`, status, text)?.payload ?? {};
        const results = payload.results ?? [];
        return { results, nextCursor: results.length > 0 ? String(page + 1) : null };
    };
    const splitNwo = (nwo) => {
        const [owner, repo] = nwo.split("/");
        if (!owner || !repo)
            throw new Error(`Expected "owner/repo", got ${JSON.stringify(nwo)}`);
        return { owner, repo };
    };
    const repoFromSearch = (r) => {
        const name = decode(r.hl_name ?? "");
        return {
            name,
            description: r.hl_trunc_description ? decode(r.hl_trunc_description) : null,
            language: r.language ?? null,
            stars: r.followers ?? 0,
            topics: r.topics ?? [],
            archived: !!r.archived,
            isPrivate: !r.public,
            starredByMe: !!r.starred_by_current_user,
            url: `${ORIGIN}/${name}`,
        };
    };
    const issueFromSearch = (r) => {
        const nwo = `${r.repo?.repository?.owner_login}/${r.repo?.repository?.name}`;
        const isPr = r.issue?.issue?.pull_request_id != null || r.merged != null;
        return {
            number: r.number,
            title: decode(r.hl_title ?? ""),
            state: r.state,
            repo: nwo,
            author: r.author_name ?? "",
            comments: r.num_comments ?? 0,
            labels: (r.labels ?? []).map((l) => (typeof l === "string" ? l : l?.name ?? "")),
            isPullRequest: isPr,
            createdAt: r.created ?? null,
            url: `${ORIGIN}/${nwo}/${isPr ? "pull" : "issues"}/${r.number}`,
        };
    };
    const attr = (doc, selector, name) => doc.querySelector(selector)?.getAttribute(name) ?? null;
    action("getSignInUrl", {
        async invoke() {
            return { url: `${ORIGIN}/login` };
        },
    });
    action("getSignInState", {
        async invoke() {
            const doc = await fetchDoc("/");
            const login = attr(doc, 'meta[name="user-login"]', "content");
            return { signedIn: !!login };
        },
    });
    action("getCurrentUser", {
        async invoke() {
            const doc = await fetchDoc("/");
            const login = attr(doc, 'meta[name="user-login"]', "content");
            if (!login)
                throw new Error("GitHub requires sign-in");
            return { login, avatarUrl: `${ORIGIN}/${login}.png`, url: `${ORIGIN}/${login}` };
        },
    });
    action("listMyRepos", {
        async invoke({ cursor }) {
            const doc = await fetchDoc("/");
            const login = attr(doc, 'meta[name="user-login"]', "content");
            if (!login)
                throw new Error("GitHub requires sign-in");
            const { results, nextCursor } = await searchPayload("repositories", `user:${login} sort:updated`, cursor);
            return { items: results.map(repoFromSearch), nextCursor };
        },
    });
    action("searchRepos", {
        async invoke({ query, cursor }) {
            const { results, nextCursor } = await searchPayload("repositories", query, cursor);
            return { items: results.map(repoFromSearch), nextCursor };
        },
    });
    action("searchCode", {
        async invoke({ query, cursor }) {
            const { results, nextCursor } = await searchPayload("code", query, cursor);
            const items = results.map((r) => {
                const nwo = r.repo_nwo ?? `${r.repo?.repository?.owner_login}/${r.repo?.repository?.name}`;
                const ref = (r.ref_name ?? "HEAD").replace(/^refs\/(heads|tags)\//, "");
                const snippet = (r.snippets ?? [])
                    .flatMap((s) => s.lines ?? [])
                    .map((line) => decode(line))
                    .join("\n");
                return {
                    repo: nwo,
                    path: r.path ?? "",
                    url: r.path ? `${ORIGIN}/${nwo}/blob/${ref}/${r.path}` : "",
                    snippet,
                };
            });
            return { items, nextCursor };
        },
    });
    action("getUser", {
        async invoke({ username }) {
            const { results } = await searchPayload("users", `user:${username}`);
            const u = results.find((r) => (r.login ?? "").toLowerCase() === username.toLowerCase()) ?? results[0];
            if (!u)
                throw new Error(`User not found: ${username}`);
            return {
                login: u.login,
                name: u.name || null,
                bio: u.profile_bio || null,
                location: u.location || null,
                followers: u.followers ?? 0,
                repos: u.repos ?? 0,
                avatarUrl: u.avatar_url ?? `${ORIGIN}/${u.login}.png`,
                url: `${ORIGIN}/${u.login}`,
            };
        },
    });
    action("getRepo", {
        async invoke({ repo }) {
            const { owner, repo: name } = splitNwo(repo);
            const { text } = await fetchText(`/${owner}/${name}`);
            const num = (id) => {
                const m = text.match(new RegExp(`id="${id}"[^>]*title="([^"]+)"`));
                return m ? parseInt(m[1].replace(/\D/g, ""), 10) || 0 : 0;
            };
            const desc = text.match(/property="og:description" content="([^"]*)"/)?.[1];
            const defaultBranch = text.match(/"defaultBranch":"([^"]+)"/)?.[1] ?? null;
            const isPrivate = /"private":true/.test(text) || /"isPrivate":true/.test(text);
            return {
                name: `${owner}/${name}`,
                description: desc ? decode(desc.replace(/\.\s*Contribute to .*$/, "")) : null,
                defaultBranch,
                stars: num("repo-stars-counter-star"),
                forks: num("repo-network-counter"),
                isPrivate,
                url: `${ORIGIN}/${owner}/${name}`,
            };
        },
    });
    action("listBranches", {
        async invoke({ repo, cursor }) {
            const { owner, repo: name } = splitNwo(repo);
            const page = pageCursor(cursor, 1);
            const payload = await fetchPayload(`/${owner}/${name}/branches/all?page=${page}`);
            const items = (payload.branches ?? []).map((branch) => ({
                name: branch.name,
                isDefault: !!branch.isDefault,
                author: branch.author?.login ?? null,
            }));
            return { items, nextCursor: payload.has_more ? String(payload.current_page + 1) : null };
        },
    });
    action("listCommits", {
        async invoke({ repo, ref, cursor }) {
            const { owner, repo: name } = splitNwo(repo);
            const branch = ref || "HEAD";
            const suffix = cursor ? `?after=${encodeURIComponent(cursor)}` : "";
            const payload = await fetchPayload(`/${owner}/${name}/commits/${branch}${suffix}`);
            const items = (payload.commitGroups ?? []).flatMap((g) => (g.commits ?? []).map((c) => ({
                oid: c.oid,
                message: c.shortMessage,
                author: c.authors?.[0]?.login ?? c.authors?.[0]?.displayName ?? "",
                authoredDate: c.authoredDate,
                url: `${ORIGIN}${c.url}`,
            })));
            const pagination = payload.filters?.pagination;
            return { items, nextCursor: pagination?.hasNextPage ? pagination.endCursor ?? null : null };
        },
    });
    action("listRepoContents", {
        async invoke({ repo, path, ref }) {
            const { owner, repo: name } = splitNwo(repo);
            const branch = ref || "HEAD";
            const sub = path ? `/${path.replace(/^\/+/, "")}` : "";
            const payload = await fetchPayload(`/${owner}/${name}/tree/${branch}${sub}`);
            const items = (payload.codeViewTreeRoute?.tree?.items ?? []).map((it) => ({
                name: it.name,
                path: it.path,
                type: it.contentType === "directory" ? "dir" : "file",
            }));
            return { items, nextCursor: null };
        },
    });
    action("getFileContent", {
        async invoke({ repo, path, ref }) {
            const { owner, repo: name } = splitNwo(repo);
            const branch = ref || "HEAD";
            const clean = path.replace(/^\/+/, "");
            const route = `/${owner}/${name}/blob/${branch}/${clean}?plain=1`;
            const { status, text } = await fetchText(route);
            if (status >= 400)
                throw new Error(`File not found or inaccessible (HTTP ${status}): ${clean}`);
            const doc = new DOMParser().parseFromString(text, "text/html");
            const embedded = doc.querySelector('script[data-target="react-app.embeddedData"]')?.textContent;
            if (!embedded)
                throw new Error(`GitHub did not return file data: ${clean}`);
            const payload = JSON.parse(embedded)?.payload;
            const blob = payload?.codeViewBlobLayoutRoute?.blob;
            const rawLines = payload?.["codeViewBlobLayoutRoute.StyledBlob"]?.rawLines;
            if (blob?.truncated)
                throw new Error(`File is too large to return completely: ${clean}`);
            if (!blob?.viewable || !Array.isArray(rawLines))
                throw new Error(`File is not readable as text: ${clean}`);
            return { repo: `${owner}/${name}`, path: clean, ref: branch, content: `${rawLines.join("\n")}\n` };
        },
    });
    action("listIssues", {
        async invoke({ repo, state, cursor }) {
            const { owner, repo: name } = splitNwo(repo);
            const q = `repo:${owner}/${name} is:issue is:${state || "open"} sort:updated`;
            const { results, nextCursor } = await searchPayload("issues", q, cursor);
            return { items: results.map(issueFromSearch), nextCursor };
        },
    });
    action("listPullRequests", {
        async invoke({ repo, state, cursor }) {
            const { owner, repo: name } = splitNwo(repo);
            const q = `repo:${owner}/${name} is:pr is:${state || "open"} sort:updated`;
            const { results, nextCursor } = await searchPayload("issues", q, cursor);
            return { items: results.map(issueFromSearch), nextCursor };
        },
    });
    const getThread = async (repo, kind, number) => {
        const { owner, repo: name } = splitNwo(repo);
        const { text } = await fetchText(`/${owner}/${name}/${kind}/${number}`);
        const title = text.match(/property="og:title" content="([^"]*)"/)?.[1] ?? "";
        const body = text.match(/property="og:description" content="([^"]*)"/)?.[1] ?? "";
        const state = text.match(/"state":"(open|closed|merged)"/i)?.[1]?.toLowerCase() ?? null;
        return {
            number: parseInt(number, 10),
            title: decode(title.replace(/\s*·.*$/, "")),
            state,
            body: decode(body),
            repo: `${owner}/${name}`,
            url: `${ORIGIN}/${owner}/${name}/${kind}/${number}`,
        };
    };
    action("getIssue", {
        async invoke({ repo, number }) {
            return await getThread(repo, "issues", String(number));
        },
    });
    action("getPullRequest", {
        async invoke({ repo, number }) {
            const t = await getThread(repo, "pull", String(number));
            return { ...t, isPullRequest: true };
        },
    });
    const pullPayload = async (repo, number, route) => {
        const { owner, repo: name } = splitNwo(repo);
        return await fetchPayload(`/${owner}/${name}/pull/${number}/${route}`);
    };
    action("listPullRequestFiles", {
        async invoke({ repo, number }) {
            const payload = await pullPayload(repo, number, "changes");
            const route = payload.pullRequestsChangesRoute ?? {};
            if (route.pageLimits?.filesLimitExceeded) {
                throw new Error(`GitHub truncated pull request files at ${route.pageLimits.filesLimit ?? "its"} file limit`);
            }
            const summaries = new Map((route.diffSummaries ?? []).map((summary) => [summary.path, summary]));
            const items = (route.diffContents ?? []).map((file) => {
                const summary = summaries.get(file.path) ?? {};
                return {
                    path: file.path,
                    status: (file.status ?? summary.changeType ?? "").toString().toLowerCase(),
                    additions: file.linesAdded ?? summary.linesAdded ?? 0,
                    deletions: file.linesDeleted ?? summary.linesDeleted ?? 0,
                    isBinary: !!file.isBinary,
                    isTooBig: !!file.isTooBig,
                    truncatedReason: file.truncatedReason ?? null,
                };
            });
            return { items, nextCursor: null };
        },
    });
    action("listPullRequestCommits", {
        async invoke({ repo, number }) {
            const payload = await pullPayload(repo, number, "commits");
            const route = payload.pullRequestsCommitsRoute ?? {};
            if (route.truncated)
                throw new Error("GitHub truncated the pull request commit list");
            const items = (route.commitGroups ?? []).flatMap((group) => (group.commits ?? []).map((commit) => ({
                oid: commit.oid,
                message: commit.shortMessage ?? "",
                author: commit.authors?.[0]?.login ?? commit.authors?.[0]?.displayName ?? "",
                authoredDate: commit.authoredDate,
                url: commit.url?.startsWith("http") ? commit.url : `${ORIGIN}${commit.url ?? ""}`,
            })));
            return { items, nextCursor: null };
        },
    });
    action("listPullRequestChecks", {
        async invoke({ repo, number }) {
            const payload = await pullPayload(repo, number, "checks");
            const fragment = payload["pullRequestsChecksRoute.Main"]?.value ?? "";
            const doc = new DOMParser().parseFromString(fragment, "text/html");
            const items = [];
            for (const suite of doc.querySelectorAll('details[id^="sidebar_check_suite_"]')) {
                const runLink = suite.querySelector('summary a[href*="/actions/runs/"]');
                const workflow = textOf(runLink?.querySelector("span") ?? runLink);
                for (const jobLink of suite.querySelectorAll('a[href*="/actions/runs/"][href*="/job/"]')) {
                    const href = jobLink.getAttribute("href") ?? "";
                    const ids = href.match(/\/actions\/runs\/([^/]+)\/job\/([^/?#]+)/);
                    if (!ids)
                        continue;
                    const row = jobLink.closest(".checks-list-item");
                    items.push({
                        name: textOf(jobLink),
                        workflow,
                        status: statusFrom(row),
                        runId: ids[1],
                        jobId: ids[2],
                        url: `${ORIGIN}${href.split("?")[0]}`,
                    });
                }
            }
            return { items, nextCursor: null };
        },
    });
    const reviewThread = (thread) => ({
        id: String(thread.id),
        subjectType: thread.subjectType ?? "",
        isResolved: !!thread.isResolved,
        resolvedBy: thread.resolvedBy?.login ?? null,
        comments: (thread.commentsData?.comments ?? []).map((comment) => ({
            id: String(comment.id),
            author: comment.author?.login ?? "",
            body: comment.body ?? "",
            createdAt: comment.createdAt ?? null,
            url: comment.url ?? "",
        })),
    });
    action("listPullRequestReviewThreads", {
        async invoke({ repo, number, cursor }) {
            const { owner, repo: name } = splitNwo(repo);
            const base = `/${owner}/${name}/pull/${number}`;
            if (cursor) {
                if (!cursor.startsWith(`${base}/page_data/threads?`))
                    throw new Error("Invalid review-thread cursor");
                const { json, headers } = await fetchReactPageData(cursor);
                return { items: (json ?? []).map(reviewThread), nextCursor: nextLink(headers) };
            }
            const payload = await fetchPayload(`${base}/changes`);
            const markers = payload.pullRequestsChangesRoute?.markers ?? {};
            const items = Object.values(markers.threads ?? {}).map(reviewThread);
            const pageInfo = markers.threadsPageInfo;
            const nextCursor = pageInfo?.hasNextPage && pageInfo.cursor
                ? `${base}/page_data/threads?after=${encodeURIComponent(pageInfo.cursor)}`
                : null;
            return { items, nextCursor };
        },
    });
    action("listWorkflowRuns", {
        async invoke({ repo, workflow, cursor }) {
            const { owner, repo: name } = splitNwo(repo);
            const base = `/${owner}/${name}/actions`;
            if (cursor && cursor !== base && !cursor.startsWith(`${base}?`) && !cursor.startsWith(`${base}/`)) {
                throw new Error("Invalid workflow-run cursor");
            }
            const workflowPath = workflow
                ? `/workflows/${workflow.replace(/^\/+/, "").split("/").map(encodeURIComponent).join("/")}`
                : "";
            const doc = await fetchDoc(cursor ?? `${base}${workflowPath}`);
            const items = [...doc.querySelectorAll('.Box-row[id^="check_suite_"]')].map((row) => {
                const link = row.querySelector('a[href*="/actions/runs/"]');
                const href = link?.getAttribute("href") ?? "";
                const runId = href.match(/\/actions\/runs\/([^/?#]+)/)?.[1] ?? "";
                return {
                    runId,
                    title: textOf(row.querySelector(".markdown-title")),
                    workflow: textOf(row.querySelector(".text-small .text-bold")),
                    status: statusFrom(link),
                    branch: row.querySelector("a.branch-name")?.getAttribute("title") ?? null,
                    createdAt: row.querySelector("relative-time")?.getAttribute("datetime") ?? null,
                    duration: textOf(row.querySelector('svg[aria-label="Run duration"]')?.parentElement) || null,
                    url: href ? `${ORIGIN}${href}` : "",
                };
            }).filter((run) => run.runId);
            const nextCursor = doc.querySelector('a[rel="next"]')?.getAttribute("href") ?? null;
            return { items, nextCursor };
        },
    });
    action("getWorkflowRun", {
        async invoke({ repo, runId }) {
            const { owner, repo: name } = splitNwo(repo);
            const path = `/${owner}/${name}/actions/runs/${runId}`;
            const doc = await fetchDoc(path);
            const summary = doc.querySelector('[aria-label="Workflow run summary"]');
            const labelParent = (label) => [...(summary?.querySelectorAll("span") ?? [])].find((span) => textOf(span) === label)?.parentElement ?? null;
            const triggerText = textOf([...(summary?.querySelectorAll("span") ?? [])]
                .find((span) => textOf(span).startsWith("Triggered via ")) ?? null);
            const jobs = [...doc.querySelectorAll("streaming-graph-job")].map((job) => {
                const link = job.querySelector('a[href*="/job/"]');
                const href = link?.getAttribute("href") ?? "";
                const jobId = href.match(/\/job\/([^/?#]+)/)?.[1] ?? "";
                return {
                    jobId,
                    name: textOf(job.querySelector('[data-target="streaming-graph-job.name"]')),
                    status: statusFrom(link),
                    duration: textOf(link?.querySelector(".text-small")) || null,
                    url: href ? `${ORIGIN}${href}` : "",
                };
            }).filter((job) => job.jobId);
            const commitHref = summary?.querySelector('a[href*="/commit/"]')?.getAttribute("href") ?? "";
            return {
                runId: String(runId),
                title: textOf(doc.querySelector(".PageHeader-title .markdown-title")),
                workflow: textOf(doc.querySelector(".PageHeader-parentLink-label")),
                status: textOf(labelParent("Status")?.querySelector(".h4")),
                event: triggerText.match(/^Triggered via\s+(\S+)/i)?.[1] ?? null,
                branch: summary?.querySelector("a.branch-name")?.getAttribute("title") ?? null,
                commitSha: commitHref.match(/\/commit\/([^/?#]+)/)?.[1] ?? null,
                createdAt: summary?.querySelector("relative-time")?.getAttribute("datetime") ?? null,
                duration: textOf(labelParent("Total duration")?.querySelector(".h4")) || null,
                jobs,
                url: `${ORIGIN}${path}`,
            };
        },
    });
    action("getWorkflowJob", {
        async invoke({ repo, runId, jobId }) {
            const { owner, repo: name } = splitNwo(repo);
            const path = `/${owner}/${name}/actions/runs/${runId}/job/${jobId}`;
            const doc = await fetchDoc(path);
            const header = doc.querySelector(`[data-url$="/runs/${jobId}/header"]`);
            const headerText = textOf(header);
            const steps = [...doc.querySelectorAll("check-step")].map((step) => ({
                number: parseInt(step.getAttribute("data-number") ?? "0", 10),
                name: step.getAttribute("data-name") ?? "",
                conclusion: step.getAttribute("data-conclusion") || null,
                startedAt: step.getAttribute("data-started-at"),
                completedAt: step.getAttribute("data-completed-at"),
            }));
            return {
                runId: String(runId),
                jobId: String(jobId),
                name: textOf(doc.querySelector("#check-step-header-title .two-line-wrapping"))
                    || textOf(doc.querySelector('[data-target="streaming-graph-job.name"]')),
                status: headerText.split(/\s+/)[0] ?? "",
                startedAt: steps[0]?.startedAt ?? null,
                completedAt: header?.querySelector("relative-time")?.getAttribute("datetime") ?? null,
                duration: headerText.match(/\sin\s+(.+)$/)?.[1] ?? null,
                steps,
                url: `${ORIGIN}${path}`,
            };
        },
    });
    action("listNotifications", {
        async invoke({ cursor }) {
            const doc = await fetchDoc(`/notifications${cursor ? `?after=${encodeURIComponent(cursor)}` : ""}`);
            const repoFromUrl = (url) => {
                const m = url.match(/github\.com\/([^/]+\/[^/]+)/);
                return m ? m[1] : "";
            };
            const items = [...doc.querySelectorAll(".notifications-list-item")].map((row) => {
                const link = row.querySelector("a.notification-list-item-link");
                const url = link?.href ?? "";
                return {
                    title: row.querySelector(".markdown-title")?.innerText.trim() ?? "",
                    repo: repoFromUrl(url),
                    url,
                    unread: row.classList.contains("notification-unread"),
                };
            }).filter((n) => n.title || n.url);
            return { items, nextCursor: null };
        },
    });
    action("searchIssues", {
        async invoke({ query, cursor }) {
            const { results, nextCursor } = await searchPayload("issues", query, cursor);
            return { items: results.map(issueFromSearch), nextCursor };
        },
    });
    const MY_ISSUE_FILTERS = {
        assigned: "assignee:@me",
        created: "author:@me",
        mentioned: "mentions:@me",
    };
    const MY_PR_FILTERS = {
        created: "author:@me",
        assigned: "assignee:@me",
        "review-requested": "review-requested:@me",
        involves: "involves:@me",
    };
    const listMine = async (kind, filters, fallback, args) => {
        const qualifier = filters[args.filter ?? fallback] ?? filters[fallback];
        const q = `is:${kind} is:${args.state || "open"} ${qualifier} sort:updated`;
        const { results, nextCursor } = await searchPayload("issues", q, args.cursor);
        return { items: results.map(issueFromSearch), nextCursor };
    };
    action("listMyIssues", {
        async invoke(args) {
            return await listMine("issue", MY_ISSUE_FILTERS, "assigned", args);
        },
    });
    action("listMyPullRequests", {
        async invoke(args) {
            return await listMine("pr", MY_PR_FILTERS, "created", args);
        },
    });
    action("getCommit", {
        async invoke({ repo, sha }) {
            const { owner, repo: name } = splitNwo(repo);
            const payload = await fetchPayload(`/${owner}/${name}/commit/${sha}`);
            const c = payload.commit ?? {};
            const files = (payload.diffEntryData ?? []).map((f) => ({
                path: f.path ?? f.newPath ?? f.oldPath ?? "",
                changeType: (f.changeType ?? f.status ?? null)?.toString().toLowerCase() ?? null,
                additions: f.numAdded ?? f.linesAdded ?? f.additions ?? null,
                deletions: f.numRemoved ?? f.linesDeleted ?? f.deletions ?? null,
            }));
            return {
                oid: c.oid ?? sha,
                message: c.shortMessage ?? "",
                author: c.authors?.[0]?.login ?? c.authors?.[0]?.displayName ?? "",
                authoredDate: c.authoredDate ?? null,
                parents: (c.parents ?? []).map((p) => p.oid ?? p).filter(Boolean),
                files,
                url: `${ORIGIN}/${owner}/${name}/commit/${c.oid ?? sha}`,
            };
        },
    });
    action("listIssueComments", {
        async invoke({ repo, number }) {
            const { owner, repo: name } = splitNwo(repo);
            const doc = await fetchDoc(`/${owner}/${name}/issues/${number}`);
            const items = [...doc.querySelectorAll(".js-timeline-item")].map((el) => {
                const body = el.querySelector(".comment-body, .js-comment-body");
                if (!body)
                    return null;
                return {
                    author: el.querySelector("a.author")?.textContent?.trim() ?? "",
                    createdAt: el.querySelector("relative-time")?.getAttribute("datetime") ?? null,
                    body: body.textContent?.trim() ?? "",
                };
            }).filter((c) => !!c);
            return { items, nextCursor: null };
        },
    });
    const listTaggedRefs = async (repo, route, cursor) => {
        const { owner, repo: name } = splitNwo(repo);
        const base = `/${owner}/${name}/${route}`;
        if (cursor && cursor !== base && !cursor.startsWith(`${base}?`))
            throw new Error(`Invalid ${route} cursor`);
        const doc = await fetchDoc(cursor ?? base);
        const seen = new Set();
        const items = [];
        for (const a of doc.querySelectorAll('a[href*="/releases/tag/"]')) {
            const tag = decodeURIComponent((a.getAttribute("href") ?? "").split("/tag/")[1] ?? "");
            const label = a.textContent?.trim() ?? "";
            if (!tag || seen.has(tag))
                continue;
            seen.add(tag);
            items.push({ tag, name: label && label !== tag ? label : tag, url: `${ORIGIN}/${owner}/${name}/releases/tag/${tag}` });
        }
        const nextCursor = doc.querySelector('a[rel="next"]')?.getAttribute("href") ?? null;
        return { items, nextCursor };
    };
    action("listReleases", {
        async invoke({ repo, cursor }) {
            return await listTaggedRefs(repo, "releases", cursor);
        },
    });
    action("listTags", {
        async invoke({ repo }) {
            return await listTaggedRefs(repo, "tags");
        },
    });
    action("getReadme", {
        async invoke({ repo, ref }) {
            const { owner, repo: name } = splitNwo(repo);
            const branch = ref || "HEAD";
            const names = ["README.md", "readme.md", "README.rst", "README.txt", "README", "docs/README.md"];
            for (const fn of names) {
                const r = await retryFetch(`https://raw.githubusercontent.com/${owner}/${name}/${branch}/${fn}`, { credentials: "omit" });
                if (r.status < 400)
                    return { repo: `${owner}/${name}`, path: fn, content: await r.text() };
            }
            throw new Error(`README not found in ${owner}/${name}`);
        },
    });
});
