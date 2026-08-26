# Canvas integration fixtures

These fixtures exercise the generated HTML SDK, native approval and handoff UI,
and production MCP artifact decoding without credentials or purchases. Use a
numbered QA simulator with its matching ports; the commands below use `ox-qa-2`.

Start the repository and fixture MCP endpoint:

```sh
bun run tooling/canvas-integration-fixture.ts --device ox-qa-2
curl --fail http://127.0.0.1:8102/health
```

The command prints a temporary bootstrap profile. Import it with
`bun run sim:bootstrap --device ox-qa-2 --profile <printed-profile>`.
In Services, select the MCP filter and connect `http://127.0.0.1:8102/mcp`.
The server uses the production Herdr artifact handler and permits only workspace
lookup for `canvas-fixture`; other Herdr operations fail. The only supplied file
is `artifacts/canvas-export.txt`.

Start the network fixtures using mitmproxy 12.2.3:

```sh
mitmdump --listen-host 127.0.0.1 --listen-port 7102 \
  --set confdir=/tmp/ox-canvas-integration-ca \
  --set connection_strategy=lazy --set upstream_cert=false --set flow_detail=0 \
  -s tooling/fixtures/canvas-network.py
sim --device ox-qa-2 keychain add-root-cert /tmp/ox-canvas-integration-ca/mitmproxy-ca-cert.pem
```

All requests receive local responses; unmatched requests return 503. No upstream
connection, credential entry, order submission, or charge is needed. Keep the
generated CA and logs outside the repository. Trust this CA only on the QA
simulator; do not reset an existing simulator keychain to remove it.

Build with `sim build --project apps/ios/Ox.xcodeproj --scheme ios` and launch
the resulting app:

```sh
sim run ai.oxcraft.bot --device ox-qa-2 --app <built-app> \
  --env OX_SERVICES_ENDPOINT=http://127.0.0.1:8102/repository.git \
  --env OX_DEBUG_ENDPOINT=ws://127.0.0.1:9102 \
  --env OX_SERVICE_PROXY=http://127.0.0.1:7102 --disable-icloud
```

Open Canvas Integration from Artifacts → All. Verify:

- Sign-in shows a native control and then the fixture page. Completing it resolves
  to `signedIn: true`; dismissing with Done rejects the promise.
- Checkout shows a native Pay control and fixture page; Done cancels. Completion
  currently exposes the Often Dining base-URL mismatch described below. The
  fixture supplies receipt `424242`, with a timestamp one minute ahead to fit
  its minute-resolution parser, for retesting after that contract is repaired.
- Export prompts for approval. Deny rejects; Approve returns metadata and creates
  a temporary `tmp/ox-canvas-<caller>` file with the exact fixture bytes. Closing
  the canvas deletes that directory. Missing file errors must reject without
  creating an output. Closing while approval is pending must cancel the call.
- No chat is created. Use `ox --host ws://127.0.0.1:9102 chat list --json` and
  `ox --host ws://127.0.0.1:9102 logs --grep Canvas` to inspect results.

To repeat handoff tests, request `/canvas-test/reset` on `github.com` and
`oftendining.com` through the fixture proxy. Restarting the proxy also resets its
state. Relaunch the app without `OX_SERVICE_PROXY` after testing, remove the
fixture MCP connection through Services, and stop the fixture processes.

The PSC button preserves a separate existing service failure: completing its
fixture receipt causes `getPaymentState` to report `Can't find variable:
cleanText`. Dismiss the sheet; do not treat the visible receipt as successful
Host completion. Repair service behavior through the repository's Ox
`manage-services` workflow.

Often Dining also cannot complete: `getPaymentUrl` uses the service base URL
`/search.php`, while `getPaymentState` declares `/`. `ServiceFlowSession` rejects
the latter with `base-url-mismatch`. Successful checkout completion remains
unverified; neither fixture should be counted as a passing payment test.

The current canvas UI has no service-output share control. File receipt and
cleanup can be checked through `sim file list` and `sim file pull`; native saving
is not available from the current UI.
