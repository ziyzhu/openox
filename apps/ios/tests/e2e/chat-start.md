# Start independent chats

Use `sim` on a free numbered QA simulator and its matching `ox --host` endpoint.
Record the default model and Action policies, temporarily select Mock in Settings,
and restore those settings afterward. Keep captures outside the repository.

1. Verify `ox vm help ox.chat.start` requires `prompt` and `purpose`, accepts an
   optional `title`, and returns only `id`. From a persisted parent, start a child
   with Mock prompt `2`. In the same VM execution, read the child's `chat.json`
   and `turns.jsonl` and list its directory. They must exist immediately, retain
   the supplied title, use the default model, and contain only the child's prompt.
   The selected chat must remain the parent.
2. Read the transcript while the child runs and after completion. Verify the
   agent outcome changes from `running` to `completed`. Check `ox.fs.list`,
   `ox.fs.glob`, and explicit chat-scoped `ox.fs.grep` discover the child.
3. Start a child with Mock prompt `24`, which asks a question. Without answering
   it, read its pending choice from the parent and start another child with `2`.
   The parent's VM must remain usable and the second child must complete. Stop
   the pending child using `ox --chat <id> chat stop`.
4. Start a child with Mock prompt `4` and verify a `failed` outcome. Start another
   with `2`, stop it while running, and verify `cancelled` through `ox.fs`.
5. Reject a missing, empty, whitespace-only, null, or numeric prompt without
   creating a chat. Reject starting a persisted child from a Temporary chat.
6. With the start Action blocked, reject creation. With Ask, deny creation and
   verify no child; approve a fresh attempt and verify exactly one child. Stop
   or switch Profiles while approval is pending and verify no child is created
   in either Profile. Restore the policies.
7. Relaunch the app after completion. Read the unloaded child's metadata and
   transcript through `ox.fs`, verify its result and title survive, then open it
   from the sidebar and continue normally. Existing saved chats must still read.

Report which cases ran. Remove only disposable chats created by the test.
