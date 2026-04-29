# Action Items

Hourly Outlook + Teams scrape that surfaces a live to-do list with deadlines and "who to respond to."

## What this folder is right now

A scaffold.

- `View.swift` — bucketed list (Overdue / Today / This Week / Later) with toggle-done rows.
- `ViewModel.swift` — `ActionItem` model + bucketing logic.

## TODO(slate-actions)

1. `Scheduler.scheduleHourly(...)` registers `refreshNow()`.
2. `MailScraper` returns Outlook deltas (since last refresh) + Teams chat deltas.
3. `LLMClient.extractActionItems(messages:)`:
   - **System prompt is the cacheable part** — set `cache_control: ephemeral` on it. The user payload (the new messages) varies per call.
   - Returns: `[ActionItem]`, each with title, respondTo, dueAt, priority bucket, source.
4. Dedupe by Graph message ID. Persist `done` locally so manual completes survive restart.
5. Optional: notification on new high-priority items (separate entitlement, defer until v0.2).
