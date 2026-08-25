import { cleanText } from "@openox/service-sdk/action-lib";
import type { ActionInstaller } from "@openox/service-sdk/action";

type DatabaseCount = {
  db: string;
  label: string;
  category: string;
  count: number | null;
};

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils";

  const eutils = async (fcgi: string, params: Record<string, string>) => {
    const qs = new URLSearchParams({ tool: "ox", ...params });
    const res = await retryFetch(`${EUTILS}/${fcgi}?${qs}`, { credentials: "omit" });
    if (!res.ok) throw new Error(`${fcgi} HTTP ${res.status}`);
    return res;
  };

  const eutilsJson = async (fcgi: string, params: Record<string, string>) =>
    (await eutils(fcgi, { ...params, retmode: "json" })).json();

  const recordUrl = (db: string, uid: string) => db === "pubmed"
    ? `https://pubmed.ncbi.nlm.nih.gov/${encodeURIComponent(uid)}/`
    : `https://www.ncbi.nlm.nih.gov/${encodeURIComponent(db)}/${encodeURIComponent(uid)}`;

  const authorsOf = (summary: any): string[] | undefined =>
    Array.isArray(summary?.authors)
      ? summary.authors.map((author: any) => author?.name).filter((name: any) => typeof name === "string")
      : undefined;

  const titleOf = (summary: any, db: string, uid: string): string => {
    if (typeof summary?.title === "string" && summary.title) return summary.title;
    if (Array.isArray(summary?.ds_meshterms) && summary.ds_meshterms[0]) return summary.ds_meshterms[0];
    if (summary?.name && summary?.description) return `${summary.name} — ${summary.description}`;
    return summary?.name || summary?.caption || summary?.description || summary?.ds_scopenote || `${db} ${uid}`;
  };

  const sourceOf = (summary: any): string | undefined =>
    summary?.fulljournalname || summary?.source || summary?.book
    || summary?.organism?.scientificname || summary?.ds_scopenote || undefined;

  const dateOf = (summary: any): string | undefined =>
    summary?.sortpubdate || summary?.pubdate || summary?.epubdate || summary?.ds_yearintroduced || undefined;

  const articleIdOf = (summary: any, type: string): string | undefined =>
    Array.isArray(summary?.articleids)
      ? summary.articleids.find((articleId: any) => articleId?.idtype === type)?.value
      : undefined;

  const fullTextLinksOf = (summary: any) => {
    const links: { label: string; url: string }[] = [];
    const pmc = articleIdOf(summary, "pmc");
    const doi = articleIdOf(summary, "doi");
    if (pmc) links.push({ label: "PubMed Central", url: `https://pmc.ncbi.nlm.nih.gov/articles/${encodeURIComponent(pmc)}/` });
    if (doi) links.push({ label: "Publisher via DOI", url: `https://doi.org/${doi}` });
    if (typeof summary?.availablefromurl === "string" && /^https?:\/\//.test(summary.availablefromurl)) {
      links.push({ label: "Full text", url: summary.availablefromurl });
    }
    return links.filter((link, index) => links.findIndex((candidate) => candidate.url === link.url) === index);
  };

  const normalize = (summary: any, db: string) => {
    const uid = String(summary?.uid ?? "");
    const item: Record<string, unknown> = { id: uid, db, title: titleOf(summary, db, uid), url: recordUrl(db, uid) };
    const authors = authorsOf(summary);
    if (authors?.length) item.authors = authors;
    const source = sourceOf(summary);
    if (source) item.source = source;
    const date = dateOf(summary);
    if (date) item.date = date;
    if (db === "pubmed") {
      const doi = articleIdOf(summary, "doi");
      if (doi) item.doi = doi;
      if (summary?.volume) item.volume = String(summary.volume);
      if (summary?.issue) item.issue = String(summary.issue);
      if (summary?.pages) item.pages = String(summary.pages);
      if (Array.isArray(summary?.pubtype) && summary.pubtype.length) item.publicationTypes = summary.pubtype.map(String);
      const fullTextLinks = fullTextLinksOf(summary);
      if (fullTextLinks.length) item.fullTextLinks = fullTextLinks;
    }
    return item;
  };

  const summarize = async (db: string, ids: string[]) => {
    const items: Record<string, unknown>[] = [];
    for (let index = 0; index < ids.length; index += 100) {
      const batch = ids.slice(index, index + 100);
      const data = await eutilsJson("esummary.fcgi", { db, id: batch.join(",") });
      const result = data?.result;
      const uids: string[] = Array.isArray(result?.uids) ? result.uids : batch;
      items.push(...uids.map((uid) => normalize(result?.[uid] ?? { uid }, db)));
    }
    return items;
  };

  const enrichPubmedRecord = async (record: Record<string, unknown>, id: string, hasAbstract: boolean) => {
    const xml = await (await eutils("efetch.fcgi", { db: "pubmed", id, retmode: "xml" })).text();
    const document = new DOMParser().parseFromString(xml, "application/xml");
    if (document.querySelector("parsererror")) throw new Error(`record pubmed/${id} returned invalid XML`);

    if (hasAbstract) {
      const sections = Array.from(document.querySelectorAll("Abstract AbstractText"))
        .map((node) => {
          const text = cleanText(node.textContent);
          const label = cleanText(node.getAttribute("Label"));
          return text && label ? `${label}: ${text}` : text;
        })
        .filter(Boolean);
      if (sections.length) record.abstract = sections.join("\n\n");
    }

    const meshTerms = Array.from(document.querySelectorAll("MeshHeadingList MeshHeading"))
      .map((heading) => {
        const descriptor = heading.querySelector("DescriptorName");
        const id = cleanText(descriptor?.getAttribute("UI"));
        const name = cleanText(descriptor?.textContent);
        const qualifierNodes = Array.from(heading.querySelectorAll("QualifierName"));
        const qualifiers = qualifierNodes.map((node) => cleanText(node.textContent)).filter(Boolean);
        const majorTopic = descriptor?.getAttribute("MajorTopicYN") === "Y"
          || qualifierNodes.some((node) => node.getAttribute("MajorTopicYN") === "Y");
        return { id, name, qualifiers, majorTopic, url: `https://www.ncbi.nlm.nih.gov/mesh/${encodeURIComponent(id)}` };
      })
      .filter((term) => term.id && term.name);
    if (meshTerms.length) record.meshTerms = meshTerms;

    const substances = Array.from(document.querySelectorAll("ChemicalList Chemical"))
      .map((chemical) => {
        const nameNode = chemical.querySelector("NameOfSubstance");
        const id = cleanText(nameNode?.getAttribute("UI"));
        const name = cleanText(nameNode?.textContent);
        const registryNumber = cleanText(chemical.querySelector("RegistryNumber")?.textContent);
        const substance: Record<string, unknown> = {
          id,
          name,
          url: `https://www.ncbi.nlm.nih.gov/mesh/${encodeURIComponent(id)}`,
        };
        if (registryNumber && registryNumber !== "0") substance.registryNumber = registryNumber;
        return substance;
      })
      .filter((substance) => substance.id && substance.name);
    if (substances.length) record.substances = substances;
  };

  action("listDatabases", {
    async invoke() {
      const data = await eutilsJson("einfo.fcgi", {});
      const items: string[] = Array.isArray(data?.einforesult?.dblist) ? data.einforesult.dblist : [];
      log(`listDatabases -> ${items.length}`);
      return { items, nextCursor: null };
    },
  });

  action("suggestSearchTerms", {
    async invoke({ query, limit } = {}) {
      if (!query) throw new Error("suggestSearchTerms: query is required");
      const qs = new URLSearchParams({ term: query });
      const response = await retryFetch(`https://pubmed.ncbi.nlm.nih.gov/suggestions/?${qs}`, { credentials: "omit" });
      if (!response.ok) throw new Error(`suggestions HTTP ${response.status}`);
      const data = await response.json();
      if (data?.code !== 0 || !Array.isArray(data?.suggestions)) throw new Error("suggestions returned an invalid response");
      const items = data.suggestions.filter((item: unknown) => typeof item === "string").slice(0, limit || 10);
      log(`suggestSearchTerms "${query}" -> ${items.length}`);
      return { items, nextCursor: null };
    },
  });

  action("search", {
    async invoke({ query, db, cursor, limit } = {}) {
      if (!query) throw new Error("search: query is required");
      const database = db || "pubmed";
      const retstart = cursor ? Math.max(0, parseInt(cursor, 10) || 0) : 0;
      const retmax = Math.min(50, Math.max(1, limit || 10));
      const data = await eutilsJson("esearch.fcgi", {
        db: database,
        term: query,
        retstart: String(retstart),
        retmax: String(retmax),
      });
      const result = data?.esearchresult;
      const ids: string[] = Array.isArray(result?.idlist) ? result.idlist : [];
      const count = parseInt(result?.count ?? "0", 10) || 0;
      const items = await summarize(database, ids);
      const next = retstart + retmax;
      const nextCursor = next < count && items.length ? String(next) : null;
      log(`search db=${database} "${query}" start=${retstart} -> ${items.length}/${count}`);
      return { items, count, nextCursor };
    },
  });

  action("getRecord", {
    async invoke({ id, db } = {}) {
      if (!id) throw new Error("getRecord: id is required");
      const database = db || "pubmed";
      const data = await eutilsJson("esummary.fcgi", { db: database, id: String(id) });
      const entry = data?.result?.[String(id)];
      if (!entry || entry.error) throw new Error(`record ${database}/${id} not found`);
      const record: Record<string, unknown> = normalize(entry, database);
      if (database === "pubmed") {
        const hasAbstract = Array.isArray(entry.attributes) && entry.attributes.includes("Has Abstract");
        await enrichPubmedRecord(record, String(id), hasAbstract);
      }
      log(`getRecord db=${database} id=${id}`);
      return record;
    },
  });

  action("listRelatedArticles", {
    async invoke({ id, kind } = {}) {
      if (!id) throw new Error("listRelatedArticles: id is required");
      const relation = kind || "similar";
      const linkname = relation === "citedBy" ? "pubmed_pubmed_citedin" : "pubmed_pubmed";
      const data = await eutilsJson("elink.fcgi", {
        dbfrom: "pubmed",
        db: "pubmed",
        id: String(id),
        linkname,
      });
      const linksets = Array.isArray(data?.linksets) ? data.linksets : [];
      const linksetdbs = Array.isArray(linksets[0]?.linksetdbs) ? linksets[0].linksetdbs : [];
      const links = linksetdbs.find((linkset: any) => linkset?.linkname === linkname)?.links;
      const ids = (Array.isArray(links) ? links.map(String) : []).filter((linkedId) => linkedId !== String(id));
      const items = await summarize("pubmed", ids);
      log(`listRelatedArticles id=${id} kind=${relation} -> ${items.length}`);
      return { items, count: items.length, nextCursor: null };
    },
  });

  const COUNT_DBS: Omit<DatabaseCount, "count">[] = [
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
    { db: "pcsubstance", label: "Substances", category: "Chemicals" },
  ];

  action("databaseCounts", {
    async invoke({ query } = {}) {
      if (!query) throw new Error("databaseCounts: query is required");
      const items = await Promise.all(COUNT_DBS.map(async ({ db, label, category }): Promise<DatabaseCount> => {
        if (db === "datasets") return { db, label, category, count: null };
        try {
          const qs = new URLSearchParams({ db, term: query });
          const response = await retryFetch(`https://www.ncbi.nlm.nih.gov/search/ajax/result-count/?${qs}`, {
            credentials: "omit",
          });
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const data = await response.json();
          const normalized = String(data?.count ?? "").replace(/,/g, "");
          const count = /^\d+$/.test(normalized) ? Number.parseInt(normalized, 10) : null;
          return { db, label, category, count };
        } catch (error: any) {
          log(`databaseCounts db=${db} failed: ${String(error?.message ?? error)}`);
          return { db, label, category, count: null };
        }
      }));
      const matches = items.filter((item) => (item.count ?? 0) > 0).length;
      log(`databaseCounts "${query}" -> ${matches}/${items.length} dbs with hits`);
      return { items, nextCursor: null };
    },
  });
};

export default install;
