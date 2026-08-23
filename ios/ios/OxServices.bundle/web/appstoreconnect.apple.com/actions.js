(() => {
  // services/builtin/web/appstoreconnect.apple.com/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const ORIGIN = "https://appstoreconnect.apple.com";
    const JSON_HEADERS = {
      Accept: "application/vnd.api+json, application/json",
      "Content-Type": "application/json",
      "x-csrf-itc": "[asc-ui]",
      "x-requested-with": "XMLHttpRequest"
    };
    const parseJson = (text, context) => {
      try {
        return JSON.parse(text);
      } catch {
        throw new Error(`${context}: Apple returned a non-JSON response`);
      }
    };
    const rawSession = async () => {
      const response = await retryFetch(`${ORIGIN}/olympus/v1/session`, {
        credentials: "include",
        headers: { Accept: "application/json" },
        redirect: "manual"
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
      ...extra
    });
    const requestJson = async (path, team, init = {}) => {
      const response = await retryFetch(`${ORIGIN}${path}`, {
        credentials: "include",
        ...init,
        headers: headers(team, init.headers)
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
          } catch {
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
      } catch {
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
        downloadable: Boolean(attributes.downloadable)
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
        url: `${ORIGIN}/apps/${encodeURIComponent(String(item?.id ?? ""))}/distribution`
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
        deviceFamilies: (attributes.deviceFamilies ?? []).map(String)
      };
    };
    const dateTime = (value) => {
      const trimmed = String(value).trim();
      return /^\d{4}-\d{2}-\d{2}$/.test(trimmed) ? `${trimmed}T00:00:00Z` : trimmed;
    };
    action("getSignInUrl", {
      async invoke() {
        return { url: `${ORIGIN}/login` };
      }
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
        } catch {
          return { signedIn: false };
        }
      }
    });
    action("listApps", {
      async invoke({ cursor, limit }) {
        const { team } = await session();
        const query = new URLSearchParams({
          include: "displayableVersions,appStoreIcon",
          "limit[displayableVersions]": "20",
          limit: String(Math.max(1, Math.min(limit ?? 100, 200)))
        });
        if (cursor)
          query.set("cursor", cursor);
        const body = await requestJson(`/iris/v1/apps?${query}`, team);
        const included = includedById(body);
        const items = (body?.data ?? []).map((item) => mapApp(item, included));
        const nextCursor = cursorFrom(body);
        log(`listApps: ${items.length} apps, next=${nextCursor ?? "end"}`);
        return { items, nextCursor };
      }
    });
    action("getApp", {
      async invoke({ id }) {
        const { team } = await session();
        const query = new URLSearchParams({
          include: "displayableVersions,appStoreIcon",
          "limit[displayableVersions]": "20"
        });
        const body = await requestJson(`/iris/v1/apps/${encodeURIComponent(id)}?${query}`, team);
        if (!body?.data)
          throw new Error(`App not found: ${id}`);
        const result = mapApp(body?.data, includedById(body));
        log(`getApp: ${result.id} ${result.name}`);
        return result;
      }
    });
    action("listPreReleaseVersions", {
      async invoke({ appId, platform, cursor, limit }) {
        const { team } = await session();
        const query = new URLSearchParams({
          "filter[app]": appId,
          sort: "-version",
          limit: String(Math.max(1, Math.min(limit ?? 25, 200)))
        });
        if (platform)
          query.set("filter[platform]", platform);
        if (cursor)
          query.set("cursor", cursor);
        const body = await requestJson(`/iris/v1/preReleaseVersions?${query}`, team);
        const items = (body?.data ?? []).map((item) => ({
          id: String(item?.id ?? ""),
          version: String(item?.attributes?.version ?? ""),
          platform: String(item?.attributes?.platform ?? "")
        }));
        const nextCursor = cursorFrom(body);
        log(`listPreReleaseVersions ${appId}: ${items.length}, next=${nextCursor ?? "end"}`);
        return { items, nextCursor };
      }
    });
    action("listBuilds", {
      async invoke({ appId, platform, processingState, cursor, limit }) {
        const { team } = await session();
        const query = new URLSearchParams({
          "filter[app]": appId,
          include: "preReleaseVersion,buildBundles,icons",
          sort: "-version",
          limit: String(Math.max(1, Math.min(limit ?? 25, 100)))
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
      }
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
            createdAt: attributes.createdDate == null ? null : String(attributes.createdDate)
          };
        });
        log(`listBetaGroups ${appId}: ${items.length}`);
        return { items, nextCursor: cursorFrom(body) };
      }
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
            frequency: frequency ?? "day"
          })
        });
        const results = (body?.results ?? []).map((result) => ({
          metric: String(result?.measure ?? ""),
          valueType: String(result?.type ?? ""),
          total: Number(result?.total ?? 0),
          previousTotal: Number(result?.previousTotal ?? 0),
          percentChange: Number(result?.percentChange ?? 0),
          meetsThreshold: Boolean(result?.meetsThreshold),
          points: (result?.data ?? []).map((point) => ({ date: String(point?.date ?? ""), value: Number(point?.value ?? 0) }))
        }));
        log(`getAppAnalytics ${appId}: ${results.length} metrics from ${startDate} to ${endDate}`);
        return { results };
      }
    });
    action("listTeamMembers", {
      async invoke({ cursor, limit }) {
        const { team } = await session();
        const query = new URLSearchParams({
          "fields[users]": "firstName,lastName,emailVettingRequired,roles,allAppsVisible,email,provisioningAllowed,username",
          sort: "lastName",
          limit: String(Math.max(1, Math.min(limit ?? 100, 500)))
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
            provisioningAllowed: Boolean(attributes.provisioningAllowed)
          };
        });
        const nextCursor = cursorFrom(body);
        log(`listTeamMembers: ${items.length}, next=${nextCursor ?? "end"}`);
        return { items, nextCursor };
      }
    });
  };
  var actions_default = install;

  // services/action-runtime.ts
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

  installService("appstoreconnect.apple.com", actions_default);
})();
