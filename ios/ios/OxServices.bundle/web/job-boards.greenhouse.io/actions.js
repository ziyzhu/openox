(() => {
  // service-sdk/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/job-boards.greenhouse.io/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const token = (value) => {
      const normalized = String(value ?? "").trim();
      if (!/^[a-zA-Z0-9_-]+$/.test(normalized))
        throw new Error("Invalid Greenhouse board name");
      return normalized;
    };
    const jobId = (value) => {
      const normalized = String(value ?? "").trim();
      if (!/^\d+$/.test(normalized))
        throw new Error("Invalid Greenhouse job id");
      return normalized;
    };
    const resourceId = (value, kind) => {
      const normalized = String(value ?? "").trim();
      if (!/^\d+$/.test(normalized))
        throw new Error(`Invalid Greenhouse ${kind} id`);
      return normalized;
    };
    const fetchJson = async (url) => {
      const response = await retryFetch(url);
      if (!response.ok)
        throw new Error(`Greenhouse returned HTTP ${response.status}`);
      return response.json();
    };
    const apiUrl = (board, path) => new URL(`https://boards.greenhouse.io/v1/boards/${encodeURIComponent(token(board))}/${path}`);
    const fetchDocument = async (url) => {
      const response = await retryFetch(url);
      if (!response.ok)
        throw new Error(`Greenhouse returned HTTP ${response.status}`);
      const document2 = new DOMParser().parseFromString(await response.text(), "text/html");
      if (!document2.documentElement)
        throw new Error("Greenhouse returned an unreadable page");
      return document2;
    };
    const loaderData = (document2) => {
      const script = [...document2.scripts].find((candidate) => candidate.textContent?.trimStart().startsWith("window.__remixContext = "));
      const source = script?.textContent ?? "";
      const start = source.indexOf("{");
      const end = source.lastIndexOf("}");
      if (start < 0 || end <= start)
        throw new Error("Greenhouse page data was not found");
      const context = JSON.parse(source.slice(start, end + 1));
      const data = context?.state?.loaderData;
      if (!data || typeof data !== "object")
        throw new Error("Greenhouse page data was incomplete");
      return data;
    };
    const htmlText = (value) => {
      const document2 = new DOMParser().parseFromString(String(value ?? ""), "text/html");
      return cleanText(document2.body?.textContent);
    };
    const boardUrl = (board, args) => {
      const url = new URL(`https://job-boards.greenhouse.io/${encodeURIComponent(board)}`);
      const page = pageCursor(args.cursor, 1);
      if (page > 1)
        url.searchParams.set("page", String(page));
      if (args.query)
        url.searchParams.set("keyword", String(args.query));
      for (const id of args.departments ?? [])
        url.searchParams.append("departments[]", String(id));
      for (const id of args.offices ?? [])
        url.searchParams.append("offices[]", String(id));
      return url.href;
    };
    const loadBoard = async (args) => {
      const board = token(args.board);
      const data = loaderData(await fetchDocument(boardUrl(board, args)))["routes/$url_token"];
      if (!data?.board || !data?.jobPosts)
        throw new Error(`Greenhouse board '${board}' was not found`);
      return data;
    };
    const namedFilter = (item) => ({
      id: String(item?.id ?? ""),
      name: cleanText(item?.name)
    });
    const jobItem = (post, company) => ({
      id: String(post?.id ?? ""),
      title: cleanText(post?.title),
      company: cleanText(company),
      location: cleanText(post?.location),
      departments: post?.department ? [namedFilter(post.department)] : [],
      offices: [],
      requisitionId: cleanText(post?.requisition_id),
      publishedAt: cleanText(post?.published_at),
      updatedAt: cleanText(post?.updated_at),
      url: String(post?.absolute_url ?? "")
    });
    const jobPage = (data) => {
      const posts = data.jobPosts;
      const page = Number(posts.page) || 1;
      const totalPages = Number(posts.total_pages) || 1;
      return {
        items: (posts.data ?? []).map((post) => jobItem(post, data.board.name)),
        nextCursor: page < totalPages ? String(page + 1) : null
      };
    };
    const money = (value) => {
      const normalized = String(value ?? "").replace(/[^0-9.-]/g, "");
      return Number(normalized) || 0;
    };
    const questionText = (value) => htmlText(htmlText(value));
    const questionOption = (option) => ({
      value: String(option?.value ?? option?.id ?? ""),
      label: cleanText(option?.label),
      freeForm: Boolean(option?.free_form),
      declineToAnswer: Boolean(option?.decline_to_answer)
    });
    const question = (item) => {
      const sourceFields = Array.isArray(item?.fields) ? item.fields : [{
        name: `demographic_question_${String(item?.id ?? "")}`,
        type: item?.type,
        values: item?.answer_options
      }];
      const fields = sourceFields.map((field) => ({
        name: cleanText(field?.name),
        type: cleanText(field?.type),
        options: (field?.values ?? []).map(questionOption)
      }));
      return {
        id: String(item?.id ?? fields[0]?.name ?? ""),
        label: cleanText(item?.label),
        description: questionText(item?.description),
        required: Boolean(item?.required),
        fields
      };
    };
    const prospectPost = (post) => ({
      id: String(post?.id ?? ""),
      title: cleanText(post?.title),
      location: cleanText(post?.location?.name),
      updatedAt: cleanText(post?.updated_at),
      language: cleanText(post?.language),
      url: String(post?.absolute_url ?? "")
    });
    const section = (item) => ({
      id: String(item?.id ?? ""),
      name: cleanText(item?.name),
      posts: (item?.jobs ?? []).map(prospectPost)
    });
    const educationPage = async (kind, args) => {
      const url = apiUrl(args.board, `education/${kind}`);
      const page = pageCursor(args.cursor, 1);
      if (page > 1)
        url.searchParams.set("page", String(page));
      if (args.query)
        url.searchParams.set("term", String(args.query));
      const data = await fetchJson(url.href);
      const totalCount = Number(data?.meta?.total_count) || 0;
      const perPage = Number(data?.meta?.per_page) || 100;
      return {
        items: (data?.items ?? []).map((item) => ({
          id: String(item?.id ?? ""),
          name: cleanText(item?.text)
        })),
        totalCount,
        nextCursor: page * perPage < totalCount ? String(page + 1) : null
      };
    };
    action("getJobBoard", {
      async invoke({ board }) {
        const data = await loadBoard({ board });
        const result = {
          name: cleanText(data.board.name),
          description: htmlText(data.board.content),
          totalJobs: Number(data.jobPosts.total) || 0,
          departments: (data.departments ?? []).map(namedFilter),
          offices: (data.offices ?? []).map(namedFilter),
          url: String(data.board.public_url ?? "")
        };
        log(`greenhouse getJobBoard board=${token(board)} jobs=${result.totalJobs}`);
        return result;
      }
    });
    action("listJobs", {
      async invoke(args) {
        const data = await loadBoard(args);
        const result = jobPage(data);
        log(`greenhouse listJobs board=${token(args.board)} items=${result.items.length} next=${result.nextCursor !== null}`);
        return result;
      }
    });
    action("searchJobs", {
      async invoke(args) {
        const data = await loadBoard(args);
        const result = jobPage(data);
        log(`greenhouse searchJobs board=${token(args.board)} items=${result.items.length} next=${result.nextCursor !== null}`);
        return result;
      }
    });
    action("getJob", {
      async invoke({ board, id }) {
        const boardName = token(board);
        const normalizedId = jobId(id);
        const document2 = await fetchDocument(`https://job-boards.greenhouse.io/${encodeURIComponent(boardName)}/jobs/${encodeURIComponent(normalizedId)}`);
        const data = loaderData(document2)["routes/$url_token_.jobs_.$job_post_id"];
        const post = data?.jobPost;
        if (!post)
          throw new Error(`Greenhouse job '${normalizedId}' was not found`);
        const applicationDeadline = cleanText(post.application_deadline);
        const result = {
          id: String(data.jobPostId ?? normalizedId),
          title: cleanText(post.title),
          company: cleanText(post.company_name),
          location: cleanText(post.job_post_location),
          description: [post.introduction, post.content, post.conclusion].map(htmlText).filter(Boolean).join(`

`),
          payRanges: (post.pay_ranges ?? []).map((range) => ({
            title: cleanText(range.title),
            description: htmlText(range.description),
            minimum: money(range.min),
            maximum: money(range.max),
            currency: cleanText(range.currency_type)
          })),
          publishedAt: cleanText(post.published_at),
          applicationDeadline: applicationDeadline || null,
          language: cleanText(post.language),
          url: String(post.public_url ?? "")
        };
        log(`greenhouse getJob board=${boardName} id=${normalizedId}`);
        return result;
      }
    });
    action("getJobQuestions", {
      async invoke({ board, id }) {
        const boardName = token(board);
        const normalizedId = jobId(id);
        const url = apiUrl(boardName, `jobs/${encodeURIComponent(normalizedId)}`);
        url.searchParams.set("questions", "true");
        const data = await fetchJson(url.href);
        const demographic = data?.demographic_questions;
        const result = {
          id: String(data?.id ?? normalizedId),
          title: cleanText(data?.title),
          questions: (data?.questions ?? []).map(question),
          locationQuestions: (data?.location_questions ?? []).map(question),
          compliance: (data?.compliance ?? []).map((group) => ({
            type: cleanText(group?.type),
            description: questionText(group?.description),
            questions: (group?.questions ?? []).map(question)
          })),
          demographicQuestions: demographic ? {
            header: cleanText(demographic.header),
            description: questionText(demographic.description),
            questions: (demographic.questions ?? []).map(question)
          } : null
        };
        log(`greenhouse getJobQuestions board=${boardName} id=${normalizedId} questions=${result.questions.length}`);
        return result;
      }
    });
    action("getDepartment", {
      async invoke({ board, id }) {
        const boardName = token(board);
        const normalizedId = resourceId(id, "department");
        const data = await fetchJson(apiUrl(boardName, `departments/${encodeURIComponent(normalizedId)}`).href);
        const url = new URL(`https://job-boards.greenhouse.io/${encodeURIComponent(boardName)}`);
        url.searchParams.append("departments[]", normalizedId);
        const result = {
          id: String(data?.id ?? normalizedId),
          name: cleanText(data?.name),
          parentId: data?.parent_id == null ? null : String(data.parent_id),
          childIds: (data?.child_ids ?? []).map(String),
          totalJobs: (data?.jobs ?? []).length,
          url: url.href
        };
        log(`greenhouse getDepartment board=${boardName} id=${normalizedId} jobs=${result.totalJobs}`);
        return result;
      }
    });
    action("getOffice", {
      async invoke({ board, id }) {
        const boardName = token(board);
        const normalizedId = resourceId(id, "office");
        const data = await fetchJson(apiUrl(boardName, `offices/${encodeURIComponent(normalizedId)}`).href);
        const url = new URL(`https://job-boards.greenhouse.io/${encodeURIComponent(boardName)}`);
        url.searchParams.append("offices[]", normalizedId);
        const jobs = new Set((data?.departments ?? []).flatMap((department) => department?.jobs ?? []).map((post) => String(post?.id ?? "")));
        const result = {
          id: String(data?.id ?? normalizedId),
          name: cleanText(data?.name),
          location: cleanText(data?.location),
          parentId: data?.parent_id == null ? null : String(data.parent_id),
          childIds: (data?.child_ids ?? []).map(String),
          departments: (data?.departments ?? []).map(namedFilter),
          totalJobs: jobs.size,
          url: url.href
        };
        log(`greenhouse getOffice board=${boardName} id=${normalizedId} jobs=${result.totalJobs}`);
        return result;
      }
    });
    action("listSections", {
      async invoke({ board }) {
        const boardName = token(board);
        const data = await fetchJson(apiUrl(boardName, "sections").href);
        const result = {
          items: (data?.sections ?? []).map(section),
          nextCursor: null
        };
        log(`greenhouse listSections board=${boardName} sections=${result.items.length}`);
        return result;
      }
    });
    action("getSection", {
      async invoke({ board, id }) {
        const boardName = token(board);
        const normalizedId = resourceId(id, "section");
        const result = section(await fetchJson(apiUrl(boardName, `sections/${encodeURIComponent(normalizedId)}`).href));
        log(`greenhouse getSection board=${boardName} id=${normalizedId} posts=${result.posts.length}`);
        return result;
      }
    });
    for (const [actionId, kind] of [
      ["listDegrees", "degrees"],
      ["listDisciplines", "disciplines"],
      ["listSchools", "schools"]
    ]) {
      action(actionId, {
        async invoke(args) {
          const result = await educationPage(kind, args);
          log(`greenhouse ${actionId} board=${token(args.board)} items=${result.items.length} next=${result.nextCursor !== null}`);
          return result;
        }
      });
    }
  };
  var actions_default = install;

  // service-sdk/action-runtime.ts
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

  installService("job-boards.greenhouse.io", actions_default);
})();
