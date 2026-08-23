(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  // services/builtin/web/www.usvisascheduling.com/actions.ts
  var ORIGIN = "https://www.usvisascheduling.com";
  var SCHEDULE_URL = `${ORIGIN}/en-US/schedule/`;
  var CUSTOM_ACTIONS_URL = `${ORIGIN}/en-US/custom-actions/`;
  var signedOut = () => new Error("USTravelDocs session is signed out. Open the sign-in page, sign in, then retry the check.");
  var pageConfiguration = () => {
    const source = [...document.scripts].map((script) => script.textContent ?? "").join(`
`);
    const applicationId = source.match(/["']applicationId["']\s*:\s*["']([0-9a-f-]{36})["']/i)?.[1];
    const appd = source.match(/[?&]appd=([0-9a-f-]{36})/i)?.[1];
    return { applicationId, appd };
  };
  var install = ({ action, log }) => {
    const readJson = async (response, label) => {
      if (response.status === 401)
        throw signedOut();
      if (response.status === 403) {
        throw new Error("USTravelDocs rejected this availability check. No retry was attempted.");
      }
      if (response.status === 429) {
        throw new Error("USTravelDocs rate-limited this availability check. No retry was attempted.");
      }
      if (!response.ok)
        throw new Error(`${label}: HTTP ${response.status}; no retry was attempted`);
      const data = await response.json();
      if (data?.HasError) {
        const message = cleanText(data?.Errors?.m_StringValue) || cleanText(data?.ErrorString);
        throw new Error(message || `${label} failed`);
      }
      return data;
    };
    const postAction = async (route, appd, parameters, label) => {
      const url = new URL(CUSTOM_ACTIONS_URL);
      url.searchParams.set("route", route);
      url.searchParams.set("appd", appd);
      url.searchParams.set("cacheString", String(Date.now()));
      const response = await fetch(url, {
        method: "POST",
        credentials: "include",
        headers: {
          Accept: "application/json, text/javascript, */*; q=0.01",
          "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
          "X-Requested-With": "XMLHttpRequest"
        },
        body: new URLSearchParams({ parameters: JSON.stringify(parameters) }).toString()
      });
      return readJson(response, label);
    };
    action("getSignInUrl", {
      async invoke() {
        return { url: SCHEDULE_URL };
      }
    });
    action("getSignInState", {
      async invoke() {
        return { signedIn: Boolean(pageConfiguration().applicationId) };
      }
    });
    action("getAppointmentAvailability", {
      async invoke() {
        const { applicationId, appd } = pageConfiguration();
        if (!applicationId || !appd)
          throw signedOut();
        const [postsResponse, membersResponse] = await Promise.all([
          postAction("/api/v1/schedule-group/query-consular-posts", appd, { applicationId }, "Consular post lookup"),
          postAction("/api/v1/schedule-group/query-family-members-consular", appd, { primaryId: applicationId, visaClass: "all" }, "Applicant lookup")
        ]);
        const posts = Array.isArray(postsResponse?.Posts) ? postsResponse.Posts : [];
        const members = Array.isArray(membersResponse?.Members) ? membersResponse.Members : [];
        const post = posts[0];
        if (!post?.ID || !cleanText(post?.Name))
          throw new Error("No consular post was found for the current application");
        if (!members.length || members.some((member) => !member?.ApplicationID)) {
          throw new Error("No applicants were found for the current application");
        }
        const daysResponse = await postAction("/api/v1/schedule-group/get-family-consular-schedule-days", appd, {
          primaryId: applicationId,
          applications: members.map((member) => String(member.ApplicationID)),
          scheduleDayId: "",
          scheduleEntryId: "",
          postId: String(post.ID),
          isReschedule: "false"
        }, "Appointment availability");
        const days = Array.isArray(daysResponse?.ScheduleDays) ? daysResponse.ScheduleDays : [];
        const dates = [...new Set(days.map((day) => String(day?.Date ?? "").trim()).filter(Boolean))];
        const visaClasses = [...new Set(members.map((member) => cleanText(member?.VisaClassName)).filter(Boolean))];
        log(`USTravelDocs availability: posts=${posts.length} applicants=${members.length} dates=${dates.length} requests=3 retries=0`);
        return {
          post: cleanText(post.Name),
          applicantCount: members.length,
          visaClasses,
          available: dates.length > 0,
          dates
        };
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

  installService("www.usvisascheduling.com", actions_default);
})();
