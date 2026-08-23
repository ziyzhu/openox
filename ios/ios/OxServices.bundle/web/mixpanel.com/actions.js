(() => {
  // services/action-lib.ts
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

  // services/builtin/web/mixpanel.com/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const ORIGIN = "https://mixpanel.com";
    const readJson = async (response, path) => {
      const text = await response.text();
      let json;
      try {
        json = JSON.parse(text);
      } catch {
        throw new Error(`${path}: non-JSON response (HTTP ${response.status}) — sign in to Mixpanel again`);
      }
      if (!response.ok)
        throw new Error(`${path}: HTTP ${response.status}`);
      if ("status" in json) {
        if (json.status !== "ok")
          throw new Error(`${path}: ${json?.error || json?.message || "Mixpanel request failed"}`);
        return json.results;
      }
      return json;
    };
    const apiGet = async (path) => {
      const response = await retryFetch(path, {
        credentials: "include",
        headers: { accept: "application/json" }
      });
      return readJson(response, path.split("?")[0]);
    };
    const apiPost = async (path, body, projectId, options = {}) => {
      const csrf = cookie("csrftoken");
      if (!csrf)
        throw new Error("Not signed in to Mixpanel (no CSRF cookie). Sign in first.");
      const requestUrl = options.requestUrl ?? `${ORIGIN}/project/${encodeURIComponent(projectId)}/app/events`;
      const response = await retryFetch(path, {
        method: "POST",
        credentials: "include",
        headers: {
          accept: "application/json",
          "content-type": options.contentType ?? "text/plain;charset=UTF-8",
          "project-id": projectId,
          "request-url": requestUrl,
          "x-csrftoken": csrf,
          ...options.headers
        },
        body: JSON.stringify(body)
      });
      return readJson(response, path);
    };
    const asEntries = (value) => value && typeof value === "object" ? Object.entries(value) : [];
    const nullableText = (value) => {
      const text = String(value ?? "").trim();
      return text || null;
    };
    const dashboardRow = (dashboard, workspaceId, projectId) => ({
      id: String(dashboard?.id ?? ""),
      workspaceId,
      title: String(dashboard?.title ?? ""),
      description: nullableText(dashboard?.description),
      creator: nullableText(dashboard?.creator_name ?? dashboard?.creator),
      createdAt: nullableText(dashboard?.created),
      modifiedAt: nullableText(dashboard?.modified),
      private: Boolean(dashboard?.is_private),
      favorited: Boolean(dashboard?.is_favorited),
      url: `${ORIGIN}/project/${encodeURIComponent(projectId)}/view/${encodeURIComponent(workspaceId)}/app/boards#id=${encodeURIComponent(String(dashboard?.id ?? ""))}`
    });
    const reportRow = (report) => ({
      id: String(report?.id ?? ""),
      name: String(report?.name ?? ""),
      type: String(report?.type ?? report?.original_type ?? ""),
      chartType: nullableText(report?.params?.displayOptions?.chartType),
      description: nullableText(report?.description),
      createdAt: nullableText(report?.created),
      modifiedAt: nullableText(report?.modified)
    });
    const decodeCursor = (cursor) => {
      if (!cursor)
        return null;
      try {
        return JSON.parse(cursor);
      } catch {
        throw new Error("Invalid event cursor");
      }
    };
    const projectIdForWorkspace = async (workspaceId) => {
      const user = await apiGet("/api/app/me/");
      const workspace = user?.workspaces?.[workspaceId];
      const projectId = String(workspace?.project_id ?? "");
      if (!projectId)
        throw new Error(`Workspace not found: ${workspaceId}`);
      return projectId;
    };
    const eventProperties = [
      ["$event_name", "event", "Event Name"],
      ["$time", "event", "Time"],
      ["$distinct_id", "event", "Distinct ID"],
      ["$city", "event", "City"],
      ["mp_country_code", "event", "Country"],
      ["$os", "event", "Operating System"],
      ["$email", "event", "Email"],
      ["$current_url", "event", "Current URL"],
      ["$email", "user", "Email"],
      ["$name", "user", "Name"],
      ["$first_name", "user", "First Name"],
      ["$last_name", "user", "Last Name"]
    ].map(([value, resourceType, label]) => ({
      value,
      resourceType,
      label,
      type: "string",
      propertyDefaultType: "string"
    }));
    action("getSignInUrl", {
      async invoke() {
        return { url: `${ORIGIN}/login/` };
      }
    });
    action("getSignInState", {
      async invoke() {
        const response = await retryFetch("/api/app/me/", {
          credentials: "include",
          headers: { accept: "application/json" }
        });
        if (response.status === 401 || response.status === 403 || response.redirected || response.url.includes("/login")) {
          log(`getSignInState: status=${response.status} signedIn=false`);
          return { signedIn: false };
        }
        const contentType = response.headers.get("content-type") ?? "";
        if (!contentType.includes("json")) {
          log(`getSignInState: status=${response.status} contentType=${contentType} signedIn=false`);
          return { signedIn: false };
        }
        const json = await response.json();
        if (!response.ok)
          throw new Error(`Mixpanel sign-in check failed (HTTP ${response.status})`);
        const signedIn = json?.status === "ok" && Boolean(json?.results?.user_id);
        log(`getSignInState: status=${response.status} signedIn=${signedIn}`);
        return { signedIn };
      }
    });
    action("getCurrentUser", {
      async invoke() {
        const user = await apiGet("/api/app/me/");
        return {
          id: String(user?.user_id ?? ""),
          name: String(user?.user_name ?? ""),
          email: String(user?.user_email ?? "")
        };
      }
    });
    action("listProjects", {
      async invoke() {
        const user = await apiGet("/api/app/me/");
        const items = asEntries(user?.projects).map(([id, project]) => ({
          id,
          name: String(project?.name ?? ""),
          organizationId: String(project?.organization_id ?? ""),
          timezone: nullableText(project?.timezone),
          role: nullableText(project?.role),
          demo: Boolean(project?.is_demo)
        }));
        log(`listProjects: ${items.length} projects`);
        return { items, nextCursor: null };
      }
    });
    action("listWorkspaces", {
      async invoke({ projectId }) {
        const user = await apiGet("/api/app/me/");
        const items = asEntries(user?.workspaces).map(([id, workspace]) => ({ id, workspace })).filter(({ workspace }) => !projectId || String(workspace?.project_id ?? "") === projectId).map(({ id, workspace }) => ({
          id,
          projectId: String(workspace?.project_id ?? ""),
          name: String(workspace?.name ?? ""),
          description: nullableText(workspace?.description),
          default: Boolean(workspace?.is_default),
          restricted: Boolean(workspace?.is_restricted)
        }));
        log(`listWorkspaces: ${items.length} workspaces`);
        return { items, nextCursor: null };
      }
    });
    action("listDashboards", {
      async invoke({ workspaceId }) {
        const [results, projectId] = await Promise.all([
          apiGet(`/api/app/workspaces/${encodeURIComponent(workspaceId)}/dashboards/?`),
          projectIdForWorkspace(workspaceId)
        ]);
        const items = (Array.isArray(results) ? results : []).map((dashboard) => dashboardRow(dashboard, workspaceId, projectId));
        log(`listDashboards: workspace=${workspaceId} dashboards=${items.length}`);
        return { items, nextCursor: null };
      }
    });
    action("getDashboard", {
      async invoke({ workspaceId, id }) {
        const [dashboard, projectId] = await Promise.all([
          apiGet(`/api/app/workspaces/${encodeURIComponent(workspaceId)}/dashboards/${encodeURIComponent(id)}/?`),
          projectIdForWorkspace(workspaceId)
        ]);
        const reports = asEntries(dashboard?.contents?.report).map(([, report]) => reportRow(report));
        log(`getDashboard: workspace=${workspaceId} dashboard=${id} reports=${reports.length}`);
        return { ...dashboardRow(dashboard, workspaceId, projectId), reports };
      }
    });
    action("getReportData", {
      async invoke({ projectId, workspaceId, dashboardId, id }) {
        const dashboard = await apiGet(`/api/app/workspaces/${encodeURIComponent(workspaceId)}/dashboards/${encodeURIComponent(dashboardId)}/?`);
        const report = asEntries(dashboard?.contents?.report).map(([, value]) => value).find((value) => String(value?.id ?? "") === id);
        if (!report)
          throw new Error(`Report not found on dashboard ${dashboardId}: ${id}`);
        const requestUrl = `${ORIGIN}/project/${encodeURIComponent(projectId)}/view/${encodeURIComponent(workspaceId)}/app/boards#id=${encodeURIComponent(dashboardId)}`;
        const query = new URLSearchParams({ workspace_id: workspaceId, project_id: projectId, query_origin: "dashboard" });
        const results = await apiPost(`/api/query/insights?${query}`, {
          bookmark: report.params,
          use_query_cache: true,
          report_query_origin: report.type ?? report.original_type ?? "insights",
          tracking_props: {
            bookmark_id: Number(report.id),
            dashboard_card_id: `report-${report.id}`,
            dashboard_id: Number(dashboardId),
            dashboard_query_origin: "dashboard",
            is_main_query_for_report: true,
            queried_from_dashboards: true,
            is_background_repoll: false,
            report_name: report.type ?? report.original_type ?? "insights",
            request_url: requestUrl
          },
          dashboard_id: Number(dashboardId)
        }, projectId, {
          contentType: "application/json; charset=UTF-8",
          requestUrl,
          headers: { "bookmark-id": id }
        });
        log(`getReportData: project=${projectId} dashboard=${dashboardId} report=${id}`);
        return {
          id,
          name: String(report?.name ?? ""),
          type: String(report?.type ?? report?.original_type ?? ""),
          headers: Array.isArray(results?.headers) ? results.headers.map(String) : [],
          computedAt: nullableText(results?.computed_at),
          dateFrom: nullableText(results?.date_range?.from_date),
          dateTo: nullableText(results?.date_range?.to_date),
          seriesJson: JSON.stringify(results?.series ?? {}),
          timeComparisonJson: results?.time_comparison == null ? null : JSON.stringify(results.time_comparison)
        };
      }
    });
    action("listEventDefinitions", {
      async invoke({ projectId, workspaceId }) {
        const query = new URLSearchParams({ project_id: projectId, workspace_id: workspaceId });
        const results = await apiGet(`/api/query/data_definitions/events?${query}`);
        const items = (Array.isArray(results) ? results : []).map((event) => ({
          name: String(event?.name ?? ""),
          displayName: nullableText(event?.displayName),
          description: nullableText(event?.description),
          status: nullableText(event?.status),
          verified: Boolean(event?.verified),
          hidden: Boolean(event?.hidden),
          dropped: Boolean(event?.dropped),
          firstSeenAt: nullableText(event?.createdUTC),
          modifiedAt: nullableText(event?.modifiedUTC ?? event?.lastModified)
        }));
        log(`listEventDefinitions: project=${projectId} events=${items.length}`);
        return { items, nextCursor: null };
      }
    });
    action("searchEvents", {
      async invoke({ projectId, workspaceId, query, days, cursor, limit }) {
        const pageSize = Math.min(100, Math.max(1, Math.floor(limit ?? 50)));
        const body = {
          bookmark: {
            entries: [{
              aggregationOperator: "total",
              aggregationOperatorPerUser: null,
              dataGroupId: null,
              event: { custom: false, label: "All Events", value: "$all_events" },
              filters: [],
              filtersOperator: "and",
              property: null,
              type: "event"
            }],
            filters: [],
            filtersOperator: "and",
            dateRange: {
              type: "in the last",
              exclusionOffset: null,
              window: { unit: "day", value: Math.min(90, Math.max(1, Math.floor(days ?? 7))) }
            },
            isQuerySamplingEnabled: false
          },
          search: query,
          search_properties: eventProperties,
          project_id: projectId,
          workspace_id: workspaceId,
          tracking_props: { report_name: "events", is_main_query_for_report: true },
          use_query_sampling: false,
          mode: "raw",
          limit: pageSize,
          paging_window: 30
        };
        const sentinel = decodeCursor(cursor);
        if (sentinel)
          body.sentinel_event = sentinel;
        const results = await apiPost("/api/query/stream/bookmark", body, projectId);
        const items = (Array.isArray(results?.events) ? results.events : []).map((event) => ({
          name: String(event?.event ?? ""),
          occurredAt: Number(event?.properties?.time ?? 0),
          distinctId: nullableText(event?.properties?.distinct_id),
          properties: asEntries(event?.properties).map(([name, value]) => ({
            name,
            value: typeof value === "string" ? value : JSON.stringify(value)
          }))
        }));
        const nextCursor = results?.sentinel_event ? JSON.stringify(results.sentinel_event) : null;
        log(`searchEvents: project=${projectId} query=${JSON.stringify(query)} events=${items.length} next=${nextCursor !== null}`);
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

  installService("mixpanel.com", actions_default);
})();
