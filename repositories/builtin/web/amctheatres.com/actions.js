window.ox.install(1, ({ action, retryFetch, lib }) => {
  const { cleanText } = lib;
  const origin = "https://www.amctheatres.com";
  const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
  function slug(value, name) { if (!slugPattern.test(value)) throw new Error(name + " is not a valid AMC slug."); return value; }
  function limitOf(value) { return Number.isInteger(value) ? Math.max(1, Math.min(50, value)) : 10; }
  async function getDocument(path) {
    const response = await retryFetch(origin + path, { credentials: "include" });
    if (!response.ok) throw new Error("AMC request failed with HTTP " + response.status + ".");
    const text = await response.text();
    const document = new DOMParser().parseFromString(text, "text/html");
    if (!document.documentElement) throw new Error("AMC returned an unreadable page.");
    return { document, url: response.url || origin + path };
  }
  action("searchTheatres", { async invoke(args) {
    const marketSlug = slug(args.marketSlug, "marketSlug");
    const query = cleanText(args.query).toLowerCase();
    const { document } = await getDocument("/movie-theatres/" + marketSlug);
    const map = new Map();
    for (const anchor of document.querySelectorAll("a[href*='/movie-theatres/']")) {
      const url = new URL(anchor.getAttribute("href"), origin);
      const match = url.pathname.match(/^\/movie-theatres\/([^/]+)\/([^/]+)(?:\/showtimes)?\/?$/);
      const name = cleanText(anchor.textContent || "");
      if (!match || match[1] !== marketSlug || !name || !name.toLowerCase().includes(query)) continue;
      const theaterSlug = match[2];
      map.set(theaterSlug, { theaterId: null, name, marketSlug, theaterSlug, url: origin + "/movie-theatres/" + marketSlug + "/" + theaterSlug + "/showtimes" });
    }
    return { items: [...map.values()].slice(0, limitOf(args.limit)), nextCursor: null };
  }});
  action("searchMovies", { async invoke(args) {
    const marketSlug = slug(args.marketSlug, "marketSlug");
    const theaterSlug = slug(args.theaterSlug, "theaterSlug");
    const query = cleanText(args.query).toLowerCase();
    const { document } = await getDocument("/movie-theatres/" + marketSlug + "/" + theaterSlug + "/showtimes");
    const map = new Map();
    for (const section of document.querySelectorAll("section[id]")) {
      const movieSlug = section.id;
      if (!slugPattern.test(movieSlug)) continue;
      const name = cleanText((section.getAttribute("aria-label") || "").replace(/^Showtimes for /i, "")) || cleanText(section.querySelector("h2,h3")?.textContent || "");
      if (!name || !name.toLowerCase().includes(query)) continue;
      const idMatch = movieSlug.match(/-(\d+)$/);
      map.set(movieSlug, { movieId: idMatch ? Number(idMatch[1]) : null, name, movieSlug, url: origin + "/movies/" + movieSlug + "/showtimes" });
    }
    return { items: [...map.values()].slice(0, limitOf(args.limit)), nextCursor: null };
  }});
  action("listMovieShowtimes", { async invoke(args) {
    const marketSlug = slug(args.marketSlug, "marketSlug");
    const theaterSlug = slug(args.theaterSlug, "theaterSlug");
    const movieSlug = slug(args.movieSlug, "movieSlug");
    const path = "/movie-theatres/" + marketSlug + "/" + theaterSlug + "/showtimes";
    const { document, url } = await getDocument(path);
    const section = document.getElementById(movieSlug);
    const pageText = cleanText(document.body?.innerText || "");
    if (!section) {
      if (/page not found|error 404/i.test(pageText)) throw new Error("AMC theatre page was not found.");
      return { movie: { name: movieSlug, movieSlug }, theater: { name: cleanText(document.querySelector("h1")?.textContent || theaterSlug), marketSlug, theaterSlug }, showtimes: [], sourceUrl: url };
    }
    const movieName = cleanText((section.getAttribute("aria-label") || "").replace(/^Showtimes for /i, "")) || movieSlug;
    const theaterGroup = section.querySelector("[aria-label^='Showtimes at ']");
    const theaterName = cleanText((theaterGroup?.getAttribute("aria-label") || "").replace(/^Showtimes at /i, "")) || cleanText(document.querySelector("h1")?.textContent || theaterSlug);
    const showtimes = [];
    for (const anchor of section.querySelectorAll("a[href*='/showtimes/']")) {
      const href = anchor.getAttribute("href") || "";
      const idMatch = href.match(/\/showtimes\/(\d+)/);
      if (!idMatch) continue;
      const described = (anchor.getAttribute("aria-describedby") || "").split(/\s+/);
      const format = described.length >= 3 ? described[2].split("-").slice(-1)[0] || null : null;
      showtimes.push({ showtimeId: Number(idMatch[1]), time: cleanText(anchor.textContent || "").replace(/\s*(?:20% OFF).*$/i, ""), format, attributes: [], ticketUrl: new URL(href, origin).href });
    }
    return { movie: { name: movieName, movieSlug }, theater: { name: theaterName, marketSlug, theaterSlug }, showtimes, sourceUrl: url };
  }});
});
