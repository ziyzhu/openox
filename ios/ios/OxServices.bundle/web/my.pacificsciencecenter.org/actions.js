(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  // services/builtin/web/my.pacificsciencecenter.org/actions.ts
  var BASE = "https://my.pacificsciencecenter.org";
  var RECEIPT_KEY = "ox.pacificsciencecenter.latestReceipt";
  var pad = (value) => String(value).padStart(2, "0");
  var dateString = (date) => `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  var localTimestamp = (date) => `${dateString(date)} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  var parseDate = (value, endOfDay) => {
    const date = new Date(`${value}T${endOfDay ? "23:59:59" : "00:00:00"}`);
    if (Number.isNaN(date.getTime()) || dateString(date) !== value)
      throw new Error(`Invalid date: ${value}`);
    return date;
  };
  var requiredToken = (doc) => {
    const token = doc.querySelector('input[name="__RequestVerificationToken"]')?.value;
    if (!token)
      throw new Error("Pacific Science Center did not provide a request token");
    return token;
  };
  var normalizeStatus = (value) => cleanText(String(value ?? "").replace(/<[^>]*>/g, " ").replace(/&nbsp;/gi, " "));
  var money = (value) => {
    const amount = Number(String(value ?? "").replace(/[^\d.-]/g, ""));
    return Number.isFinite(amount) ? amount : 0;
  };
  var ticketType = (ticket) => {
    const label = cleanText(ticket.querySelector(".tn-ticket-selector__pricetype-name")?.textContent);
    const priceText = label.match(/\$\s*([\d,]+(?:\.\d{2})?)/)?.[1];
    if (!priceText)
      throw new Error(`Missing price for ${label || "ticket type"}`);
    const select = ticket.querySelector(".tn-ticket-selector__pricetype-select");
    return {
      id: String(ticket.dataset.tnPriceTypeId ?? select?.dataset.pricetypeId ?? ""),
      name: cleanText(label.replace(/\s*\$\s*[\d,]+(?:\.\d{2})?\s*$/, "")),
      price: Number(priceText.replace(/,/g, "")),
      currency: "USD",
      maximumQuantity: Math.max(0, ...[...select?.options ?? []].map((option) => Number(option.value) || 0))
    };
  };
  var reservationBody = ({
    productionSeasonId,
    performanceId,
    zoneId,
    tickets,
    isSingleSeatsEnabled,
    isUnseated
  }) => {
    const body = new URLSearchParams({
      isSingleSeatsEnabled: String(isSingleSeatsEnabled),
      isUnseated: String(isUnseated),
      performanceId,
      productionSeasonId,
      zoneId,
      specialRequests: "ContiguousSeats=1"
    });
    tickets.forEach((ticket, index) => {
      body.set(`ticketReservationRequests[${index}][pricetypeId]`, ticket.ticketTypeId);
      body.set(`ticketReservationRequests[${index}][price]`, "0");
      body.set(`ticketReservationRequests[${index}][isUserPrice]`, "false");
      body.set(`ticketReservationRequests[${index}][quantity]`, String(ticket.quantity));
    });
    return body.toString();
  };
  var eventConfiguration = (doc) => {
    for (const script of doc.scripts) {
      const source = script.textContent ?? "";
      if (!source.includes("new window.tnew.EventDetail"))
        continue;
      const match = source.match(/new window\.tnew\.EventDetail\(\s*({[\s\S]*?})\s*\)/);
      if (!match)
        continue;
      const configuration = JSON.parse(match[1]);
      if (configuration?.performanceConfiguration)
        return configuration.performanceConfiguration;
    }
    throw new Error("Showtime page did not provide its reservation configuration");
  };
  var cartDetails = (doc) => {
    const items = [...doc.querySelectorAll(".tn-cart-item")].map((item) => ({
      productionSeasonId: String(item.dataset.tnProductionSeason ?? ""),
      performanceId: String(item.dataset.tnPerformance ?? ""),
      title: cleanText(item.querySelector(".tn-cart-line-item-name")?.textContent),
      dateTime: cleanText(item.querySelector(".tn-cart-item-summary__property--date-time")?.textContent).replace(/^Date\/Time:\s*/, ""),
      venue: cleanText(item.querySelector(".tn-cart-item-summary__property--location")?.textContent).replace(/^Location:\s*/, ""),
      total: money(item.querySelector(".tn-cart-item-summary__property--price-total")?.textContent),
      tickets: [...item.querySelectorAll(".tn-cart-item-detail__list")].map((detail) => {
        const quantity = Number(cleanText(detail.querySelector(".tn-cart-item-detail__list-item--quantity")?.textContent).match(/\d+/)?.[0]) || 0;
        const unitPrice = money(detail.querySelector(".tn-cart-item-detail__list-item--price")?.textContent);
        return {
          name: cleanText(detail.querySelector(".tn-cart-item-detail__list-item--pricetype")?.textContent).replace(/^Type:\s*/, ""),
          quantity,
          unitPrice,
          total: quantity * unitPrice
        };
      })
    }));
    const subtotal = money(doc.querySelector(".tn-cart-totals__line-item--subtotal .tn-cart-totals__value")?.textContent);
    const total = money(doc.querySelector(".tn-cart-totals__value--total")?.textContent);
    const millisecondsRemaining = Number(doc.querySelector(".tn-count-down-timer")?.dataset.tnMillisecondsRemaining);
    const expiresAt = Number.isFinite(millisecondsRemaining) && millisecondsRemaining > 0 ? localTimestamp(new Date(Date.now() + millisecondsRemaining)) : null;
    return { items, subtotal, total, currency: "USD", expiresAt };
  };
  var receiptDetails = (doc, id) => {
    const { expiresAt: _, ...cart } = cartDetails(doc);
    const orderNumber = cleanText(doc.querySelector(".tn-order-number")?.textContent).match(/\d+/)?.[0];
    if (!orderNumber || orderNumber !== id || !cart.items.length)
      throw new Error(`Receipt ${id} was not found`);
    const orderDate = cleanText(doc.querySelector(".tn-order-date")?.textContent).replace(/^Order Date:\s*/, "");
    return { id, orderDate, ...cart };
  };
  var parsedOrderDate = (value) => {
    const date = new Date(value.replace(/(\d)(AM|PM)$/, "$1 $2"));
    return Number.isNaN(date.getTime()) ? null : date;
  };
  var isSince = (orderDate, since) => {
    if (!since)
      return true;
    const order = parsedOrderDate(orderDate);
    const start = new Date(since.replace(" ", "T"));
    if (!order || Number.isNaN(start.getTime()))
      throw new Error("Invalid transaction date scope");
    return order.getTime() + 59999 >= start.getTime();
  };
  var install = ({ action, retryFetch, log }) => {
    const fetchDocument = async (url) => {
      const response = await retryFetch(url, { credentials: "include" });
      if (!response.ok)
        throw new Error(`${url}: HTTP ${response.status}`);
      return new DOMParser().parseFromString(await response.text(), "text/html");
    };
    action("searchEvents", {
      async invoke({ query, startDate, endDate }) {
        const needle = query.trim().toLocaleLowerCase();
        if (!needle)
          throw new Error("query must contain visible text");
        const start = startDate ? parseDate(startDate, false) : new Date;
        const end = endDate ? parseDate(endDate, true) : new Date(start.getTime() + 30 * 24 * 60 * 60 * 1000);
        if (end < start)
          throw new Error("endDate must be on or after startDate");
        const eventsDocument = await fetchDocument(`${BASE}/events`);
        const body = new URLSearchParams({
          startDate: `${dateString(start)}T00:00:00`,
          endDate: `${dateString(end)}T23:59:59`
        });
        const response = await retryFetch(`${BASE}/api/products/productionseasons`, {
          method: "POST",
          credentials: "include",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
            RequestVerificationToken: requiredToken(eventsDocument)
          },
          body: body.toString()
        });
        if (!response.ok)
          throw new Error(`Event search: HTTP ${response.status}`);
        const productions = await response.json();
        if (!Array.isArray(productions))
          throw new Error("Event search returned an unexpected response");
        const items = productions.flatMap((production) => {
          const productionText = [
            production.productionTitle,
            production.description,
            ...Array.isArray(production.keywords) ? production.keywords : []
          ].join(" ").toLocaleLowerCase();
          return (production.performances ?? []).filter((performance) => {
            const performanceText = [
              performance.performanceTitle,
              performance.productTypeName,
              performance.performanceStatusMessage
            ].join(" ").toLocaleLowerCase();
            return productionText.includes(needle) || performanceText.includes(needle);
          }).map((performance) => ({
            productionSeasonId: String(production.productionSeasonId),
            performanceId: String(performance.id),
            title: cleanText(performance.performanceTitle || production.productionTitle),
            dateTime: String(performance.performanceDate || performance.iso8601DateString || ""),
            displayDate: cleanText(performance.displayDate),
            displayTime: cleanText(performance.displayTime),
            onSale: Boolean(performance.isOnSale),
            limitedAvailability: Boolean(performance.hasLimitedSeatingAvailable),
            status: normalizeStatus(performance.performanceStatusMessage),
            category: cleanText(performance.productTypeName),
            pageUrl: String(performance.actionUrl || `${BASE}/${production.productionSeasonId}/${performance.id}`)
          }));
        });
        log(`searchEvents ${dateString(start)} through ${dateString(end)}: ${items.length} showtimes`);
        return { items, nextCursor: null };
      }
    });
    action("getShowtime", {
      async invoke({ productionSeasonId, performanceId }) {
        const pageUrl = `${BASE}/${encodeURIComponent(productionSeasonId)}/${encodeURIComponent(performanceId)}`;
        const doc = await fetchDocument(pageUrl);
        const title = cleanText(doc.querySelector(".tn-event-detail__title")?.textContent || doc.title.replace(/\s*\|.*$/, ""));
        const dateTime = cleanText(doc.querySelector(".tn-event-detail__display-time")?.textContent);
        const venue = cleanText(doc.querySelector(".tn-event-detail__location")?.textContent);
        const description = cleanText(doc.querySelector(".tn-event-detail__description")?.textContent);
        const zones = [...doc.querySelectorAll(".tn-ticket-selector__input-zone")].map((input) => {
          const id = input.dataset.zoneId ?? input.value;
          const container = doc.querySelector(`.tn-ticket-selector__pricetype-container[data-zone-id="${id}"]`);
          const ticketTypes = container ? [...container.querySelectorAll(".tn-ticket-selector__pricetype")].map(ticketType) : [];
          const label = cleanText(input.closest("label")?.textContent);
          return {
            id,
            name: cleanText(label.replace(/:\s*\$[\s\S]*$/, "")),
            availableCount: Number(input.dataset.tnZoneAvailableCount) || 0,
            maximumQuantity: Number(container?.dataset.tnMaxQuantity) || 0,
            ticketTypes
          };
        });
        const available = zones.some((zone) => zone.maximumQuantity > 0 && zone.ticketTypes.some((ticket) => ticket.maximumQuantity > 0));
        log(`getShowtime ${productionSeasonId}/${performanceId}: ${zones.length} sections, available=${available}`);
        return {
          productionSeasonId,
          performanceId,
          title,
          dateTime,
          venue,
          description,
          available,
          zones,
          pageUrl
        };
      }
    });
    action("updateCart", {
      async invoke({ productionSeasonId, performanceId, zoneId, tickets }) {
        if (!tickets.length)
          throw new Error("At least one ticket type is required");
        if (new Set(tickets.map((ticket) => ticket.ticketTypeId)).size !== tickets.length) {
          throw new Error("Each ticket type may appear only once");
        }
        const pageUrl = `${BASE}/${encodeURIComponent(productionSeasonId)}/${encodeURIComponent(performanceId)}`;
        const doc = await fetchDocument(pageUrl);
        const zone = doc.querySelector(`.tn-ticket-selector__input-zone[data-zone-id="${CSS.escape(zoneId)}"]`);
        const container = doc.querySelector(`.tn-ticket-selector__pricetype-container[data-zone-id="${CSS.escape(zoneId)}"]`);
        if (!zone || !container)
          throw new Error(`Section ${zoneId} is not available for this showtime`);
        const availableTickets = new Map([...container.querySelectorAll(".tn-ticket-selector__pricetype")].map(ticketType).map((ticket) => [ticket.id, ticket]));
        let quantity = 0;
        for (const requested of tickets) {
          const available = availableTickets.get(requested.ticketTypeId);
          if (!available)
            throw new Error(`Ticket type ${requested.ticketTypeId} is not available in section ${zoneId}`);
          if (!Number.isInteger(requested.quantity) || requested.quantity < 1 || requested.quantity > available.maximumQuantity) {
            throw new Error(`${available.name} quantity must be between 1 and ${available.maximumQuantity}`);
          }
          quantity += requested.quantity;
        }
        const maximumQuantity = Number(container.dataset.tnMaxQuantity) || 0;
        if (maximumQuantity && quantity > maximumQuantity)
          throw new Error(`This showtime allows at most ${maximumQuantity} tickets per order`);
        const configuration = eventConfiguration(doc);
        const response = await retryFetch(`${BASE}/api/tickets/reservation`, {
          method: "POST",
          credentials: "include",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
            RequestVerificationToken: requiredToken(doc),
            "X-Requested-With": "XMLHttpRequest"
          },
          body: reservationBody({
            productionSeasonId,
            performanceId,
            zoneId,
            tickets,
            isSingleSeatsEnabled: Boolean(configuration.isSingleSeatsEnabled),
            isUnseated: Boolean(configuration.isUnseated)
          })
        });
        if (!response.ok)
          throw new Error(`Ticket reservation: HTTP ${response.status}`);
        const result = await response.json();
        if (result?.type !== "Success" || !result?.redirectLocation) {
          throw new Error(normalizeStatus(result?.message || result?.error || "Pacific Science Center rejected the ticket reservation"));
        }
        const cart = cartDetails(await fetchDocument(`${BASE}/cart/details`));
        if (!cart.items.length)
          throw new Error("Ticket reservation succeeded, but the cart could not be read");
        log(`updateCart ${productionSeasonId}/${performanceId}: ${quantity} tickets, total ${cart.total}`);
        return cart;
      }
    });
    action("getPaymentUrl", {
      async invoke() {
        return { url: `${BASE}/components/precart?p=1` };
      }
    });
    action("getPaymentState", {
      async invoke({ since }) {
        const liveReceiptId = location.pathname.match(/^\/cart\/receipt\/(\d+)/)?.[1];
        if (liveReceiptId) {
          const receipt = receiptDetails(document, liveReceiptId);
          if (!isSince(receipt.orderDate, since))
            return { status: "none", reference: null };
          const completedAt = parsedOrderDate(receipt.orderDate);
          const completedAtText = completedAt ? localTimestamp(completedAt) : localTimestamp(new Date);
          localStorage.setItem(RECEIPT_KEY, `${liveReceiptId}|${completedAtText}`);
          log(`getPaymentState: completed order ${liveReceiptId}`);
          return {
            status: "completed",
            reference: liveReceiptId,
            total: receipt.total,
            currency: receipt.currency,
            completedAt: completedAtText
          };
        }
        const cart = cartDetails(await fetchDocument(`${BASE}/cart/details`));
        if (cart.items.length) {
          return {
            status: "pending",
            reference: null,
            total: cart.total,
            currency: cart.currency,
            ...cart.expiresAt ? { expiresAt: cart.expiresAt } : {}
          };
        }
        const stored = localStorage.getItem(RECEIPT_KEY)?.match(/^(\d+)\|(.+)$/);
        if (stored) {
          const receipt = receiptDetails(await fetchDocument(`${BASE}/cart/receipt/${encodeURIComponent(stored[1])}`), stored[1]);
          if (isSince(receipt.orderDate, since)) {
            log(`getPaymentState: restored completed order ${stored[1]}`);
            return {
              status: "completed",
              reference: stored[1],
              total: receipt.total,
              currency: receipt.currency,
              completedAt: stored[2]
            };
          }
        }
        return { status: "none", reference: null };
      }
    });
    action("getOrder", {
      async invoke({ id }) {
        const receipt = receiptDetails(await fetchDocument(`${BASE}/cart/receipt/${encodeURIComponent(id)}`), id);
        log(`getOrder ${id}: ${receipt.items.length} items, total ${receipt.total}`);
        return receipt;
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

  installService("my.pacificsciencecenter.org", actions_default);
})();
