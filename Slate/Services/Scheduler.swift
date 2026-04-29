//
//  Scheduler.swift
//  Slate
//
//  Cron-style background scheduler. Two known clients today:
//    - Action Items: hourly tick — must fire even when the app isn't focused.
//    - Views:        weekly tick on Wed 10:30 AM Pacific — should ideally
//                    fire even when the app isn't running.
//
//  macOS-native paths to use (do NOT pattern-match from iOS — macOS has no
//  `BGTaskScheduler`):
//
//    - In-process while the app is open → `NSBackgroundActivityScheduler`.
//      Handles power, thermal, and sleep states automatically. Use it for
//      the hourly Action-Items refresh.
//
//    - Fire even when the app is quit → install a `LaunchAgent` plist at
//      `~/Library/LaunchAgents/com.eenmachines.slate.weekly.plist` with a
//      `StartCalendarInterval` entry (Weekday=4, Hour=10, Minute=30) and
//      `EnvironmentVariables` setting the timezone to `America/Los_Angeles`.
//      Use it for the weekly Wed 10:30 PT report so the report fires
//      whether or not Slate is running.
//
//  The `nextWednesday1030PT(from:)` helper at
//  `Slate/Features/Views/ViewModel.swift` is the right way to compute the
//  next fire-time when we need it in-process — keep it as the single source
//  of truth and avoid duplicating the Calendar math here.
//

import Foundation

// MARK: - Models

enum ScheduleRule: Hashable {
    /// Every hour, on the hour.
    case hourly
    /// Every week on `weekday` at `hour:minute` in the given timezone.
    /// `weekday` follows `Calendar.weekday` (Sunday = 1).
    case weekly(weekday: Int, hour: Int, minute: Int, timeZone: TimeZone)
}

extension ScheduleRule {
    /// Convenience: Wednesday 10:30 AM America/Los_Angeles.
    static var wednesday1030PacificTime: ScheduleRule {
        .weekly(
            weekday: 4,
            hour: 10,
            minute: 30,
            timeZone: TimeZone(identifier: "America/Los_Angeles") ?? .current
        )
    }
}

struct ScheduledJobToken: Hashable {
    let id: UUID
}

// MARK: - Protocol

protocol Scheduling: Sendable {
    /// Register a recurring job. The closure is dispatched on a background actor.
    /// Returns a token for cancellation.
    @discardableResult
    func schedule(
        _ rule: ScheduleRule,
        action: @escaping @Sendable () async -> Void
    ) -> ScheduledJobToken

    /// Cancel a previously-scheduled job.
    func cancel(_ token: ScheduledJobToken)
}

// MARK: - Stub

/// No-op stub. Replace with a real implementation backed by
/// `NSBackgroundActivityScheduler` (in-process) plus a `LaunchAgent` plist
/// for the weekly job (see the file header).
///
/// Stateless on purpose, so it's safely `Sendable` without `@unchecked`.
struct SchedulerStub: Scheduling {
    func schedule(
        _ rule: ScheduleRule,
        action: @escaping @Sendable () async -> Void
    ) -> ScheduledJobToken {
        // TODO(slate-scheduler): real wiring per the macOS-native paths
        // documented in the file header.
        ScheduledJobToken(id: UUID())
    }

    func cancel(_ token: ScheduledJobToken) {
        // TODO(slate-scheduler): teardown.
    }
}
