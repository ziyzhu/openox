window.ox.install(({ action }) => {
  action("search", {
    async invoke({ query, limit = 10, cursor }) {
      if (!query.trim()) throw new Error("Search query must not be blank");
      if (cursor) throw new Error("Brave search does not expose continuation");
      const clean = value => String(value ?? "").replace(/\s+/g, " ").trim();
      const deadline = Date.now() + 12000;
      while (Date.now() < deadline) {
        if (location.hostname !== "search.brave.com") throw new Error("Unexpected Brave search host");
        if (document.querySelector("form[action*='challenge'], iframe[src*='captcha'], [data-testid='captcha']")) throw new Error("Brave requires human verification");
        const items = [], seen = new Set();
        for (const root of document.querySelectorAll("[data-type='web']")) {
          const heading = root.querySelector(".search-snippet-title");
          const link = heading?.closest("a[href]") ?? root.querySelector("a[href]");
          const title = clean(heading?.getAttribute("title") || heading?.textContent);
          let url;
          try { url = new URL(link?.getAttribute("href"), location.origin); } catch { continue; }
          if (!/^https?:$/.test(url.protocol) || url.hostname === "search.brave.com" || !title || seen.has(url.href)) continue;
          seen.add(url.href);
          items.push({ title, url: url.href, snippet: clean(root.querySelector(".generic-snippet .content, .generic-snippet")?.textContent) || null });
          if (items.length === limit) break;
        }
        if (items.length) return { items, nextCursor: null, scope: "Public web", coverage: "unknown" };
        if (document.querySelector("[data-testid='no-results-message'], .no-results, .no-results-message")) return { items: [], nextCursor: null, scope: "Public web", coverage: "complete" };
        await new Promise(resolve => setTimeout(resolve, 150));
      }
      throw new Error("Brave search results did not become recognizable; absence of results is unverified");
    }
  });
});
