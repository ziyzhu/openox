window.ox.install(({ action }) => {
  action("search", {
    async invoke({ query, limit = 10, cursor }) {
      if (!query.trim()) throw new Error("Search query must not be blank");
      if (cursor) throw new Error("DuckDuckGo search does not expose continuation");
      const clean = value => String(value ?? "").replace(/\s+/g, " ").trim();
      const deadline = Date.now() + 12000;
      while (Date.now() < deadline) {
        if (location.hostname !== "duckduckgo.com" && !location.hostname.endsWith(".duckduckgo.com")) throw new Error("Unexpected DuckDuckGo search host");
        if (document.querySelector(".anomaly-modal, [data-testid='anomaly-modal'], form[action*='challenge'], iframe[src*='captcha']")) throw new Error("DuckDuckGo requires human verification");
        const items = [], seen = new Set();
        for (const root of document.querySelectorAll(".result:not(.result--ad), article[data-testid='result']")) {
          const link = root.querySelector("a.result__a[href], a[data-testid='result-title-a'][href]");
          const title = clean(link?.textContent);
          let url;
          try {
            url = new URL(link?.getAttribute("href"), location.origin);
            if (url.pathname === "/l/" && (url.hostname === "duckduckgo.com" || url.hostname.endsWith(".duckduckgo.com"))) url = new URL(url.searchParams.get("uddg"));
          } catch { continue; }
          if (!/^https?:$/.test(url.protocol) || url.hostname === "duckduckgo.com" || url.hostname.endsWith(".duckduckgo.com") || !title || seen.has(url.href)) continue;
          seen.add(url.href);
          items.push({ title, url: url.href, snippet: clean(root.querySelector(".result__snippet, [data-result='snippet']")?.textContent) || null });
          if (items.length === limit) break;
        }
        if (items.length) return { items, nextCursor: null, scope: "Public web", coverage: "unknown" };
        if (document.querySelector("[data-testid='no-results-message'], .no-results, .no-results-message")) return { items: [], nextCursor: null, scope: "Public web", coverage: "complete" };
        await new Promise(resolve => setTimeout(resolve, 150));
      }
      throw new Error("DuckDuckGo search results did not become recognizable; absence of results is unverified");
    }
  });
});
