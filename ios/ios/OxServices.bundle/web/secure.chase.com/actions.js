(() => {
  // services/builtin/web/secure.chase.com/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const ORIGIN = "https://secure.chase.com";
    const DASHBOARD_URL = `${ORIGIN}/web/auth/dashboard`;
    const jpmcHeaders = (post = false) => {
      const h = {
        "x-jpmc-channel": "id=C30",
        "x-jpmc-csrf-token": "NONE",
        "x-jpmc-client-request-id": crypto.randomUUID()
      };
      if (post)
        h["content-type"] = "application/x-www-form-urlencoded; charset=UTF-8";
      return h;
    };
    const postForm = async (path, body) => {
      const res = await retryFetch(ORIGIN + path, {
        method: "POST",
        headers: jpmcHeaders(true),
        credentials: "include",
        body: body ? new URLSearchParams(body).toString() : ""
      });
      if (res.status === 401 || res.status === 403)
        throw signedOut();
      if (!res.ok)
        throw new Error(`POST ${path} HTTP ${res.status}`);
      return res.json();
    };
    const getJson = async (path) => {
      const res = await retryFetch(ORIGIN + path, {
        headers: jpmcHeaders(),
        credentials: "include"
      });
      if (res.status === 401 || res.status === 403)
        throw signedOut();
      if (!res.ok)
        throw new Error(`GET ${path} HTTP ${res.status}`);
      return res.json();
    };
    const signedOut = () => new Error("Chase session is signed out. Run getSignInUrl, sign in, then retry.");
    const fetchBootstrap = async () => postForm("/svc/rl/accounts/l4/v1/app/data/list");
    const accountTilesOf = (bootstrap) => {
      const cache = Array.isArray(bootstrap?.cache) ? bootstrap.cache : [];
      const tiles = cache.find((c) => String(c?.url ?? "").includes("dashboard/tiles/list"));
      const list = tiles?.response?.accountTiles;
      return Array.isArray(list) ? list : [];
    };
    const mapTile = (t) => ({
      accountId: t?.accountId ?? null,
      nickname: t?.nickname ?? null,
      mask: t?.mask ?? null,
      cardType: t?.cardType ?? null,
      accountTileType: t?.accountTileType ?? null,
      currentBalance: t?.tileDetail?.currentBalance ?? null,
      availableBalance: t?.tileDetail?.availableBalance ?? null,
      nextPaymentDueDate: t?.tileDetail?.nextPaymentDueDate ?? null,
      nextPaymentAmount: t?.tileDetail?.nextPaymentAmount ?? null,
      pastDueAmount: t?.tileDetail?.pastDueAmount ?? null,
      paymentDueDays: t?.tileDetail?.paymentDueDays ?? null,
      dueStatus: t?.tileDetail?.dueStatus ?? null,
      lockStatus: t?.tileDetail?.creditCardLockStatus ?? null,
      closed: t?.tileDetail?.closed ?? null
    });
    action("getSignInUrl", {
      async invoke() {
        return { url: DASHBOARD_URL };
      }
    });
    action("getSignInState", {
      async invoke() {
        const data = await fetchBootstrap();
        return { signedIn: Boolean(data?.personId) };
      }
    });
    action("listAccounts", {
      async invoke() {
        const data = await fetchBootstrap();
        if (!data?.personId)
          throw signedOut();
        return { items: accountTilesOf(data).map(mapTile), nextCursor: null };
      }
    });
    action("getAccount", {
      async invoke({ accountId } = {}) {
        if (!accountId)
          throw new Error("getAccount requires accountId");
        const data = await postForm("/svc/rr/accounts/secure/v2/account/detail/card/list", {
          accountId: String(accountId)
        });
        if (data?.code && data.code !== "SUCCESS")
          throw new Error(`Chase returned ${data.code}`);
        const d = data?.detail ?? {};
        return {
          accountId: data?.accountId ?? accountId,
          nickname: data?.nickname ?? null,
          mask: data?.mask ?? null,
          cardType: d?.cardType ?? null,
          currentBalance: d?.currentBalance ?? null,
          availableCredit: d?.availableCredit ?? null,
          creditLimit: d?.creditLimit ?? null,
          lastStmtBalance: d?.lastStmtBalance ?? null,
          lastStmtDate: d?.lastStmtDate ?? null,
          remainingStmtBalance: d?.remainingStmtBalance ?? null,
          pendingChargesAmount: d?.pendingChargesAmount ?? null,
          nextPaymentDueDate: d?.nextPaymentDueDate ?? null,
          nextPaymentAmount: d?.nextPaymentAmount ?? null,
          pastDueAmount: d?.pastDueAmount ?? null,
          lastPaymentAmount: d?.lastPaymentAmount ?? null,
          lastPaymentDate: d?.lastPaymentDate ?? null,
          purchaseAPR: d?.purchaseAPR ?? null,
          cashAPR: d?.cashAPR ?? null,
          autoPayEnrolled: d?.autoPayEnrolled ?? null,
          rewardsEligible: d?.rewardsEligible ?? null,
          lockStatus: d?.lockStatus ?? null,
          closed: d?.closed ?? null
        };
      }
    });
    const mapTxn = (a) => {
      const m = a?.merchantDetails ?? {};
      const enriched = Array.isArray(m.enrichedMerchants) ? m.enrichedMerchants[0] : null;
      const raw = m.rawMerchantDetails ?? {};
      return {
        id: a?.sorTransactionIdentifier ?? a?.derivedUniqueTransactionIdentifier ?? null,
        status: a?.transactionStatusCode ?? null,
        pending: a?.transactionStatusCode === "Pending",
        date: a?.transactionDate ?? null,
        postDate: a?.transactionPostDate ?? null,
        amount: a?.transactionAmount ?? null,
        creditDebitCode: a?.creditDebitCode ?? null,
        type: a?.etuStandardTransactionTypeName ?? null,
        typeGroup: a?.etuStandardTransactionTypeGroupName ?? null,
        expenseCategory: a?.etuStandardExpenseCategoryCode ?? null,
        merchantName: enriched?.merchantName ?? raw?.merchantDbaName ?? null,
        merchantCity: enriched?.merchantCityName ?? raw?.merchantCityName ?? null,
        merchantState: enriched?.merchantStateCode ?? raw?.merchantStateCode ?? null,
        merchantCategory: raw?.merchantCategoryName ?? null,
        earnedRewardsAmount: a?.earnedRewardsAmount ?? null,
        last4CardNumber: a?.last4CardNumber ?? null,
        disputed: a?.transactionDisputeIndicator ?? null
      };
    };
    const pad = (n) => String(n).padStart(2, "0");
    const fmtDate = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    action("listTransactions", {
      async invoke({ accountId, limit = 50, cursor, startDate, endDate } = {}) {
        if (!accountId)
          throw new Error("listTransactions requires accountId");
        const count = Math.max(1, Math.min(Number(limit) || 50, 100));
        const end = endDate ? String(endDate) : fmtDate(new Date);
        const start = startDate ? String(startDate) : (() => {
          const d = new Date;
          d.setFullYear(d.getFullYear() - 2);
          return fmtDate(d);
        })();
        const params = new URLSearchParams({
          "digital-account-identifier": String(accountId),
          "provide-available-statement-indicator": "true",
          "record-count": String(count),
          "sort-order-code": "D",
          "sort-key-code": "T",
          "account-activity-start-date": start,
          "account-activity-end-date": end
        });
        if (cursor)
          params.set("pagination-contextual-text", String(cursor));
        const data = await getJson(`/svc/rr/accounts/secure/gateway/credit-card/transactions/inquiry-maintenance/etu-transactions/v4/accounts/transactions?${params}`);
        const activities = Array.isArray(data?.activities) ? data.activities : [];
        const nextCursor = data?.moreRecordsIndicator && data?.paginationContextualText ? String(data.paginationContextualText) : null;
        return {
          items: activities.map(mapTxn),
          nextCursor
        };
      }
    });
    action("getRewards", {
      async invoke() {
        const data = await postForm("/svc/rr/accounts/secure/card/rewards/v2/summary/list");
        if (data?.code && data.code !== "SUCCESS")
          throw new Error(`Chase returned ${data.code}`);
        const summary = Array.isArray(data?.cardRewardsSummary) ? data.cardRewardsSummary : [];
        const items = summary.map((s) => ({
          accountId: s?.accountId ?? null,
          nickname: s?.nickname ?? null,
          mask: s?.mask ?? null,
          cardType: s?.cardType ?? null,
          rewardsType: s?.rewardsType ?? null,
          cardRewardType: s?.cardRewardType ?? null,
          balance: s?.balance ?? null,
          currentRewardsBalance: s?.currentRewardsBalance ?? null,
          rewardsDollarBalance: s?.rewardsDollarBalance ?? null,
          asOfDate: s?.asOfDate ?? null
        }));
        return { items, nextCursor: null };
      }
    });
    const PAYEE_TYPES = [
      "AUTO_LEASE",
      "AUTO_LOAN",
      "BUSINESS_LOAN",
      "COMMERCIAL_LOAN",
      "CREDIT_CARD",
      "HELOC",
      "HOME_EQUITY_LOAN",
      "MERCHANT",
      "MORTGAGE",
      "PERSONAL_LOAN",
      "STUDENT_LOAN",
      "CREDIT_FACILITY"
    ].join(",");
    action("listPayees", {
      async invoke() {
        const data = await postForm("/svc/rr/payments/secure/v1/billpay/merchantmultipayment/payee/list", {
          groupViewType: "ALL",
          payeeTypesFilter: PAYEE_TYPES
        });
        if (data?.code && data.code !== "SUCCESS")
          throw new Error(`Chase returned ${data.code}`);
        const payees = data?.payees && typeof data.payees === "object" ? data.payees : {};
        const items = Object.values(payees).map((p) => ({
          payeeId: p?.payeeId ?? null,
          payeeName: p?.payeeName ?? null,
          payeeNickname: p?.payeeNickname ?? null,
          payeeLabel: p?.payeeLabel ?? null,
          payeeAccountMask: p?.payeeAccountMask ?? null,
          payeeType: p?.payeeType ?? null,
          nextPaymentDate: p?.nextPaymentDate ?? null,
          nextPaymentAmount: p?.nextPaymentAmount ?? null,
          paymentDueInDays: p?.paymentDueInDays ?? null,
          blocked: p?.blocked ?? null,
          paidInFull: p?.paidInFull ?? null
        }));
        return { items, nextCursor: null };
      }
    });
    action("createPayment", {
      async invoke({ payeeId, amount, paymentDate, fundingAccountId, paymentOption } = {}) {
        if (!payeeId)
          throw new Error("createPayment requires payeeId");
        const optionsData = await postForm("/svc/rr/payments/secure/v2/billpay/multi/payment/add/options", {
          payeeId: String(payeeId)
        });
        if (optionsData?.code && optionsData.code !== "SUCCESS")
          throw new Error(`Chase returned ${optionsData.code}`);
        const opts = optionsData?.creditCardMultiPayBillOptions ?? {};
        const fundingAccounts = Array.isArray(opts.fundingAccounts) ? opts.fundingAccounts : [];
        const fundingOptions = Array.isArray(opts.fundingOptions) ? opts.fundingOptions : [];
        const dateOptions = Array.isArray(opts.dateOptions) ? opts.dateOptions : [];
        const account = fundingAccountId ? fundingAccounts.find((a) => String(a?.accountId) === String(fundingAccountId)) : fundingAccounts.find((a) => a?.defaultFlag) ?? fundingAccounts[0];
        if (!account)
          throw new Error("No matching funding account; call listAccounts/options to pick a fundingAccountId");
        const usable = fundingOptions.filter((o) => !o?.disabled);
        let chosen = paymentOption ? usable.find((o) => o?.optionType === paymentOption) : amount != null ? usable.find((o) => o?.amount === Number(amount)) : undefined;
        if (!chosen)
          chosen = usable.find((o) => o?.optionType === "OTHER_AMOUNT");
        if (!chosen)
          throw new Error("No usable payment option for this payee");
        const payAmount = amount != null ? Number(amount) : chosen?.amount;
        if (payAmount == null)
          throw new Error("createPayment requires amount for OTHER_AMOUNT");
        const payDate = paymentDate ? String(paymentDate) : dateOptions[0];
        if (!payDate)
          throw new Error("No available payment date");
        const validateData = await postForm("/svc/rr/payments/secure/v3/billpay/multi/payment/add/validate", {
          "creditCardDetail[0].fundingAccountId": String(account.accountId),
          "creditCardDetail[0].amount": String(payAmount),
          "creditCardDetail[0].paymentDate": payDate,
          "creditCardDetail[0].orderId": "1",
          "creditCardDetail[0].payeeId": String(payeeId),
          "creditCardDetail[0].accountId": "",
          "creditCardDetail[0].paymentOptionId": String(chosen.optionId),
          "creditCardDetail[0].optionId": ""
        });
        if (validateData?.errorStatus)
          throw new Error("Chase rejected the payment at validation");
        const formId = validateData?.formId;
        if (!formId)
          throw new Error("Chase did not return a formId; payment not submitted");
        const result = await postForm("/svc/wr/payments/secure/v2/billpay/multi/payment/add", {
          formId: String(formId)
        });
        if (result?.code && result.code !== "SUCCESS")
          throw new Error(`Chase returned ${result.code}`);
        const payment = (Array.isArray(result?.payments) ? result.payments : [])[0] ?? {};
        return {
          ok: true,
          paymentId: payment?.paymentId ?? null,
          status: payment?.status ?? null,
          amount: payment?.amount ?? payAmount,
          paymentDate: payment?.paymentDate ?? payDate,
          processDate: payment?.processDate ?? null,
          payeeLabel: payment?.payeeLabel ?? null,
          fundingAccountMask: payment?.fundingAccountMask ?? null
        };
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

  installService("secure.chase.com", actions_default);
})();
