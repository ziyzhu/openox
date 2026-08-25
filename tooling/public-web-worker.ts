import Defuddle from "defuddle/full";

type WorkerWindow = Window & {
  oxPublicWeb?: {
    version: number;
    extract: (html: string, url: string) => PublicWebExtraction;
  };
};

type PublicWebExtraction = {
  markdown: string;
  title: string;
  author: string;
  description: string;
  published: string;
  site: string;
  wordCount: number;
};

const extract = (html: string, url: string): PublicWebExtraction => {
  const document = new DOMParser().parseFromString(html, "text/html");
  const result = new Defuddle(document, { url, markdown: true }).parse();
  return {
    markdown: result.content,
    title: result.title,
    author: result.author,
    description: result.description,
    published: result.published,
    site: result.site,
    wordCount: result.wordCount,
  };
};

(window as WorkerWindow).oxPublicWeb = { version: 1, extract };
