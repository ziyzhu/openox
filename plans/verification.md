# Remaining verification

These checks remain from implemented search and Profile import/export work. Their presence does not establish a current failure or authorize destructive testing.

## Service search

- Verify authenticated website searches with fresh execution pages, explicit account selection, pagination, and detail lookup from returned identifiers.
- Verify successful Google search; previous runs reached CAPTCHA and did not bypass it.
- Verify denial and cancellation UI, fresh-setup attachment approvals, and no expansion into private targets.
- Exercise remaining empty-result and changed-markup branches, and real-provider model use of the search contract.
- Evaluate Taobao search opt-in after account-contract verification. Other service opt-ins remain optional expansion, not unfinished core search.
- Audit affected qualified action names, translations, fixtures, and skills before declaring migration complete.

## Profile import and export

- On a disposable physical installation, export to iCloud Drive, independently confirm upload, reinstall, and import. Obtain explicit confirmation before deleting Ox. Repeat import on another device using the same Apple Account.
- Verify large Profiles, active writes, cancellation, low storage, process termination, interrupted publication, and startup recovery.
- Verify corrupt, unsupported, and unsafe archives; unavailable file providers; offline access; and delayed iCloud downloads.
- Preserve conversations, attachments, historical files, skills, memory, and settings; exclude credentials, live sessions, device permissions, and app-wide configuration. Verify original Profile preservation, duplicate names, renewed external permissions, and second-launch stability.
- Confirm imported pending actions and schedules do not execute automatically.
- Establish released-predecessor acceptance using actual build-written backups. Keep private artifacts and diagnostics outside Git.
