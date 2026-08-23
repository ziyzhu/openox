import type { ActionInstaller } from "../action.ts";
import { cookie } from "../../../action-lib.ts";

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const ORIGIN = "https://mixpanel.com";

  const readJson = async (response: Response, path: string): Promise<any> => {
    const text = await response.text();
    let json: any;
    try {
      json = JSON.parse(text);
    } catch {
      throw new Error(`${path}: non-JSON response (HTTP ${response.status}) — sign in to Mixpanel again`);
    }
    if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
    if ("status" in json) {
      if (json.status !== "ok") throw new Error(`${path}: ${json?.error || json?.message || "Mixpanel request failed"}`);
      return json.results;
    }
    return json;
  };

  const apiGet = async (path: string): Promise<any> => {
    const response = await retryFetch(path, {
      credentials: "include",
      headers: { accept: "application/json" },
    });
    return readJson(response, path.split("?")[0]!);
  };

  const apiPost = async (
    path: string,
    body: unknown,
    projectId: string,
    options: { contentType?: string; requestUrl?: string; headers?: Record<string, string> } = {},
  ): Promise<any> => {
    const csrf = cookie("csrftoken");
    if (!csrf) throw new Error("Not signed in to Mixpanel (no CSRF cookie). Sign in first.");
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
        ...options.headers,
      },
      body: JSON.stringify(body),
    });
    return readJson(response, path);
  };

  const asEntries = (value: any): Array<[string, any]> =>
    value && typeof value === "object" ? Object.entries(value) : [];

  const nullableText = (value: unknown): string | null => {
    const text = String(value ?? "").trim();
    return text || null;
  };

  const dashboardRow = (dashboard: any, workspaceId: string, projectId: string) => ({
    id: String(dashboard?.id ?? ""),
    workspaceId,
    title: String(dashboard?.title ?? ""),
    description: nullableText(dashboard?.description),
    creator: nullableText(dashboard?.creator_name ?? dashboard?.creator),
    createdAt: nullableText(dashboard?.created),
    modifiedAt: nullableText(dashboard?.modified),
    private: Boolean(dashboard?.is_private),
    favorited: Boolean(dashboard?.is_favorited),
    url: `${ORIGIN}/project/${encodeURIComponent(projectId)}/view/${encodeURIComponent(workspaceId)}/app/boards#id=${encodeURIComponent(String(dashboard?.id ?? ""))}`,
  });

  const reportRow = (report: any) => ({
    id: String(report?.id ?? ""),
    name: String(report?.name ?? ""),
    type: String(report?.type ?? report?.original_type ?? ""),
    chartType: nullableText(report?.params?.displayOptions?.chartType),
    description: nullableText(report?.description),
    createdAt: nullableText(report?.created),
    modifiedAt: nullableText(report?.modified),
  });

  const decodeCursor = (cursor: string | undefined): any => {
    if (!cursor) return null;
    try {
      return JSON.parse(cursor);
    } catch {
      throw new Error("Invalid event cursor");
    }
  };

  const projectIdForWorkspace = async (workspaceId: string): Promise<string> => {
    const user = await apiGet("/api/app/me/");
    const workspace = user?.workspaces?.[workspaceId];
    const projectId = String(workspace?.project_id ?? "");
    if (!projectId) throw new Error(`Workspace not found: ${workspaceId}`);
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
    ["$last_name", "user", "Last Name"],
  ].map(([value, resourceType, label]) => ({
    value,
    resourceType,
    label,
    type: "string",
    propertyDefaultType: "string",
  }));

  action("getSignInUrl", {
    async invoke() {
      return { url: `${ORIGIN}/login/` };
    },
  });

  action("getSignInState", {
    async invoke() {
      const response = await retryFetch("/api/app/me/", {
        credentials: "include",
        headers: { accept: "application/json" },
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
      if (!response.ok) throw new Error(`Mixpanel sign-in check failed (HTTP ${response.status})`);
      const signedIn = json?.status === "ok" && Boolean(json?.results?.user_id);
      log(`getSignInState: status=${response.status} signedIn=${signedIn}`);
      return { signedIn };
    },
  });

  action("getCurrentUser", {
    async invoke() {
      const user = await apiGet("/api/app/me/");
      return {
        id: String(user?.user_id ?? ""),
        name: String(user?.user_name ?? ""),
        email: String(user?.user_email ?? ""),
      };
    },
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
        demo: Boolean(project?.is_demo),
      }));
      log(`listProjects: ${items.length} projects`);
      return { items, nextCursor: null };
    },
  });

  action("listWorkspaces", {
    async invoke({ projectId }: { projectId?: string }) {
      const user = await apiGet("/api/app/me/");
      const items = asEntries(user?.workspaces)
        .map(([id, workspace]) => ({ id, workspace }))
        .filter(({ workspace }) => !projectId || String(workspace?.project_id ?? "") === projectId)
        .map(({ id, workspace }) => ({
          id,
          projectId: String(workspace?.project_id ?? ""),
          name: String(workspace?.name ?? ""),
          description: nullableText(workspace?.description),
          default: Boolean(workspace?.is_default),
          restricted: Boolean(workspace?.is_restricted),
        }));
      log(`listWorkspaces: ${items.length} workspaces`);
      return { items, nextCursor: null };
    },
  });

  action("listDashboards", {
    async invoke({ workspaceId }: { workspaceId: string }) {
      const [results, projectId] = await Promise.all([
        apiGet(`/api/app/workspaces/${encodeURIComponent(workspaceId)}/dashboards/?`),
        projectIdForWorkspace(workspaceId),
      ]);
      const items = (Array.isArray(results) ? results : []).map((dashboard: any) => dashboardRow(dashboard, workspaceId, projectId));
      log(`listDashboards: workspace=${workspaceId} dashboards=${items.length}`);
      return { items, nextCursor: null };
    },
  });

  action("getDashboard", {
    async invoke({ workspaceId, id }: { workspaceId: string; id: string }) {
      const [dashboard, projectId] = await Promise.all([
        apiGet(`/api/app/workspaces/${encodeURIComponent(workspaceId)}/dashboards/${encodeURIComponent(id)}/?`),
        projectIdForWorkspace(workspaceId),
      ]);
      const reports = asEntries(dashboard?.contents?.report).map(([, report]) => reportRow(report));
      log(`getDashboard: workspace=${workspaceId} dashboard=${id} reports=${reports.length}`);
      return { ...dashboardRow(dashboard, workspaceId, projectId), reports };
    },
  });

  action("getReportData", {
    async invoke({ projectId, workspaceId, dashboardId, id }: {
      projectId: string;
      workspaceId: string;
      dashboardId: string;
      id: string;
    }) {
      const dashboard = await apiGet(`/api/app/workspaces/${encodeURIComponent(workspaceId)}/dashboards/${encodeURIComponent(dashboardId)}/?`);
      const report = asEntries(dashboard?.contents?.report)
        .map(([, value]) => value)
        .find((value) => String(value?.id ?? "") === id);
      if (!report) throw new Error(`Report not found on dashboard ${dashboardId}: ${id}`);
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
          request_url: requestUrl,
        },
        dashboard_id: Number(dashboardId),
      }, projectId, {
        contentType: "application/json; charset=UTF-8",
        requestUrl,
        headers: { "bookmark-id": id },
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
        timeComparisonJson: results?.time_comparison == null ? null : JSON.stringify(results.time_comparison),
      };
    },
  });

  action("listEventDefinitions", {
    async invoke({ projectId, workspaceId }: { projectId: string; workspaceId: string }) {
      const query = new URLSearchParams({ project_id: projectId, workspace_id: workspaceId });
      const results = await apiGet(`/api/query/data_definitions/events?${query}`);
      const items = (Array.isArray(results) ? results : []).map((event: any) => ({
        name: String(event?.name ?? ""),
        displayName: nullableText(event?.displayName),
        description: nullableText(event?.description),
        status: nullableText(event?.status),
        verified: Boolean(event?.verified),
        hidden: Boolean(event?.hidden),
        dropped: Boolean(event?.dropped),
        firstSeenAt: nullableText(event?.createdUTC),
        modifiedAt: nullableText(event?.modifiedUTC ?? event?.lastModified),
      }));
      log(`listEventDefinitions: project=${projectId} events=${items.length}`);
      return { items, nextCursor: null };
    },
  });

  action("searchEvents", {
    async invoke({ projectId, workspaceId, query, days, cursor, limit }: {
      projectId: string;
      workspaceId: string;
      query: string;
      days?: number;
      cursor?: string;
      limit?: number;
    }) {
      const pageSize = Math.min(100, Math.max(1, Math.floor(limit ?? 50)));
      const body: Record<string, unknown> = {
        bookmark: {
          entries: [{
            aggregationOperator: "total",
            aggregationOperatorPerUser: null,
            dataGroupId: null,
            event: { custom: false, label: "All Events", value: "$all_events" },
            filters: [],
            filtersOperator: "and",
            property: null,
            type: "event",
          }],
          filters: [],
          filtersOperator: "and",
          dateRange: {
            type: "in the last",
            exclusionOffset: null,
            window: { unit: "day", value: Math.min(90, Math.max(1, Math.floor(days ?? 7))) },
          },
          isQuerySamplingEnabled: false,
        },
        search: query,
        search_properties: eventProperties,
        project_id: projectId,
        workspace_id: workspaceId,
        tracking_props: { report_name: "events", is_main_query_for_report: true },
        use_query_sampling: false,
        mode: "raw",
        limit: pageSize,
        paging_window: 30,
      };
      const sentinel = decodeCursor(cursor);
      if (sentinel) body.sentinel_event = sentinel;
      const results = await apiPost("/api/query/stream/bookmark", body, projectId);
      const items = (Array.isArray(results?.events) ? results.events : []).map((event: any) => ({
        name: String(event?.event ?? ""),
        occurredAt: Number(event?.properties?.time ?? 0),
        distinctId: nullableText(event?.properties?.distinct_id),
        properties: asEntries(event?.properties).map(([name, value]) => ({
          name,
          value: typeof value === "string" ? value : JSON.stringify(value),
        })),
      }));
      const nextCursor = results?.sentinel_event ? JSON.stringify(results.sentinel_event) : null;
      log(`searchEvents: project=${projectId} query=${JSON.stringify(query)} events=${items.length} next=${nextCursor !== null}`);
      return { items, nextCursor };
    },
  });
};

export default install;
