# Service Icon

Every newly authored customer-facing web or API service needs a verified product `faviconUrl` before attachment or reload. For API services, discover artwork on the official product website; the API identifier need not be a hostname. Preserve an existing verified icon unless broken or the user requests replacement. This requirement does not apply to model-provider configuration.

1. Prefer official artwork from page icon links or a linked web-app manifest. Use a stable public HTTPS URL without credentials, signatures, or expiration.
2. Fetch anonymously and confirm it decodes as PNG, JPEG, or ICO; SVG is unsupported. Prefer a square image at least 128×128. Reject failed responses, blank images, generic placeholders, and unrelated marks. Try the best candidate first and stop when it passes.
3. Set the verified URL in the final manifest before normal service validation and attachment. Manifest validation is not image-loading evidence; no post-apply avatar inspection or screenshot is required. Preflight any replacement before reloading.

If none passes, preserve the draft and existing attachment, do not attach or reload, and report the favicon blocker.

When official candidates fail, Google's cache is a last fallback unless the user prohibits third-party icon requests:

```text
https://www.google.com/s2/favicons?domain_url=<percent-encoded-public-origin>&sz=128&alt=404
```

Submit only the public product origin, stripping credentials, path, query, and fragment. This discloses that origin to Google. Apply the same checks; `sz=128` does not prove returned dimensions.
