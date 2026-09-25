# Repository proposal personal access token

Use an available numbered QA simulator with its matching debug port.
Build and install with `sim` using bundled services.
Use a verified Local service created through the manage-services workflow and
saved to a Local commit. Never author a service directly for this test.

Ask the Ox chat to propose the saved commit and service domain through
manage-services, and approve the publication prompt. Verify the next prompt
is **GitHub personal access token**, with a secure field identified by
`repository.github.token`, and no OAuth device code or third-party consent page.
Cancel and verify that no branch or pull request was created.

Repeat and submit an empty value, then a malformed synthetic value. Verify an
error and **Try Again**, with no saved credential or value in logs. Retry and
cancel. Submit an invalid synthetic classic token to verify GitHub rejection
and recovery. Never use production tokens in command arguments or fixtures.

Choose **Create token** and verify that GitHub opens the classic token creation
page with `public_repo` scope and the OpenOx description. Return and propose
again. When a dedicated test-account token is available, enter it manually in
the secure field. Verify the resulting pull request and author. Relaunch and
verify reuse without another prompt. Revoke the token on GitHub, then verify
that a new proposal prompts for replacement. A temporary network failure must
preserve the saved token.

Keep screenshots outside the repository and exclude credential contents. Remove
test publications and revoke test tokens after testing. Record any checks that
could not run without a test account. Restore changed simulator settings.
