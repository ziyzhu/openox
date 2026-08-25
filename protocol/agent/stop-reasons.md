# Stop Reasons

Status: Draft. The categories below are design targets, not version 1 encoded values.

A generation ends with an explicit outcome. The portable categories are
completed, cancelled, failed, context exhausted, and awaiting user input.

Provider-specific finish reasons are diagnostics. A Host maps them to the
portable outcome while retaining enough local detail for troubleshooting.
Incomplete streaming output must not be presented as a completed generation.
