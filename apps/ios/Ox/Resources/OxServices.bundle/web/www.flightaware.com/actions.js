window.ox.install(1, ({ action, retryFetch }) => {
    const fetchText = async (path) => (await retryFetch(path, { credentials: "include" })).text();
    const matchBrace = (html, from) => {
        let depth = 0, instr = false, esc = false;
        for (let j = from; j < html.length; j++) {
            const c = html[j];
            if (instr) {
                if (esc)
                    esc = false;
                else if (c === "\\")
                    esc = true;
                else if (c === '"')
                    instr = false;
            }
            else if (c === '"')
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
    const place = (p) => p && p.icao
        ? { icao: p.icao || null, iata: p.iata || null, name: p.friendlyName || null, location: p.friendlyLocation || null, gate: p.gate || null, terminal: p.terminal || null }
        : null;
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
        route: f.flightPlan?.route ?? null,
    });
    const parseBoard = (doc, type) => {
        const table = doc.querySelector(`table.airportBoard[data-type="${type}"]`);
        if (!table)
            return [];
        return [...table.querySelectorAll("tr")]
            .filter((tr) => tr.querySelector('a[href^="/live/flight"]'))
            .map((tr) => {
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
                arrivalTime: text(cells[5]) || null,
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
                body: JSON.stringify({ searchTerm: query }),
            });
            const rows = await res.json();
            const items = (rows ?? []).map((r) => r.icao
                ? { kind: "airport", name: r.description, icao: r.icao || null, iata: r.iata || null, dailyOps: r.ops ? Number(r.ops) : null }
                : { kind: "flight", name: r.description, ident: r.ident || null, registration: r.reg || null });
            return { items, nextCursor: null };
        },
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
        },
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
                scheduled: parseBoard(doc, "scheduled"),
            };
        },
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
                cancellations: d.cancels ? { total: d.cancels.total ?? null, updated: d.cancels.last_updated ?? null } : null,
            };
        },
    });
});
