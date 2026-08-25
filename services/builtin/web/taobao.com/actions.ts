import type { ActionInstaller } from "@openox/service-sdk/action";
import { cookie } from "@openox/service-sdk/action-lib";

const install: ActionInstaller = ({ action, log }) => {
  const ORIGIN = "https://www.taobao.com";

  const cleanText = (v: any) =>
    String(v ?? "").replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
  const httpsUrl = (u: any) => {
    const s = String(u ?? "").trim();
    if (!s) return "";
    if (s.startsWith("//")) return "https:" + s;
    return s.replace(/^http:\/\//, "https://");
  };

  // Taobao signs every mtop request with a `sign` (md5 over the _m_h5_tk token)
  // *and* a `bx-ua` anti-bot token minted by Alibaba's obfuscated baxia JS, which
  // we can't reproduce. The page's own mtop SDK (`window.lib.mtop`) generates
  // both, so we delegate to it rather than forging the request. Detail APIs are
  // gated behind the anti-crawl handshake, hence `antiCreepRequest`.
  const mtop = async (
    api: string, v: string, data: object, method: "request" | "antiCreepRequest" = "request",
  ): Promise<any> => {
    const sdk = (window as any).lib?.mtop;
    if (!sdk?.[method]) throw new Error(`taobao mtop SDK unavailable on ${location.href}`);
    let r: any;
    try {
      r = await sdk[method]({ api, v, data, dataType: "json", type: "GET" });
    } catch (rej: any) {
      throw new Error(`mtop ${api}: ${rej?.ret?.[0] ?? rej?.message ?? JSON.stringify(rej)}`);
    }
    const ret = String(r?.ret?.[0] ?? "");
    if (!/^SUCCESS/i.test(ret)) throw new Error(`mtop ${api}: ${ret || "no ret"}`);
    return r?.data ?? {};
  };

  action("getSignInUrl", { async invoke() { return { url: "https://login.taobao.com" }; } });

  action("getSignInState", {
    async invoke() {
      try {
        return { signedIn: !!cookie("unb") || !!cookie("tracknick") };
      } catch (e: any) {
        log("getSignInState: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  const searchData = (query: string, page: number) => ({
    appId: "34385",
    params: JSON.stringify({
      schemaType: "auction",
      isEnterSrpSearch: "true",
      searchDoorFrom: "srp",
      search_action: "initiative",
      sversion: "13.6",
      style: "list",
      m: "pc",
      page,
      n: 48,
      q: query,
      qSource: "url",
      tab: "all",
      pageSize: 48,
      sort: "_coefp",
    }),
  });

  const mapItem = (it: any) => {
    const id = String(it?.item_id ?? "");
    if (!id) return null;
    return {
      id,
      title: cleanText(it.title),
      price: cleanText(it.priceShow?.price ?? it.price),
      originalPrice: cleanText(it.price),
      sales: cleanText(it.realSales),
      shop: cleanText(it.nick),
      location: cleanText(it.procity),
      image: httpsUrl(it.pic_path),
      url: `https://item.taobao.com/item.htm?id=${id}`,
    };
  };

  action("searchItems", {
    async invoke({ query, cursor, limit = 20 } = {} as any) {
      try {
        if (!query) throw new Error("searchItems requires a query");
        const page = cursor ? parseInt(cursor, 10) || 1 : 1;
        const data = await mtop(
          "mtop.relationrecommend.wirelessrecommend.recommend", "2.0",
          searchData(String(query), page),
        );
        const arr: any[] = Array.isArray(data.itemsArray) ? data.itemsArray : [];
        const items = arr.map(mapItem).filter(Boolean).slice(0, limit);
        if (items.length === 0) throw new Error(`search yielded no items for "${query}"`);
        const totalPage = parseInt(data.mainInfo?.totalPage ?? "0", 10);
        const nextCursor = !totalPage || page < totalPage ? String(page + 1) : null;
        return { items, nextCursor };
      } catch (e: any) {
        log("searchItems: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  const itemIdOf = (input: string) => {
    const m = String(input || "").match(/[?&]id=(\d+)/) || String(input || "").match(/(\d{8,})/);
    return m ? m[1]! : "";
  };

  action("getItem", {
    async invoke({ id } = {} as any) {
      try {
        const itemId = itemIdOf(String(id));
        if (!itemId) throw new Error(`unrecognised item id or url: ${id}`);
        const data = await mtop(
          "mtop.taobao.detail.getdetail", "6.0",
          { itemNumId: itemId, exParams: JSON.stringify({ id: itemId }) },
          "antiCreepRequest",
        );
        const it = data.item || {};
        let price = "";
        try { price = JSON.parse(data.apiStack?.[0]?.value ?? "{}")?.price?.price?.priceText ?? ""; } catch {}
        return {
          id: String(it.itemId ?? itemId),
          title: cleanText(it.title),
          price: cleanText(price),
          favorites: String(it.favcount ?? ""),
          comments: String(it.commentCount ?? ""),
          skuText: cleanText(it.skuText),
          images: (it.images || []).map(httpsUrl).filter(Boolean),
          url: `https://item.taobao.com/item.htm?id=${itemId}`,
        };
      } catch (e: any) {
        log("getItem: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  action("getMe", {
    async invoke() {
      try {
        const d = await mtop("mtop.user.getUserSimple", "1.0", {});
        return {
          userId: String(d.userNumId ?? ""),
          nick: cleanText(d.nick),
          displayNick: cleanText(d.displayNick),
        };
      } catch (e: any) {
        log("getMe: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  action("getCartCount", {
    async invoke() {
      try {
        const d = await mtop("mtop.trade.queryBagCount", "1.0",
          { cartFrom: "main_site", extStatus: 0, netType: 0 });
        return { count: parseInt(String(d.count ?? "0"), 10) || 0 };
      } catch (e: any) {
        log("getCartCount: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  action("isFavorited", {
    async invoke({ id } = {} as any) {
      try {
        const itemId = itemIdOf(String(id));
        if (!itemId) throw new Error(`unrecognised item id or url: ${id}`);
        const d = await mtop("mtop.taobao.mercury.checkCollect", "1.0",
          { ids: JSON.stringify([itemId]), type: "1" });
        return { id: itemId, favorited: !!d.result?.[itemId] };
      } catch (e: any) {
        log("isFavorited: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  const mapQuestion = (q: any) => ({
    question: cleanText(q.questionTitle),
    answerCount: parseInt(String(q.answerCount ?? "0"), 10) || 0,
    answers: (q.topAnswerList || [])
      .map((a: any) => ({ text: cleanText(a.answerTitle), date: cleanText(a.gmtCreateStr) }))
      .filter((a: any) => a.text),
  });

  action("listItemQuestions", {
    async invoke({ id, cursor, limit = 10 } = {} as any) {
      try {
        const itemId = itemIdOf(String(id));
        if (!itemId) throw new Error(`unrecognised item id or url: ${id}`);
        const page = cursor ? parseInt(cursor, 10) || 1 : 1;
        const d = await mtop("mtop.taobao.wdj.list.merge.search", "1.0", {
          itemId, page, pageSize: Math.min(limit, 20),
          type: "mix_group", tagId: "", extraInfo: JSON.stringify({ searchText: "" }),
          ecode: 0, biz: "pc",
        }, "antiCreepRequest");
        const items = (d.questionList || []).map(mapQuestion).slice(0, limit);
        const nextCursor = d.hasNext ? String(page + 1) : null;
        return { items, nextCursor };
      } catch (e: any) {
        log("listItemQuestions: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });
};

export default install;
