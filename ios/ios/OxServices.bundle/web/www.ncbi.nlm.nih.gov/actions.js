(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  // services/builtin/web/www.ncbi.nlm.nih.gov/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils";
    const eutils = async (fcgi, params) => {
      const qs = new URLSearchParams({ tool: "ox", ...params });
      const res = await retryFetch(`${EUTILS}/${fcgi}?${qs}`, { credentials: "omit" });
      if (!res.ok)
        throw new Error(`${fcgi} HTTP ${res.status}`);
      return res;
    };
    const eutilsJson = async (fcgi, params) => (await eutils(fcgi, { ...params, retmode: "json" })).json();
    const recordUrl = (db, uid) => db === "pubmed" ? `https://pubmed.ncbi.nlm.nih.gov/${encodeURIComponent(uid)}/` : `https://www.ncbi.nlm.nih.gov/${encodeURIComponent(db)}/${encodeURIComponent(uid)}`;
    const authorsOf = (summary) => Array.isArray(summary?.authors) ? summary.authors.map((author) => author?.name).filter((name) => typeof name === "string") : undefined;
    const titleOf = (summary, db, uid) => {
      if (typeof summary?.title === "string" && summary.title)
        return summary.title;
      if (Array.isArray(summary?.ds_meshterms) && summary.ds_meshterms[0])
        return summary.ds_meshterms[0];
      if (summary?.name && summary?.description)
        return `${summary.name} — ${summary.description}`;
      return summary?.name || summary?.caption || summary?.description || summary?.ds_scopenote || `${db} ${uid}`;
    };
    const sourceOf = (summary) => summary?.fulljournalname || summary?.source || summary?.book || summary?.organism?.scientificname || summary?.ds_scopenote || undefined;
    const dateOf = (summary) => summary?.sortpubdate || summary?.pubdate || summary?.epubdate || summary?.ds_yearintroduced || undefined;
    const articleIdOf = (summary, type) => Array.isArray(summary?.articleids) ? summary.articleids.find((articleId) => articleId?.idtype === type)?.value : undefined;
    const fullTextLinksOf = (summary) => {
      const links = [];
      const pmc = articleIdOf(summary, "pmc");
      const doi = articleIdOf(summary, "doi");
      if (pmc)
        links.push({ label: "PubMed Central", url: `https://pmc.ncbi.nlm.nih.gov/articles/${encodeURIComponent(pmc)}/` });
      if (doi)
        links.push({ label: "Publisher via DOI", url: `https://doi.org/${doi}` });
      if (typeof summary?.availablefromurl === "string" && /^https?:\/\//.test(summary.availablefromurl)) {
        links.push({ label: "Full text", url: summary.availablefromurl });
      }
      return links.filter((link, index) => links.findIndex((candidate) => candidate.url === link.url) === index);
    };
    const normalize = (summary, db) => {
      const uid = String(summary?.uid ?? "");
      const item = { id: uid, db, title: titleOf(summary, db, uid), url: recordUrl(db, uid) };
      const authors = authorsOf(summary);
      if (authors?.length)
        item.authors = authors;
      const source = sourceOf(summary);
      if (source)
        item.source = source;
      const date = dateOf(summary);
      if (date)
        item.date = date;
      if (db === "pubmed") {
        const doi = articleIdOf(summary, "doi");
        if (doi)
          item.doi = doi;
        if (summary?.volume)
          item.volume = String(summary.volume);
        if (summary?.issue)
          item.issue = String(summary.issue);
        if (summary?.pages)
          item.pages = String(summary.pages);
        if (Array.isArray(summary?.pubtype) && summary.pubtype.length)
          item.publicationTypes = summary.pubtype.map(String);
        const fullTextLinks = fullTextLinksOf(summary);
        if (fullTextLinks.length)
          item.fullTextLinks = fullTextLinks;
      }
      return item;
    };
    const summarize = async (db, ids) => {
      const items = [];
      for (let index = 0;index < ids.length; index += 100) {
        const batch = ids.slice(index, index + 100);
        const data = await eutilsJson("esummary.fcgi", { db, id: batch.join(",") });
        const result = data?.result;
        const uids = Array.isArray(result?.uids) ? result.uids : batch;
        items.push(...uids.map((uid) => normalize(result?.[uid] ?? { uid }, db)));
      }
      return items;
    };
    const enrichPubmedRecord = async (record, id, hasAbstract) => {
      const xml = await (await eutils("efetch.fcgi", { db: "pubmed", id, retmode: "xml" })).text();
      const document2 = new DOMParser().parseFromString(xml, "application/xml");
      if (document2.querySelector("parsererror"))
        throw new Error(`record pubmed/${id} returned invalid XML`);
      if (hasAbstract) {
        const sections = Array.from(document2.querySelectorAll("Abstract AbstractText")).map((node) => {
          const text = cleanText(node.textContent);
          const label = cleanText(node.getAttribute("Label"));
          return text && label ? `${label}: ${text}` : text;
        }).filter(Boolean);
        if (sections.length)
          record.abstract = sections.join(`

`);
      }
      const meshTerms = Array.from(document2.querySelectorAll("MeshHeadingList MeshHeading")).map((heading) => {
        const descriptor = heading.querySelector("DescriptorName");
        const id2 = cleanText(descriptor?.getAttribute("UI"));
        const name = cleanText(descriptor?.textContent);
        const qualifierNodes = Array.from(heading.querySelectorAll("QualifierName"));
        const qualifiers = qualifierNodes.map((node) => cleanText(node.textContent)).filter(Boolean);
        const majorTopic = descriptor?.getAttribute("MajorTopicYN") === "Y" || qualifierNodes.some((node) => node.getAttribute("MajorTopicYN") === "Y");
        return { id: id2, name, qualifiers, majorTopic, url: `https://www.ncbi.nlm.nih.gov/mesh/${encodeURIComponent(id2)}` };
      }).filter((term) => term.id && term.name);
      if (meshTerms.length)
        record.meshTerms = meshTerms;
      const substances = Array.from(document2.querySelectorAll("ChemicalList Chemical")).map((chemical) => {
        const nameNode = chemical.querySelector("NameOfSubstance");
        const id2 = cleanText(nameNode?.getAttribute("UI"));
        const name = cleanText(nameNode?.textContent);
        const registryNumber = cleanText(chemical.querySelector("RegistryNumber")?.textContent);
        const substance = {
          id: id2,
          name,
          url: `https://www.ncbi.nlm.nih.gov/mesh/${encodeURIComponent(id2)}`
        };
        if (registryNumber && registryNumber !== "0")
          substance.registryNumber = registryNumber;
        return substance;
      }).filter((substance) => substance.id && substance.name);
      if (substances.length)
        record.substances = substances;
    };
    action("listDatabases", {
      async invoke() {
        const data = await eutilsJson("einfo.fcgi", {});
        const items = Array.isArray(data?.einforesult?.dblist) ? data.einforesult.dblist : [];
        log(`listDatabases -> ${items.length}`);
        return { items, nextCursor: null };
      }
    });
    action("suggestSearchTerms", {
      async invoke({ query, limit } = {}) {
        if (!query)
          throw new Error("suggestSearchTerms: query is required");
        const qs = new URLSearchParams({ term: query });
        const response = await retryFetch(`https://pubmed.ncbi.nlm.nih.gov/suggestions/?${qs}`, { credentials: "omit" });
        if (!response.ok)
          throw new Error(`suggestions HTTP ${response.status}`);
        const data = await response.json();
        if (data?.code !== 0 || !Array.isArray(data?.suggestions))
          throw new Error("suggestions returned an invalid response");
        const items = data.suggestions.filter((item) => typeof item === "string").slice(0, limit || 10);
        log(`suggestSearchTerms "${query}" -> ${items.length}`);
        return { items, nextCursor: null };
      }
    });
    action("search", {
      async invoke({ query, db, cursor, limit } = {}) {
        if (!query)
          throw new Error("search: query is required");
        const database = db || "pubmed";
        const retstart = cursor ? Math.max(0, parseInt(cursor, 10) || 0) : 0;
        const retmax = Math.min(50, Math.max(1, limit || 10));
        const data = await eutilsJson("esearch.fcgi", {
          db: database,
          term: query,
          retstart: String(retstart),
          retmax: String(retmax)
        });
        const result = data?.esearchresult;
        const ids = Array.isArray(result?.idlist) ? result.idlist : [];
        const count = parseInt(result?.count ?? "0", 10) || 0;
        const items = await summarize(database, ids);
        const next = retstart + retmax;
        const nextCursor = next < count && items.length ? String(next) : null;
        log(`search db=${database} "${query}" start=${retstart} -> ${items.length}/${count}`);
        return { items, count, nextCursor };
      }
    });
    action("getRecord", {
      async invoke({ id, db } = {}) {
        if (!id)
          throw new Error("getRecord: id is required");
        const database = db || "pubmed";
        const data = await eutilsJson("esummary.fcgi", { db: database, id: String(id) });
        const entry = data?.result?.[String(id)];
        if (!entry || entry.error)
          throw new Error(`record ${database}/${id} not found`);
        const record = normalize(entry, database);
        if (database === "pubmed") {
          const hasAbstract = Array.isArray(entry.attributes) && entry.attributes.includes("Has Abstract");
          await enrichPubmedRecord(record, String(id), hasAbstract);
        }
        log(`getRecord db=${database} id=${id}`);
        return record;
      }
    });
    action("listRelatedArticles", {
      async invoke({ id, kind } = {}) {
        if (!id)
          throw new Error("listRelatedArticles: id is required");
        const relation = kind || "similar";
        const linkname = relation === "citedBy" ? "pubmed_pubmed_citedin" : "pubmed_pubmed";
        const data = await eutilsJson("elink.fcgi", {
          dbfrom: "pubmed",
          db: "pubmed",
          id: String(id),
          linkname
        });
        const linksets = Array.isArray(data?.linksets) ? data.linksets : [];
        const linksetdbs = Array.isArray(linksets[0]?.linksetdbs) ? linksets[0].linksetdbs : [];
        const links = linksetdbs.find((linkset) => linkset?.linkname === linkname)?.links;
        const ids = (Array.isArray(links) ? links.map(String) : []).filter((linkedId) => linkedId !== String(id));
        const items = await summarize("pubmed", ids);
        log(`listRelatedArticles id=${id} kind=${relation} -> ${items.length}`);
        return { items, count: items.length, nextCursor: null };
      }
    });
    const COUNT_DBS = [
      { db: "books", label: "Bookshelf", category: "Literature" },
      { db: "mesh", label: "MeSH", category: "Literature" },
      { db: "nlmcatalog", label: "NLM Catalog", category: "Literature" },
      { db: "pubmed", label: "PubMed", category: "Literature" },
      { db: "pmc", label: "PubMed Central", category: "Literature" },
      { db: "gene", label: "Gene", category: "Genes" },
      { db: "gds", label: "GEO DataSets", category: "Genes" },
      { db: "geoprofiles", label: "GEO Profiles", category: "Genes" },
      { db: "cdd", label: "Conserved Domains", category: "Proteins" },
      { db: "ipg", label: "Identical Protein Groups", category: "Proteins" },
      { db: "protein", label: "Protein", category: "Proteins" },
      { db: "protfam", label: "Protein Family Models", category: "Proteins" },
      { db: "structure", label: "Structure", category: "Proteins" },
      { db: "datasets", label: "Datasets", category: "Genomes" },
      { db: "biocollections", label: "BioCollections", category: "Genomes" },
      { db: "bioproject", label: "BioProject", category: "Genomes" },
      { db: "biosample", label: "BioSample", category: "Genomes" },
      { db: "nuccore", label: "Nucleotide", category: "Genomes" },
      { db: "sra", label: "SRA", category: "Genomes" },
      { db: "taxonomy", label: "Taxonomy", category: "Genomes" },
      { db: "clinicaltrials", label: "ClinicalTrials.gov", category: "Health" },
      { db: "clinvar", label: "ClinVar", category: "Health" },
      { db: "gap", label: "dbGaP", category: "Health" },
      { db: "snp", label: "dbSNP", category: "Health" },
      { db: "dbvar", label: "dbVar", category: "Health" },
      { db: "gtr", label: "GTR", category: "Health" },
      { db: "medgen", label: "MedGen", category: "Health" },
      { db: "omim", label: "OMIM", category: "Health" },
      { db: "pcassay", label: "BioAssays", category: "Chemicals" },
      { db: "pccompound", label: "Compounds", category: "Chemicals" },
      { db: "biosystems", label: "Pathways", category: "Chemicals" },
      { db: "pcsubstance", label: "Substances", category: "Chemicals" }
    ];
    action("databaseCounts", {
      async invoke({ query } = {}) {
        if (!query)
          throw new Error("databaseCounts: query is required");
        const items = await Promise.all(COUNT_DBS.map(async ({ db, label, category }) => {
          if (db === "datasets")
            return { db, label, category, count: null };
          try {
            const qs = new URLSearchParams({ db, term: query });
            const response = await retryFetch(`https://www.ncbi.nlm.nih.gov/search/ajax/result-count/?${qs}`, {
              credentials: "omit"
            });
            if (!response.ok)
              throw new Error(`HTTP ${response.status}`);
            const data = await response.json();
            const normalized = String(data?.count ?? "").replace(/,/g, "");
            const count = /^\d+$/.test(normalized) ? Number.parseInt(normalized, 10) : null;
            return { db, label, category, count };
          } catch (error) {
            log(`databaseCounts db=${db} failed: ${String(error?.message ?? error)}`);
            return { db, label, category, count: null };
          }
        }));
        const matches = items.filter((item) => (item.count ?? 0) > 0).length;
        log(`databaseCounts "${query}" -> ${matches}/${items.length} dbs with hits`);
        return { items, nextCursor: null };
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

  installService("www.ncbi.nlm.nih.gov", actions_default);
})();
