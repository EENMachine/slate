# Call Sheets

Autonomous call sheet generator. Watches Outlook + Teams, drafts and continually updates four template variants.

## Variants

- **Press Junket** (`.junket`) — back-to-back press interviews
- **Press Event** (`.press`) — premieres, panels, junket-adjacent
- **Executive** (`.executive`) — high-touch principal-only sheets
- **Social** (`.social`) — short-form / creator-pickup shoots

## What this folder does today

Generic template fallback. Each variant has its own labels (Junket → "Press window", Social → "Creator pickup", etc.) but the same Schedule / People / Logistics / Notes section structure. Every artifact is marked **"PENDING EENMACHINES TEMPLATE"** in the UI until Ian shares the client's real call-sheet doc.

- `View.swift` — sidebar list of generated sheets, segmented variant picker across the top of the preview pane, prominent yellow PENDING banner, structured-section preview rendered in SwiftUI. Generate button picks up the current variant from the picker.
- `ViewModel.swift` — `CallSheetsViewModel`. `generateForSelectedVariant()` calls `TemplateEngine.shared.render(.callSheet(variant:), context:)` with a small placeholder context and adds the result to the sheets list. `previewArtifact(for:)` is the empty-state preview used by the picker.
- Section schema lives in `Slate/Services/TemplateEngine.swift` — variant-specific labels in `CallSheetSchemas.junket / .press / .executive / .social`.

## TODO(slate-callsheets)

1. **Need a sample of the existing EENMACHINES call sheet** before we can lock formatting. Until then the generic schema stands.
2. Wire `MailScraper` to fetch shoot-related threads (subject filters + Teams channel hints) once Microsoft Graph integration is available (open Q on Azure tenant).
3. Pass threads + variant template into `LLMClient.generateCallSheet(...)` with **prompt caching enabled on the template** (it's the long, stable part — cache it).
4. Render output via `TemplateEngine` once the real layout is locked. PDF rendering via `PDFKit` lands at the same time.
5. Persist to `~/Library/Application Support/Slate/callsheets/` and to local SQLite.
6. Subscribe to the hourly `Scheduler` tick to auto-refresh open sheets when new mail arrives.
7. Footer on every exported artifact: small monochrome `EENMACHINESWordmark(style: .artifact)` (already present in the SwiftUI preview).
