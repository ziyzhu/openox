import "./encoding";
import { URL, URLSearchParams } from "whatwg-url";
import { parseHTML } from "linkedom";
import { Defuddle } from "defuddle/node";

Object.assign(globalThis, { URL, URLSearchParams });

export function extract(html: string, url: string) {
  let markup = 0;
  for (let index = html.indexOf("<"); index !== -1; index = html.indexOf("<", index + 1)) {
    if (++markup > 100_000) throw new Error("HTML document exceeds extraction complexity limits");
  }
  const { document } = parseHTML(html);
  Object.assign(document, { styleSheets: [], URL: url });
  if (document.defaultView) Object.assign(document.defaultView, { getComputedStyle: () => ({ display: "" }) });
  const stack = [{ node: document as unknown as Node, depth: 0 }];
  let nodes = 0;
  while (stack.length) {
    const { node, depth } = stack.pop()!;
    if (++nodes > 100_000 || depth > 256) throw new Error("HTML document exceeds extraction complexity limits");
    for (let child = node.lastChild; child; child = child.previousSibling) stack.push({ node: child, depth: depth + 1 });
  }
  const result = { settled: false, content: "", error: "" };
  void Defuddle(document as unknown as Document, url, { markdown: true, useAsync: false }).then(response => {
    result.content = response.content;
    result.settled = true;
  }, () => {
    result.error = "HTML extraction failed";
    result.settled = true;
  });
  return result;
}
