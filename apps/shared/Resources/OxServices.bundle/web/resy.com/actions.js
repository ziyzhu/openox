const clean = value => String(value ?? "").replace(/\s+/g, " ").trim();
const slug = value => clean(value).toLocaleLowerCase().replace(/['’]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

const normalizeVenueUrl = rawHref => {
  const href = clean(rawHref);
  if (!href) return null;
  try {
    const normalizedPath = href.startsWith("cities/") ? "/" + href : href;
    const resolved = new URL(normalizedPath, location.origin);
    if (resolved.hostname.endsWith("resy.com") && /\/cities\/[^/]+\/venues\/[^/]+/i.test(resolved.pathname)) {
      return `${resolved.origin}${resolved.pathname}`;
    }
    return resolved.href;
  } catch {
    return null;
  }
};

const cityFromUrlOrCard = (url, card, fallbackCity) => {
  const neighborhood = clean(card?.querySelector(".neighborhood")?.textContent);
  if (neighborhood) return neighborhood;
  try {
    const match = new URL(url).pathname.match(/\/cities\/([^/]+)\/venues\//i);
    if (match) return decodeURIComponent(match[1]).replace(/-[a-z]{2}$/i, "").replace(/-/g, " ");
  } catch {}
  return fallbackCity ? fallbackCity.replace(/-[a-z]{2}$/i, "").replace(/-/g, " ") : null;
};

window.ox.install(({ action }) => {
  action("searchRestaurants", {
    async invoke(args) {
      const query = clean(args.query);
      if (!query) throw new Error("A search query is required.");
      const city = slug(args.city || "seattle-wa") || "seattle-wa";
      const limit = Math.max(1, Math.min(Number(args.limit ?? 10), 20));
      const targetPath = `/cities/${city}/search`;

      // Wait for AngularJS injector or initial DOM readiness
      for (let i = 0; i < 30; i += 1) {
        if (window.angular?.element(document.body)?.injector?.() || document.querySelector(".SearchResult, .NoResults")) break;
        await wait(200);
      }

      const currentParams = new URLSearchParams(location.search);
      const needsRoute = !location.pathname.toLocaleLowerCase().startsWith(targetPath) || clean(currentParams.get("query")).toLocaleLowerCase() !== query.toLocaleLowerCase();

      if (needsRoute) {
        const injector = window.angular?.element(document.body)?.injector?.();
        if (injector) {
          const $location = injector.get("$location");
          const $rootScope = injector.get("$rootScope");
          const date = currentParams.get("date") || new Date().toISOString().slice(0, 10);
          const seats = currentParams.get("seats") || "2";
          $rootScope.$apply(() => {
            $location.path(targetPath).search({ query, date, seats });
          });
        }
      }

      let cards = [];
      for (let attempt = 0; attempt < 40; attempt += 1) {
        if (document.querySelector(".NoResults")) {
          console.log("searchRestaurants", "noResults", city, query);
          return { items: [], nextCursor: null };
        }
        const found = [...document.querySelectorAll(".SearchResult")];
        if (found.length > 0) {
          const headerText = clean(document.querySelector(".SearchResultsContainer, main")?.textContent);
          if (!needsRoute || headerText.toLocaleLowerCase().includes(query.toLocaleLowerCase()) || attempt >= 12) {
            cards = found;
            break;
          }
        }
        await wait(250);
      }

      const seen = new Set();
      const items = [];
      for (const card of cards) {
        const link = card.querySelector("a.SearchResult__container-link, a[href*='/venues/']");
        if (!link) continue;
        const name = clean(card.querySelector(".SearchResult__venue-name")?.textContent || link.textContent);
        const url = normalizeVenueUrl(link.getAttribute("href"));
        if (!name || !url || url.includes("/cities/undefined/") || seen.has(url)) continue;
        seen.add(url);
        items.push({
          name,
          url,
          city: cityFromUrlOrCard(url, card, city)
        });
        if (items.length >= limit) break;
      }

      console.log("searchRestaurants", "done", city, "count", items.length);
      return { items, nextCursor: null };
    }
  });
});
