# Chat deletion approval

Verify `ox.chat.delete({ id, purpose })` on a numbered QA simulator using only
disposable chats in a local test Profile. Start the matching repository server,
verify `/health`, and build, install, and launch with `sim`. Use `ox vm help
ox.chat.delete` to verify the live contract. Keep screenshots and logs outside
the repository. Record and restore any changed settings and Action policies.

Create two saved disposable chats and record their IDs using `ox chat list`.
Call the function from one chat, targeting the other, with `ox vm call`. Use
`sim` to answer the visible approval sheet.

1. Deny deletion. Verify the target title and ID appear in the prompt, no
   Always allow option appears, the call fails, and the target survives a relaunch.
2. Set the global Action policy to Allow and repeat. The approval sheet must
   still appear. Change the policy to Allow while the sheet is open and verify
   it stays pending. Deny and verify the target remains.
3. Set the deletion Action policy to Block. Verify deletion fails without a
   prompt and the target remains. Restore its policy.
4. Approve deletion. Verify the result reports the target ID and `deleted: true`,
   the target disappears from the sidebar and `ox chat list`, and its directory
   is absent from `ox.fs.list` at `chats/`, including after relaunch. Profile
   artifacts must remain available.
5. Repeat with a target that has a pending save, using the repository save gate
   if necessary. Deletion must wait for the save; releasing it must not resurrect
   the target. Check again after relaunch.
6. Try an invalid ID, a nonexistent UUID, the calling chat's ID, and an ID from
   another Profile. Each must fail without deleting any chat. A Temporary chat
   must not delete a saved chat.
7. Stop the calling execution while approval is pending. Verify no deletion.
   Repeat while switching Profiles before answering; no chat in either Profile
   may be deleted by the stale request.

Report build and test results separately, capture the approval sheet, and note
any unverified cases. Remove only the disposable data created by this test.
