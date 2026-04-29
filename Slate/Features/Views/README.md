# Views

Tracks viewership of EENMACHINES content across the internet. The headline cadence is a **Wednesday 10:30 AM Pacific** weekly report.

## What this folder is right now

A scaffold.

- `View.swift` — list of tracked items, run-now button, schedule indicator.
- `ViewModel.swift` — owns `nextWednesday1030PT(...)` (DST-aware via `America/Los_Angeles`).

## TODO(slate-views)

1. Confirm the platform list with the client. Default working set: YouTube Data API, TikTok, Instagram Graph, X / Twitter.
2. Per-platform adapter inside `Services/` (out of scope for this scaffold).
3. Live / semi-live counter (optional per the brief). Throttle hard — every-30-minute polling at most.
4. Weekly report:
   - Wed 10:30 AM PT via `Scheduler.scheduleWeekly(...)`.
   - Aggregate stats → `LLMClient.summarizeViews(...)` with **prompt caching** on the template.
   - Render PDF. Header line: `Branding.viewReportHeader` + `EENMACHINESWordmark(style: .artifact)`.
5. Local SQLite for time-series so we can chart deltas.
