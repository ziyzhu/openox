window.ox.install(1, ({ action, retryFetch, lib }) => {
  const { cleanText } = lib;
  const origin = "https://www.cinemark.com";
  const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
  function limitOf(value) { return Number.isInteger(value) ? Math.max(1, Math.min(50, value)) : 10; }
  async function getDocument(url) {
    const response = await retryFetch(url, { credentials: "include" });
    if (!response.ok) throw new Error("Cinemark request failed with HTTP " + response.status + ".");
    const text = await response.text();
    const document = new DOMParser().parseFromString(text, "text/html");
    if (!document.documentElement) throw new Error("Cinemark returned an unreadable page.");
    return { document, text, url: response.url || new URL(url, origin).href };
  }
  function ids(args) { return args.theaterIds.join(","); }
  action("findTheatres", { async invoke(args) {
    const endpoint = origin + "/theatres/?z=" + encodeURIComponent(args.zipCode);
    const { document } = await getDocument(endpoint);
    const query = cleanText(args.query || "").toLowerCase();
    const rows = [];
    for (const card of document.querySelectorAll(".theatreBlock[data-theater-id]")) {
      const anchor = card.querySelector("a.theaterLink");
      const spans = [...card.querySelectorAll(".theatreBlockInfo > span")].map(s => cleanText(s.textContent || "")).filter(Boolean);
      const name = cleanText(anchor?.textContent || "");
      if (!anchor || !name || (query && !name.toLowerCase().includes(query) && !(spans[0] || "").toLowerCase().includes(query))) continue;
      rows.push({ theaterId: Number(card.getAttribute("data-theater-id")), name, cityState: spans[0] || null, distance: spans[1] || null, url: new URL(anchor.getAttribute("href"), origin).href });
    }
    return { items: rows.slice(0, limitOf(args.limit)), nextCursor: null };
  }});
  action("getMovie", { async invoke(args) {
    if (!slugPattern.test(args.movieSlug)) throw new Error("movieSlug is not valid.");
    const path = "/movies/" + args.movieSlug;
    const { document, text, url } = await getDocument(origin + path);
    const movieMatch = text.match(/currentMovieId\s*=\s*(\d+)/);
    if (!movieMatch) {
      if (/page not found|error 404/i.test(cleanText(document.body?.innerText || ""))) throw new Error("Cinemark movie was not found.");
      throw new Error("Cinemark movie ID was not present on the page.");
    }
    const contentMatch = text.match(/contentId\s*=\s*(\d+)/);
    const title = cleanText(document.querySelector("h1")?.textContent || document.title.replace(/ Showtimes.*$/i, ""));
    return { movieId: Number(movieMatch[1]), contentId: contentMatch ? Number(contentMatch[1]) : null, title, movieSlug: args.movieSlug, url };
  }});
  action("listMovieDates", { async invoke(args) {
    const endpoint = origin + "/umbraco/surface/Showtimes/MovieDates?cinemarkMovieId=" + args.movieId + "&theaterIds=" + encodeURIComponent(ids(args)) + "&currentTheaterId=" + args.currentTheaterId;
    const { document, url } = await getDocument(endpoint);
    const dates = [...new Set([...document.querySelectorAll("[data-datevalue]")].map(e => e.getAttribute("data-datevalue")).filter(v => /^\d{4}-\d{2}-\d{2}$/.test(v || "")))];
    return { dates, sourceUrl: url };
  }});
  action("listMovieShowtimes", { async invoke(args) {
    const endpoint = origin + "/umbraco/surface/Showtimes/GetByMovieId?cinemarkMovieId=" + args.movieId + "&showDate=" + encodeURIComponent(args.date) + "&theaterIds=" + encodeURIComponent(ids(args)) + "&expandSearch=" + String(Boolean(args.expandSearch)) + "&currentTheaterId=" + args.currentTheaterId;
    const { document, url } = await getDocument(endpoint);
    const items = [];
    for (const anchor of document.querySelectorAll("a[href*='/TicketSeatMap/']")) {
      const ticketUrl = new URL(anchor.getAttribute("href"), origin);
      const theaterId = Number(ticketUrl.searchParams.get("TheaterId"));
      const showtimeId = Number(ticketUrl.searchParams.get("ShowtimeId"));
      if (!theaterId || !showtimeId) continue;
      const block = anchor.closest(".theatreBlock, .theater-block, article, section") || anchor.parentElement?.parentElement;
      const theaterAnchor = block?.querySelector("a[href*='/theatres/']");
      const theaterName = cleanText(theaterAnchor?.textContent || block?.querySelector("h2,h3,h4")?.textContent || "Cinemark");
      const blockText = cleanText(block?.innerText || "");
      const cityMatch = blockText.match(/([A-Za-z .'-]+,\s*[A-Z]{2})/);
      items.push({ theaterId, theaterName, cityState: cityMatch ? cleanText(cityMatch[1]) : null, showtimeId, time: cleanText(anchor.textContent || ""), showtimeLocal: ticketUrl.searchParams.get("Showtime"), format: anchor.getAttribute("data-print-type-name") || null, ticketUrl: ticketUrl.href });
    }
    return { items, sourceUrl: url };
  }});
});
