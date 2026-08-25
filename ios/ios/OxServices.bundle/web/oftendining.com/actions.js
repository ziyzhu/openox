(() => {
  // service-sdk/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/oftendining.com/actions.ts
  var BASE = "https://oftendining.com";
  var PICKUP_TYPE_ID = 101;
  var DEFAULT_NEAR = { latitude: 47.6859, longitude: -122.2994 };
  var CART_VERSION = "1.3";
  var splitCharges = (charges) => ({
    taxes: charges.filter(({ name }) => !/\b(?:fee|surcharge)\b/i.test(name)),
    fees: charges.filter(({ name }) => /\b(?:fee|surcharge)\b/i.test(name))
  });
  var pad = (n) => String(n).padStart(2, "0");
  var localDateTime = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  var localDate = (d) => localDateTime(d).slice(0, 10);
  var ceilMinutes = (d, step) => {
    const out = new Date(d);
    out.setSeconds(0, 0);
    out.setMinutes(Math.ceil(d.getMinutes() / step) * step);
    return out;
  };
  var install = ({ action, retryFetch, log }) => {
    const enginePost = async (path, submitType, json, opts) => {
      const body = new URLSearchParams;
      if (json !== undefined)
        body.set("data", JSON.stringify(json));
      body.set("submit_type", submitType);
      const res = await retryFetch(`${BASE}${path}`, {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: body.toString()
      }, opts);
      return { status: res.status, text: await res.text() };
    };
    const enginePostJson = async (path, submitType, json, opts) => {
      const { status, text } = await enginePost(path, submitType, json, opts);
      const formError = text.match(/displayFormError\('([^']*)',\s*'([^']*)'/);
      if (formError)
        throw new Error(`${formError[1]}: ${formError[2]}`);
      const partial = text.match(/<!-- PARTIAL json=json -->([\s\S]*?)<!-- END_PARTIAL json/);
      try {
        return JSON.parse((partial ? partial[1] : text).trim());
      } catch {
        throw new Error(`${path} HTTP ${status}: unrecognized response`);
      }
    };
    action("getSignInUrl", {
      async invoke() {
        return { url: `${BASE}/` };
      }
    });
    action("getSignInState", {
      async invoke() {
        const res = await retryFetch(`${BASE}/account_profile.php`, {
          method: "POST",
          credentials: "include"
        });
        if (!res.ok)
          throw new Error(`account_profile HTTP ${res.status}`);
        return { signedIn: (await res.text()).includes('id="account-profile"') };
      }
    });
    action("getProfile", {
      async invoke() {
        const doc = await fetchDoc("/account_profile.php");
        const value = (selector) => (doc.querySelector(selector)?.value ?? "").trim();
        const firstName = value("[name='first_name']");
        const lastName = value("[name='last_name']");
        const phone = value("[name='sms_number']");
        if (!firstName && !lastName && !phone)
          throw new Error("getProfile: profile details unavailable");
        return {
          firstName,
          lastName,
          phone,
          vehicle: {
            make: value("[name='curbside_make']"),
            model: value("[name='curbside_model']"),
            color: value("[name='curbside_color']"),
            licensePlate: value("[name='curbside_license_plate']")
          }
        };
      }
    });
    action("listOrders", {
      async invoke({ cursor } = {}) {
        const offset = pageCursor(cursor, 0);
        const doc = offset === 0 ? await fetchDoc("/account_orders.php") : new DOMParser().parseFromString(await enginePost("/account_orders.php", "load", { offset }).then(({ status, text }) => {
          if (status < 200 || status >= 300)
            throw new Error(`account_orders HTTP ${status}`);
          return text;
        }), "text/html");
        const items = [...doc.querySelectorAll(".invoice-header")].map((header) => {
          const columns = [...header.querySelectorAll(".col-xs-12")].map((column) => cleanText(column.textContent));
          return {
            id: header.dataset.invoiceId ?? "",
            storeId: header.dataset.storeId ?? "",
            typeId: Number(header.dataset.oid) || 0,
            orderedOn: columns[0] ?? "",
            restaurant: columns[1] ?? "",
            status: cleanText(columns[2]).replace(/^(?:Order|Status):\s*/i, ""),
            total: Number(cleanText(columns[3]).replace(/[^0-9.]/g, "")) || 0
          };
        });
        if (items.some(({ id, storeId }) => !id || !storeId)) {
          throw new Error("listOrders: order identifiers unavailable");
        }
        log(`listOrders offset ${offset}: ${items.length} orders`);
        return {
          items,
          nextCursor: doc.querySelector(".load-more") ? String(offset + items.length) : null
        };
      }
    });
    action("searchStores", {
      async invoke({ query = "", latitude, longitude, openNow = false, cursor } = {}) {
        const page = pageCursor(cursor, 0);
        const lat = latitude ?? DEFAULT_NEAR.latitude;
        const lng = longitude ?? DEFAULT_NEAR.longitude;
        const now = new Date;
        const result = await enginePostJson("/index.php", "search", {
          search: query,
          page,
          location: "",
          near_geo: { location: "", latitude: lat, longitude: lng },
          latitude: lat,
          longitude: lng,
          search_here: 0,
          search_distance: 100,
          open_now: openNow,
          pick_up: false,
          delivery: false,
          reservations: false,
          open_now_datetime: localDateTime(now),
          catering: false,
          today: localDate(now)
        }, { retries: 0 });
        const items = (result.store_list ?? []).map((s) => ({
          id: String(s.store_id),
          name: cleanText(s.name),
          description: cleanText(s.description),
          phone: s.phone_number_formatted ?? s.phone_number ?? "",
          address: cleanText(`${s.address}, ${s.city}`),
          latitude: Number(s.latitude),
          longitude: Number(s.longitude),
          distanceMiles: Math.round(Number(s.distance) * 10) / 10,
          online: s.online === "1",
          pickup: s.pick_up === "1",
          delivery: s.delivery === "1",
          pickupWaitMinutes: Number(s.pickup_wait_time) || 0,
          deliveryWaitMinutes: Number(s.delivery_wait_time) || 0,
          hours: (s.hours ?? []).map((h) => ({ days: h.name, times: h.list ?? [] }))
        }));
        log(`searchStores page ${page}: ${items.length} stores`);
        return { items, nextCursor: result.more ? String(page + 1) : null };
      }
    });
    action("getMenu", {
      async invoke({ storeId, typeId = PICKUP_TYPE_ID }) {
        const params = new URLSearchParams({
          store_id: String(storeId),
          category_id: "0",
          menu_id: "-2",
          type_id: String(typeId)
        });
        const res = await retryFetch(`${BASE}/menu_category.php?${params}`, {
          method: "POST",
          credentials: "include"
        });
        if (!res.ok)
          throw new Error(`menu_category HTTP ${res.status}`);
        const doc = new DOMParser().parseFromString(await res.text(), "text/html");
        const categories = [...doc.querySelectorAll(".category-block")].map((block) => ({
          name: cleanText(block.querySelector("h2")?.textContent),
          items: [...block.querySelectorAll(".product.tile")].map((tile) => {
            const bg = tile.querySelector(".tile-image")?.style.backgroundImage ?? "";
            const rawImage = bg.match(/url\(["']?(.*?)["']?\)/)?.[1];
            const imageUrl = rawImage ? new URL(rawImage, BASE).href : null;
            return {
              productId: Number(tile.dataset.productId),
              sizeId: Number(tile.dataset.sizeId) || 1,
              name: cleanText(tile.dataset.name),
              description: cleanText(tile.querySelector(".description")?.textContent),
              price: Number(tile.dataset.price),
              unavailable: !!tile.dataset.unavailable,
              requiresModifiers: tile.dataset.requiredMods !== "0",
              hasMoreSizes: /More Sizes/i.test(tile.querySelector(".price-info")?.textContent ?? ""),
              imageUrl
            };
          })
        })).filter((c) => c.items.length > 0);
        if (categories.length === 0)
          throw new Error(`getMenu: no menu for store ${storeId}`);
        return { categories };
      }
    });
    const fetchDoc = async (path) => {
      const res = await retryFetch(`${BASE}${path}`, { method: "POST", credentials: "include" });
      if (!res.ok)
        throw new Error(`${path} HTTP ${res.status}`);
      return new DOMParser().parseFromString(await res.text(), "text/html");
    };
    action("updateCart", {
      async invoke({ storeId, items, typeId = PICKUP_TYPE_ID, notes = "" }) {
        if (!items.length)
          throw new Error("updateCart: items must not be empty");
        const now = new Date;
        const asap = localDateTime(ceilMinutes(now, 5));
        const future = localDateTime(ceilMinutes(new Date(now.getTime() + 20 * 60000), 5));
        const cartItems = {};
        items.forEach((item, i) => {
          const salesId = 1000 + i;
          cartItems[String(salesId)] = {
            sales_id: salesId,
            price_name: "",
            name: item.name,
            product_id: item.productId,
            size_id: item.sizeId ?? 1,
            quantity: item.quantity ?? 1,
            unit_price: "0.00",
            price: 0,
            total: 0,
            notes: item.notes ?? "",
            group_id: 0,
            mod_key: "",
            mod_price: 0,
            mod_name: "",
            min_qty: null
          };
        });
        const result = await enginePostJson("/cart.php", "calculate", {
          store_id: String(storeId),
          cart: {
            version: CART_VERSION,
            items: cartItems,
            taxes: {},
            payments: {},
            redeem_code: null,
            subtotal: 0,
            total: 0,
            total_qty: items.length,
            expiry: now.getTime(),
            notes,
            max_id: 1000 + items.length,
            menu_id: -2,
            date_type: "asap",
            date_asap: asap,
            date_future: future,
            type_id: String(typeId)
          },
          options: { validate_menu_items: true, check_throttle: true }
        });
        const serverCart = result.cart;
        if (!serverCart)
          throw new Error("updateCart: no cart in response");
        const returned = Object.values(serverCart.items ?? {});
        const dropped = items.filter((item) => !returned.some((r) => r.product_id === item.productId));
        if (dropped.length) {
          throw new Error(`updateCart: store rejected product ids ${dropped.map((d) => d.productId).join(", ")}`);
        }
        persistCart(String(storeId), String(typeId), serverCart, asap, future);
        log(`updateCart store ${storeId}: ${returned.length} items, total ${serverCart.total}`);
        const charges = (serverCart.taxes ?? []).map((t) => ({
          name: t.name,
          amount: Number(t.amount)
        }));
        const { taxes, fees } = splitCharges(charges);
        return {
          items: returned.map((r) => ({
            name: r.name,
            quantity: Number(r.quantity),
            unitPrice: Number(r.unit_price),
            total: Number(r.total)
          })),
          subtotal: Number(serverCart.subtotal),
          taxes,
          fees,
          total: Number(serverCart.total),
          readyAt: serverCart.date_needed
        };
      }
    });
    const readStoredCart = (storeId) => {
      const site = window.cart;
      if (site?.setStore && site?.getCart) {
        site.setStore(storeId);
        const cart = site.getCart();
        if (cart?.items && Object.keys(cart.items).length)
          return cart;
      }
      let root = null;
      try {
        root = JSON.parse(localStorage.getItem("cart") ?? "null");
      } catch {}
      const stored = root?.[storeId];
      if (!stored?.items || !Object.keys(stored.items).length)
        return null;
      return { ...stored, ...root.common };
    };
    const CART_LIFETIME_MS = 4 * 60 * 60 * 1000;
    const parseReceiptTimestamp = (text) => {
      const m = text.match(/(\w{3}) (\d{1,2}), (\d{4}) (\d{2}):(\d{2}) (AM|PM)/);
      if (!m)
        return null;
      const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      const month = months.indexOf(m[1]);
      if (month < 0)
        return null;
      let hours = Number(m[4]) % 12;
      if (m[6] === "PM")
        hours += 12;
      return new Date(Number(m[3]), month, Number(m[2]), hours, Number(m[5]));
    };
    const newestInvoiceId = async () => {
      const doc = await fetchDoc("/account_orders.php");
      for (const a of doc.querySelectorAll("[link*='invoice_id='], a[href*='invoice_id='], [onclick*='invoice_id']")) {
        const source = `${a.getAttribute("link") ?? ""} ${a.getAttribute("href") ?? ""} ${a.getAttribute("onclick") ?? ""}`;
        const m2 = source.match(/invoice_id=(\d+)/);
        if (m2)
          return m2[1];
      }
      const m = doc.body?.innerHTML.match(/invoice_id[=":\s]+(\d+)/);
      return m?.[1] ?? null;
    };
    action("getPaymentUrl", {
      async invoke({ storeId, typeId = PICKUP_TYPE_ID }) {
        return { url: `${BASE}/#s:order_payment.php?store_id=${encodeURIComponent(storeId)}&type_id=${typeId}` };
      }
    });
    action("getPaymentState", {
      async invoke({ storeId, since }) {
        const liveReceipt = location.href.match(/order_receipt\.php\?[^,#]*invoice_id=(\d+)/);
        if (liveReceipt) {
          log(`getPaymentState: live receipt ${liveReceipt[1]}`);
          return { status: "completed", reference: liveReceipt[1], total: null, expiresAt: null, completedAt: null };
        }
        const cart = readStoredCart(String(storeId));
        if (cart) {
          const expiresAt = cart.expiry ? localDateTime(new Date(cart.expiry + CART_LIFETIME_MS)) : null;
          return {
            status: "pending",
            reference: null,
            total: Number(cart.total) || null,
            expiresAt,
            completedAt: null
          };
        }
        if (since) {
          const invoiceId = await newestInvoiceId();
          if (invoiceId) {
            const receipt = await fetchDoc(`/order_receipt.php?invoice_id=${encodeURIComponent(invoiceId)}`);
            const orderedOnText = cleanText(receipt.body?.textContent).match(/Ordered On:\s*([^|]+?(?:AM|PM))/)?.[1] ?? "";
            const orderedOn = parseReceiptTimestamp(orderedOnText);
            const sinceDate = new Date(since.replace(" ", "T"));
            if (orderedOn && !Number.isNaN(sinceDate.getTime()) && orderedOn >= sinceDate) {
              log(`getPaymentState: reconstructed completion ${invoiceId} ordered ${orderedOnText}`);
              return {
                status: "completed",
                reference: invoiceId,
                total: null,
                expiresAt: null,
                completedAt: localDateTime(orderedOn)
              };
            }
          }
        }
        return { status: "none", reference: null, total: null, expiresAt: null, completedAt: null };
      }
    });
    action("getOrder", {
      async invoke({ id }) {
        const doc = await fetchDoc(`/order_receipt.php?invoice_id=${encodeURIComponent(id)}`);
        const items = [...doc.querySelectorAll("tr.item")].map((row) => {
          const cells = row.querySelectorAll("td");
          return {
            quantity: Number(cleanText(cells[0]?.textContent)) || 0,
            name: cleanText(cells[1]?.textContent),
            price: Number(cleanText(cells[2]?.textContent).replace(/[^0-9.]/g, ""))
          };
        });
        if (!items.length)
          throw new Error(`getOrder: no order found for invoice ${id}`);
        const labeled = (label) => {
          for (const el of doc.querySelectorAll("div, td")) {
            if (cleanText(el.querySelector(":scope > label")?.textContent) === label) {
              const clone = el.cloneNode(true);
              clone.querySelector("label")?.remove();
              return cleanText(clone.textContent);
            }
          }
          return "";
        };
        const money = (text) => Number(text.replace(/[^0-9.]/g, "")) || 0;
        const totalsRows = [...doc.querySelectorAll("tr")].filter((r) => !r.classList.contains("item") && r.querySelector("td.price") && cleanText(r.textContent));
        const rowByLabel = (needle) => totalsRows.find((r) => needle.test(cleanText(r.querySelector("td")?.textContent)));
        const charges = totalsRows.filter((r) => {
          const label = cleanText(r.querySelector("td")?.textContent);
          return label && !/Sub Total|^Total|Payment/.test(label);
        }).map((r) => ({
          name: cleanText(r.querySelector("td")?.textContent).replace(/:$/, ""),
          amount: money(cleanText(r.querySelector("td.price")?.textContent))
        }));
        const { taxes, fees } = splitCharges(charges);
        return {
          id: String(id),
          orderId: labeled("ID:"),
          status: cleanText(doc.querySelector(".status-box")?.textContent).replace(/^Status:\s*/, ""),
          pickupTime: labeled("Pickup Time:"),
          orderedOn: labeled("Ordered On:"),
          items,
          subtotal: money(cleanText(rowByLabel(/Sub Total/)?.querySelector("td.price")?.textContent ?? "")),
          taxes,
          fees,
          total: money(cleanText(rowByLabel(/^Total:/)?.querySelector("td.price")?.textContent ?? "")),
          payment: labeled("Payment:")
        };
      }
    });
    const persistCart = (storeId, typeId, serverCart, asap, future) => {
      const site = window.cart;
      if (site?.setStore && site?.setCart) {
        try {
          site.data("type_id", typeId);
          site.data("date_type", "asap");
          site.data("date_asap", asap);
          site.data("date_future", future);
          site.setStore(storeId);
          site.setCart(serverCart);
          site.saveCart();
          return;
        } catch (e) {
          log(`updateCart: site cart API failed (${e}), writing localStorage`);
        }
      }
      const raw = localStorage.getItem("cart");
      let root = null;
      try {
        root = raw ? JSON.parse(raw) : null;
      } catch {}
      if (!root || root.version !== CART_VERSION)
        root = { version: CART_VERSION, common: {} };
      root.common = root.common ?? {};
      Object.assign(root.common, {
        type_id: typeId,
        date_type: "asap",
        date_asap: asap,
        date_future: future
      });
      delete serverCart.table_data;
      root[storeId] = { ...serverCart, expiry: Date.now() };
      localStorage.setItem("cart", JSON.stringify(root));
    };
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

  installService("oftendining.com", actions_default);
})();
