# Resources

Static assets that ship inside the Slate app bundle.

## `com.eenmachines.slate.weekly.plist`

LaunchAgent that fires the weekly Wed 10:30 AM Pacific view report **even when Slate is quit**. In-process scheduling (via `BackgroundActivityScheduler` in `Services/Scheduler.swift`) covers the case when the app is open; this plist covers the case when it's not.

### Install path (macOS 13+)

Modern install is via `SMAppService.agent(plistName:)`. That API expects the plist to live inside the app bundle at:

```
Slate.app/Contents/Library/LaunchAgents/com.eenmachines.slate.weekly.plist
```

When the app first launches (or via a settings toggle later), call:

```swift
import ServiceManagement

let service = SMAppService.agent(plistName: "com.eenmachines.slate.weekly.plist")
do {
    try service.register()
} catch {
    // Surface to the user — sandbox + signing issues will land here.
}
```

`SMAppService` copies the plist into the user's `~/Library/LaunchAgents/` automatically.

### Build-phase wiring

Update `project.yml` (XcodeGen) so this plist is **copied** (not linked) into the bundle's `Library/LaunchAgents/` subdirectory:

```yaml
targets:
  Slate:
    sources:
      - path: Slate
      # ...
    copySources:
      - path: Resources/com.eenmachines.slate.weekly.plist
        destination: Library/LaunchAgents
```

(That's the conceptual shape — verify XcodeGen syntax against the current XcodeGen docs when the Mac build first runs. Worst case, add a "Copy Files" build phase manually in Xcode.)

### TODOs

- `TODO(slate-scheduler):` build a `SlateWeeklyHelper` target — a small CLI that the LaunchAgent invokes. It should hand off to a running Slate via XPC if available, otherwise launch the main app headlessly with `--run-weekly-report` to generate and email/save the report, then exit.
- `TODO(slate-scheduler):` once the helper exists, update `ProgramArguments` in the plist (currently points at a placeholder path under `/Applications/Slate.app/...`).
- `TODO(slate-scheduler):` confirm timezone behavior on developer's Mac. launchd interprets `StartCalendarInterval` in system local time, NOT in the plist's `TZ` env var. EENMACHINES is in PT so this is fine on their machines.
