export const replayCases = [
  {
    "action": "getArticle",
    "name": "article-with-images",
    "args": {
      "url": "https://mp.weixin.qq.com/s/example-article"
    },
    "output": {
      "title": "A Walk Through Spring",
      "accountName": "Example Account",
      "publishedAt": "2026-04-18",
      "summary": "A photo essay about a neighborhood garden.",
      "url": "https://mp.weixin.qq.com/s/example-article",
      "coverImageUrl": "https://mmbiz.qpic.cn/mmbiz_jpg/synthetic-cover/0?wx_fmt=jpeg",
      "content": "The garden reopened after the rain.\n\n[Image 1]\n\nNew leaves appeared along the path.\n\n[Image 2]\n\nVisitors returned before sunset.",
      "images": [
        {
          "index": 1,
          "url": "https://mmbiz.qpic.cn/mmbiz_jpg/synthetic-first/640?wx_fmt=jpeg",
          "alt": null,
          "width": 1280,
          "height": 853
        },
        {
          "index": 2,
          "url": "https://mmbiz.qpic.cn/mmbiz_png/synthetic-second/640?wx_fmt=png",
          "alt": null,
          "width": 960,
          "height": 540
        }
      ]
    }
  },
  {
    "action": "getArticle",
    "name": "unavailable",
    "args": {
      "url": "https://mp.weixin.qq.com/s/unavailable-article"
    },
    "error": "getArticle: article content is unavailable or requires verification"
  }
];
