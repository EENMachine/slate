# Slate

> *Your production command center.* A native macOS app built **by EENMACHINES, for EENMACHINES** — four production-team superpowers in one window.

## What it does

Four features, one Mac app:

1. **Call Sheets** — autonomously generates and updates call sheets (junket / press / executive / social variants) by scraping Outlook + Teams.
2. **Views** — tracks viewership of EENMACHINES content across the internet. Weekly insight drop every **Wednesday 10:30 AM PT**.
3. **Watermark** — embeds invisible watermarks into video files.
4. **Action Items** — hourly Outlook/Teams scrape that surfaces a live to-do list with deadlines and "who to respond to".

## Repo layout

```
Slate/
  SlateApp.swift              # @main entry, sidebar nav
  Branding/                   # EENMACHINES wordmark + brand constants
  Features/
    CallSheets/               # View + ViewModel + module README
    Views/                    # weekly Wed 10:30 PT report
    Watermark/                # invisible video watermarking
    ActionItems/              # hourly to-do list
  Services/                   # shared protocols (stubs only — see TODOs)
    MailScraper.swift         # MS Graph
    Scheduler.swift           # hourly + Wed 10:30 PT cron
    LLMClient.swift           # Anthropic SDK wrapper, prompt caching on
    TemplateEngine.swift      # call sheet rendering
    MediaPipeline.swift       # FFmpeg + watermark
  Slate.entitlements          # sandbox + network + Mail/Calendar (OAuth TBD)
  Info.plist
project.yml                   # XcodeGen — single source of truth for the Xcode project
```

## Building (on a Mac)

This repo is authored on Windows, so the `.xcodeproj` is **not** committed. Generate it on a Mac:

```sh
brew install xcodegen
xcodegen generate
open Slate.xcodeproj
```

Targets macOS 14+ (Sonoma). SwiftUI only, no UIKit.

## Status

This is the **scaffold** — module boundaries, protocols, and `// TODO(slate-<feature>)` markers. No real logic yet for Microsoft Graph, FFmpeg, or watermark algorithms. See each feature's `README.md` for what comes next.

## More

- Long-form project notes live in **ClaudeBrain** at `Projects/Slate.md` (the `Documentation` agent maintains it).
- Branding rules: tasteful EENMACHINES presence — sidebar footer, About panel, generated-artifact headers/footers, watermark payload. Never bigger than the feature UI.
