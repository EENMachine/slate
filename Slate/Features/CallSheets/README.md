# Call Sheets

Autonomous call sheet generator. Watches Outlook + Teams, drafts and continually updates four template variants.

## Variants

- **Press Junket** (`.junket`) — back-to-back press interviews
- **Press Event** (`.press`) — premieres, panels, junket-adjacent
- **Executive** (`.executive`) — high-touch principal-only sheets
- **Social** (`.social`) — short-form / creator-pickup shoots

## What this folder is right now

A scaffold. No real generation yet.

- `View.swift` — sidebar list of sheets + preview pane, generate menu in the toolbar.
- `ViewModel.swift` — `CallSheetsViewModel` with stub deps.

## TODO(slate-callsheets)

1. Wire `MailScraper` to fetch shoot-related threads (subject filters + Teams channel hints).
2. Pass the threads + variant template into `LLMClient.generateCallSheet(...)` with **prompt caching enabled on the template** (it's the long, stable part — cache it).
3. Render output via `TemplateEngine` to match the EENMACHINES house style. **Need a sample of the existing call sheet** before we can lock formatting.
4. Persist to `~/Library/Application Support/Slate/callsheets/` and to local SQLite.
5. Subscribe to the hourly `Scheduler` tick to auto-refresh open sheets when new mail arrives.
6. Footer on every exported artifact: small monochrome `EENMACHINESWordmark(style: .artifact)`.
