window.ox.install(1, ({ action, retryFetch, log }) => {
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
