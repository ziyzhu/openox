import type { ActionInstaller } from "@openox/service-sdk/action";
import { cleanText, pageCursor } from "@openox/service-sdk/action-lib";

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const token = (value: unknown): string => {
    const normalized = String(value ?? "").trim();
    if (!/^[a-zA-Z0-9_-]+$/.test(normalized)) throw new Error("Invalid Greenhouse board name");
    return normalized;
  };

  const jobId = (value: unknown): string => {
    const normalized = String(value ?? "").trim();
    if (!/^\d+$/.test(normalized)) throw new Error("Invalid Greenhouse job id");
    return normalized;
  };

  const resourceId = (value: unknown, kind: string): string => {
    const normalized = String(value ?? "").trim();
    if (!/^\d+$/.test(normalized)) throw new Error(`Invalid Greenhouse ${kind} id`);
    return normalized;
  };

  const fetchJson = async (url: string): Promise<any> => {
    const response = await retryFetch(url);
    if (!response.ok) throw new Error(`Greenhouse returned HTTP ${response.status}`);
    return response.json();
  };

  const apiUrl = (board: unknown, path: string): URL =>
    new URL(`https://boards.greenhouse.io/v1/boards/${encodeURIComponent(token(board))}/${path}`);

  const fetchDocument = async (url: string): Promise<Document> => {
    const response = await retryFetch(url);
    if (!response.ok) throw new Error(`Greenhouse returned HTTP ${response.status}`);
    const document = new DOMParser().parseFromString(await response.text(), "text/html");
    if (!document.documentElement) throw new Error("Greenhouse returned an unreadable page");
    return document;
  };

  const loaderData = (document: Document): Record<string, any> => {
    const script = [...document.scripts].find((candidate) =>
      candidate.textContent?.trimStart().startsWith("window.__remixContext = ")
    );
    const source = script?.textContent ?? "";
    const start = source.indexOf("{");
    const end = source.lastIndexOf("}");
    if (start < 0 || end <= start) throw new Error("Greenhouse page data was not found");
    const context = JSON.parse(source.slice(start, end + 1));
    const data = context?.state?.loaderData;
    if (!data || typeof data !== "object") throw new Error("Greenhouse page data was incomplete");
    return data;
  };

  const htmlText = (value: unknown): string => {
    const document = new DOMParser().parseFromString(String(value ?? ""), "text/html");
    return cleanText(document.body?.textContent);
  };

  const boardUrl = (board: string, args: any): string => {
    const url = new URL(`https://job-boards.greenhouse.io/${encodeURIComponent(board)}`);
    const page = pageCursor(args.cursor, 1);
    if (page > 1) url.searchParams.set("page", String(page));
    if (args.query) url.searchParams.set("keyword", String(args.query));
    for (const id of args.departments ?? []) url.searchParams.append("departments[]", String(id));
    for (const id of args.offices ?? []) url.searchParams.append("offices[]", String(id));
    return url.href;
  };

  const loadBoard = async (args: any): Promise<any> => {
    const board = token(args.board);
    const data = loaderData(await fetchDocument(boardUrl(board, args)))["routes/$url_token"];
    if (!data?.board || !data?.jobPosts) throw new Error(`Greenhouse board '${board}' was not found`);
    return data;
  };

  const namedFilter = (item: any): any => ({
    id: String(item?.id ?? ""),
    name: cleanText(item?.name),
  });

  const jobItem = (post: any, company: string): any => ({
    id: String(post?.id ?? ""),
    title: cleanText(post?.title),
    company: cleanText(company),
    location: cleanText(post?.location),
    departments: post?.department ? [namedFilter(post.department)] : [],
    offices: [],
    requisitionId: cleanText(post?.requisition_id),
    publishedAt: cleanText(post?.published_at),
    updatedAt: cleanText(post?.updated_at),
    url: String(post?.absolute_url ?? ""),
  });

  const jobPage = (data: any): any => {
    const posts = data.jobPosts;
    const page = Number(posts.page) || 1;
    const totalPages = Number(posts.total_pages) || 1;
    return {
      items: (posts.data ?? []).map((post: any) => jobItem(post, data.board.name)),
      nextCursor: page < totalPages ? String(page + 1) : null,
    };
  };

  const money = (value: unknown): number => {
    const normalized = String(value ?? "").replace(/[^0-9.-]/g, "");
    return Number(normalized) || 0;
  };

  const questionText = (value: unknown): string => htmlText(htmlText(value));

  const questionOption = (option: any): any => ({
    value: String(option?.value ?? option?.id ?? ""),
    label: cleanText(option?.label),
    freeForm: Boolean(option?.free_form),
    declineToAnswer: Boolean(option?.decline_to_answer),
  });

  const question = (item: any): any => {
    const sourceFields = Array.isArray(item?.fields)
      ? item.fields
      : [{
          name: `demographic_question_${String(item?.id ?? "")}`,
          type: item?.type,
          values: item?.answer_options,
        }];
    const fields = sourceFields.map((field: any) => ({
      name: cleanText(field?.name),
      type: cleanText(field?.type),
      options: (field?.values ?? []).map(questionOption),
    }));
    return {
      id: String(item?.id ?? fields[0]?.name ?? ""),
      label: cleanText(item?.label),
      description: questionText(item?.description),
      required: Boolean(item?.required),
      fields,
    };
  };

  const prospectPost = (post: any): any => ({
    id: String(post?.id ?? ""),
    title: cleanText(post?.title),
    location: cleanText(post?.location?.name),
    updatedAt: cleanText(post?.updated_at),
    language: cleanText(post?.language),
    url: String(post?.absolute_url ?? ""),
  });

  const section = (item: any): any => ({
    id: String(item?.id ?? ""),
    name: cleanText(item?.name),
    posts: (item?.jobs ?? []).map(prospectPost),
  });

  const educationPage = async (kind: string, args: any): Promise<any> => {
    const url = apiUrl(args.board, `education/${kind}`);
    const page = pageCursor(args.cursor, 1);
    if (page > 1) url.searchParams.set("page", String(page));
    if (args.query) url.searchParams.set("term", String(args.query));
    const data = await fetchJson(url.href);
    const totalCount = Number(data?.meta?.total_count) || 0;
    const perPage = Number(data?.meta?.per_page) || 100;
    return {
      items: (data?.items ?? []).map((item: any) => ({
        id: String(item?.id ?? ""),
        name: cleanText(item?.text),
      })),
      totalCount,
      nextCursor: page * perPage < totalCount ? String(page + 1) : null,
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
        url: String(data.board.public_url ?? ""),
      };
      log(`greenhouse getJobBoard board=${token(board)} jobs=${result.totalJobs}`);
      return result;
    },
  });

  action("listJobs", {
    async invoke(args) {
      const data = await loadBoard(args);
      const result = jobPage(data);
      log(`greenhouse listJobs board=${token(args.board)} items=${result.items.length} next=${result.nextCursor !== null}`);
      return result;
    },
  });

  action("searchJobs", {
    async invoke(args) {
      const data = await loadBoard(args);
      const result = jobPage(data);
      log(`greenhouse searchJobs board=${token(args.board)} items=${result.items.length} next=${result.nextCursor !== null}`);
      return result;
    },
  });

  action("getJob", {
    async invoke({ board, id }) {
      const boardName = token(board);
      const normalizedId = jobId(id);
      const document = await fetchDocument(
        `https://job-boards.greenhouse.io/${encodeURIComponent(boardName)}/jobs/${encodeURIComponent(normalizedId)}`,
      );
      const data = loaderData(document)["routes/$url_token_.jobs_.$job_post_id"];
      const post = data?.jobPost;
      if (!post) throw new Error(`Greenhouse job '${normalizedId}' was not found`);
      const applicationDeadline = cleanText(post.application_deadline);
      const result = {
        id: String(data.jobPostId ?? normalizedId),
        title: cleanText(post.title),
        company: cleanText(post.company_name),
        location: cleanText(post.job_post_location),
        description: [post.introduction, post.content, post.conclusion].map(htmlText).filter(Boolean).join("\n\n"),
        payRanges: (post.pay_ranges ?? []).map((range: any) => ({
          title: cleanText(range.title),
          description: htmlText(range.description),
          minimum: money(range.min),
          maximum: money(range.max),
          currency: cleanText(range.currency_type),
        })),
        publishedAt: cleanText(post.published_at),
        applicationDeadline: applicationDeadline || null,
        language: cleanText(post.language),
        url: String(post.public_url ?? ""),
      };
      log(`greenhouse getJob board=${boardName} id=${normalizedId}`);
      return result;
    },
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
        compliance: (data?.compliance ?? []).map((group: any) => ({
          type: cleanText(group?.type),
          description: questionText(group?.description),
          questions: (group?.questions ?? []).map(question),
        })),
        demographicQuestions: demographic
          ? {
              header: cleanText(demographic.header),
              description: questionText(demographic.description),
              questions: (demographic.questions ?? []).map(question),
            }
          : null,
      };
      log(`greenhouse getJobQuestions board=${boardName} id=${normalizedId} questions=${result.questions.length}`);
      return result;
    },
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
        url: url.href,
      };
      log(`greenhouse getDepartment board=${boardName} id=${normalizedId} jobs=${result.totalJobs}`);
      return result;
    },
  });

  action("getOffice", {
    async invoke({ board, id }) {
      const boardName = token(board);
      const normalizedId = resourceId(id, "office");
      const data = await fetchJson(apiUrl(boardName, `offices/${encodeURIComponent(normalizedId)}`).href);
      const url = new URL(`https://job-boards.greenhouse.io/${encodeURIComponent(boardName)}`);
      url.searchParams.append("offices[]", normalizedId);
      const jobs = new Set(
        (data?.departments ?? []).flatMap((department: any) => department?.jobs ?? []).map((post: any) => String(post?.id ?? "")),
      );
      const result = {
        id: String(data?.id ?? normalizedId),
        name: cleanText(data?.name),
        location: cleanText(data?.location),
        parentId: data?.parent_id == null ? null : String(data.parent_id),
        childIds: (data?.child_ids ?? []).map(String),
        departments: (data?.departments ?? []).map(namedFilter),
        totalJobs: jobs.size,
        url: url.href,
      };
      log(`greenhouse getOffice board=${boardName} id=${normalizedId} jobs=${result.totalJobs}`);
      return result;
    },
  });

  action("listSections", {
    async invoke({ board }) {
      const boardName = token(board);
      const data = await fetchJson(apiUrl(boardName, "sections").href);
      const result = {
        items: (data?.sections ?? []).map(section),
        nextCursor: null,
      };
      log(`greenhouse listSections board=${boardName} sections=${result.items.length}`);
      return result;
    },
  });

  action("getSection", {
    async invoke({ board, id }) {
      const boardName = token(board);
      const normalizedId = resourceId(id, "section");
      const result = section(await fetchJson(apiUrl(boardName, `sections/${encodeURIComponent(normalizedId)}`).href));
      log(`greenhouse getSection board=${boardName} id=${normalizedId} posts=${result.posts.length}`);
      return result;
    },
  });

  for (const [actionId, kind] of [
    ["listDegrees", "degrees"],
    ["listDisciplines", "disciplines"],
    ["listSchools", "schools"],
  ] as const) {
    action(actionId, {
      async invoke(args) {
        const result = await educationPage(kind, args);
        log(`greenhouse ${actionId} board=${token(args.board)} items=${result.items.length} next=${result.nextCursor !== null}`);
        return result;
      },
    });
  }
};

export default install;
