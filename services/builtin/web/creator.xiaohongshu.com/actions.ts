import type { ActionInstaller } from "@openox/service-sdk/action";

type CaptureWindow = Window & {
  oxFetchCapture?: (
    pattern: RegExp,
    options?: { timeoutMs?: number; replayLatest?: boolean },
  ) => Promise<any>;
};

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const ORIGIN = "https://creator.xiaohongshu.com";
  const PUBLIC_ORIGIN = "https://www.xiaohongshu.com";

  const number = (value: any) => {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  };

  const markPageUsed = () => {
    const url = new URL(location.href);
    url.searchParams.set("_ox_used", String(Date.now()));
    history.replaceState({}, "", url);
  };

  const captureData = async (
    pattern: RegExp,
    label: string,
    replayLatest: boolean,
  ) => {
    const capture = (window as CaptureWindow).oxFetchCapture;
    if (!capture) throw new Error("response capture is unavailable");
    log(`capture start endpoint=${label} replay=${replayLatest}`);
    const response = await capture(pattern, { timeoutMs: 12000, replayLatest });
    if (!response || response.success !== true || number(response.code) !== 0) {
      throw new Error(
        `${label}: ${response?.msg || response?.result || "request failed"}`,
      );
    }
    if (!response.data || typeof response.data !== "object") {
      throw new Error(`${label}: missing response data`);
    }
    log(`capture success endpoint=${label}`);
    return response.data;
  };

  const waitFor = async <T>(
    read: () => T | null | undefined,
    timeoutMs = 8000,
  ): Promise<T> => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const value = read();
      if (value) return value;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error("page state timed out");
  };

  const nextPageButton = () =>
    document.querySelector(
      ".el-pagination button.btn-next:not([disabled]), .el-pagination .btn-next:not(.is-disabled)",
    ) as HTMLElement | null;

  const analyticsPeriod = (period: any) => ({
    startTime: number(period?.begin_time),
    endTime: number(period?.end_time),
    summary: String(period?.summary ?? ""),
    publishedNotes: number(period?.publish_note_num),
    publishedImageNotes: number(period?.publish_normal_note_num),
    publishedVideoNotes: number(period?.publish_video_note_num),
    impressions: number(period?.impl_count),
    views: number(period?.view_count),
    profileViews: number(period?.home_view_count),
    likes: number(period?.like_count),
    collects: number(period?.collect_count),
    comments: number(period?.comment_count),
    shares: number(period?.share_count),
    followersGained: number(period?.rise_fans_count),
    followersLost: number(period?.loss_fans_count),
    netFollowersGained: number(period?.net_rise_fans_count),
  });

  const noteUrl = (note: any) => {
    const id = String(note?.id ?? "");
    if (!id) return "";
    const params = new URLSearchParams();
    if (note?.xsec_token) params.set("xsec_token", String(note.xsec_token));
    if (note?.xsec_source) params.set("xsec_source", String(note.xsec_source));
    const query = params.toString();
    return `${PUBLIC_ORIGIN}/explore/${encodeURIComponent(id)}${query ? `?${query}` : ""}`;
  };

  const creatorNote = (note: any) => {
    const images = Array.isArray(note?.images_list)
      ? note.images_list
          .map((image: any) => String(image?.url ?? ""))
          .filter(Boolean)
      : [];
    return {
      id: String(note?.id ?? ""),
      title: String(note?.display_title ?? ""),
      type: String(note?.type ?? ""),
      publishedAt: String(note?.time ?? ""),
      visibleTime: number(note?.visible_time),
      scheduledTime: number(note?.schedule_post_time),
      permissionCode: number(note?.permission_code),
      permissionMessage: String(note?.permission_msg ?? ""),
      tabStatus: number(note?.tab_status),
      sticky: Boolean(note?.sticky),
      cocreated: Boolean(note?.cocreate),
      views: number(note?.view_count),
      likes: number(note?.likes),
      collects: number(note?.collected_count),
      comments: number(note?.comments_count),
      shares: number(note?.shared_count),
      cover: images[0] ?? "",
      images,
      url: noteUrl(note),
    };
  };

  const optionalMetric = (value: any) => {
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
  };

  const visible = (element: Element) => {
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return (
      rect.width > 0 &&
      rect.height > 0 &&
      style.display !== "none" &&
      style.visibility !== "hidden"
    );
  };

  const noteCard = async (id: string) =>
    waitFor(
      () =>
        Array.from(document.querySelectorAll(".note-card")).find((card) =>
          String(card.getAttribute("data-impression") ?? "").includes(id),
        ) as HTMLElement | undefined,
    );

  const dialog = async (text: RegExp) =>
    waitFor(
      () =>
        Array.from(
          document.querySelectorAll("[role='dialog'], .d-modal, .el-dialog"),
        )
          .filter(visible)
          .find((element) => text.test(element.textContent ?? "")) as
          HTMLElement | undefined,
    );

  const confirmDialog = (container: HTMLElement) => {
    const button = Array.from(container.querySelectorAll("button"))
      .filter(visible)
      .find((candidate) =>
        /^(确定|确认)$/.test(candidate.textContent?.trim() ?? ""),
      );
    if (!(button instanceof HTMLElement))
      throw new Error("confirmation control unavailable");
    button.click();
  };

  const captureMutation = async (pattern: RegExp, label: string) => {
    const capture = (window as CaptureWindow).oxFetchCapture;
    if (!capture) throw new Error("response capture is unavailable");
    log(`mutation capture start endpoint=${label}`);
    const response = await capture(pattern, {
      timeoutMs: 12000,
      replayLatest: false,
    });
    const success =
      response?.success === true ||
      (response && "code" in response && number(response.code) === 0) ||
      response?.result?.success === true;
    if (!response || !success) {
      throw new Error(
        `${label}: ${response?.msg || response?.result?.message || "request failed"}`,
      );
    }
    log(`mutation success endpoint=${label}`);
    return response;
  };

  const readStore = (database: IDBDatabase, name: string) =>
    new Promise<any[]>((resolve, reject) => {
      if (!database.objectStoreNames.contains(name)) return resolve([]);
      const request = database
        .transaction(name, "readonly")
        .objectStore(name)
        .getAll();
      request.onsuccess = () =>
        resolve(Array.isArray(request.result) ? request.result : []);
      request.onerror = () =>
        reject(request.error ?? new Error(`failed to read ${name}`));
    });

  const currentUserId = () =>
    String(
      (document.querySelector("#app") as any)?.__vue_app__?.config
        ?.globalProperties?.$store?.state?.Auth?.userInfo?.userId ??
        (window as any).publish?.getUserState?.()?.userInfo?.value?.id ??
        "",
    );

  const draftTitle = (content: any) =>
    String(
      content?.articleTitle ??
        content?.draftStore?.title ??
        content?.title ??
        "",
    );

  const draftDescription = (content: any) =>
    String(
      content?.shortTextContent ??
        content?.draftStore?.desc ??
        content?.description ??
        content?.desc ??
        "",
    );

  const draftCover = (content: any) => {
    const cover =
      content?.draftStore?.coverUrl ??
      content?.draftStore?.cover ??
      content?.coverUrl ??
      "";
    return typeof cover === "string"
      ? cover
      : String(cover?.url ?? cover?.src ?? "");
  };

  const paginationNumber = (element: Element) =>
    element.querySelector(".d-pagination-page-content")?.textContent?.trim() ??
    "";

  action("getSignInUrl", {
    async invoke() {
      return { url: `${ORIGIN}/login` };
    },
  });

  action("getSignInState", {
    async invoke() {
      const response = await retryFetch(
        `${ORIGIN}/api/galaxy/creator/home/personal_info`,
        {
          credentials: "include",
          headers: { accept: "application/json" },
        },
      );
      if (response.status === 401 || response.status === 403) {
        log(`getSignInState status=${response.status} signedIn=false`);
        return { signedIn: false };
      }
      if (!response.ok) {
        throw new Error(`getSignInState HTTP ${response.status}`);
      }
      const contentType = response.headers.get("content-type") ?? "";
      if (!contentType.includes("json")) {
        throw new Error("getSignInState non-JSON response");
      }
      const value = await response.json();
      const signedIn =
        value?.success === true &&
        number(value?.code) === 0 &&
        value?.data !== null &&
        typeof value?.data === "object";
      log(`getSignInState status=${response.status} signedIn=${signedIn}`);
      return { signedIn };
    },
  });

  action("getCreatorProfile", {
    async invoke() {
      const data = await captureData(
        /\/api\/galaxy\/creator\/home\/personal_info(?:\?|$)/,
        "creator profile",
        true,
      );
      markPageUsed();
      return {
        name: String(data.name ?? ""),
        avatar: String(data.avatar ?? ""),
        redId: String(data.red_num ?? ""),
        bio: String(data.personal_desc ?? ""),
        followingCount: number(data.follow_count),
        followerCount: number(data.fans_count),
        receivedLikesAndCollects: number(data.faved_count),
        growthLevel: number(data.grow_info?.level),
        growthLevelMinimumFollowers: number(data.grow_info?.min_fans_count),
        growthLevelMaximumFollowers: number(data.grow_info?.max_fans_count),
        liveStatus: number(data.live_info?.live_status),
      };
    },
  });

  action("getCreatorAnalytics", {
    async invoke() {
      const data = await captureData(
        /\/api\/galaxy\/v2\/creator\/datacenter\/account\/base(?:\?|$)/,
        "creator analytics",
        true,
      );
      markPageUsed();
      return {
        sevenDays: analyticsPeriod(data.seven),
        thirtyDays: analyticsPeriod(data.thirty),
      };
    },
  });

  action("listCreatorNotes", {
    async invoke({ cursor }: { cursor?: string } = {}) {
      const page = cursor === undefined ? 0 : Number(cursor);
      if (!Number.isInteger(page) || page < 0)
        throw new Error(`invalid notes cursor: ${cursor}`);
      let data = await captureData(
        /\/api\/galaxy\/v2\/creator\/note\/user\/posted(?:\?|$)/,
        "creator notes",
        true,
      );
      for (let index = 0; index < page; index++) {
        const button = await waitFor(nextPageButton);
        const pending = captureData(
          /\/api\/galaxy\/v2\/creator\/note\/user\/posted(?:\?|$)/,
          "creator notes",
          false,
        );
        button.click();
        data = await pending;
      }
      markPageUsed();
      const items = Array.isArray(data.notes)
        ? data.notes.map(creatorNote)
        : [];
      const nextPage = Number(data.page);
      return {
        items,
        nextCursor:
          Number.isInteger(nextPage) && nextPage >= 0 ? String(nextPage) : null,
      };
    },
  });

  action("listCreatorActivities", {
    async invoke() {
      const data = await captureData(
        /\/api\/galaxy\/v2\/creator\/activity_center\/list(?:\?|$)/,
        "creator activities",
        true,
      );
      markPageUsed();
      return {
        items: (Array.isArray(data.activity_list)
          ? data.activity_list
          : []
        ).map((item: any) => ({
          id: String(item.activity_id ?? item.instance_id ?? ""),
          name: String(item.activity_name ?? ""),
          image: String(item.picture_link ?? ""),
          url: String(item.activity_link ?? ""),
          publishUrl: String(item.pc_post_link ?? ""),
          startTime: number(item.start_time),
          endTime: number(item.end_time),
          status: number(item.activity_status),
          reward: String(item.activity_reward ?? ""),
          followed: Boolean(item.focus_status),
          topics: (Array.isArray(item.topic_infos) ? item.topic_infos : []).map(
            (topic: any) => ({
              id: String(topic.id ?? ""),
              name: String(topic.name ?? ""),
              url: String(topic.link ?? ""),
            }),
          ),
        })),
        followedCount: number(data.focus_total),
      };
    },
  });

  action("listCreatorInspiration", {
    async invoke() {
      const data = await captureData(
        /\/api\/galaxy\/creator\/select\/topic\/detail(?:\?|$)/,
        "creator inspiration",
        true,
      );
      markPageUsed();
      return {
        groups: (Array.isArray(data) ? data : []).map((group: any) => ({
          id: String(group.labelId ?? ""),
          name: String(group.labelName ?? ""),
          topics: (Array.isArray(group.selectTopics)
            ? group.selectTopics
            : []
          ).map((topic: any) => ({
            id: String(topic.id ?? ""),
            title: String(topic.title ?? ""),
            url: String(topic.link ?? ""),
            participantCount: number(topic.joinNum),
            viewCount: number(topic.viewNum),
            exampleNotes: (Array.isArray(topic.notes) ? topic.notes : []).map(
              (note: any) => ({
                id: String(note.noteId ?? ""),
                title: String(note.title ?? ""),
                type: String(note.type ?? ""),
                likes: number(note.likes),
                images: (Array.isArray(note.images_list)
                  ? note.images_list
                  : []
                )
                  .map((image: any) => String(image?.url ?? image ?? ""))
                  .filter(Boolean),
              }),
            ),
          })),
        })),
      };
    },
  });

  action("listCreationGuidance", {
    async invoke({
      category = "official",
      cursor,
    }: { category?: string; cursor?: string } = {}) {
      const categories: Record<string, { type: number; label: string }> = {
        official: { type: 1, label: "官方课程" },
        beginner: { type: 2, label: "新手入门" },
        account: { type: 3, label: "账号运营" },
        content: { type: 4, label: "内容创作" },
        monetization: { type: 5, label: "变现指南" },
      };
      const selected = categories[category];
      if (!selected) throw new Error(`invalid guidance category: ${category}`);
      const page = cursor === undefined ? 1 : Number(cursor);
      if (!Number.isInteger(page) || page < 1)
        throw new Error(`invalid guidance cursor: ${cursor}`);
      const pattern = /\/api\/galaxy\/creator\/data\/create_guidance(?:\?|$)/;
      let data;
      const panels = await waitFor(() => {
        const items = Array.from(document.querySelectorAll("section.panel"));
        return items.length >= 2 &&
          items.every((item) => item.querySelector(".card"))
          ? items
          : null;
      });
      const panel = panels[selected.type === 1 ? 0 : 1];
      if (!(panel instanceof HTMLElement))
        throw new Error("creation guidance panel unavailable");
      const categoryButton = Array.from(
        panel.querySelectorAll(".button-group-item"),
      ).find((element) => element.textContent?.trim() === selected.label) as
        HTMLElement | undefined;
      if (
        selected.type !== 1 &&
        categoryButton &&
        !categoryButton.classList.contains("active")
      ) {
        const pending = captureData(pattern, "creation guidance", false);
        categoryButton.click();
        data = await pending;
      } else if (selected.type === 1 && page === 1) {
        const secondPage = Array.from(
          panel.querySelectorAll(".d-pagination-page"),
        ).find((element) => paginationNumber(element) === "2") as
          HTMLElement | undefined;
        if (!secondPage)
          throw new Error("official guidance pagination unavailable");
        const next = captureData(pattern, "creation guidance", false);
        secondPage.click();
        await next;
        const firstPage = await waitFor(
          () =>
            Array.from(panel.querySelectorAll(".d-pagination-page")).find(
              (element) => paginationNumber(element) === "1",
            ) as HTMLElement | undefined,
        );
        const pending = captureData(pattern, "creation guidance", false);
        firstPage.click();
        data = await pending;
      } else {
        data = await captureData(pattern, "creation guidance", true);
      }
      if (page > 1) {
        const pageButton = await waitFor(
          () =>
            Array.from(panel.querySelectorAll(".d-pagination-page")).find(
              (element) => paginationNumber(element) === String(page),
            ) as HTMLElement | undefined,
        );
        if (!pageButton.classList.contains("--color-bg-primary-light")) {
          const pending = captureData(pattern, "creation guidance", false);
          pageButton.click();
          data = await pending;
        }
      }
      markPageUsed();
      const total = number(data.total);
      return {
        items: (Array.isArray(data.create_guidance)
          ? data.create_guidance
          : []
        ).map((item: any) => ({
          noteId: String(item.note_id ?? ""),
          title: String(item.title ?? ""),
          image: String(item.image ?? ""),
          url: String(item.link ?? ""),
          authorId: String(item.user_id ?? ""),
          authorName: String(item.nickname ?? ""),
          authorAvatar: String(item.avatar ?? ""),
          viewCount: number(item.view_count),
          viewCountText: String(item.display_count_text ?? ""),
        })),
        nextCursor: page * 6 < total ? String(page + 1) : null,
      };
    },
  });

  action("listCreatorNotices", {
    async invoke() {
      const data = await captureData(
        /\/api\/galaxy\/v2\/creator\/notice(?:\?|$)/,
        "creator notices",
        true,
      );
      markPageUsed();
      return {
        items: (Array.isArray(data.notice_list) ? data.notice_list : []).map(
          (item: any) => ({
            title: String(item.title ?? ""),
            url: String(item.link ?? ""),
            image: String(item.img ?? ""),
            type: number(item.type),
            position: number(item.position),
            backgroundColor: String(item.bg_color ?? ""),
          }),
        ),
      };
    },
  });

  action("getLiveAnalytics", {
    async invoke() {
      const data = await captureData(
        /\/api\/galaxy\/v2\/creator\/datacenter\/livedata\/overview(?:\?|$)/,
        "live analytics",
        true,
      );
      const overview = data.live_overview_data ?? {};
      markPageUsed();
      return {
        date: String(overview.dtm ?? ""),
        validLiveCount: number(overview.valid_live_num),
        liveDuration: number(overview.duration_of_live),
        averageViewers: number(overview.average_num_of_viewers),
        averageInteractions: number(overview.average_num_of_interactive),
        newFollowers: number(overview.num_of_new_fans),
        potatoDiamonds: number(overview.num_of_potato_diamonds),
        sellerIncome: number(overview.seller_real_income_amount),
        packageDeals: number(overview.deal_pkg_cnt),
      };
    },
  });

  action("getNoteAnalytics", {
    async invoke({ noteId }: { noteId: string }) {
      if (!noteId?.trim()) throw new Error("noteId is required");
      const [base, trend] = await Promise.all([
        captureData(
          /\/api\/galaxy\/creator\/datacenter\/note\/base(?:\?|$)/,
          "note analytics",
          true,
        ),
        captureData(
          /\/api\/galaxy\/creator\/datacenter\/note\/analyze\/audience\/trend(?:\?|$)/,
          "note audience trend",
          true,
        ),
      ]);
      if (String(base.note_info?.id ?? "") !== noteId)
        throw new Error("note analytics did not match noteId");
      const note = base.note_info ?? {};
      markPageUsed();
      return {
        note: {
          id: String(note.id ?? ""),
          title: String(note.desc ?? ""),
          type: String(note.type ?? ""),
          cover: String(note.cover_url ?? ""),
          publishedAt: number(note.post_time),
          updatedAt: number(note.update_time),
          auditStatus: number(note.audit_status),
          tags: (Array.isArray(note.tags) ? note.tags : []).map((tag: any) => ({
            id: String(tag.id ?? ""),
            name: String(tag.name ?? ""),
            type: String(tag.type ?? ""),
          })),
        },
        impressions: optionalMetric(base.impl_count),
        views: optionalMetric(base.view_count),
        likes: optionalMetric(base.like_count),
        collects: optionalMetric(base.collect_count),
        comments: optionalMetric(base.comment_count),
        shares: optionalMetric(base.share_count),
        followersGained: optionalMetric(base.rise_fans_count),
        averageViewTime: optionalMetric(base.view_time_avg),
        coverClickRate: optionalMetric(base.cover_click_rate),
        fiveSecondCompletionRate: optionalMetric(base.finish5s_rate),
        fullViewRate: optionalMetric(base.full_view_rate),
        twoSecondExitRate: optionalMetric(base.exit_view2s_rate),
        audienceAvailable: trend.no_data !== true,
        audienceMessage: String(trend.no_data_tip_msg ?? ""),
        images: (Array.isArray(trend.images_list) ? trend.images_list : [])
          .map((image: any) => String(image?.url ?? ""))
          .filter(Boolean),
        videoUrl: String(trend.video?.video_url ?? ""),
      };
    },
  });

  action("listCreatorDrafts", {
    async invoke() {
      const userId = await waitFor(() => currentUserId() || null);
      const databases =
        typeof indexedDB.databases === "function"
          ? await indexedDB.databases()
          : [];
      if (
        databases.length &&
        !databases.some((database) => database.name === "draft-database-v1")
      ) {
        return { items: [] };
      }
      const database = await new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open("draft-database-v1");
        request.onsuccess = () => resolve(request.result);
        request.onerror = () =>
          reject(request.error ?? new Error("draft database unavailable"));
      });
      const stores = [
        "video-draft",
        "image-draft",
        "article-draft",
        "audio-draft",
      ];
      const records = await Promise.all(
        stores.map(async (store) => ({
          store,
          items: await readStore(database, store),
        })),
      );
      database.close();
      const items = records
        .flatMap(({ store, items: values }) =>
          values
            .filter((record) => String(record?.uid ?? "") === userId)
            .map((record) => ({
              id: String(record.draftId ?? ""),
              type: store.replace("-draft", ""),
              updatedAt: number(record.timeStamp),
              title: draftTitle(record.content),
              description: draftDescription(record.content),
              cover: draftCover(record.content),
            })),
        )
        .sort((left, right) => right.updatedAt - left.updatedAt);
      markPageUsed();
      return { items };
    },
  });

  action("updateNoteVisibility", {
    async invoke({
      noteId,
      visibility,
    }: {
      noteId: string;
      visibility: string;
    }) {
      const labels: Record<string, string> = {
        public: "公开可见",
        private: "仅自己可见",
        friends: "仅互关好友可见",
      };
      const label = labels[visibility];
      if (!noteId?.trim()) throw new Error("noteId is required");
      if (!label) throw new Error(`invalid visibility: ${visibility}`);
      const card = await noteCard(noteId);
      const button = card.querySelectorAll<HTMLElement>(
        ".note-card__action-btn",
      )[0];
      if (!button) throw new Error("note visibility control unavailable");
      button.click();
      const modal = await dialog(/可见|公开|私密/);
      const select = modal.querySelector<HTMLElement>(".d-select");
      if (!select) throw new Error("visibility menu unavailable");
      select.click();
      const option = await waitFor(
        () =>
          Array.from(document.querySelectorAll(".d-popover .custom-option"))
            .filter(visible)
            .find((element) => element.textContent?.trim() === label) as
            HTMLElement | undefined,
      );
      if (!(option instanceof HTMLElement))
        throw new Error(`visibility option unavailable: ${label}`);
      option.click();
      const pending = captureMutation(
        /\/web_api\/sns\/v1\/note\/privacy(?:\?|$)/,
        "note visibility",
      );
      confirmDialog(modal);
      await pending;
      markPageUsed();
      return { noteId, visibility };
    },
  });

  action("updatePinnedNote", {
    async invoke({ noteId, pinned }: { noteId: string; pinned: boolean }) {
      if (!noteId?.trim()) throw new Error("noteId is required");
      const card = await noteCard(noteId);
      const currentlyPinned = card.getAttribute("show-top") === "true";
      if (currentlyPinned === pinned) return { noteId, pinned };
      const button = card.querySelectorAll<HTMLElement>(
        ".note-card__action-btn",
      )[1];
      if (!button) throw new Error("note pin control unavailable");
      button.click();
      const modal = await dialog(/置顶|取消置顶/);
      const pending = captureMutation(
        /\/api\/galaxy\/creator\/sns\/note\/top(?:\?|$)/,
        "note pin",
      );
      confirmDialog(modal);
      await pending;
      markPageUsed();
      return { noteId, pinned };
    },
  });

  action("deleteCreatorNote", {
    async invoke({ noteId }: { noteId: string }) {
      if (!noteId?.trim()) throw new Error("noteId is required");
      const card = await noteCard(noteId);
      const button = card.querySelector<HTMLElement>(
        ".note-card__action-btn--del",
      );
      if (!button) throw new Error("note delete control unavailable");
      button.click();
      const modal = await dialog(/删除后|删除笔记|无法恢复/);
      const pending = captureMutation(
        /\/web_api\/sns\/capa\/postgw\/note\/delete(?:\?|$)/,
        "note deletion",
      );
      confirmDialog(modal);
      await pending;
      markPageUsed();
      return { noteId, deleted: true };
    },
  });
};

export default install;
