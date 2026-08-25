import type { ActionInstaller } from "@openox/service-sdk/action";

const install: ActionInstaller = ({ action, retryFetch }) => {
  const API = "https://qao9lxc60h.execute-api.us-west-2.amazonaws.com/prod";

  const getJson = async (path: string) => {
    const res = await retryFetch(`${API}${path}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  };

  const localIso = (epochMs: number, timeZone?: string) => {
    try {
      return new Intl.DateTimeFormat("sv-SE", {
        timeZone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      }).format(new Date(epochMs)).replace(" ", "T");
    } catch {
      return new Date(epochMs).toISOString();
    }
  };

  const summarize = (p: any) => ({
    id: p.placeId,
    name: p.displayName,
    provider: p.provider?.name ?? null,
    tags: p.tags ?? [],
    coordinate: p.coordinate ?? null,
    timezone: p.timezone ?? null,
    courtCount: p.provider?.resources?.length ?? 0,
    url: `https://matchatennis.com/places/${p.placeId}`,
  });

  const mapCourt = (r: any, timeZone?: string) => ({
    mrn: r.mrn,
    name: r.name,
    tags: r.tags ?? [],
    slots: (r.slots ?? []).map((s: any) => ({
      start: localIso(s.start, timeZone),
      durationMinutes: Math.round(s.duration / 60000),
      state: s.state ?? null,
    })),
  });

  const mapPlace = (p: any) => ({
    ...summarize(p),
    courts: (p.provider?.resources ?? []).map((r: any) => mapCourt(r, p.timezone)),
  });

  action("listPlaces", {
    async invoke({ cursor }) {
      const path = cursor ? `/places?cursor=${encodeURIComponent(cursor)}` : "/places";
      const page = await getJson(path);
      return {
        items: (page.data ?? []).map(summarize),
        nextCursor: page.cursor ?? null,
      };
    },
  });

  action("getPlace", {
    async invoke({ id }) {
      return mapPlace(await getJson(`/places/${encodeURIComponent(id)}`));
    },
  });
};

export default install;
