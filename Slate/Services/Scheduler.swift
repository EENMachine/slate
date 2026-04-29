//
//  Scheduler.swift
//  Slate
//
//  Cron-style background scheduler. Two known clients today:
//    - Action Items: hourly tick.
//    - Views:        weekly tick on Wed 10:30 AM Pacific.
//
//  Implementation will likely sit on top of Foundation Timers + a wake-up
//  helper that recomputes the next fire after each tick (so DST and sleep
//  cycles don't drift the schedule).
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

/// No-op stub. Replace with a real implementation using Timer + a
/// next-fire calculator (see `ViewsViewModel.nextWednesday1030PT(...)`).
final class SchedulerStub: Scheduling, @unchecked Sendable {
    func schedule(
        _ rule: ScheduleRule,
        action: @escaping @Sendable () async -> Void
    ) -> ScheduledJobToken {
        // TODO(slate-scheduler): real Timer / DispatchSourceTimer wiring.
        ScheduledJobToken(id: UUID())
    }

    func cancel(_ token: ScheduledJobToken) {
        // TODO(slate-scheduler): teardown.
    }
}
