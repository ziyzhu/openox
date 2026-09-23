# GitHub proposal authorization

Proposing services uses a user-provided GitHub personal access token (classic)
with `public_repo` scope. No OAuth app registration, client ID, or client secret
is required. Fine-grained tokens are not supported by this flow because GitHub
limits their use for contributing to public repositories outside the user's
memberships.

When prompted, choose **Create token**, sign in on GitHub, select an expiration,
and generate a classic token with `public_repo` scope. Return to Ox, propose
again, and paste it into the secure token field. Never paste it into a chat.
Ox validates the account and scope before storing the token in Keychain.
The proposal Action still requires publication approval. An expired or revoked
token prompts for replacement; a temporary network error preserves the token.
To revoke access, delete the token in GitHub Settings → Developer settings →
Personal access tokens → Tokens (classic).

Older proposal OAuth credentials are removed locally at startup and never
reused as personal tokens. Copilot provider authentication remains separate.

Verify cancellation, malformed tokens, missing scope, expired tokens, saved-token
reuse after relaunch, and a successful proposal using a dedicated test account.
Keep tokens out of fixtures, command arguments, screenshots, and diagnostics.

See [GitHub's token documentation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).
