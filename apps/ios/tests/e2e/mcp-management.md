# MCP connection management

Use a numbered QA simulator with the Mock model and standing approvals disabled
for service creation, update, and deletion. This scenario uses only loopback
fixtures; it needs no account or provider credentials.

Start `bun tooling/canvas-integration-fixture.ts --device ox-qa-5` from the selected
OpenOx checkout. Verify `http://127.0.0.1:8105/health`, then build and launch:

```sh
sim --device ox-qa-5 run ai.oxcraft.bot --project apps/ios/Ox.xcodeproj --scheme ios --env OX_SERVICES_ENDPOINT=http://localhost:8105/repository.git --env OX_DEBUG_ENDPOINT=ws://127.0.0.1:9105 --force
```

Send `92` in a fresh Mock chat. Leave the first approval pending for more than
60 seconds and verify it remains answerable, then choose **Deny** for the steps named “Deny this test
connection” and “Deny this test deletion”; choose **Approve** for the other test
steps. Do not select Always approve. The expected answer is `PASS: 16 MCP
lifecycle checks`. The unavailable endpoint must leave the existing attachment
intact, while a successful endpoint change must detach the old service. Removal
must make its tools unavailable.

To verify persistence, pause at “Reuse existing test connection” after the first
successful create, relaunch the same build, and verify the saved endpoint appears
in Services → MCP. Run `92` again to finish and clean up the connection. Relaunch
once more and verify the fixture endpoints are absent from saved MCP connections.

Capture approval, successful completion, and persistence screenshots outside the
repository. Inspect the fixture logs to confirm denied creation made no MCP
request. Stop the fixture process after verification.
