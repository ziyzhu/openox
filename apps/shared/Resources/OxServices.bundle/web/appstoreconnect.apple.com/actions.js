window.ox.install(({ action }) => {
const retryFetch = async (input, init, options) => {
  const method = String(init?.method ?? "GET").toUpperCase();
  const retries = ["GET", "HEAD"].includes(method) ? (options?.retries ?? 3) : 0;
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


const log = (...args) => console.log(...args);
    const ORIGIN = "https://appstoreconnect.apple.com";
    const JSON_HEADERS = {
        Accept: "application/vnd.api+json, application/json",
        "Content-Type": "application/json",
        "x-csrf-itc": "[asc-ui]",
        "x-requested-with": "XMLHttpRequest",
    };
    const parseJson = (text, context) => {
        try {
            return JSON.parse(text);
        }
        catch {
            throw new Error(`${context}: Apple returned a non-JSON response`);
        }
    };
    const rawSession = async () => {
        const response = await retryFetch(`${ORIGIN}/olympus/v1/session`, {
            credentials: "include",
            headers: { Accept: "application/json" },
            redirect: "manual",
        });
        const text = await response.text();
        return { response, text };
    };
    const session = async () => {
        const { response, text } = await rawSession();
        if (response.status === 401 || response.status === 403 || response.status === 302) {
            throw new Error("Sign in to App Store Connect is required");
        }
        if (response.status < 200 || response.status >= 300) {
            throw new Error(`App Store Connect session HTTP ${response.status}`);
        }
        const body = parseJson(text, "App Store Connect session");
        const id = body?.provider?.publicProviderId;
        if (!id)
            throw new Error("App Store Connect has no active provider");
        return { body, team: { id: String(id), type: "PURPLESOFTWARE" } };
    };
    const headers = (team, extra = {}) => ({
        ...JSON_HEADERS,
        "x-connect-team-id": team.id,
        "x-connect-team-type": team.type,
        ...extra,
    });
    const requestJson = async (path, team, init = {}) => {
        const response = await retryFetch(`${ORIGIN}${path}`, {
            credentials: "include",
            ...init,
            headers: headers(team, init.headers),
        });
        const text = await response.text();
        if (response.status === 401 || response.status === 403) {
            throw new Error(`App Store Connect access denied (HTTP ${response.status}); sign in and check your role`);
        }
        if (response.status < 200 || response.status >= 300) {
            const detail = (() => {
                try {
                    const body = JSON.parse(text);
                    return body?.errors?.[0]?.detail ?? body?.message ?? "";
                }
                catch {
                    return "";
                }
            })();
            throw new Error(`App Store Connect HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
        }
        return parseJson(text, path);
    };
    const cursorFrom = (body) => {
        if (body?.meta?.paging?.nextCursor)
            return String(body.meta.paging.nextCursor);
        const next = body?.links?.next;
        if (!next)
            return null;
        try {
            return new URL(next, ORIGIN).searchParams.get("cursor");
        }
        catch {
            return null;
        }
    };
    const imageUrl = (asset) => {
        const template = asset?.templateUrl;
        if (!template)
            return null;
        return String(template).replace("{w}", "256").replace("{h}", "256").replace("{f}", "png");
    };
    const includedById = (body) => new Map((body?.included ?? []).map((item) => [String(item.id), item]));
    const mapVersion = (item) => {
        const attributes = item?.attributes ?? {};
        return {
            id: String(item?.id ?? ""),
            version: String(attributes.versionString ?? ""),
            platform: String(attributes.platform ?? ""),
            state: String(attributes.appVersionState ?? attributes.appStoreState ?? ""),
            releaseType: attributes.releaseType == null ? null : String(attributes.releaseType),
            createdAt: attributes.createdDate == null ? null : String(attributes.createdDate),
            earliestReleaseAt: attributes.earliestReleaseDate == null ? null : String(attributes.earliestReleaseDate),
            downloadable: Boolean(attributes.downloadable),
        };
    };
    const mapApp = (item, included) => {
        const attributes = item?.attributes ?? {};
        const versionIds = item?.relationships?.displayableVersions?.data ?? [];
        const versions = versionIds.map((reference) => included.get(reference.id)).filter(Boolean).map(mapVersion);
        const iconId = item?.relationships?.appStoreIcon?.data?.id;
        const icon = iconId ? included.get(iconId) : null;
        return {
            id: String(item?.id ?? ""),
            name: String(attributes.name ?? ""),
            bundleId: String(attributes.bundleId ?? ""),
            sku: String(attributes.sku ?? ""),
            primaryLocale: String(attributes.primaryLocale ?? ""),
            distributionType: String(attributes.distributionType ?? ""),
            removed: Boolean(attributes.removed),
            storeUrl: attributes.storeUrl == null ? null : String(attributes.storeUrl),
            iconUrl: imageUrl(icon?.attributes?.iconAsset),
            versions,
            url: `${ORIGIN}/apps/${encodeURIComponent(String(item?.id ?? ""))}/distribution`,
        };
    };
    const mapBuild = (item, included) => {
        const attributes = item?.attributes ?? {};
        const preReleaseId = item?.relationships?.preReleaseVersion?.data?.id;
        const preRelease = preReleaseId ? included.get(preReleaseId) : null;
        const bundleId = item?.relationships?.buildBundles?.data?.[0]?.id;
        const bundle = bundleId ? included.get(bundleId) : null;
        return {
            id: String(item?.id ?? ""),
            buildNumber: String(attributes.version ?? ""),
            version: preRelease?.attributes?.version == null ? null : String(preRelease.attributes.version),
            platform: preRelease?.attributes?.platform == null ? null : String(preRelease.attributes.platform),
            bundleId: bundle?.attributes?.bundleId == null ? null : String(bundle.attributes.bundleId),
            uploadedAt: attributes.uploadedDate == null ? null : String(attributes.uploadedDate),
            expiresAt: attributes.expirationDate == null ? null : String(attributes.expirationDate),
            expired: Boolean(attributes.expired),
            processingState: String(attributes.processingState ?? ""),
            testingState: attributes.qcState == null ? null : String(attributes.qcState),
            minimumOsVersion: attributes.minOsVersion == null ? null : String(attributes.minOsVersion),
            usesNonExemptEncryption: attributes.usesNonExemptEncryption == null ? null : Boolean(attributes.usesNonExemptEncryption),
            deviceFamilies: (attributes.deviceFamilies ?? []).map(String),
        };
    };
    const dateTime = (value) => {
        const trimmed = String(value).trim();
        return /^\d{4}-\d{2}-\d{2}$/.test(trimmed) ? `${trimmed}T00:00:00Z` : trimmed;
    };

    const listAllApps = async () => {
        const { team } = await session();
        const query = new URLSearchParams({ include: "displayableVersions,appStoreIcon", "limit[displayableVersions]": "20", limit: "200" });
        const apps = [];
        const seen = new Set();
        for (let page = 0; page < 100; page++) {
            const body = await requestJson(`/iris/v1/apps?${query}`, team);
            const included = includedById(body);
            apps.push(...(body?.data ?? []).map(item => mapApp(item, included)));
            const cursor = cursorFrom(body);
            if (!cursor) return apps;
            if (seen.has(cursor)) throw new Error("App pagination did not advance");
            seen.add(cursor);
            query.set("cursor", cursor);
        }
        throw new Error("App pagination exceeded 100 pages; narrow the request");
    };
    const getVersionResource = async (team, versionId) => requestJson(`/iris/v1/appStoreVersions/${encodeURIComponent(versionId)}?include=app,appStoreVersionLocalizations,appStoreReviewDetail`, team);
    const nullableString = (value) => value == null ? null : String(value);
    const mapLocalization = (item) => {
        const a = item?.attributes ?? {};
        return { id: String(item?.id ?? ""), locale: String(a.locale ?? ""), description: nullableString(a.description), keywords: nullableString(a.keywords), marketingUrl: nullableString(a.marketingUrl), promotionalText: nullableString(a.promotionalText), supportUrl: nullableString(a.supportUrl), whatsNew: nullableString(a.whatsNew) };
    };
    const getDraftData = async (team, appId, versionId, locale) => {
        const versionBody = await getVersionResource(team, versionId);
        if (!versionBody?.data) throw new Error(`Version not found: ${versionId}`);
        const va = versionBody.data.attributes ?? {};
        const linkedApp = versionBody.data.relationships?.app?.data?.id;
        if ((!linkedApp || String(linkedApp) !== String(appId))) throw new Error("Version does not belong to the supplied app");
        const query = new URLSearchParams({ "filter[appStoreVersion]": versionId, limit: "50" });
        const localizationBody = await requestJson(`/iris/v1/appStoreVersionLocalizations?${query}`, team);
        let localizations = (localizationBody?.data ?? []).map(mapLocalization);
        if (locale) localizations = localizations.filter((x) => x.locale === locale);
        return { appId: String(appId), versionId: String(versionId), version: String(va.versionString ?? ""), platform: String(va.platform ?? ""), state: String(va.appVersionState ?? va.appStoreState ?? ""), releaseType: nullableString(va.releaseType), earliestReleaseAt: nullableString(va.earliestReleaseDate), copyright: nullableString(va.copyright), localizations };
    };
    action("getSignInUrl", {
        async invoke() {
            return { url: `${ORIGIN}/login` };
        },
    });
    action("getSignInState", {
        async invoke() {
            const { response, text } = await rawSession();
            if (response.status === 401 || response.status === 403 || response.status === 302)
                return { signedIn: false };
            if (response.status < 200 || response.status >= 300)
                throw new Error(`App Store Connect session HTTP ${response.status}`);
            try {
                const body = JSON.parse(text);
                return { signedIn: Boolean(body?.provider?.publicProviderId && body?.user) };
            }
            catch {
                return { signedIn: false };
            }
        },
    });
    action("listApps", {
        async invoke({ cursor, limit }) {
            const { team } = await session();
            const query = new URLSearchParams({
                include: "displayableVersions,appStoreIcon",
                "limit[displayableVersions]": "20",
                limit: String(Math.max(1, Math.min(limit ?? 100, 200))),
            });
            if (cursor)
                query.set("cursor", cursor);
            const body = await requestJson(`/iris/v1/apps?${query}`, team);
            const included = includedById(body);
            const items = (body?.data ?? []).map((item) => mapApp(item, included));
            const nextCursor = cursorFrom(body);
            log(`listApps: ${items.length} apps, next=${nextCursor ?? "end"}`);
            return { items, nextCursor };
        },
    });
    action("getApp", {
        async invoke({ id }) {
            const { team } = await session();
            const query = new URLSearchParams({
                include: "displayableVersions,appStoreIcon",
                "limit[displayableVersions]": "20",
            });
            const body = await requestJson(`/iris/v1/apps/${encodeURIComponent(id)}?${query}`, team);
            if (!body?.data)
                throw new Error(`App not found: ${id}`);
            const result = mapApp(body?.data, includedById(body));
            log(`getApp: ${result.id} ${result.name}`);
            return result;
        },
    });
    action("listPreReleaseVersions", {
        async invoke({ appId, platform, cursor, limit }) {
            const { team } = await session();
            const query = new URLSearchParams({
                "filter[app]": appId,
                sort: "-version",
                limit: String(Math.max(1, Math.min(limit ?? 25, 200))),
            });
            if (platform)
                query.set("filter[platform]", platform);
            if (cursor)
                query.set("cursor", cursor);
            const body = await requestJson(`/iris/v1/preReleaseVersions?${query}`, team);
            const items = (body?.data ?? []).map((item) => ({
                id: String(item?.id ?? ""),
                version: String(item?.attributes?.version ?? ""),
                platform: String(item?.attributes?.platform ?? ""),
            }));
            const nextCursor = cursorFrom(body);
            log(`listPreReleaseVersions ${appId}: ${items.length}, next=${nextCursor ?? "end"}`);
            return { items, nextCursor };
        },
    });
    action("listBuilds", {
        async invoke({ appId, platform, processingState, cursor, limit }) {
            const { team } = await session();
            const query = new URLSearchParams({
                "filter[app]": appId,
                include: "preReleaseVersion,buildBundles,icons",
                sort: "-version",
                limit: String(Math.max(1, Math.min(limit ?? 25, 100))),
            });
            if (platform)
                query.set("filter[preReleaseVersion.platform]", platform);
            if (processingState)
                query.set("filter[processingState]", processingState);
            if (cursor)
                query.set("cursor", cursor);
            const body = await requestJson(`/iris/v1/builds?${query}`, team);
            const included = includedById(body);
            const items = (body?.data ?? []).map((item) => mapBuild(item, included));
            const nextCursor = cursorFrom(body);
            log(`listBuilds ${appId}: ${items.length}, next=${nextCursor ?? "end"}`);
            return { items, nextCursor };
        },
    });
    action("listBetaGroups", {
        async invoke({ appId }) {
            const { team } = await session();
            const query = new URLSearchParams({ "filter[app]": appId, sort: "name", limit: "300" });
            const body = await requestJson(`/iris/v1/betaGroups?${query}`, team);
            const items = (body?.data ?? []).map((item) => {
                const attributes = item?.attributes ?? {};
                return {
                    id: String(item?.id ?? ""),
                    name: String(attributes.name ?? ""),
                    internal: Boolean(attributes.isInternalGroup),
                    allBuilds: Boolean(attributes.hasAccessToAllBuilds),
                    feedbackEnabled: Boolean(attributes.feedbackEnabled),
                    publicLinkEnabled: Boolean(attributes.publicLinkEnabled),
                    publicLink: attributes.publicLink == null ? null : String(attributes.publicLink),
                    createdAt: attributes.createdDate == null ? null : String(attributes.createdDate),
                };
            });
            log(`listBetaGroups ${appId}: ${items.length}`);
            return { items, nextCursor: cursorFrom(body) };
        },
    });
    action("getAppAnalytics", {
        async invoke({ appId, startDate, endDate, frequency, metrics }) {
            const { team } = await session();
            const selected = metrics?.length ? metrics : ["units", "redownloads", "conversionRate", "impressionsTotal", "pageViewCount", "updates"];
            const body = await requestJson("/analytics/api/v1/data/app/detail/measures", team, {
                method: "POST",
                headers: { "x-requested-by": "appstoreconnect.apple.com" },
                body: JSON.stringify({
                    adamId: [appId],
                    startTime: dateTime(startDate),
                    endTime: dateTime(endDate),
                    measures: selected,
                    frequency: frequency ?? "day",
                }),
            });
            const results = (body?.results ?? []).map((result) => ({
                metric: String(result?.measure ?? ""),
                valueType: String(result?.type ?? ""),
                total: Number(result?.total ?? 0),
                previousTotal: Number(result?.previousTotal ?? 0),
                percentChange: Number(result?.percentChange ?? 0),
                meetsThreshold: Boolean(result?.meetsThreshold),
                points: (result?.data ?? []).map((point) => ({ date: String(point?.date ?? ""), value: Number(point?.value ?? 0) })),
            }));
            log(`getAppAnalytics ${appId}: ${results.length} metrics from ${startDate} to ${endDate}`);
            return { results };
        },
    });
    action("getPortfolioDashboard", {
        async invoke({ startDate, endDate, frequency, includeRemoved }) {
            const apps = (await listAllApps()).filter((app) => includeRemoved || !app.removed);
            const selected = ["units", "redownloads", "conversionRate", "impressionsTotal", "pageViewCount", "updates"];
            const rows = [];
            for (const app of apps) {
                const { team } = await session();
                const body = await requestJson("/analytics/api/v1/data/app/detail/measures", team, { method: "POST", headers: { "x-requested-by": "appstoreconnect.apple.com" }, body: JSON.stringify({ adamId: [app.id], startTime: dateTime(startDate), endTime: dateTime(endDate), measures: selected, frequency: frequency ?? "day" }) });
                rows.push({ appId: app.id, name: app.name, removed: app.removed, metrics: (body?.results ?? []).map((x) => ({ metric: String(x?.measure ?? ""), total: Number(x?.total ?? 0), previousTotal: Number(x?.previousTotal ?? 0), percentChange: Number(x?.percentChange ?? 0) })) });
            }
            const names = [...new Set(rows.flatMap((r) => r.metrics.map((m) => m.metric)))].filter((metric) => metric !== "conversionRate");
            const portfolio = names.map((metric) => { const matches = rows.flatMap((r) => r.metrics.filter((m) => m.metric === metric)); const total = matches.reduce((n, m) => n + m.total, 0); const previousTotal = matches.reduce((n, m) => n + m.previousTotal, 0); return { metric, total, previousTotal, percentChange: previousTotal ? (total - previousTotal) / previousTotal : 0 }; });
            return { apps: rows, portfolio };
        },
    });
    action("listCustomerReviews", {
        async invoke({ appId, territory, sort, cursor, limit }) {
            const { team } = await session();
            const sortMap = { newest: "-createdDate", oldest: "createdDate", highestRating: "-rating", lowestRating: "rating" };
            const query = new URLSearchParams({ limit: String(Math.max(1, Math.min(limit ?? 50, 200))), sort: sortMap[sort ?? "newest"] });
            if (territory) query.set("filter[territory]", territory.toUpperCase());
            if (cursor) query.set("cursor", cursor);
            const body = await requestJson(`/iris/v1/apps/${encodeURIComponent(appId)}/customerReviews?${query}`, team);
            const items = (body?.data ?? []).map((item) => { const a = item?.attributes ?? {}; return { id: String(item?.id ?? ""), rating: Number(a.rating ?? 0), title: String(a.title ?? ""), body: String(a.body ?? ""), reviewerNickname: String(a.reviewerNickname ?? ""), createdAt: String(a.createdDate ?? ""), territory: String(a.territory ?? "") }; });
            return { items, nextCursor: cursorFrom(body) };
        },
    });
    action("getVersionDraft", { async invoke({ appId, versionId, locale }) { const { team } = await session(); return getDraftData(team, appId, versionId, locale); } });
    action("getReleaseReadiness", {
        async invoke({ appId, versionId }) {
            const { team } = await session();
            const body = await getVersionResource(team, versionId); const d = body?.data; if (!d) throw new Error(`Version not found: ${versionId}`);
            const a = d.attributes ?? {}; const relationships = d.relationships ?? {}; const linkedApp = relationships.app?.data?.id; if ((!linkedApp || String(linkedApp) !== String(appId))) throw new Error("Version does not belong to the supplied app");
            const draft = await getDraftData(team, appId, versionId); const buildBody = await requestJson(`/iris/v1/appStoreVersions/${encodeURIComponent(versionId)}/build`, team);
            const warnings = []; const state = String(a.appVersionState ?? a.appStoreState ?? ""); if (!buildBody?.data) warnings.push("No build is attached"); if (!relationships.appStoreReviewDetail?.data) warnings.push("App Review information is missing"); if (!draft.localizations.length) warnings.push("No version localizations exist"); for (const l of draft.localizations) { if (!l.description) warnings.push(`${l.locale}: description is missing`); if (!l.supportUrl) warnings.push(`${l.locale}: support URL is missing`); }
            return { versionId: String(versionId), version: String(a.versionString ?? ""), state, hasBuild: Boolean(buildBody?.data), hasReviewDetail: Boolean(relationships.appStoreReviewDetail?.data), localizationCount: draft.localizations.length, warnings, url: `${ORIGIN}/apps/${encodeURIComponent(appId)}/distribution/${String(a.platform ?? "IOS").toLowerCase().replace("_", "-")}/version/deliverable` };
        },
    });
    action("getReviewIssues", {
        async invoke({ appId, versionId }) {
            const { team } = await session();
            const versionBody = await getVersionResource(team, versionId);
            const versionItem = versionBody?.data;
            if (!versionItem) throw new Error(`Version not found: ${versionId}`);
            const linkedApp = versionItem?.relationships?.app?.data?.id;
            if ((!linkedApp || String(linkedApp) !== String(appId))) throw new Error("Version does not belong to the supplied app");
            const versionAttributes = versionItem.attributes ?? {};
            const threadQuery = new URLSearchParams({
                "filter[appStoreVersion]": versionId,
                include: "appStoreVersions,reviewSubmission",
                "limit[appStoreVersions]": "2000",
            });
            const threadsBody = await requestJson(`/iris/v1/resolutionCenterThreads?${threadQuery}`, team);
            const threads = (threadsBody?.data ?? []).filter((item) => item?.relationships?.reviewSubmission?.data?.id);
            threads.sort((a, b) => String(b?.attributes?.createdDate ?? "").localeCompare(String(a?.attributes?.createdDate ?? "")));
            const thread = threads[0] ?? null;
            const base = {
                appId: String(appId),
                versionId: String(versionId),
                version: String(versionAttributes.versionString ?? ""),
                state: String(versionAttributes.appVersionState ?? versionAttributes.appStoreState ?? ""),
                url: `${ORIGIN}/apps/${encodeURIComponent(appId)}/distribution/reviewsubmissions`,
            };
            if (!thread) return { ...base, submission: null, threadId: null, messages: [] };
            const submissionId = String(thread.relationships.reviewSubmission.data.id);
            const [submissionBody, messagesBody] = await Promise.all([
                requestJson(`/iris/v1/reviewSubmissions/${encodeURIComponent(submissionId)}`, team),
                requestJson(`/iris/v1/resolutionCenterThreads/${encodeURIComponent(thread.id)}/resolutionCenterMessages?include=fromActor,rejections,resolutionCenterMessageAttachments&limit[rejections]=2000&limit[resolutionCenterMessageAttachments]=1000`, team),
            ]);
            const included = includedById(messagesBody);
            const plainText = (html) => {
                const document = new DOMParser().parseFromString(String(html ?? ""), "text/html");
                return String(document.body?.textContent ?? "").replace(/\u00a0/g, " ").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
            };
            const messages = (messagesBody?.data ?? []).map((item) => {
                const actorRef = item?.relationships?.fromActor?.data;
                const actor = actorRef ? included.get(String(actorRef.id)) : null;
                const rejectionRefs = item?.relationships?.rejections?.data ?? [];
                const guidelines = rejectionRefs.flatMap((ref) => included.get(String(ref.id))?.attributes?.reasons ?? []).map((reason) => ({
                    section: String(reason?.reasonSection ?? ""),
                    description: String(reason?.reasonDescription ?? ""),
                    code: String(reason?.reasonCode ?? ""),
                }));
                const attachmentRefs = item?.relationships?.resolutionCenterMessageAttachments?.data ?? [];
                const attachments = attachmentRefs.map((ref) => included.get(String(ref.id))).filter(Boolean).map((attachment) => ({
                    id: String(attachment.id ?? ""),
                    fileName: String(attachment?.attributes?.fileName ?? ""),
                    downloadUrl: nullableString(attachment?.attributes?.downloadUrl),
                    state: nullableString(attachment?.attributes?.assetDeliveryState),
                }));
                return {
                    id: String(item?.id ?? ""),
                    createdAt: nullableString(item?.attributes?.createdDate),
                    actorType: String(actor?.attributes?.actorType ?? "UNKNOWN"),
                    body: plainText(item?.attributes?.messageBody),
                    guidelines,
                    attachments,
                };
            });
            const submissionAttributes = submissionBody?.data?.attributes ?? {};
            log(`getReviewIssues ${versionId}: ${messages.length} messages`);
            return {
                ...base,
                submission: {
                    id: submissionId,
                    state: String(submissionAttributes.state ?? ""),
                    submittedAt: nullableString(submissionAttributes.submittedDate),
                    lastUpdatedAt: nullableString(submissionAttributes.lastUpdatedDate),
                },
                threadId: String(thread.id),
                messages,
            };
        },
    });
    action("createAppVersion", {
        async invoke({ appId, version, platform, releaseType, earliestReleaseAt }) {
            const { team } = await session(); const chosenRelease = releaseType ?? "MANUAL"; if (chosenRelease === "SCHEDULED" && !earliestReleaseAt) throw new Error("earliestReleaseAt is required for a scheduled release");
            const query = new URLSearchParams({ "filter[app]": appId, "filter[platform]": platform ?? "IOS", limit: "200" }); const existing = await requestJson(`/iris/v1/appStoreVersions?${query}`, team); if ((existing?.data ?? []).some((x) => String(x?.attributes?.versionString) === version)) throw new Error(`Version ${version} already exists for this platform`);
            const attributes = { versionString: version, platform: platform ?? "IOS", releaseType: chosenRelease }; if (chosenRelease === "SCHEDULED") attributes.earliestReleaseDate = earliestReleaseAt;
            const body = await requestJson("/iris/v1/appStoreVersions", team, { method: "POST", body: JSON.stringify({ data: { type: "appStoreVersions", attributes, relationships: { app: { data: { type: "apps", id: appId } } } } }) }); const item = body?.data; if (!item?.id) throw new Error("Apple did not return the created version"); const a = item.attributes ?? {};
            return { id: String(item.id), appId: String(appId), version: String(a.versionString ?? version), platform: String(a.platform ?? platform ?? "IOS"), state: String(a.appVersionState ?? a.appStoreState ?? "PREPARE_FOR_SUBMISSION"), releaseType: nullableString(a.releaseType ?? chosenRelease), url: `${ORIGIN}/apps/${encodeURIComponent(appId)}/distribution` };
        },
    });
    action("updateVersionDraft", {
        async invoke(args) {
            const { team } = await session();
            const current = await getDraftData(team, args.appId, args.versionId);
            const editable = new Set(["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]);
            if (!editable.has(current.state)) throw new Error(`Version state ${current.state} is not editable`);
            const versionKeys = ["copyright", "releaseType", "earliestReleaseAt"];
            const localizationKeys = ["description", "keywords", "marketingUrl", "promotionalText", "supportUrl", "whatsNew"];
            const supplied = key => Object.prototype.hasOwnProperty.call(args, key);
            const changedVersion = versionKeys.filter(supplied);
            const changedLocalization = localizationKeys.filter(supplied);
            if (!changedVersion.length && !changedLocalization.length) throw new Error("Provide at least one field to update");
            const releaseType = supplied("releaseType") ? args.releaseType : current.releaseType;
            const earliestReleaseAt = supplied("earliestReleaseAt") ? args.earliestReleaseAt : current.earliestReleaseAt;
            if (releaseType === "SCHEDULED" && !earliestReleaseAt) throw new Error("earliestReleaseAt is required for a scheduled release");
            let localization;
            if (changedLocalization.length) {
                if (!args.locale) throw new Error("locale is required when updating localized fields");
                localization = current.localizations.find(item => item.locale === args.locale);
                if (!localization) throw new Error(`Localization not found: ${args.locale}`);
            }
            const updatedFields = [];
            if (changedVersion.length) {
                const attributes = Object.fromEntries(changedVersion.map(key => [key === "earliestReleaseAt" ? "earliestReleaseDate" : key, args[key]]));
                await requestJson(`/iris/v1/appStoreVersions/${encodeURIComponent(args.versionId)}`, team, { method: "PATCH", body: JSON.stringify({ data: { type: "appStoreVersions", id: args.versionId, attributes } }) });
                updatedFields.push(...changedVersion);
            }
            if (localization) {
                const attributes = Object.fromEntries(changedLocalization.map(key => [key, args[key]]));
                try {
                    await requestJson(`/iris/v1/appStoreVersionLocalizations/${encodeURIComponent(localization.id)}`, team, { method: "PATCH", body: JSON.stringify({ data: { type: "appStoreVersionLocalizations", id: localization.id, attributes } }) });
                } catch (error) {
                    throw new Error(`Localization update failed after version fields [${updatedFields.join(", ")}] were updated; read the draft before retrying: ${error.message}`);
                }
                updatedFields.push(...changedLocalization);
            }
            const draft = await getDraftData(team, args.appId, args.versionId, args.locale);
            return { versionId: String(args.versionId), state: draft.state, updatedFields, draft };
        },
    });

    action("listTeamMembers", {
        async invoke({ cursor, limit }) {
            const { team } = await session();
            const query = new URLSearchParams({
                "fields[users]": "firstName,lastName,emailVettingRequired,roles,allAppsVisible,email,provisioningAllowed,username",
                sort: "lastName",
                limit: String(Math.max(1, Math.min(limit ?? 100, 500))),
            });
            if (cursor)
                query.set("cursor", cursor);
            const body = await requestJson(`/iris/v1/users?${query}`, team);
            const items = (body?.data ?? []).map((item) => {
                const attributes = item?.attributes ?? {};
                return {
                    id: String(item?.id ?? ""),
                    firstName: String(attributes.firstName ?? ""),
                    lastName: String(attributes.lastName ?? ""),
                    email: String(attributes.email ?? ""),
                    username: String(attributes.username ?? ""),
                    roles: (attributes.roles ?? []).map(String),
                    allAppsVisible: Boolean(attributes.allAppsVisible),
                    provisioningAllowed: Boolean(attributes.provisioningAllowed),
                };
            });
            const nextCursor = cursorFrom(body);
            log(`listTeamMembers: ${items.length}, next=${nextCursor ?? "end"}`);
            return { items, nextCursor };
        },
    });
});
