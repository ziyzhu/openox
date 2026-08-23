# Targeted request diagnosis

Read this only when the HAR cannot explain a page-generated request, when a
request changes under different headers, or when a redirect succeeds in the
proxy but fails in page JavaScript.

## Observe page-generated fetches

Hook fetch narrowly through `ox service eval`, then trigger a known
read-only in-SPA interaction:

```js
window.__requestCapture = [];
const matches = /searchBox|batchSearch|\/api\//;
const originalFetch = window.fetch;
window.fetch = function (input, init) {
  const url = String(input);
  if (!matches.test(url)) return originalFetch.apply(this, arguments);
  const record = {
    url: new URL(url, location.href).pathname,
    method: init?.method || "GET",
    headerNames: [...new Headers(init?.headers).keys()],
    bodyType: init?.body == null ? null : typeof init.body,
  };
  window.__requestCapture.push(record);
  return originalFetch.apply(this, arguments).then(async response => {
    const copy = response.clone();
    const text = await copy.text();
    record.response = {
      status: response.status,
      contentType: response.headers.get("content-type"),
      bytes: text.length,
    };
    return response;
  }, error => {
    record.error = String(error);
    throw error;
  });
};
```

Read only structural results:

```bash
ox service eval <domain> --script 'return window.__requestCapture'
```

- Narrow the matcher before installing the hook. Do not record header values,
  bodies, full signed URLs, or response snippets by default.
- Install after load. The hook survives SPA navigation but not a full reload.
- For load-time traffic, use mitmproxy or CDP network events rather than
  broadening the hook.
- Extend to XHR only when required; wrap `open`, `setRequestHeader`, and `send`
  with the same method and secret-handling rules.

## Compare request modes

Capture ordinary navigation first. If existing service code or an observed
page request uses special safe headers, repeat with exactly those headers and
compare status, MIME type, top-level keys, and array lengths. A 200 HTML page
and a 200 JSON data route are different contracts. A 404 or 406 under the
alternate mode proves that the route does not support it.

Treat per-request signatures, CSRF values, nonces, and verification material
as inherited authentication. Do not forge them. Prefer another observed
same-origin route or report that the request cannot become a stable action.

## Diagnose redirects and CORS

For each redirect, record the source status and destination host/path without
the query. Inspect the destination status in mitmproxy separately from the
result seen by page JavaScript.

If mitmproxy records a successful destination but `fetch` rejects, the action
cannot necessarily consume that body. Check CSP, CORS, credentials mode,
content disposition, and whether the destination is an expiring signed URL.
Do not treat proxy visibility as proof that Ox action JavaScript can read
the response, and never persist a signed download query in a replay fixture.
