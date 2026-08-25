import { pageCursor } from "@openox/service-sdk/action-lib";
import type { ActionInstaller } from "@openox/service-sdk/action";

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const ORIGIN = "https://secure.bankofamerica.com";
  const OVERVIEW_URL = `${ORIGIN}/myaccounts/ao/accounts-overview.go`;
  const PAY_TRANSFER_URL = `${ORIGIN}/pay-transfer-pay-portal/`;
  const SIGNON_URL = `${ORIGIN}/auth/signon/`;

  const signedOut = () =>
    new Error("Bank of America session is signed out. Run getSignInUrl, sign in, then retry.");

  const baseHeaders = (): Record<string, string> => ({
    accept: "application/json, text/javascript, */*; q=0.01",
    "x-requested-with": "XMLHttpRequest",
  });

  const getJson = async (path: string): Promise<any> => {
    const res = await retryFetch(ORIGIN + path, {
      headers: baseHeaders(),
      credentials: "include",
    });
    if (res.status === 401 || res.status === 403) throw signedOut();
    if (!res.ok) throw new Error(`GET ${path} HTTP ${res.status}`);
    return res.json();
  };

  const postJson = async (path: string, body: unknown): Promise<any> => {
    const res = await retryFetch(ORIGIN + path, {
      method: "POST",
      headers: { ...baseHeaders(), "content-type": "application/json; charset=UTF-8" },
      credentials: "include",
      body: JSON.stringify(body ?? {}),
    });
    if (res.status === 401 || res.status === 403) throw signedOut();
    if (!res.ok) throw new Error(`POST ${path} HTTP ${res.status}`);
    return res.json();
  };

  const fetchCustomer = () => getJson("/myaccounts/target/services/common/v2/customer");

  const accountTokenOf = (account: any): string | null => {
    const match = String(account?.additionalParam ?? "").match(/(?:^|[?&])adx=([0-9a-f]{64})(?:&|$)/i);
    return match?.[1] ?? null;
  };

  const extractAccounts = (customer: any) => {
    const accounts = Array.isArray(customer?.accounts?.personal) ? customer.accounts.personal : [];
    return accounts.flatMap((account: any) => {
      const accountToken = accountTokenOf(account);
      if (!accountToken) return [];
      const name = String(account?.accountDisplayName ?? account?.accountFullName ?? "").trim() || null;
      const mask = name?.match(/(\d{4})\s*$/)?.[1] ?? null;
      return [{
        accountToken,
        name,
        mask,
        balance: account?.balance == null ? null : String(account.balance).trim(),
      }];
    });
  };

  const fetchAccounts = async () => extractAccounts(await fetchCustomer());

  const paymentActivityFilters = async (): Promise<any> =>
    getJson("/ogateway/payment-activity/api/v3/activityfilterinput");

  const requireToken = (accountToken: unknown): string => {
    const t = String(accountToken ?? "").trim();
    if (!/^[0-9a-f]{64}$/.test(t)) throw new Error("accountToken must be a 64-char hex account token from listAccounts");
    return t;
  };

  action("getPayTransferUrl", {
    async invoke() {
      return { url: PAY_TRANSFER_URL };
    },
  });

  action("getSignInUrl", {
    async invoke() {
      return { url: SIGNON_URL };
    },
  });

  action("getSignInState", {
    async invoke() {
      const profile = (await fetchCustomer())?.profile;
      const signedIn = Boolean(profile?.name?.first || profile?.name?.full);
      log(`bofa getSignInState signedIn=${signedIn}`);
      return { signedIn };
    },
  });

  action("listAccounts", {
    async invoke() {
      const items = await fetchAccounts();
      log(`bofa listAccounts count=${items.length}`);
      if (!items.length) throw new Error("No accounts found; session may be signed out");
      return { items, nextCursor: null };
    },
  });

  action("getAccount", {
    async invoke({ accountToken } = {} as any) {
      const token = requireToken(accountToken);
      const account = (await fetchAccounts()).find((candidate: { accountToken: string }) =>
        candidate.accountToken === token
      );
      if (!account) throw new Error("Account not found for that token; rerun listAccounts");
      log("bofa getAccount found=true");
      return account;
    },
  });

  const mapPaymentFilterAccount = (account: any) => ({
    identifier: String(account?.identifier ?? ""),
    displayName: account?.displayName ?? null,
    accountName: account?.accountName ?? null,
    activityTypes: Array.isArray(account?.activityTypes)
      ? account.activityTypes.map((value: unknown) => String(value))
      : [],
  });

  action("getPaymentActivityFilters", {
    async invoke() {
      const data = await paymentActivityFilters();
      const fromAccounts = Array.isArray(data?.fromAccounts)
        ? data.fromAccounts.map(mapPaymentFilterAccount).filter((account: any) => account.identifier)
        : [];
      const toAccounts = Array.isArray(data?.toAccounts)
        ? data.toAccounts.map(mapPaymentFilterAccount).filter((account: any) => account.identifier)
        : [];
      const strings = (value: unknown) => Array.isArray(value) ? value.map(String) : [];
      log(`bofa getPaymentActivityFilters from=${fromAccounts.length} to=${toAccounts.length}`);
      return {
        fromAccounts,
        toAccounts,
        statuses: strings(data?.statuses),
        dateOptions: strings(data?.dateOptions),
        activityTypes: strings(data?.activityTypes),
        fromDate: data?.fromDate ?? null,
        toDate: data?.toDate ?? null,
      };
    },
  });

  const selectedParticipants = (
    identifiers: unknown,
    accounts: any[],
    label: string,
  ): Array<{ identifier: string; activityTypes: string[] }> => {
    if (!Array.isArray(identifiers)) return [];
    return identifiers.map((value) => {
      const identifier = String(value);
      const account = accounts.find((candidate) => String(candidate?.identifier) === identifier);
      if (!account) throw new Error(`${label} account identifier is not available; rerun getPaymentActivityFilters`);
      return {
        identifier,
        activityTypes: Array.isArray(account.activityTypes) ? account.activityTypes.map(String) : [],
      };
    });
  };

  const mapPaymentActivity = (item: any) => ({
    id: item?.instructionId ?? null,
    confirmationNumber: item?.confirmationNumber ?? null,
    source: item?.sourceAccount?.accountDisplayName ?? item?.sourceAccount?.displayName ?? null,
    target: item?.targetAccount?.accountDisplayName ?? item?.targetAccount?.displayName ?? null,
    amount: typeof item?.amount === "number" ? item.amount : null,
    status: item?.status ?? null,
    type: item?.transactionType ?? null,
    direction: item?.direction ?? null,
    transactionDate: item?.transactionDate ?? null,
    createdAt: item?.creationDate ?? null,
    updatedAt: item?.lastUpdatedDate ?? null,
    category: item?.category ?? null,
    transferType: item?.transferType ?? null,
    memo: item?.memoText ?? null,
    cancelEligible: typeof item?.cancelEligible === "boolean" ? item.cancelEligible : null,
    editEligible: typeof item?.editEligible === "boolean" ? item.editEligible : null,
    approveEligible: typeof item?.approveEligible === "boolean" ? item.approveEligible : null,
  });

  action("listPaymentActivities", {
    async invoke({
      cursor,
      limit,
      timeframe = "DEFAULTDAYS",
      fromDate,
      toDate,
      fromAccountIdentifiers,
      toAccountIdentifiers,
      keyword,
      minimumAmount,
      maximumAmount,
      activityTypes,
      statuses,
    } = {} as any) {
      if (timeframe === "CUSTOMDATE" && (!fromDate || !toDate)) {
        throw new Error("CUSTOMDATE requires fromDate and toDate");
      }
      const page = pageCursor(cursor, 1);
      const pageSize = limit == null ? "" : Math.max(1, Math.min(Number(limit) || 100, 100));
      const dateFilter = {
        timeframeForHistory: String(timeframe),
        ...(timeframe === "CUSTOMDATE" ? { fromDate: String(fromDate), toDate: String(toDate) } : {}),
      };
      const hasAccountFilters = Array.isArray(fromAccountIdentifiers) && fromAccountIdentifiers.length > 0
        || Array.isArray(toAccountIdentifiers) && toAccountIdentifiers.length > 0;
      const options = hasAccountFilters ? await paymentActivityFilters() : null;
      const sourceParticipants = selectedParticipants(
        fromAccountIdentifiers,
        Array.isArray(options?.fromAccounts) ? options.fromAccounts : [],
        "From",
      );
      const targetParticipants = selectedParticipants(
        toAccountIdentifiers,
        Array.isArray(options?.toAccounts) ? options.toAccounts : [],
        "To",
      );
      const trimmedKeyword = String(keyword ?? "").trim();
      const selectedActivityTypes = Array.isArray(activityTypes) ? activityTypes.map(String) : [];
      const selectedStatuses = Array.isArray(statuses) ? statuses.map(String) : [];
      const amountFilter = {
        ...(Number(minimumAmount) > 0 ? { startingAmount: Number(minimumAmount) } : {}),
        ...(Number(maximumAmount) > 0 ? { endingAmount: Number(maximumAmount) } : {}),
      };
      const hasFilters = timeframe !== "DEFAULTDAYS"
        || Boolean(fromDate || toDate || trimmedKeyword)
        || sourceParticipants.length > 0
        || targetParticipants.length > 0
        || Object.keys(amountFilter).length > 0
        || selectedActivityTypes.length > 0
        || selectedStatuses.length > 0;
      const filterV1 = {
        dateFilter,
        ...(sourceParticipants.length ? { sourceParticipantFilter: { sourceParticipants } } : {}),
        ...(targetParticipants.length ? { targetParticipantFilter: { targetParticipants } } : {}),
        ...(trimmedKeyword ? { keywordFilter: { keyword: trimmedKeyword } } : {}),
        ...(Object.keys(amountFilter).length ? { amountFilter } : {}),
        ...(selectedActivityTypes.length ? { activityTypeFilter: { activityTypes: selectedActivityTypes } } : {}),
        ...(selectedStatuses.length ? { statusFilter: { statuses: selectedStatuses } } : {}),
        ...(hasFilters ? { activityRequestFrom: "FILTER" } : {}),
      };
      const data = await postJson("/ogateway/payment-activity/api/v4/activity", {
        filterV1,
        sortCriteriaV1: { fieldName: "DATE", order: "DESCENDING" },
        pageInfo: { pageNum: page, pageSize },
        ...(hasFilters || cursor || limit != null ? { requestSection: "HISTORY" } : {}),
      });
      const items = Array.isArray(data?.completedTransactions)
        ? data.completedTransactions.map(mapPaymentActivity)
        : [];
      const numberOfPages = Number(data?.pageInfo?.numberOfPages) || page;
      const nextCursor = page < numberOfPages ? String(page + 1) : null;
      log(`bofa listPaymentActivities page=${page} count=${items.length} next=${nextCursor != null}`);
      return { items, nextCursor };
    },
  });

  const txnsOf = (data: any): any[] => {
    const payload = data?.payload ?? {};
    for (const k of Object.keys(payload)) {
      const list = payload[k]?.transactionList?.transactions;
      if (Array.isArray(list)) return list;
    }
    return [];
  };

  const mapTxn = (t: any) => ({
    date: t?.formattedTxnDate ?? null,
    description: t?.preferredDescription ?? t?.customizedDescription ?? null,
    amount: t?.amount?.amount ?? null,
    displayAmount: t?.amount?.displayAmount ?? null,
    type: t?.transactionType?.code ?? null,
    status: t?.status?.value ?? null,
    runningBalance: t?.actualRunningBalanceAmount?.amount ?? null,
    transactionToken: t?.transactionToken ?? null,
  });

  action("listTransactions", {
    async invoke({ accountToken, limit = 50 } = {} as any) {
      const token = requireToken(accountToken);
      const count = Math.max(1, Math.min(Number(limit) || 50, 100));
      const data = await postJson("/ogateway/addapi/v1/activity", {
        payload: { accountToken: token },
        pagingRules: { pagingRequestedItemCount: count },
      });
      const items = txnsOf(data).map(mapTxn);
      log(`bofa listTransactions count=${items.length}`);
      return { items, nextCursor: null };
    },
  });

  const mapStatement = (s: any) => ({
    docId: s?.docId ?? null,
    name: s?.docDisplayName ?? null,
    date: s?.dateString ?? null,
    category: s?.docCategory ?? null,
    docTypeId: s?.docTypeId ?? null,
  });

  action("listStatements", {
    async invoke({ accountToken, year } = {} as any) {
      const token = requireToken(accountToken);
      const data = await postJson("/ogateway/dsviewdocuments/omni/statements/v1/gatherDocuments", {
        adx: token,
        year: String(year ?? new Date().getFullYear()),
        docCategoryId: "DISPFLD001",
        lang: "en-US",
      });
      const docs = Array.isArray(data?.documentList) ? data.documentList : [];
      log(`bofa listStatements docs=${docs.length}`);
      return { items: docs.map(mapStatement), nextCursor: null };
    },
  });

  action("getSpending", {
    async invoke() {
      const data = await postJson("/myaccounts/omni/spending/v4/category-domain", {});
      const source = Array.isArray(data?.payload)
        ? data.payload
        : Array.isArray(data?.categories)
          ? data.categories
          : Object.values(data?.payload ?? data ?? {}).filter((value) => value && typeof value === "object");
      const categories = source.map((category: any) => ({
        name: category?.categoryName ?? category?.name ?? category?.label ?? null,
        amount: category?.amount?.amount ?? category?.amount ?? category?.totalAmount ?? null,
        displayAmount: category?.amount?.displayAmount ?? category?.displayAmount ?? null,
        percentage: category?.percentage ?? category?.percent ?? null,
      }));
      log(`bofa getSpending categories=${categories.length}`);
      return { categories };
    },
  });

  action("listDeals", {
    async invoke() {
      const data = await postJson("/ogateway/rewards-deals/digital/deals/v1/deals-info", {
        pageId: "global",
      });
      const map = data?.locationDealsMap ?? {};
      const items = Object.values(map).flatMap((loc: any) =>
        Array.isArray(loc?.deals) ? loc.deals : [],
      ).map((deal: any) => ({
        id: deal?.dealId ?? deal?.id ?? null,
        merchant: deal?.merchantName ?? deal?.merchant?.name ?? null,
        title: deal?.dealTitle ?? deal?.title ?? deal?.name ?? null,
        description: deal?.description ?? deal?.dealDescription ?? null,
        cashBack: deal?.cashBackAmount ?? deal?.rewardAmount ?? deal?.offerValue ?? null,
        expirationDate: deal?.expirationDate ?? deal?.endDate ?? null,
        status: deal?.status ?? null,
      }));
      log(`bofa listDeals deals=${items.length}`);
      return { items, nextCursor: null };
    },
  });
};

export default install;
