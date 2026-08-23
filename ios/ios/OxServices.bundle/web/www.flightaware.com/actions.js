(() => {
  // services/builtin/web/www.flightaware.com/actions.ts
  var install = ({ action, retryFetch }) => {
    const fetchText = async (path) => (await retryFetch(path, { credentials: "include" })).text();
    const matchBrace = (html, from) => {
      let depth = 0, instr = false, esc = false;
      for (let j = from;j < html.length; j++) {
        const c = html[j];
        if (instr) {
          if (esc)
            esc = false;
          else if (c === "\\")
            esc = true;
          else if (c === '"')
            instr = false;
        } else if (c === '"')
          instr = true;
        else if (c === "{")
          depth++;
        else if (c === "}" && --depth === 0)
          return html.slice(from, j + 1);
      }
      throw new Error("unterminated JSON object");
    };
    const islandVar = (html, name) => {
      const i = html.indexOf(`var ${name} = `);
      if (i < 0)
        throw new Error(`missing ${name}`);
      return JSON.parse(matchBrace(html, html.indexOf("{", i)));
    };
    const place = (p) => p && p.icao ? { icao: p.icao || null, iata: p.iata || null, name: p.friendlyName || null, location: p.friendlyLocation || null, gate: p.gate || null, terminal: p.terminal || null } : null;
    const times = (t) => t ? { scheduled: t.scheduled ?? null, estimated: t.estimated ?? null, actual: t.actual ?? null } : null;
    const flightSummary = (f) => ({
      ident: f.ident,
      displayIdent: f.displayIdent ?? f.ident,
      friendlyIdent: f.friendlyIdent ?? null,
      status: f.flightStatus ?? null,
      cancelled: !!f.cancelled,
      diverted: !!f.diverted,
      airline: f.airline ? { name: f.airline.fullName || f.airline.shortName || null, icao: f.airline.icao || null, iata: f.airline.iata || null } : null,
      aircraft: f.aircraft ? { type: f.aircraft.type || null, description: f.aircraft.friendlyType || null, tail: f.aircraft.tail || null } : null,
      origin: place(f.origin),
      destination: place(f.destination),
      position: { groundspeed: f.groundspeed ?? null, altitude: f.altitude ?? null, heading: f.heading ?? null, coord: f.coord ?? null },
      gateDeparture: times(f.gateDepartureTimes),
      takeoff: times(f.takeoffTimes),
      landing: times(f.landingTimes),
      gateArrival: times(f.gateArrivalTimes),
      distance: f.distance ? { elapsed: f.distance.elapsed ?? null, remaining: f.distance.remaining ?? null, total: f.distance.actual ?? null } : null,
      route: f.flightPlan?.route ?? null
    });
    const parseBoard = (doc, type) => {
      const table = doc.querySelector(`table.airportBoard[data-type="${type}"]`);
      if (!table)
        return [];
      return [...table.querySelectorAll("tr")].filter((tr) => tr.querySelector('a[href^="/live/flight"]')).map((tr) => {
        const cells = [...tr.querySelectorAll("td")];
        const text = (el) => (el?.innerText ?? "").replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
        const ident = text(tr.querySelector(".flight-ident a"));
        const aircraftType = text(cells[1]);
        const placeCode = (cells[2]?.querySelector('a[href^="/live/airport"]')?.innerText ?? "").trim();
        const placeName = text(cells[2]?.querySelector('[itemprop="name"]')) || text(cells[2]);
        return {
          ident,
          aircraftType: aircraftType || null,
          place: placeCode ? { code: placeCode, name: placeName || null } : null,
          departureTime: text(cells[3]) || null,
          arrivalTime: text(cells[5]) || null
        };
      });
    };
    action("search", {
      async invoke({ query }) {
        if (!query)
          throw new Error("search: query required");
        const res = await retryFetch("https://www.flightaware.com/search/homepage-api/", {
          method: "POST",
          credentials: "include",
          headers: { "content-type": "application/json", "x-requested-with": "XMLHttpRequest" },
          body: JSON.stringify({ searchTerm: query })
        });
        const rows = await res.json();
        const items = (rows ?? []).map((r) => r.icao ? { kind: "airport", name: r.description, icao: r.icao || null, iata: r.iata || null, dailyOps: r.ops ? Number(r.ops) : null } : { kind: "flight", name: r.description, ident: r.ident || null, registration: r.reg || null });
        return { items, nextCursor: null };
      }
    });
    action("getFlight", {
      async invoke({ ident }) {
        if (!ident)
          throw new Error("getFlight: ident required");
        const html = await fetchText(`/live/flight/${encodeURIComponent(ident)}`);
        const boot = islandVar(html, "trackpollBootstrap");
        const flights = Object.values(boot.flights ?? {});
        if (!flights.length)
          throw new Error(`getFlight: no flight for ${ident}`);
        return flightSummary(flights[0]);
      }
    });
    action("getAirport", {
      async invoke({ airport }) {
        if (!airport)
          throw new Error("getAirport: airport code required");
        const html = await fetchText(`/live/airport/${encodeURIComponent(airport)}`);
        const doc = new DOMParser().parseFromString(html, "text/html");
        return {
          airport: airport.toUpperCase(),
          arrivals: parseBoard(doc, "arrivals"),
          departures: parseBoard(doc, "departures"),
          enroute: parseBoard(doc, "enroute"),
          scheduled: parseBoard(doc, "scheduled")
        };
      }
    });
    action("getAirportStats", {
      async invoke({ airport, days = 30 }) {
        if (!airport)
          throw new Error("getAirportStats: airport code required");
        const res = await retryFetch(`/ajax/ignoreuser/airport_stats.rvt?airport=${encodeURIComponent(airport)}`, { credentials: "include", headers: { "x-requested-with": "XMLHttpRequest" } });
        const d = await res.json();
        return {
          airport: airport.toUpperCase(),
          daily: (d.chart_data ?? []).slice(0, Math.max(1, days)).map((c) => ({ date: c.date, arrivals: c.arrivals, departures: c.departures })),
          cancellations: d.cancels ? { total: d.cancels.total ?? null, updated: d.cancels.last_updated ?? null } : null
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

  installService("www.flightaware.com", actions_default);
})();
