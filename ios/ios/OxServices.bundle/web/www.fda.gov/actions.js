(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/www.fda.gov/actions.ts
  var ORIGIN = "https://www.fda.gov";
  var API_ORIGIN = "https://api.fda.gov";
  var RECALLS_PATH = "/safety/recalls-market-withdrawals-safety-alerts";
  var OPENFDA_DISCLAIMER = "Do not rely on openFDA to make decisions regarding medical care. Results may be incomplete or unvalidated.";
  var LABEL_SECTIONS = {
    uses: {
      title: "Uses and indications",
      fields: ["indications_and_usage", "purpose"]
    },
    dosage: {
      title: "Dosage and administration",
      fields: ["dosage_and_administration"]
    },
    warnings: {
      title: "Warnings and cautions",
      fields: ["warnings_and_cautions", "warnings", "do_not_use", "ask_doctor", "stop_use", "when_using"]
    },
    boxedWarning: {
      title: "Boxed warning",
      fields: ["boxed_warning"]
    },
    contraindications: {
      title: "Contraindications",
      fields: ["contraindications"]
    },
    drugInteractions: {
      title: "Drug interactions",
      fields: ["drug_interactions", "drug_and_or_laboratory_test_interactions"]
    },
    adverseReactions: {
      title: "Adverse reactions",
      fields: ["adverse_reactions"]
    },
    patientInformation: {
      title: "Patient information",
      fields: ["information_for_patients", "patient_medication_information"]
    }
  };
  var PRODUCT_VALUES = {
    any: "All",
    "animal-veterinary": "2274",
    biologics: "2286",
    cosmetics: "2294",
    "dietary-supplements": "2305",
    drugs: "2312",
    "food-beverages": "2323",
    "medical-devices": "2374",
    "radiation-emitting-products": "2393",
    tobacco: "2398"
  };
  var TERMINATED_VALUES = {
    any: "All",
    yes: "1",
    no: "0"
  };
  var SORT_VALUES = {
    relevance: "rel_DESC",
    newest: "date_DESC",
    oldest: "date_ASC"
  };
  var install = ({ action, retryFetch, log }) => {
    const strings = (value) => (Array.isArray(value) ? value : value === undefined || value === null ? [] : [value]).map(cleanText).filter(Boolean);
    const boolean = (value) => value === true || String(value).toLowerCase() === "true";
    const phrase = (value) => `"${value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
    const openFda = async (path, params) => {
      const url = `${API_ORIGIN}/${path}.json?${params}`;
      const response = await retryFetch(url);
      if (response.status === 404) {
        return {
          url,
          payload: {
            meta: { disclaimer: OPENFDA_DISCLAIMER, last_updated: "", results: { total: 0 } },
            results: []
          }
        };
      }
      if (!response.ok)
        throw new Error(`openFDA returned HTTP ${response.status}`);
      const payload = await response.json();
      if (!Array.isArray(payload?.results))
        throw new Error("openFDA returned an unexpected response");
      return { url, payload };
    };
    const pageResult = (payload, offset, returned) => {
      const total = Number(payload?.meta?.results?.total ?? returned);
      const nextOffset = offset + returned;
      return {
        total,
        nextCursor: nextOffset < total && nextOffset <= 25000 ? String(nextOffset) : null,
        dataLastUpdated: cleanText(payload?.meta?.last_updated),
        disclaimer: cleanText(payload?.meta?.disclaimer) || OPENFDA_DISCLAIMER
      };
    };
    const labelSection = (record, name) => {
      const definition = LABEL_SECTIONS[name];
      const text = [...new Set(definition.fields.flatMap((field) => strings(record?.[field])))].join(`

`);
      const limit = 12000;
      return {
        name,
        title: definition.title,
        text: text.slice(0, limit),
        truncated: text.length > limit
      };
    };
    const drugProduct = (record) => ({
      id: cleanText(record?.product_id),
      productNdc: cleanText(record?.product_ndc),
      brandName: cleanText(record?.brand_name),
      genericName: cleanText(record?.generic_name),
      labelerName: cleanText(record?.labeler_name),
      productType: cleanText(record?.product_type),
      dosageForm: cleanText(record?.dosage_form),
      routes: strings(record?.route),
      marketingCategory: cleanText(record?.marketing_category),
      applicationNumber: cleanText(record?.application_number),
      marketingStartDate: cleanText(record?.marketing_start_date),
      marketingEndDate: cleanText(record?.marketing_end_date),
      listingExpirationDate: cleanText(record?.listing_expiration_date),
      finished: boolean(record?.finished),
      activeIngredients: (Array.isArray(record?.active_ingredients) ? record.active_ingredients : []).map((ingredient) => ({
        name: cleanText(ingredient?.name),
        strength: cleanText(ingredient?.strength)
      })),
      packages: (Array.isArray(record?.packaging) ? record.packaging : []).slice(0, 30).map((packaging) => ({
        packageNdc: cleanText(packaging?.package_ndc),
        description: cleanText(packaging?.description),
        marketingStartDate: cleanText(packaging?.marketing_start_date),
        marketingEndDate: cleanText(packaging?.marketing_end_date),
        sample: boolean(packaging?.sample)
      }))
    });
    const medicalDevice = (record) => ({
      recordKey: cleanText(record?.public_device_record_key ?? record?.record_key),
      brandName: cleanText(record?.brand_name),
      companyName: cleanText(record?.company_name),
      deviceDescription: cleanText(record?.device_description),
      versionOrModelNumber: cleanText(record?.version_or_model_number),
      catalogNumber: cleanText(record?.catalog_number),
      recordStatus: cleanText(record?.record_status),
      commercialDistributionStatus: cleanText(record?.commercial_distribution_status),
      publishDate: cleanText(record?.publish_date),
      mriSafety: cleanText(record?.mri_safety),
      prescription: boolean(record?.is_rx),
      overTheCounter: boolean(record?.is_otc),
      singleUse: boolean(record?.is_single_use),
      combinationProduct: boolean(record?.is_combination_product),
      identifiers: (Array.isArray(record?.identifiers) ? record.identifiers : []).map((identifier) => ({
        id: cleanText(identifier?.id),
        type: cleanText(identifier?.type),
        issuingAgency: cleanText(identifier?.issuing_agency)
      })),
      productCodes: (Array.isArray(record?.product_codes) ? record.product_codes : []).map((productCode) => ({
        code: cleanText(productCode?.code),
        name: cleanText(productCode?.name),
        deviceClass: cleanText(productCode?.openfda?.device_class),
        regulationNumber: cleanText(productCode?.openfda?.regulation_number)
      }))
    });
    const fetchDoc = async (url) => {
      const response = await retryFetch(url);
      if (!response.ok)
        throw new Error(`FDA returned HTTP ${response.status}`);
      return new DOMParser().parseFromString(await response.text(), "text/html");
    };
    const absoluteUrl = (value) => new URL(value, ORIGIN).href;
    const fdaUrl = (value) => {
      const url = new URL(value, ORIGIN);
      if (url.origin !== ORIGIN)
        throw new Error("The page must be on www.fda.gov");
      return url;
    };
    const fragmentDoc = (value) => new DOMParser().parseFromString(`<body>${String(value ?? "")}</body>`, "text/html");
    const fragmentText = (value) => cleanText(fragmentDoc(value).body.textContent);
    const parseRecallRow = (row) => {
      const linkDoc = fragmentDoc(row[1]);
      const link = linkDoc.querySelector("a[href]");
      if (!link)
        return null;
      const url = new URL(link.getAttribute("href") ?? "", ORIGIN);
      const id = decodeURIComponent(url.pathname.split("/").filter(Boolean).at(-1) ?? "");
      if (!id)
        return null;
      const dateDoc = fragmentDoc(row[0]);
      const date = dateDoc.querySelector("time")?.getAttribute("datetime") ?? fragmentText(row[0]);
      return {
        id,
        url: url.href,
        date,
        brand: cleanText(link.textContent),
        productDescription: fragmentText(row[2]),
        productType: fragmentText(row[3]),
        reason: fragmentText(row[4]),
        company: fragmentText(row[5]),
        terminated: fragmentText(row[6]).toLowerCase() === "yes",
        excerpt: fragmentText(row[7])
      };
    };
    const summaryEntry = (doc, label) => {
      const normalized = label.toLowerCase();
      const term = [...doc.querySelectorAll("dl.lcds-description-list--grid dt")].find((element) => cleanText(element.textContent).replace(/:$/, "").toLowerCase() === normalized);
      return term?.nextElementSibling ?? null;
    };
    action("searchSite", {
      async invoke({ query, cursor, limit = 25, sort = "relevance" }) {
        const page = pageCursor(cursor, 0);
        const params = new URLSearchParams({
          s: query,
          page: String(page),
          items_per_page: String(limit),
          sort_bef_combine: SORT_VALUES[sort] ?? SORT_VALUES.relevance
        });
        const doc = await fetchDoc(`${ORIGIN}/search?${params}`);
        const resultRoot = [...doc.querySelectorAll("main .view-content")].find((element) => element.querySelector(":scope > div > div > a[href]"));
        const items = [...resultRoot?.children ?? []].filter((element) => element.tagName === "DIV").map((element) => {
          const sections = [...element.children].filter((child) => child.tagName === "DIV");
          const link = sections[1]?.querySelector("a[href]");
          return {
            title: cleanText(sections[0]?.textContent),
            url: link ? absoluteUrl(link.getAttribute("href") ?? "") : "",
            snippet: cleanText(sections[2]?.textContent)
          };
        }).filter((item) => item.title && item.url);
        const nextLink = doc.querySelector(".pager__item--next a[rel='next']");
        const nextCursor = nextLink ? new URL(nextLink.getAttribute("href") ?? "", ORIGIN).searchParams.get("page") : null;
        log(`fda site search page ${page} returned ${items.length} results`);
        return { items, nextCursor };
      }
    });
    action("listRecalls", {
      async invoke({ query = "", productType = "any", terminated = "any", cursor, limit = 25 } = {}) {
        const start = pageCursor(cursor, 0);
        const params = new URLSearchParams({
          search_api_fulltext: query,
          field_regulated_product_field: PRODUCT_VALUES[productType] ?? PRODUCT_VALUES.any,
          field_terminated_recall: TERMINATED_VALUES[terminated] ?? TERMINATED_VALUES.any,
          draw: "1",
          start: String(start),
          length: String(limit),
          _drupal_ajax: "1",
          _wrapper_format: "drupal_ajax",
          pager_element: "0",
          view_args: "",
          view_base_path: `${RECALLS_PATH.slice(1)}/datatables-data`,
          view_display_id: "recall_datatable_block_1",
          view_name: "recall_solr_index",
          view_path: RECALLS_PATH
        });
        const response = await retryFetch(`${ORIGIN}/datatables/views/ajax?${params}`);
        if (!response.ok)
          throw new Error(`FDA recalls returned HTTP ${response.status}`);
        const payload = await response.json();
        if (!Array.isArray(payload.data))
          throw new Error("FDA recalls returned an unexpected response");
        const items = payload.data.map(parseRecallRow).filter((item) => item !== null);
        const total = Number(payload.recordsFiltered ?? items.length);
        const nextOffset = start + payload.data.length;
        const nextCursor = nextOffset < total ? String(nextOffset) : null;
        log(`fda recalls offset ${start} returned ${items.length} of ${total} results`);
        return { items, nextCursor };
      }
    });
    action("getRecall", {
      async invoke({ id }) {
        const url = `${ORIGIN}${RECALLS_PATH}/${encodeURIComponent(id)}`;
        const doc = await fetchDoc(url);
        const title = cleanText(doc.querySelector("h1.content-title")?.textContent);
        if (!title)
          throw new Error(`No FDA recall found for ${id}`);
        const announcementDate = summaryEntry(doc, "Company Announcement Date");
        const publishDate = summaryEntry(doc, "FDA Publish Date");
        const brandEntry = summaryEntry(doc, "Brand Name");
        const productEntry = summaryEntry(doc, "Product Description");
        const reasonEntry = summaryEntry(doc, "Reason for Announcement");
        const brands = [...brandEntry?.querySelectorAll(".field--item") ?? []].map((element) => cleanText(element.textContent)).filter(Boolean);
        if (brands.length === 0 && brandEntry)
          brands.push(cleanText(brandEntry.textContent));
        const announcementHeading = doc.querySelector("#recall-announcement");
        const announcementParts = [];
        for (let element = announcementHeading?.nextElementSibling;element; element = element.nextElementSibling) {
          if (element.id === "recall-photos")
            break;
          const sectionTitle = cleanText(element.querySelector("h2")?.textContent);
          if (sectionTitle === "Company Contact Information")
            break;
          const text = cleanText(element.textContent);
          if (text)
            announcementParts.push(text);
        }
        return {
          id,
          url,
          title,
          announcementType: cleanText(doc.querySelector(".content-type-label")?.textContent),
          companyAnnouncementDate: announcementDate?.querySelector("time")?.getAttribute("datetime") ?? cleanText(announcementDate?.textContent),
          fdaPublishDate: publishDate?.querySelector("time")?.getAttribute("datetime") ?? cleanText(publishDate?.textContent),
          productType: cleanText(summaryEntry(doc, "Product Type")?.textContent),
          reason: cleanText(reasonEntry?.querySelector(".field--item")?.textContent ?? reasonEntry?.textContent),
          company: cleanText(summaryEntry(doc, "Company Name")?.textContent),
          brands,
          productDescription: cleanText(productEntry?.querySelector(".field--item")?.textContent ?? productEntry?.textContent),
          announcement: announcementParts.join(`

`).slice(0, 30000)
        };
      }
    });
    action("getDrugLabel", {
      async invoke({ query, field = "any", sections = ["uses", "dosage", "warnings", "contraindications", "drugInteractions"] }) {
        const value = phrase(query);
        const searches = {
          any: `(openfda.brand_name.exact:${value} OR openfda.generic_name.exact:${value} OR openfda.product_ndc.exact:${value} OR openfda.package_ndc.exact:${value})`,
          brand: `openfda.brand_name.exact:${value}`,
          generic: `openfda.generic_name.exact:${value}`,
          ndc: `(openfda.product_ndc.exact:${value} OR openfda.package_ndc.exact:${value})`
        };
        const params = new URLSearchParams({
          search: searches[field] ?? searches.any,
          sort: "effective_time:desc",
          limit: "1"
        });
        const { url, payload } = await openFda("drug/label", params);
        const record = payload.results[0];
        if (!record)
          throw new Error(`No FDA drug label found for ${query}`);
        const openfda = record.openfda ?? {};
        log(`openFDA drug label search matched ${payload.meta?.results?.total ?? 1} records`);
        return {
          id: cleanText(record.id),
          setId: cleanText(record.set_id),
          version: cleanText(record.version),
          effectiveTime: cleanText(record.effective_time),
          matchedCount: Number(payload.meta?.results?.total ?? 1),
          brandNames: strings(openfda.brand_name),
          genericNames: strings(openfda.generic_name),
          manufacturerNames: strings(openfda.manufacturer_name),
          productNdcs: strings(openfda.product_ndc),
          packageNdcs: strings(openfda.package_ndc),
          applicationNumbers: strings(openfda.application_number),
          routes: strings(openfda.route),
          sections: sections.map((name) => labelSection(record, name)),
          sourceUrl: url,
          dataLastUpdated: cleanText(payload.meta?.last_updated),
          disclaimer: cleanText(payload.meta?.disclaimer) || OPENFDA_DISCLAIMER,
          labelingNotice: "This is submitted labeling data and may not match currently distributed or FDA-approved labeling."
        };
      }
    });
    action("searchDrugShortages", {
      async invoke({ query, status = "Current", cursor, limit = 20 }) {
        const offset = pageCursor(cursor, 0);
        const value = phrase(query);
        const nameSearch = `(generic_name:${value} OR proprietary_name:${value} OR openfda.brand_name:${value} OR openfda.generic_name:${value})`;
        const search = status === "Any" ? nameSearch : `${nameSearch} AND status:${phrase(status)}`;
        const params = new URLSearchParams({
          search,
          sort: "update_date:desc",
          skip: String(offset),
          limit: String(limit)
        });
        const { url, payload } = await openFda("drug/shortages", params);
        const items = payload.results.map((record) => ({
          packageNdc: cleanText(record?.package_ndc),
          genericName: cleanText(record?.generic_name),
          proprietaryName: cleanText(record?.proprietary_name),
          companyName: cleanText(record?.company_name),
          presentation: cleanText(record?.presentation),
          status: cleanText(record?.status),
          availability: cleanText(record?.availability),
          shortageReason: cleanText(record?.shortage_reason),
          resolvedNote: cleanText(record?.resolved_note),
          relatedInformation: cleanText(record?.related_info),
          relatedInformationUrl: cleanText(record?.related_info_link),
          therapeuticCategories: strings(record?.therapeutic_category),
          dosageForm: cleanText(record?.dosage_form),
          strengths: strings(record?.strength),
          updateDate: cleanText(record?.update_date),
          changeDate: cleanText(record?.change_date),
          initialPostingDate: cleanText(record?.initial_posting_date)
        }));
        log(`openFDA drug shortages offset ${offset} returned ${items.length} results`);
        return { items, ...pageResult(payload, offset, items.length), sourceUrl: url };
      }
    });
    action("lookupDrug", {
      async invoke({ ndc, brandName, genericName, cursor, limit = 20 }) {
        const offset = pageCursor(cursor, 0);
        const search = ndc ? `(product_ndc:${phrase(ndc)} OR packaging.package_ndc:${phrase(ndc)})` : brandName ? `brand_name:${phrase(brandName)}` : `generic_name:${phrase(genericName)}`;
        const params = new URLSearchParams({ search, skip: String(offset), limit: String(limit) });
        const { url, payload } = await openFda("drug/ndc", params);
        const items = payload.results.map(drugProduct);
        log(`openFDA drug products offset ${offset} returned ${items.length} results`);
        return {
          items,
          ...pageResult(payload, offset, items.length),
          sourceUrl: url,
          approvalNotice: "An NDC listing does not mean the product is FDA approved."
        };
      }
    });
    action("lookupDevice", {
      async invoke({ udi, brandName, catalogNumber, cursor, limit = 20 }) {
        const offset = pageCursor(cursor, 0);
        const search = udi ? `identifiers.id:${phrase(udi)}` : brandName ? `brand_name:${phrase(brandName)}` : `catalog_number:${phrase(catalogNumber)}`;
        const params = new URLSearchParams({ search, skip: String(offset), limit: String(limit) });
        const { url, payload } = await openFda("device/udi", params);
        const items = payload.results.map(medicalDevice);
        log(`openFDA medical devices offset ${offset} returned ${items.length} results`);
        return { items, ...pageResult(payload, offset, items.length), sourceUrl: url };
      }
    });
    action("getPage", {
      async invoke({ path }) {
        const requestedUrl = fdaUrl(path);
        const response = await retryFetch(requestedUrl.href);
        if (!response.ok)
          throw new Error(`FDA returned HTTP ${response.status}`);
        const finalUrl = fdaUrl(response.url || requestedUrl.href);
        const doc = new DOMParser().parseFromString(await response.text(), "text/html");
        const title = cleanText(doc.querySelector("h1")?.textContent || doc.title.replace(/\s*\|\s*FDA\s*$/, ""));
        const main = (doc.querySelector("main#main") || doc.querySelector("main") || doc.body).cloneNode(true);
        main.querySelectorAll("script, style, noscript, nav, aside, form, iframe, .lcds-breadcrumb, .region-pre-header").forEach((element) => element.remove());
        main.querySelectorAll("h1, h2, h3, h4, p, li, dt, dd, tr").forEach((element) => element.after(doc.createTextNode(`
`)));
        const text = (main.textContent ?? "").replace(/[ \t]+/g, " ").replace(/ *\n */g, `
`).replace(/\n{3,}/g, `

`).trim().slice(0, 30000);
        const seen = new Set;
        const links = [...main.querySelectorAll("a[href]")].map((link) => ({
          text: cleanText(link.textContent),
          url: absoluteUrl(link.getAttribute("href") ?? "")
        })).filter((link) => link.text && !seen.has(link.url) && seen.add(link.url)).slice(0, 80);
        if (!title || !text)
          throw new Error("FDA page did not contain readable content");
        return { url: finalUrl.href, title, text, links };
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

  installService("www.fda.gov", actions_default);
})();
