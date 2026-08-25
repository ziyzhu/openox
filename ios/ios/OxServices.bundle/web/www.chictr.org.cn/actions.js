(() => {
  // service-sdk/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/www.chictr.org.cn/actions.ts
  var ORIGIN = "https://www.chictr.org.cn";
  var START_URL = `${ORIGIN}/images/fav.ico`;
  var normalizedLabel = (value) => cleanText(value).replace(/[：:]$/, "").toLowerCase();
  var englishText = (element) => {
    if (!element)
      return "";
    const copy = element.cloneNode(true);
    copy.querySelectorAll(".cn, script, style").forEach((node) => node.remove());
    return cleanText(copy.textContent).replace(/\u00a0/g, " ").trim();
  };
  var labelElement = (root, label) => [...root.querySelectorAll("p.en, span.en")].find((element) => normalizedLabel(element.textContent) === normalizedLabel(label));
  var fieldCell = (root, label) => {
    const labelCell = labelElement(root, label)?.closest("td");
    if (!labelCell)
      return null;
    if (labelCell.nextElementSibling)
      return labelCell.nextElementSibling;
    const row = labelCell.parentElement;
    const previousRow = row?.previousElementSibling;
    if (!row || !previousRow)
      return null;
    const index = [...row.children].indexOf(labelCell);
    return previousRow.children[index + 1] ?? null;
  };
  var fieldText = (root, label) => englishText(fieldCell(root, label));
  var absoluteUrl = (value) => value ? new URL(value, ORIGIN).href : "";
  var optional = (key, value) => value ? { [key]: value } : {};
  var tablesInField = (root, label) => {
    const cell = fieldCell(root, label);
    if (!cell)
      return [];
    return [...cell.querySelectorAll(":scope > table, :scope > div > table")];
  };
  var ageValue = (root, label) => {
    const marker = labelElement(root, label);
    const valueCell = marker?.closest("td")?.nextElementSibling;
    if (!valueCell)
      return "";
    const value = englishText(valueCell);
    if (!value)
      return "";
    const unitCell = valueCell.nextElementSibling;
    return cleanText(`${value} ${englishText(unitCell)}`);
  };
  var install = ({ action, log }) => {
    action("searchTrials", {
      async invoke({
        query,
        cursor
      }) {
        if (!query)
          throw new Error("searchTrials: query is required");
        const page = pageCursor(cursor, 1);
        const totalElement = document.querySelector("#data-totalEN");
        if (!totalElement) {
          throw new Error("searchTrials: registry search page did not load");
        }
        const rows = [...document.querySelectorAll("table.table1 tr")].filter((row) => row.querySelector("a[href*='showprojEN.html?proj=']"));
        const items = rows.map((row) => {
          const cells = [...row.querySelectorAll(":scope > td")];
          const link = row.querySelector("a[href*='showprojEN.html?proj=']");
          const url = absoluteUrl(link?.getAttribute("href") ?? null);
          return {
            id: url ? new URL(url).searchParams.get("proj") ?? "" : "",
            registrationNumber: englishText(cells[1] ?? null),
            title: englishText(link),
            institution: englishText(link?.parentElement?.querySelector("p") ?? null),
            studyType: englishText(cells[3] ?? null),
            registeredAt: englishText(cells[4] ?? null),
            url
          };
        }).filter((item) => item.id && item.registrationNumber && item.title && item.url);
        const totalCount = Number.parseInt(englishText(totalElement), 10) || 0;
        const nextCursor = page * 10 < totalCount ? String(page + 1) : null;
        log(`searchTrials "${query}" page ${page}: ${items.length}/${totalCount}`);
        return { items, totalCount, nextCursor };
      }
    });
    action("getTrial", {
      async invoke({ id }) {
        if (!id)
          throw new Error("getTrial: id is required");
        const url = `${ORIGIN}/showprojEN.html?proj=${encodeURIComponent(id)}`;
        const doc = document;
        const title = englishText(doc.querySelector(".project-tit p.en"));
        const registrationNumber = fieldText(doc, "Registration number");
        if (!title || !registrationNumber)
          throw new Error(`getTrial: no trial found for id ${id}`);
        const interventions = tablesInField(doc, "Interventions").map((table) => {
          const sampleSizeText = fieldText(table, "Sample size");
          const sampleSize = Number.parseInt(sampleSizeText, 10);
          return {
            group: fieldText(table, "Group"),
            intervention: fieldText(table, "Intervention"),
            ...Number.isFinite(sampleSize) ? { sampleSize } : {},
            ...optional("code", fieldText(table, "Intervention code"))
          };
        }).filter((item) => item.group || item.intervention);
        const locations = tablesInField(doc, "Countries of recruitment and research settings").map((table) => ({
          country: fieldText(table, "Country"),
          province: fieldText(table, "Province"),
          city: fieldText(table, "City"),
          institution: fieldText(table, "Institution hospital"),
          level: fieldText(table, "Level of the institution")
        })).filter((item) => item.country || item.institution);
        const outcomes = tablesInField(doc, "Outcomes").map((table) => ({
          name: fieldText(table, "Outcome"),
          type: fieldText(table, "Type"),
          timepoint: fieldText(table, "Measure time point of outcome"),
          method: fieldText(table, "Measure method")
        })).filter((item) => item.name);
        const result = {
          id,
          registrationNumber,
          title,
          url,
          interventions,
          locations,
          outcomes,
          ...optional("updatedAt", fieldText(doc, "Date of Last Refreshed on")),
          ...optional("registeredAt", fieldText(doc, "Date of Registration")),
          ...optional("registrationStatus", fieldText(doc, "Registration Status")),
          ...optional("scientificTitle", fieldText(doc, "Scientific title")),
          ...optional("acronym", fieldText(doc, "English Acronym")),
          ...optional("subjectId", fieldText(doc, "Study subject ID")),
          ...optional("studyLeader", fieldText(doc, "Study leader")),
          ...optional("institution", fieldText(doc, "Affiliation of the Leader")),
          ...optional("ethicsApproved", fieldText(doc, "Approved by ethic committee")),
          ...optional("ethicsCommittee", fieldText(doc, "Name of the ethic committee")),
          ...optional("primarySponsor", fieldText(doc, "Primary sponsor")),
          ...optional("fundingSource", fieldText(doc, "Source(s) of funding")),
          ...optional("targetDisease", fieldText(doc, "Target disease")),
          ...optional("targetDiseaseCode", fieldText(doc, "Target disease code")),
          ...optional("studyType", fieldText(doc, "Study type")),
          ...optional("phase", fieldText(doc, "Study phase")),
          ...optional("design", fieldText(doc, "Study design")),
          ...optional("objectives", fieldText(doc, "Objectives of Study")),
          ...optional("inclusionCriteria", fieldText(doc, "Inclusion criteria")),
          ...optional("exclusionCriteria", fieldText(doc, "Exclusion criteria")),
          ...optional("studyStart", englishText(doc.querySelector(".splaceTen3"))),
          ...optional("studyEnd", englishText(doc.querySelector(".splaceTen4"))),
          ...optional("recruitmentStart", englishText(doc.querySelector(".splaceTen5"))),
          ...optional("recruitmentEnd", englishText(doc.querySelector(".splaceTen6"))),
          ...optional("recruitingStatus", fieldText(doc, "Recruiting status")),
          ...optional("minimumAge", ageValue(fieldCell(doc, "Participant age") ?? doc, "Min age")),
          ...optional("maximumAge", ageValue(fieldCell(doc, "Participant age") ?? doc, "Max age")),
          ...optional("gender", fieldText(doc, "Gender")),
          ...optional("blinding", fieldText(doc, "Blinding")),
          ...optional("ipdSharing", fieldText(doc, "IPD sharing")),
          ...optional("ipdSharingPlan", fieldText(doc, "The way of sharing IPD”(include metadata and protocol, If use web-based public database, please provide the url)"))
        };
        log(`getTrial ${id}: ${interventions.length} interventions, ${locations.length} locations, ${outcomes.length} outcomes`);
        return result;
      }
    });
  };
  var actions_default = install;

  // service-sdk/action-runtime.ts
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

  installService("www.chictr.org.cn", actions_default);
})();
