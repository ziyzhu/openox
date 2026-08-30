# End-to-end test: add a custom model provider

Test adding and using a custom OpenAI Chat Completions provider through the
visible iOS UI. Exercise the full path from model discovery through an agent
response and persistence across app relaunch. Do not modify repository source or
use a paid external provider.

Use the `sim-cli` and `ox-cli` skills. Work on the user-selected numbered QA
simulator, or `ox-qa-1` when none was selected. Use the matching repository and
debug ports from `tooling/qa-config.ts`. Keep screenshots, request journals,
temporary server code, and diagnostics in a new temporary directory outside the
repository.

## Setup

1. Confirm the simulator exists and is available.
2. Start exactly one repository server for `repositories/builtin` and verify its
   `/health` endpoint before launching the app.
3. Create and start a temporary loopback HTTP server implementing the two OpenAI
   Chat Completions endpoints below. Use a harmless fixed test bearer value and
   never log its raw value.
4. Build the iOS app with `sim`, install it fresh, mark onboarding complete, and
   launch the DEBUG app with the matching repository and debug endpoints. Disable
   iCloud and the built-in mock LLM.

The temporary provider must implement:

- `GET /v1/models`, requiring the test bearer value and returning one model named
  `ox-e2e-model` with `supported_parameters` containing `tools`. Also return one
  model without tool support so the test can verify it is filtered out.
- `POST /v1/chat/completions`, requiring the same bearer value and rejecting a
  request unless its model is `ox-e2e-model`, streaming is enabled, and at least
  one function tool is present. Return a valid SSE Chat Completions stream whose
  final choice has `finish_reason` set to `stop`. Respond with
  `CUSTOM_PROVIDER_RELAUNCH_OK` when the latest user message contains that text;
  otherwise respond with `CUSTOM_PROVIDER_E2E_OK`.

The server's request journal may record the method, path, whether authentication
matched, model, streaming flag, and tool count. It must not record authorization
headers or bearer values.

## User-visible flow

1. Open the current chat's model picker.
2. Open the provider picker and choose Custom provider.
3. Enter `Ox E2E Stub` as the name, the temporary server origin without `/v1` as
   the server URL, and the fixed test bearer value as the API key.
4. Load models. Confirm `ox-e2e-model` becomes selectable and the model without
   tool support does not appear.
5. Save the provider and confirm the current chat switches to it.
6. Send `Reply exactly CUSTOM_PROVIDER_E2E_OK.` through the visible composer.
7. Wait for the completed assistant response and confirm the exact sentinel is
   visible in the transcript.

Use accessibility identifiers discovered from the current accessibility tree.
Prefer the existing `chat.modelPicker`, `chat.modelProvider`,
`chat.modelCustomProviders`, `settings.customProviderName`,
`settings.customProviderURL`, `settings.customProviderKey`,
`chat.modelSelection`, `chat.modelSave`, `chat.input`, and `chat.send`
identifiers when they are present. Do not substitute Host debug commands for the
UI actions under test.

## Assertions

Verify all of the following before declaring the case passed:

- Model discovery requested `/v1/models`, proving that the pathless origin was
  normalized to `/v1`.
- Discovery used the supplied bearer value without exposing it in logs.
- The Host model catalog contains exactly one `Ox E2E Stub` client, with endpoint
  ending in `/v1`, and only the tool-capable `ox-e2e-model` model.
- Chat completion requested `/v1/chat/completions` with the expected model,
  streaming enabled, and a non-empty tools array.
- `ox chat inspect` shows `ox-e2e-model` and the completed sentinel response.
- Ox warning and error logs contain no unexpected failures and no credentials.

Capture a success screenshot and the sanitized request journal in the temporary
evidence directory.

## Relaunch

Keep both local servers running and relaunch the app without reinstalling it.
Confirm the custom provider is rediscovered through a second authenticated
`/v1/models` request and remains present in the Host model catalog with the same
client identity. Send `Reply exactly CUSTOM_PROVIDER_RELAUNCH_OK.` through the
visible composer, require a second successful `/v1/chat/completions` request,
and confirm the new sentinel is visible and complete.

## Failure handling and cleanup

On failure, capture a screenshot, accessibility tree, structured Ox logs, the
sanitized provider journal, and the exact failing boundary. Do not keep retrying
an unchanged interaction.

Before uninstalling, clear the custom client's test credential through the DEBUG
Host if possible. Then uninstall the app, stop the temporary provider and
repository servers, and shut down only the simulator claimed by this test. Leave
all evidence outside the repository. Finish with a concise PASS or FAIL summary,
the verified boundaries, and the evidence paths.
