function createEmbeddedAutomation({ timeout = 5000 } = {}) {
  const normalize = value => String(value ?? "").replace(/\s+/g, " ").trim();
  const matches = (actual, expected, exact = false) => exact
    ? normalize(actual) === normalize(expected)
    : normalize(actual).toLowerCase().includes(normalize(expected).toLowerCase());
  const visible = element => {
    if (!element.isConnected || element.closest('[hidden], [inert], [aria-hidden="true"]')) return false;
    for (let node = element; node?.nodeType === 1; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
    }
    return element.getClientRects().length > 0;
  };
  const disabled = element => element.matches(":disabled") || !!element.closest('[aria-disabled="true"], [inert]');
  const label = element => {
    const ids = element.getAttribute("aria-labelledby");
    if (ids) {
      const text = normalize(ids.split(/\s+/).map(id => element.ownerDocument.getElementById(id)?.textContent ?? "").join(" "));
      if (text) return text;
    }
    if (element.hasAttribute("aria-label")) return normalize(element.getAttribute("aria-label"));
    if (element.labels?.length) return normalize(Array.from(element.labels, item => item.textContent).join(" "));
    if (element.tagName === "IMG") return normalize(element.getAttribute("alt"));
    if (element.tagName === "INPUT" && ["submit", "reset", "button"].includes(element.type)) return normalize(element.value);
    return normalize(element.getAttribute("title") || (["INPUT", "TEXTAREA", "SELECT"].includes(element.tagName) ? "" : element.textContent));
  };
  const role = element => {
    const explicit = element.getAttribute("role")?.trim().split(/\s+/)[0];
    if (explicit) return explicit;
    const tag = element.tagName;
    if (tag === "INPUT") {
      const type = element.type;
      if (["button", "submit", "reset", "image"].includes(type)) return "button";
      if (["checkbox", "radio"].includes(type)) return type;
      if (type === "range") return "slider";
      if (type === "number") return "spinbutton";
      if (type === "search") return "searchbox";
      if (["text", "email", "tel", "url"].includes(type)) return "textbox";
      return "";
    }
    if (tag === "A") return element.hasAttribute("href") ? "link" : "";
    if (tag === "SELECT") return element.multiple || element.size > 1 ? "listbox" : "combobox";
    if (/^H[1-6]$/.test(tag)) return "heading";
    return ({ BUTTON: "button", TEXTAREA: "textbox", OPTION: "option", IMG: "img", UL: "list", OL: "list", LI: "listitem", TABLE: "table", TR: "row", TD: "cell", TH: "columnheader", DIALOG: "dialog", MAIN: "main", NAV: "navigation" })[tag] ?? "";
  };
  const duration = value => {
    const ms = value ?? timeout;
    if (!Number.isFinite(ms) || ms < 0 || ms > 30000) throw new Error("Automation timeout must be between 0 and 30000 ms");
    return ms;
  };
  duration(timeout);
  const pause = () => new Promise(resolve => setTimeout(resolve, 25));
  const locator = (resolve, description) => {
    const unique = () => {
      const elements = resolve();
      if (elements.length > 1) throw new Error(`Strict locator matched ${elements.length} elements: ${description}`);
      return elements[0];
    };
    const wait = async (predicate, options = {}) => {
      const deadline = Date.now() + duration(options.timeout);
      for (;;) {
        const element = unique();
        if (predicate(element)) return element;
        if (Date.now() >= deadline) throw new Error(`Locator condition timed out: ${description}`);
        await pause();
      }
    };
    const actionable = options => wait(element => element && visible(element) && !disabled(element), options);
    const clickElement = element => {
      element.scrollIntoView({ block: "center", inline: "center" });
      const rect = element.getBoundingClientRect();
      const hit = element.ownerDocument.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
      if (!hit || hit !== element && !element.contains(hit)) throw new Error(`Locator is obscured: ${description}`);
      if (!element.isConnected || disabled(element)) throw new Error(`Locator became unavailable: ${description}`);
      element.click();
    };
    const api = {
      ...queries(() => resolve()),
      filter({ hasText }) {
        if (typeof hasText !== "string") throw new Error("filter requires a string hasText");
        return locator(() => resolve().filter(element => matches(element.textContent, hasText)), `${description}.filter`);
      },
      nth(index) {
        if (!Number.isSafeInteger(index) || index < 0) throw new Error("nth requires a nonnegative integer");
        return locator(() => resolve().slice(index, index + 1), `${description}.nth(${index})`);
      },
      first() { return api.nth(0); },
      last() { return locator(() => resolve().slice(-1), `${description}.last()`); },
      async count() { return resolve().length; },
      async isVisible() { const element = unique(); return !!element && visible(element); },
      async waitFor({ state = "visible", ...options } = {}) {
        if (!["attached", "detached", "visible", "hidden"].includes(state)) throw new Error("Unsupported locator state");
        await wait(element => state === "attached" ? !!element : state === "detached" ? !element : state === "visible" ? !!element && visible(element) : !element || !visible(element), options);
      },
      async innerText(options) { return (await wait(element => !!element, options)).innerText; },
      async textContent(options) { return (await wait(element => !!element, options)).textContent; },
      async getAttribute(name, options) { return (await wait(element => !!element, options)).getAttribute(name); },
      async allTextContents() { return resolve().map(element => element.textContent ?? ""); },
      async click(options) { clickElement(await actionable(options)); },
      async fill(value, options) {
        if (typeof value !== "string") throw new Error("fill requires a string");
        const element = await actionable(options);
        if (element.readOnly) throw new Error(`Locator is read-only: ${description}`);
        if (element.tagName === "INPUT" && !["text", "email", "password", "search", "tel", "url", "number"].includes(element.type)) throw new Error("Unsupported input type for fill");
        const view = element.ownerDocument.defaultView;
        const prototype = element.tagName === "INPUT" ? view.HTMLInputElement.prototype : element.tagName === "TEXTAREA" ? view.HTMLTextAreaElement.prototype : null;
        element.focus();
        if (prototype) Object.getOwnPropertyDescriptor(prototype, "value").set.call(element, value);
        else if (element.isContentEditable) element.textContent = value;
        else throw new Error("fill requires an input, textarea, or contenteditable element");
        element.dispatchEvent(new view.Event("input", { bubbles: true }));
        element.dispatchEvent(new view.Event("change", { bubbles: true }));
      },
      async check(options) { await api.setChecked(true, options); },
      async uncheck(options) { await api.setChecked(false, options); },
      async setChecked(checked, options) {
        if (typeof checked !== "boolean") throw new Error("setChecked requires a boolean");
        const element = await actionable(options);
        if (element.tagName !== "INPUT" || !["checkbox", "radio"].includes(element.type)) throw new Error("setChecked requires a checkbox or radio input");
        if (element.checked === checked) return;
        clickElement(element);
        if (element.checked !== checked) throw new Error("Checked state unverified after dispatch; inspect before retrying");
      },
      async selectOption(value, options) {
        const values = Array.isArray(value) ? value : [value];
        if (values.some(item => typeof item !== "string")) throw new Error("selectOption accepts string values only");
        const element = await actionable(options);
        if (element.tagName !== "SELECT" || !element.multiple && values.length !== 1) throw new Error("Invalid selectOption target or values");
        const selected = Array.from(element.options).filter(option => values.includes(option.value));
        if (values.some(value => !selected.some(option => option.value === value)) || selected.some(option => option.disabled || option.parentElement?.disabled)) throw new Error("Select option is missing or disabled");
        for (const option of element.options) option.selected = values.includes(option.value);
        const view = element.ownerDocument.defaultView;
        element.dispatchEvent(new view.Event("input", { bubbles: true }));
        element.dispatchEvent(new view.Event("change", { bubbles: true }));
        return selected.map(option => option.value);
      },
    };
    return api;
  };
  function queries(roots) {
    const find = predicate => [...new Set(roots().flatMap(root => Array.from(root.querySelectorAll("*"))))].filter(predicate);
    return {
      locator(selector) { return locator(() => [...new Set(roots().flatMap(root => Array.from(root.querySelectorAll(selector))))], "css locator"); },
      getByRole(expected, { name, exact = false, includeHidden = false } = {}) {
        return locator(() => find(element => role(element) === expected && (includeHidden || visible(element)) && (name === undefined || matches(label(element), name, exact))), `role=${expected}`);
      },
      getByLabel(text, { exact = false } = {}) {
        return locator(() => find(element => element.matches("input, textarea, select, button, [contenteditable], [aria-label], [aria-labelledby]") && matches(label(element), text, exact)), "label locator");
      },
      getByText(text, { exact = false } = {}) {
        return locator(() => find(element => !element.matches("script, style, head, title") && matches(element.textContent, text, exact)
          && !Array.from(element.children).some(child => matches(child.textContent, text, exact))), "text locator");
      },
      getByPlaceholder(text, { exact = false } = {}) {
        return locator(() => find(element => element.hasAttribute("placeholder") && matches(element.getAttribute("placeholder"), text, exact)), "placeholder locator");
      },
      getByTestId(value) { return locator(() => find(element => element.getAttribute("data-testid") === value), "test id locator"); },
    };
  }
  return queries(() => [document]);
}

