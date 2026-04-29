# Views

Tracks viewership of EENMACHINES content across the internet. The headline cadence is a **Wednesday 10:30 AM Pacific** weekly report.

## What this folder does today

Generic source pipeline + one mock source. The platform list (YouTube Data API, TikTok, Instagram Graph, X, …) is parked on Ian's confirmation, so we don't pick concrete sources without his call.

- `ViewSource.swift` — `ViewSource` protocol (`name` + `snapshot()` returning `[ViewSnapshot]`) and the `WeeklyViewReport` model with derived `totalViews` / `topPerformer` / `perPlatform` computed properties.
- `MockViewSource.swift` — six plausible visual-comms entries (brand teaser, episode shorts, BTS, talent Q&A pickup, launch teaser) across Mock-YouTube / Mock-TikTok / Mock-Instagram / Mock-X. Numbers are deterministic per (week, title) via a tiny FNV-1a hash so reports are stable across reloads.
- `View.swift` + `WeeklyReportView` — SwiftUI report rendering. Headline stats card (Total views / Top performer / Sources), per-platform totals, full snapshot list with view + like counts. Branded EENMACHINES footer. PDF export button stubbed (parked on platform-list confirmation).
- `ViewModel.swift` — `runWeeklyReportNow()` snapshots every configured source, builds a `WeeklyViewReport`, pushes onto `latestReport`. Wired to `BackgroundActivityScheduler.shared` via `.wednesday1030PacificTime` (which now uses a stable identifier — Reviewer's Scheduler nit #2).

## TODO(slate-views)

1. Confirm the platform list with Ian. Once locked: implement concrete `ViewSource` impls per platform (rate limits, OAuth, pagination — all per-source).
2. Live / semi-live counter (optional per the brief). Throttle hard — every-30-minute polling at most.
3. Wire the LLM pass (`LLMClient.generateWeeklySummary(...)` — not yet a helper) to write the prose summary section. System prompt cacheable; per-week stats are the volatile user payload.
4. PDF export via `PDFKit` — render `WeeklyReportView` to a PDFDocument and write to a configurable output path. Header line: `Branding.viewReportHeader` (already used in the SwiftUI render).
5. Local SQLite for time-series so we can chart deltas across weeks.
