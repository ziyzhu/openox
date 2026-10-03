# Bundled Public Suffix List

Website resets, cookie diagnostics, and MCP same-site icon URL validation use
`apps/ios/Ox/Host/Services/Web/WebsitePublicSuffixList.swift` with the ICANN and
PRIVATE rules in `apps/ios/Ox/Resources/PublicSuffixList.bundle`. The bundle is
copied into the iOS app by its file-system-synchronized resource group. There is
no runtime download or Swift package dependency.

The source list is unmodified and licensed under MPL-2.0; the bundle includes its
license and a source notice. The initial snapshot is publicsuffix/list commit
`e1b8015c3b2f0f4f8c18659c2480fc1a22c07b20`, whose 10,239 rules match the removed
swift-psl 1.1.161 resources. The local lookup matched the former package on 30,717
hostnames generated from those rules. Persisted website data and its ownership
boundaries are unchanged.

The lookup uses longest matching rules, wildcard rules, exceptions, and the
implicit `*` rule for unknown suffixes. Foundation converts Unicode list entries
to IDNA ASCII hostnames when loading the list. Callers continue to provide
lowercase, IDNA-encoded hostnames; the website-data coordinator also strips cookie
domain dots and bypasses PSL lookup for IP addresses. Missing resources fail
closed rather than silently using an incomplete list for data deletion.

## Updating the list

Choose and review an explicit commit from <https://github.com/publicsuffix/list>.
Download that revision, not a floating latest URL:

```sh
revision=<reviewed-publicsuffix-list-commit>
curl --fail --location \
  "https://raw.githubusercontent.com/publicsuffix/list/$revision/public_suffix_list.dat" \
  --output apps/ios/Ox/Resources/PublicSuffixList.bundle/public_suffix_list.dat
bun test tooling/public-suffix-list.test.ts
```

Update `NOTICE.txt` with the revision and rule count. Review rule changes for
website-reset scope, especially PRIVATE domains and wildcard exceptions. Retain
the source license header and `LICENSE.txt`. Rebuild/install with `sim` on a free
numbered QA device and verify that website data can still be reset without
clearing an unrelated site. Keep diagnostic artifacts outside the repository.