const retryFetch = async (input, init, options) => {
  const retries = options?.retries ?? 3;
  const delay = options?.delay ?? 400;
  const factor = options?.factor ?? 2;
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await window.fetch(input, init);
      const retryable = response.status === 408 || response.status === 429
        || (response.status >= 500 && response.status <= 599);
      if (response.ok || !retryable || attempt >= retries) return response;
      console.log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}`);
    } catch (error) {
      const message = String(error?.message ?? "");
      const retryable = message.includes("Load failed")
        || message.includes("NetworkError")
        || message.includes("Failed to fetch");
      if (!retryable || attempt >= retries) throw error;
      console.log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}`);
    }
    await new Promise(resolve => setTimeout(resolve, delay * Math.pow(factor, attempt)));
  }
};

const operationBaselines = {
    "CometGroupDiscussionRootSuccessQuery": {
        "docId": "37236348126012704",
        "variables": {
            "autoOpenChat": false,
            "creative_provider_id": null,
            "feedbackSource": 0,
            "feedLocation": "GROUP",
            "feedType": "DISCUSSION",
            "filter_topic_id": null,
            "focusCommentID": null,
            "groupID": "",
            "hasHoistStories": false,
            "hoistedSectionHeaderType": "notifications",
            "hoistStories": [],
            "hoistStoriesCount": 0,
            "privacySelectorRenderLocation": "COMET_STREAM",
            "regular_stories_count": 1,
            "regular_stories_stream_initial_count": 1,
            "renderLocation": "group",
            "scale": 2,
            "shouldDeferMainFeed": false,
            "sortingSetting": "TOP_POSTS",
            "threadID": "",
            "useDefaultActor": false,
            "__relay_internal__pv__FBReels_enable_view_dubbed_audio_type_gkrelayprovider": true,
            "__relay_internal__pv__GHLShouldChangeAdIdFieldNamerelayprovider": true,
            "__relay_internal__pv__GHLShouldChangeSponsoredDataFieldNamerelayprovider": true,
            "__relay_internal__pv__CometFeedStory_enable_reactor_facepilerelayprovider": false,
            "__relay_internal__pv__CometFeedStory_enable_social_bubblesrelayprovider": false,
            "__relay_internal__pv__CometFeedStory_enable_post_permalink_white_space_clickrelayprovider": false,
            "__relay_internal__pv__CometUFICommentActionLinksRewriteEnabledrelayprovider": true,
            "__relay_internal__pv__CometUFICommentAvatarStickerAnimatedImagerelayprovider": false,
            "__relay_internal__pv__IsWorkUserrelayprovider": false,
            "__relay_internal__pv__TestPilotShouldIncludeDemoAdUseCaserelayprovider": false,
            "__relay_internal__pv__FBReels_deprecate_short_form_video_context_gkrelayprovider": true,
            "__relay_internal__pv__CometFeedShareMedia_shouldPrefetchShareImagerelayprovider": false,
            "__relay_internal__pv__CometImmersivePhotoCanUserDisable3DMotionrelayprovider": false,
            "__relay_internal__pv__WorkCometIsEmployeeGKProviderrelayprovider": false,
            "__relay_internal__pv__IsMergQAPollsrelayprovider": false,
            "__relay_internal__pv__FBReelsMediaFooter_comet_enable_reels_ads_gkrelayprovider": true,
            "__relay_internal__pv__CometUFIReactionsEnableShortNamerelayprovider": false,
            "__relay_internal__pv__CometUFICommentAutoTranslationTyperelayprovider": "AUTO_TRANSLATE",
            "__relay_internal__pv__CometUFIShareActionMigrationrelayprovider": true,
            "__relay_internal__pv__CometUFISingleLineUFIrelayprovider": true,
            "__relay_internal__pv__relay_provider_comet_ufi_ssr_seo_deferrelayprovider": true,
            "__relay_internal__pv__CometUFI_dedicated_comment_routable_dialog_gkrelayprovider": false,
            "__relay_internal__pv__ReelsIFUCard_reelsIFULikeCountrelayprovider": false,
            "__relay_internal__pv__FBReelsIFUTileContent_reelsIFUPlayOnHoverrelayprovider": true,
            "__relay_internal__pv__GroupsCometGYSJFeedItemHeightrelayprovider": 206,
            "__relay_internal__pv__ShouldEnableBakedInTextStoriesrelayprovider": false,
            "__relay_internal__pv__StoriesShouldIncludeFbNotesrelayprovider": true,
            "__relay_internal__pv__GroupsCometGroupChatLazyLoadLastMessageSnippetrelayprovider": false,
            "__relay_internal__pv__groups_comet_use_glvrelayprovider": false
        }
    },
    "GroupsCometFeedRegularStoriesPaginationQuery": {
        "docId": "27705429719151309",
        "variables": {
            "count": 3,
            "cursor": null,
            "feedLocation": "GROUP",
            "feedType": "DISCUSSION",
            "feedbackSource": 0,
            "filterTopicId": null,
            "focusCommentID": null,
            "privacySelectorRenderLocation": "COMET_STREAM",
            "referringStoryRenderLocation": null,
            "renderLocation": "group",
            "scale": 2,
            "sortingSetting": "TOP_POSTS",
            "stream_initial_count": 1,
            "useDefaultActor": false,
            "id": "",
            "__relay_internal__pv__GHLShouldChangeAdIdFieldNamerelayprovider": true,
            "__relay_internal__pv__GHLShouldChangeSponsoredDataFieldNamerelayprovider": true,
            "__relay_internal__pv__CometFeedStory_enable_reactor_facepilerelayprovider": false,
            "__relay_internal__pv__CometFeedStory_enable_social_bubblesrelayprovider": false,
            "__relay_internal__pv__CometFeedStory_enable_post_permalink_white_space_clickrelayprovider": false,
            "__relay_internal__pv__CometUFICommentActionLinksRewriteEnabledrelayprovider": true,
            "__relay_internal__pv__CometUFICommentAvatarStickerAnimatedImagerelayprovider": false,
            "__relay_internal__pv__IsWorkUserrelayprovider": false,
            "__relay_internal__pv__TestPilotShouldIncludeDemoAdUseCaserelayprovider": false,
            "__relay_internal__pv__FBReels_deprecate_short_form_video_context_gkrelayprovider": true,
            "__relay_internal__pv__FBReels_enable_view_dubbed_audio_type_gkrelayprovider": true,
            "__relay_internal__pv__CometFeedShareMedia_shouldPrefetchShareImagerelayprovider": false,
            "__relay_internal__pv__CometImmersivePhotoCanUserDisable3DMotionrelayprovider": false,
            "__relay_internal__pv__WorkCometIsEmployeeGKProviderrelayprovider": false,
            "__relay_internal__pv__IsMergQAPollsrelayprovider": false,
            "__relay_internal__pv__FBReelsMediaFooter_comet_enable_reels_ads_gkrelayprovider": true,
            "__relay_internal__pv__CometUFIReactionsEnableShortNamerelayprovider": false,
            "__relay_internal__pv__CometUFICommentAutoTranslationTyperelayprovider": "AUTO_TRANSLATE",
            "__relay_internal__pv__CometUFIShareActionMigrationrelayprovider": true,
            "__relay_internal__pv__CometUFISingleLineUFIrelayprovider": true,
            "__relay_internal__pv__relay_provider_comet_ufi_ssr_seo_deferrelayprovider": true,
            "__relay_internal__pv__CometUFI_dedicated_comment_routable_dialog_gkrelayprovider": false,
            "__relay_internal__pv__ReelsIFUCard_reelsIFULikeCountrelayprovider": false,
            "__relay_internal__pv__FBReelsIFUTileContent_reelsIFUPlayOnHoverrelayprovider": true,
            "__relay_internal__pv__GroupsCometGYSJFeedItemHeightrelayprovider": 206,
            "__relay_internal__pv__ShouldEnableBakedInTextStoriesrelayprovider": false,
            "__relay_internal__pv__StoriesShouldIncludeFbNotesrelayprovider": true
        }
    },
    "FriendingCometRootContentQuery": {
        "docId": "35433309119618037",
        "variables": {
            "scale": 2
        }
    },
    "FriendingCometPYMKGridPaginationQuery": {
        "docId": "9818261294924549",
        "variables": {
            "count": 20,
            "cursor": null,
            "location": "FRIENDS_HOME_MAIN",
            "scale": 2
        }
    },
    "MarketplaceCometBrowseFeedLightContainerQuery": {
        "docId": "28467847722799340",
        "variables": {
            "buyLocation": {
                "latitude": 0,
                "longitude": 0
            },
            "count": 1,
            "cursor": null,
            "imageWidth": 256,
            "mediaType": "image/jpeg",
            "radius": 65000,
            "scale": 2,
            "sizing": "cover-fill-cropped",
            "useSDFPath": true,
            "__relay_internal__pv__CometMarketplaceShouldShowTopPicksStrikethroughrelayprovider": false,
            "__relay_internal__pv__GHLShouldChangeMarketplaceSponsoredDataFieldNamerelayprovider": true,
            "__relay_internal__pv__MarketplaceCometAdmodulerelayprovider": true,
            "__relay_internal__pv__CometMarketplaceShouldShowFeedShippingIconrelayprovider": false
        }
    },
    "MarketplaceCometBrowseFeedLightPaginationQuery": {
        "docId": "28009763081992897",
        "variables": {
            "buyLocation": {
                "latitude": 0,
                "longitude": 0
            },
            "count": 5,
            "cursor": null,
            "imageWidth": 256,
            "includePDPRelevantListings": false,
            "mediaType": "image/jpeg",
            "pdpListingId": "",
            "radius": 65000,
            "refinement": null,
            "scale": 2,
            "sizing": "cover-fill-cropped",
            "useSDFPath": true,
            "__relay_internal__pv__CometMarketplaceShouldShowTopPicksStrikethroughrelayprovider": false,
            "__relay_internal__pv__GHLShouldChangeMarketplaceSponsoredDataFieldNamerelayprovider": true,
            "__relay_internal__pv__MarketplaceCometAdmodulerelayprovider": true,
            "__relay_internal__pv__CometMarketplaceShouldShowFeedShippingIconrelayprovider": false
        }
    },
    "CometMarketplaceSearchContentContainerQuery": {
        "docId": "27517490627932547",
        "variables": {
            "buyLocation": {
                "latitude": 0,
                "longitude": 0
            },
            "contextual_data": null,
            "count": 24,
            "cursor": null,
            "params": {
                "bqf": {
                    "callsite": "COMMERCE_MKTPLACE_WWW",
                    "query": ""
                },
                "browse_request_params": {
                    "commerce_enable_local_pickup": true,
                    "commerce_enable_shipping": true,
                    "commerce_search_and_rp_available": true,
                    "commerce_search_and_rp_category_id": [],
                    "commerce_search_and_rp_condition": null,
                    "commerce_search_and_rp_ctime_days": null,
                    "filter_location_latitude": 0,
                    "filter_location_longitude": 0,
                    "filter_price_lower_bound": 0,
                    "filter_price_upper_bound": 214748364700,
                    "filter_radius_km": 65,
                    "commerce_search_sort_by": "DISTANCE_ASCEND"
                },
                "custom_request_params": {
                    "browse_context": null,
                    "contextual_filters": [],
                    "referral_code": null,
                    "referral_ui_component": null,
                    "saved_search_strid": null,
                    "search_vertical": "C2C",
                    "seo_url": null,
                    "serp_landing_settings": {
                        "virtual_category_id": ""
                    },
                    "surface": "SEARCH",
                    "virtual_contextual_filters": []
                }
            },
            "savedSearchID": null,
            "savedSearchQuery": "",
            "scale": 2,
            "shouldDeferNonCritical": false,
            "shouldIncludePopularSearches": false,
            "topicPageParams": {
                "location_id": "",
                "url": null
            },
            "__relay_internal__pv__GHLShouldChangeMarketplaceSponsoredDataFieldNamerelayprovider": true
        }
    },
    "CometMarketplaceSearchContentPaginationQuery": {
        "docId": "27212616558440397",
        "variables": {
            "count": 24,
            "cursor": null,
            "params": {
                "bqf": {
                    "callsite": "COMMERCE_MKTPLACE_WWW",
                    "query": ""
                },
                "browse_request_params": {
                    "commerce_enable_local_pickup": true,
                    "commerce_enable_shipping": true,
                    "commerce_search_and_rp_available": true,
                    "commerce_search_and_rp_category_id": [],
                    "commerce_search_and_rp_condition": null,
                    "commerce_search_and_rp_ctime_days": null,
                    "filter_location_latitude": 0,
                    "filter_location_longitude": 0,
                    "filter_price_lower_bound": 0,
                    "filter_price_upper_bound": 214748364700,
                    "filter_radius_km": 65
                },
                "custom_request_params": {
                    "browse_context": null,
                    "contextual_filters": [],
                    "referral_code": null,
                    "referral_ui_component": null,
                    "saved_search_strid": null,
                    "search_vertical": "C2C",
                    "seo_url": null,
                    "serp_landing_settings": {
                        "virtual_category_id": ""
                    },
                    "surface": "SEARCH",
                    "virtual_contextual_filters": []
                }
            },
            "scale": 2,
            "__relay_internal__pv__GHLShouldChangeMarketplaceSponsoredDataFieldNamerelayprovider": true
        }
    }
};
const clone = (value) => JSON.parse(JSON.stringify(value));
const objects = function* (value) {
    if (!value || typeof value !== "object")
        return;
    if (Array.isArray(value)) {
        for (const item of value)
            yield* objects(item);
        return;
    }
    yield value;
    for (const item of Object.values(value))
        yield* objects(item);
};
const text = (...values) => {
    for (const value of values)
        if (typeof value === "string" && value)
            return value;
    return "";
};
const number = (...values) => {
    for (const value of values) {
        const parsed = Number(value);
        if (Number.isFinite(parsed))
            return parsed;
    }
    return 0;
};
const firstImage = (value) => {
    if (!value || typeof value !== "object")
        return null;
    for (const candidate of objects(value)) {
        const uri = text(candidate.large_share_image?.uri, candidate.image?.uri, candidate.default_image?.uri, candidate.media_image?.uri, candidate.square_media_image?.uri);
        if (uri)
            return uri;
    }
    return null;
};
const nextCursor = (payloads, preferred) => {
    if (preferred?.page_info) {
        return preferred.page_info.has_next_page ? text(preferred.page_info.end_cursor) || null : null;
    }
    let cursor = null;
    for (const payload of payloads) {
        for (const candidate of objects(payload)) {
            if (!candidate.page_info || typeof candidate.page_info !== "object")
                continue;
            cursor = candidate.page_info.has_next_page ? text(candidate.page_info.end_cursor) || null : null;
        }
    }
    return cursor;
};
const groupPosts = (payloads) => {
    const byId = new Map();
    for (const payload of payloads) {
        for (const candidate of objects(payload)) {
            const content = candidate.comet_sections?.content?.story;
            const story = content || candidate;
            const id = text(story.post_id, candidate.post_id);
            if (!id)
                continue;
            const context = candidate.comet_sections?.context_layout?.story;
            const timestamp = candidate.comet_sections?.timestamp?.story;
            const actors = story.actors || candidate.actors || context?.actors || [];
            const message = text(story.message?.text, story.comet_sections?.message?.story?.message?.text, story.comet_sections?.message_container?.story?.message?.text, candidate.message?.text);
            const current = byId.get(id) || {
                id,
                author: "",
                message: "",
                createdAt: 0,
                url: "",
                imageUrl: null,
            };
            current.author ||= text(actors[0]?.name);
            if (message.length > current.message.length)
                current.message = message;
            current.createdAt ||= number(candidate.creation_time, story.creation_time, timestamp?.creation_time);
            current.url ||= text(story.wwwURL, story.url, candidate.wwwURL, candidate.url, timestamp?.url);
            current.imageUrl ||= firstImage(story.attachments || candidate.attachments);
            byId.set(id, current);
        }
    }
    return [...byId.values()];
};
const friendSuggestions = (payloads) => {
    const byId = new Map();
    for (const payload of payloads) {
        for (const candidate of objects(payload)) {
            if (typeof candidate.friendship_status !== "string")
                continue;
            const id = text(candidate.id);
            const name = text(candidate.name);
            if (!id || !name)
                continue;
            byId.set(id, {
                id,
                name,
                mutualContext: text(candidate.social_context?.text),
                profilePictureUrl: text(candidate.profile_picture?.uri),
                url: `https://www.facebook.com/profile.php?id=${encodeURIComponent(id)}`,
            });
        }
    }
    return [...byId.values()];
};
const marketplaceListings = (payloads) => {
    const byId = new Map();
    for (const payload of payloads) {
        for (const candidate of objects(payload)) {
            const listing = candidate.listing || candidate.entity || candidate;
            const title = text(listing.marketplace_listing_title, candidate.data?.title);
            const id = text(listing.id, candidate.entity_id, candidate.data?.product_item_id);
            if (!id || !title)
                continue;
            const place = listing.location?.reverse_geocode || candidate.entity?.location?.reverse_geocode || {};
            const city = text(place.city_page?.display_name, place.city);
            const state = text(place.state);
            const rawPrice = text(listing.formatted_price?.text, listing.listing_price?.formatted_amount, listing.listing_price?.amount_with_offset_in_currency, listing.listing_price?.amount, candidate.data?.price?.amount_with_offset);
            const currency = text(candidate.data?.price?.currency);
            byId.set(id, {
                id,
                title,
                price: currency && rawPrice && !rawPrice.includes(currency) ? `${rawPrice} ${currency}` : rawPrice,
                location: [city, state].filter(Boolean).join(", "),
                sellerName: text(listing.marketplace_listing_seller?.name),
                createdAt: number(listing.creation_time),
                imageUrl: firstImage(listing.primary_listing_photo || candidate.photo),
                url: `https://www.facebook.com/marketplace/item/${encodeURIComponent(id)}/`,
            });
        }
    }
    return [...byId.values()];
};
window.ox.install(({ action }) => {
    action('listMessengerInbox',{async invoke(){const end=Date.now()+12000;let grid;while(Date.now()<end){grid=document.querySelector('[role=grid][aria-label="Chats"]');if(grid?.querySelector('a[href*="/messages/"]'))break;await new Promise(r=>setTimeout(r,150));}if(!grid?.querySelector('a[href*="/messages/"]'))throw Error('Messenger chat-grid inventory not ready');const map=new Map();for(const a of grid.querySelectorAll('a[href*="/messages/"]')){const u=new URL(a.href);if(u.origin===location.origin&&(u.pathname.startsWith('/messages/e2ee/t/')||u.pathname.startsWith('/messages/t/')))map.set(u.origin+u.pathname,{url:u.origin+u.pathname,preview:a.innerText.trim()});}return {items:[...map.values()],nextCursor:null,coverage:'rendered_chat_grid_inventory_only; requests_archives_spam_and_server_pagination_not_established'};}});
    action('getOpenConversation',{async invoke({url}){const u=new URL(url);if(u.origin!==location.origin||u.pathname.split('/').filter(Boolean).join('/')!==location.pathname.split('/').filter(Boolean).join('/'))throw Error('Exact requested conversation is not open');const end=Date.now()+10000;let log;while(Date.now()<end){log=document.querySelector('[role=log][aria-label^="Messages in conversation with"]');const target=[...document.querySelectorAll('[role=grid][aria-label="Chats"] a[href]')].find(a=>new URL(a.href).pathname===u.pathname);const expected=target?.innerText.trim().split('\n')[0];if(log?.querySelector('[data-scope="messages_table"][aria-label]')&&expected&&log.getAttribute('aria-label')==='Messages in conversation with '+expected)break;log=null;await new Promise(r=>setTimeout(r,150));}if(!log)throw Error('Conversation log is unavailable');const items=[...log.querySelectorAll('[data-scope="messages_table"][aria-label]')].map(e=>({accessibleLabel:e.getAttribute('aria-label')||'',text:e.innerText.trim()}));if(!items.length)throw Error('No rendered message turns; empty history cannot be inferred');return {url:u.origin+u.pathname,name:log.getAttribute('aria-label').replace('Messages in conversation with ',''),items,nextCursor:null,coverage:'rendered_message_turns_only; unloaded_older_history_not_established'};}});
    action('openConversation',{async invoke({url}){const u=new URL(url);if(u.origin!==location.origin||!(u.pathname.startsWith('/messages/e2ee/t/')||u.pathname.startsWith('/messages/t/'))||!u.pathname.endsWith('/'))throw Error('Unsupported Messenger conversation URL');if(location.pathname===u.pathname)return {requested:false};const page=createEmbeddedAutomation({timeout:8000});const grid=page.getByRole('grid',{name:'Chats',exact:true});await grid.locator('a[href$="'+u.pathname+'"]').click();return {requested:true};}});

    action('listFriendsFeed',{async invoke({limit=15}){
        const sessions=await discoverAuthenticatedSessions();if(sessions.length!==1)throw Error('A single authenticated Facebook account is required');const session=sessions[0];
        const verify=()=>{const u=window.require('CurrentUserInitialData');if(String(u.ACCOUNT_ID||u.USER_ID)!==session?.id)throw Error('Facebook account changed.');};
        verify();const route=new URL(location.href);if(route.searchParams.get('filter')!=='friends'||route.searchParams.get('sk')!=='h_chr')throw Error('Not on Facebook friends-only feed.');
        const controls=()=>[...document.querySelectorAll('[role=button][aria-label]')].filter(e=>(e.getAttribute('aria-label')||'').startsWith('Actions for this post by ')&&!e.closest('[aria-hidden=true],[inert]'));
        const end=Date.now()+20000;while(Date.now()<end&&!controls().length)await new Promise(r=>setTimeout(r,250));
        if(!controls().length)throw Error('No verified loaded friends-feed posts; cannot infer an empty feed.');
        const rows=[];
        for(const button of controls()){
            let card=button.parentElement;
            for(let i=0;card&&i<14;i++,card=card.parentElement){
                const labels=[...card.querySelectorAll('[aria-label]')].map(e=>e.getAttribute('aria-label')||'');
                const actionCount=labels.filter(s=>s.startsWith('Actions for this post by ')).length;
                if(actionCount>1){card=null;break;}
                if(card.querySelector('h3')&&labels.some(s=>s.startsWith('Comment on ')||s.startsWith('React to ')))break;
            }
            if(!card)continue;
            const author=(button.getAttribute('aria-label')||'').replace('Actions for this post by ','');
            const links=[...card.querySelectorAll('a[href]')];const permalink=links.find(a=>/\/posts\/|\/permalink\/|story_fbid=/.test(a.href))||links.find(a=>/\/photo[/?]/.test(a.href));
            let url='';if(permalink){const u=new URL(permalink.href);for(const k of [...u.searchParams.keys()])if(!['story_fbid','id','fbid'].includes(k))u.searchParams.delete(k);url=u.href;}
            const cleanTime=s=>s.replace(/[\u034f\u200b-\u200f\u202a-\u202e\u2060-\u206f]/g,'').trim();
            const time=links.find(a=>/^\d+\s*[smhdwy]$/i.test(cleanTime(a.innerText)));
            rows.push({author,message:card.innerText.split('\n').map(s=>s.trim()).filter(s=>s&&s!=='Facebook').join('\n').slice(0,5000),url,timeLabel:time?cleanTime(time.innerText):'',imageDescriptions:[...card.querySelectorAll('img[alt]')].map(e=>e.alt).filter(s=>s&&!s.includes('profile picture'))});
            if(rows.length>=Math.min(30,Math.max(1,Number(limit)||15)))break;
        }
        verify();if(!rows.length)throw Error('Friends-feed post extraction did not establish content.');
        return {items:rows,nextCursor:null,coverage:'currently_loaded_friends_only_feed_snapshot; no complete date range or pagination established; image descriptions are website-provided alt text'};
    }});
    const docIds = Object.fromEntries(Object.entries(operationBaselines).map(([name, baseline]) => [name, baseline.docId]));
    const moduleToken = (name) => {
        try {
            const loader = window.require;
            const value = typeof loader === "function" ? loader(name) : null;
            return text(value?.token, value?.initialToken);
        }
        catch {
            return "";
        }
    };
    const token = (name, modules) => {
        const input = document.querySelector(`input[name="${name}"]`);
        if (input?.value)
            return input.value;
        for (const module of modules) {
            const value = moduleToken(module);
            if (value)
                return value;
        }
        return "";
    };
    const refreshDocId = async (operation) => {
        const urls = new Set();
        for (const script of document.querySelectorAll("script[src]"))
            urls.add(script.src);
        for (const resource of performance.getEntriesByType("resource")) {
            if (/\.js(?:\?|$)/.test(resource.name))
                urls.add(resource.name);
        }
        const escaped = operation.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const marker = new RegExp(`name:\\\\?"${escaped}\\\\?"`);
        for (const url of urls) {
            let source = "";
            try {
                source = await (await fetch(url, { credentials: "include" })).text();
            }
            catch {
                continue;
            }
            const match = marker.exec(source);
            if (!match)
                continue;
            const prefix = source.slice(Math.max(0, match.index - 3000), match.index);
            const ids = [...prefix.matchAll(/(?:id|doc_id):\\?"([0-9]+)\\?"/g)];
            const id = ids.at(-1)?.[1];
            if (!id)
                continue;
            docIds[operation] = id;
            console.log(`Facebook refreshed ${operation}`);
            return true;
        }
        return false;
    };
    const request = async (operation, variables) => {
        const invoke = async () => {
            const dtsg = token("fb_dtsg", ["DTSGInitialData", "DTSG"]);
            const lsd = token("lsd", ["LSD"]);
            if (!dtsg || !lsd)
                throw new Error("Facebook sign-in is required");
            const body = new URLSearchParams({
                __a: "1",
                __comet_req: "15",
                fb_dtsg: dtsg,
                jazoest: `2${[...dtsg].map((character) => character.charCodeAt(0)).join("")}`,
                lsd,
                fb_api_caller_class: "RelayModern",
                fb_api_req_friendly_name: operation,
                variables: JSON.stringify(variables),
                server_timestamps: "true",
                doc_id: docIds[operation],
            });
            const response = await retryFetch("/api/graphql/", {
                method: "POST",
                credentials: "include",
                headers: { "content-type": "application/x-www-form-urlencoded" },
                body: body.toString(),
            });
            const source = (await response.text()).replace(/^for\s*\(;;\);/, "").trim();
            const payloads = [];
            for (const line of source.split(/\r?\n/)) {
                if (!line.trim())
                    continue;
                try {
                    payloads.push(JSON.parse(line));
                }
                catch {
                    throw new Error(`Facebook returned an unreadable response for ${operation}`);
                }
            }
            return { response, payloads };
        };
        let result = await invoke();
        const failed = !result.response.ok || result.payloads.some((payload) => Array.isArray(payload.errors));
        if (failed && await refreshDocId(operation))
            result = await invoke();
        if (!result.response.ok || result.payloads.some((payload) => Array.isArray(payload.errors))) {
            throw new Error(`Facebook could not complete ${operation}`);
        }
        return result.payloads;
    };
    const variables = (operation) => clone(operationBaselines[operation].variables);
    action('login', { async invoke() {
 const end=Date.now()+15000;
 while(Date.now()<end){
 const pw=document.querySelector('input[type="password"]');
 if(pw&&pw.getBoundingClientRect().width>0)return null;
 const d=document.querySelector('[role="dialog"][aria-label="Your profile"]');
 if(d&&d.getBoundingClientRect().width>0&&d.innerText.includes('Log out'))return null;
 const b=document.querySelector('[aria-label="Account, your profile"]');
 if(b&&b.getAttribute('aria-expanded')!=='true')b.click();
 await new Promise(r=>setTimeout(r,250));
 }
 throw Error('Facebook sign-in or account-selection controls unavailable');
 } });
    const discoverAuthenticatedSessions = async () => {
const end=Date.now()+15000;while(Date.now()<end){
const pending=[...document.scripts].filter(s=>s.type==='application/json'&&s.textContent.includes('CurrentUserInitialData')).flatMap(s=>{try{return [JSON.parse(s.textContent)];}catch{return [];}});const users=[];let visited=0;
while(pending.length&&visited++<150000){const n=pending.pop();if(Array.isArray(n)&&n[0]==='CurrentUserInitialData')users.push(n[2]);else if(n&&typeof n==='object')pending.push(...Object.values(n));}
const identities=users.filter(u=>/^[1-9][0-9]+$/.test(String(u?.ACCOUNT_ID||u?.USER_ID||'')));const ids=[...new Set(identities.map(u=>String(u.ACCOUNT_ID||u.USER_ID)))];
if(ids.length===1){const u=identities[0];return [{id:ids[0],label:u.NAME||ids[0],url:'https://www.facebook.com/'}];}
if(ids.length>1)throw Error('Facebook current account identity is ambiguous');
if(document.querySelector('input[type="password"]')&&/login/.test(location.pathname))return [];
await new Promise(r=>setTimeout(r,250));}
throw Error('Facebook current account identity unavailable');

    };
    action('listSessions', { invoke: discoverAuthenticatedSessions });
    action("listGroupPosts", {
        async invoke({ groupId, cursor, limit } = {}) {
            const operation = cursor
                ? "GroupsCometFeedRegularStoriesPaginationQuery"
                : "CometGroupDiscussionRootSuccessQuery";
            const args = variables(operation);
            const count = Math.min(Math.max(Number(limit) || 5, 1), 20);
            if (cursor) {
                args.id = groupId;
                args.cursor = cursor;
                args.count = count;
            }
            else {
                args.groupID = groupId;
                args.regular_stories_count = count;
                args.regular_stories_stream_initial_count = count;
            }
            const payloads = await request(operation, args);
            return { items: groupPosts(payloads), nextCursor: nextCursor(payloads) };
        },
    });
    action("listFriendSuggestions", {
        async invoke({ cursor, limit } = {}) {
            const operation = cursor ? "FriendingCometPYMKGridPaginationQuery" : "FriendingCometRootContentQuery";
            const args = variables(operation);
            if (cursor) {
                args.cursor = cursor;
                args.count = Math.min(Math.max(Number(limit) || 20, 1), 50);
            }
            const payloads = await request(operation, args);
            const pymk = payloads[0]?.data?.viewer?.pymk_grid;
            return { items: friendSuggestions(payloads), nextCursor: nextCursor(payloads, pymk) };
        },
    });
    action("listMarketplace", {
        async invoke({ latitude, longitude, radiusKm, cursor, limit } = {}) {
            const operation = cursor
                ? "MarketplaceCometBrowseFeedLightPaginationQuery"
                : "MarketplaceCometBrowseFeedLightContainerQuery";
            const args = variables(operation);
            args.buyLocation = { latitude, longitude };
            args.radius = (Number(radiusKm) || 65) * 1000;
            args.count = Math.min(Math.max(Number(limit) || 12, 1), 50);
            args.cursor = cursor || null;
            const payloads = await request(operation, args);
            return { items: marketplaceListings(payloads), nextCursor: nextCursor(payloads) };
        },
    });
    action("searchMarketplace", {
        async invoke({ query, latitude, longitude, radiusKm, cursor, limit } = {}) {
            const operation = cursor
                ? "CometMarketplaceSearchContentPaginationQuery"
                : "CometMarketplaceSearchContentContainerQuery";
            const args = variables(operation);
            const search = String(query || "").trim();
            const radius = Number(radiusKm) || 65;
            args.count = Math.min(Math.max(Number(limit) || 24, 1), 50);
            args.cursor = cursor || null;
            if (args.buyLocation)
                args.buyLocation = { latitude, longitude };
            args.params.bqf.query = search;
            args.params.browse_request_params.filter_location_latitude = latitude;
            args.params.browse_request_params.filter_location_longitude = longitude;
            args.params.browse_request_params.filter_radius_km = radius;
            if ("savedSearchQuery" in args)
                args.savedSearchQuery = search;
            const payloads = await request(operation, args);
            const feed = payloads[0]?.data?.marketplace_search?.feed_units;
            return { items: marketplaceListings(payloads), nextCursor: nextCursor(payloads, feed) };
        },
    });
action('getMessageAccess',{async invoke(args){const sessions=await discoverAuthenticatedSessions();if(sessions.length!==1)throw Error('A single authenticated Facebook account is required');const session=sessions[0];const u=window.require('CurrentUserInitialData');if(String(u.ACCOUNT_ID||u.USER_ID)!==session.id)throw Error('Facebook account changed');const end=Date.now()+15000;while(Date.now()<end){const d=location.pathname.startsWith('/messages')?document:document.querySelector('[role="dialog"][aria-label="Messenger"]');if(d&&d.querySelector('a[href*="/messages/e2ee/t/"]')){const restore=/Chat history is missing|Enter your PIN|Message not restored|Restore messages/.test((d.body||d).innerText||'');const current=await discoverAuthenticatedSessions();if(current.length!==1||current[0].id!==session.id)throw Error('Facebook account changed');return {requiresRestore:restore,status:restore?'Enter your PIN or use a one-time code to restore encrypted chat history.':'Messenger chat list is available.',items:[...d.querySelectorAll('a[href*="/messages/e2ee/t/"]')].slice(0,10).map(a=>({url:a.href,preview:a.innerText.trim()}))};}const b=document.querySelector('[aria-label^="Messenger,"]')||document.querySelector('[aria-label="Messenger"]');if(b&&b.getAttribute('aria-expanded')!=='true')b.click();await new Promise(r=>setTimeout(r,250));}throw Error('Messenger did not become ready');}});
});
