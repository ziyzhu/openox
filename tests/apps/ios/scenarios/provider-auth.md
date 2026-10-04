# Website model authentication

Use a reserved numbered simulator, its reachable Host, and a sanitized QA
Profile. Rebuild the checkout with sim. Doubao must already be signed out; never
sign out a real account or clear website state to create this condition. Preserve
provider defaults, drafts, Action policies, and credentials. Use temporary chats.

1. Create a temporary Mock chat with ox. Open the model picker and choose Doubao
   Web. Wait for its fresh sign-in probe. Verify the sign-in control is visible,
   website models are hidden, and the selected model remains Mock.
2. Create a temporary chat selecting Doubao Web's default website model through
   ox, simulating an expired session. Verify the early sign-in warning is visible.
3. Enter a disposable draft. Tap Send while signed out. The picker must offer
   sign-in, no user message may be enqueued, and closing the picker must preserve
   the draft. Credential entry is app-only; do not pass secrets through ox.
4. Run `ox --chat <id> chat send 'Reply hello.' --json` against this chat. It must
   fail with a user-facing sign-in instruction, not an internal
   `startModelGeneration` Action error. Inspect Host logs: authentication must be
   denied and no model generation may have been submitted.
5. Switch the chat to Mock through the warning. Verify the warning disappears,
   the blocked draft remains intact, and a fresh Mock submission completes.

Inspect current accessibility IDs rather than guessing coordinates. Capture
picker/warning/recovery screenshots and the CLI outcome outside the repository.
Restore the selected saved chat and any settings changed for setup. State which
assertions ran; this signed-out scenario does not establish a signed-in OAuth
handoff or real-provider generation. Those require a separate authorized run.
