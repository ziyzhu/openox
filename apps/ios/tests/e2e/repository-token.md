# Repository proposal personal access token

Use an available numbered QA simulator with its matching debug port.
Build and install with `sim` using bundled services.
Use a verified Local service created through the manage-services workflow and
saved to a Local commit. Never author a service directly for this test.

Ask the Ox chat to propose the saved commit and service domain through
manage-services, and approve the publication prompt. Verify an inline
**GitHub personal access token** card appears in the chat with a secure field
identified by
`repository.github.token`, and no OAuth device code or third-party consent page.
Cancel and verify that no branch or pull request was created.

Repeat and verify **Save and continue** is disabled for an empty value, then
submit a malformed synthetic value. Verify an inline error with the card still editable, with no saved credential or value
in logs or the transcript. Retry and cancel. Submit an invalid synthetic classic token to verify GitHub rejection
and recovery. Never use production tokens in command arguments or fixtures.

Choose **Create token** and verify that GitHub opens the classic token creation
page with `public_repo` scope and the OpenOx description. Return to Ox and verify
that the inline token card is still present and the original proposal is still
pending.
Repeat the browser round trip and verify that only one token card appears.
Submit a malformed synthetic value, retry, then cancel and verify the proposal
ends without publication. When a dedicated test-account token is available,
enter it manually in the secure field and select **Save and continue**. Verify
the pending proposal resumes and creates the expected pull request and author.
Relaunch and verify reuse without another prompt. Revoke the token on GitHub, then verify
that a new proposal prompts for replacement. A temporary network failure must
preserve the saved token.

Keep screenshots outside the repository and exclude credential contents. Remove
test publications and revoke test tokens after testing. Record any checks that
could not run without a test account. Restore changed simulator settings.

While validation is pending, stop the chat and verify that it does not save a
credential or resume publication later. Exercise ordinary **Add Secret** and
**Edit Secret** cards to verify named fields still save and cancel correctly.
For a Canvas proposal, verify the same form appears in a dismissible sheet.
