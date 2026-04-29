//
//  Scheduler.swift
//  Slate
//
//  Cron-style background scheduler. Two known clients today:
//    - Action Items: hourly tick — must fire even when the app isn't focused.
//    - Views:        weekly tick on Wed 10:30 AM Pacific — should ideally
//                    fire even when the app isn't running.
//
//  macOS-native paths (do NOT pattern-match from iOS — macOS has no
//  `BGTaskScheduler`):
//
//    - In-process while the app is open → `NSBackgroundActivityScheduler`
//      for the hourly job. It hands the OS coalescing windows so the
//      system can batch wake-ups across apps to save power. We pass a
//      `tolerance` of ±60s as Reviewer asked.
//
//    - In-process while the app is open → a self-rearming
//      `DispatchSourceTimer` for the weekly job. `NSBackgroundActivityScheduler`
//      is interval-based and can't target a specific calendar instant
//      (Wed 10:30 PT), so we compute the next fire-time from
//      `Calendar.nextDate(...)` and re-arm in the completion handler.
//
//    - Fire even when the app is quit → install a `LaunchAgent` plist at
//      `~/Library/LaunchAgents/com.eenmachines.slate.weekly.plist` with
//      `StartCalendarInterval` set for Wednesday 10:30 in the system
//      local timezone. The plist source lives in the repo at
//      `Resources/com.eenmachines.slate.weekly.plist`. Modern install
//      path is `SMAppService.agent(plistName:)` on macOS 13+ — see
//      `Resources/README.md` for the install dance.
//
//  The `nextWednesday1030PT(from:)` helper at
//  `Slate/Features/Views/ViewsViewModel.swift` is the canonical Calendar math
//  for the weekly job; this file uses the same approach via
//  `nextFireDate(...)` below — keep them in sync if you change one.
//

import Foundation

// MARK: - Models

enum ScheduleRule: Hashable {
    /// Every hour, with a ±60s coalescing tolerance.
    /// `stableKey` is appended to the bundle prefix to form the
    /// `NSBackgroundActivityScheduler` identifier — pass a stable
    /// per-logical-job string (e.g. `"action-items"`) so the OS
    /// activity database doesn't accumulate orphan UUID-suffixed
    /// entries across reboots. Defaults to `nil`, which reverts to the
    /// per-registration UUID identifier.
    case hourly(stableKey: String? = nil)

    /// Every week on `weekday` at `hour:minute` in the given timezone.
    /// `weekday` follows `Calendar.weekday` (Sunday = 1, Wednesday = 4).
    /// Note: `launchd`'s `StartCalendarInterval.Weekday` uses 0–6 with
    /// Wednesday = 3, so the LaunchAgent plist value differs by one.
    /// `stableKey` plays the same role as on `.hourly` — passed in so
    /// the OS doesn't accumulate orphan activity records.
    case weekly(weekday: Int, hour: Int, minute: Int, timeZone: TimeZone, stableKey: String? = nil)
}

extension ScheduleRule {
    /// Convenience: Wednesday 10:30 AM America/Los_Angeles, with a
    /// stable identifier so the OS activity database doesn't grow on
    /// every app launch.
    static var wednesday1030PacificTime: ScheduleRule {
        .weekly(
            weekday: 4,
            hour: 10,
            minute: 30,
            timeZone: TimeZone(identifier: "America/Los_Angeles") ?? .current,
            stableKey: "weekly-view-report"
        )
    }

    /// Convenience: hourly, stably keyed for the action-items refresh.
    static var hourlyActionItems: ScheduleRule {
        .hourly(stableKey: "action-items")
    }
}

struct ScheduledJobToken: Hashable {
    let id: UUID
}

// MARK: - Protocol

protocol Scheduling: Sendable {
    /// Register a recurring job. The closure is dispatched on a background
    /// queue. Returns a token that can be passed to `cancel(_:)`.
    @discardableResult
    func schedule(
        _ rule: ScheduleRule,
        action: @escaping @Sendable () async -> Void
    ) -> ScheduledJobToken

    /// Cancel a previously-scheduled job.
    func cancel(_ token: ScheduledJobToken)
}

// MARK: - Real implementation

/// Real scheduler backed by `NSBackgroundActivityScheduler` (hourly) and
/// `DispatchSourceTimer` (weekly). Use `BackgroundActivityScheduler.shared`
/// from app code; tests can construct their own instance.
///
/// Marked `@unchecked Sendable` because we guard internal state with an
/// `NSLock`. The protocol requires `Sendable`, and the alternative — an
/// actor — would force every call site into async context for what is
/// fundamentally a fire-and-forget registration.
final class BackgroundActivityScheduler: Scheduling, @unchecked Sendable {
    static let shared = BackgroundActivityScheduler()

    /// Reverse-DNS prefix used to namespace `NSBackgroundActivityScheduler`
    /// identifiers. Must match the app bundle ID's prefix or macOS may
    /// reject the registration.
    private let bundlePrefix: String

    /// ±60s coalescing window per Reviewer's nit. Lets the OS batch wake-ups
    /// across apps so we don't drag the laptop out of low-power state every
    /// hour on the dot.
    private let toleranceSeconds: TimeInterval = 60

    private let lock = NSLock()
    private var hourlyActivities: [UUID: NSBackgroundActivityScheduler] = [:]
    private var weeklyTimers: [UUID: DispatchSourceTimer] = [:]
    /// Tokens that have been explicitly cancelled. The weekly timer's
    /// re-arm path consults this set so a fire-then-cancel race can't
    /// resurrect a cancelled token (Reviewer's Scheduler nit #1 on 729b102).
    private var cancelledTokenIDs: Set<UUID> = []

    init(bundlePrefix: String = "com.eenmachines.slate") {
        self.bundlePrefix = bundlePrefix
    }

    @discardableResult
    func schedule(
        _ rule: ScheduleRule,
        action: @escaping @Sendable () async -> Void
    ) -> ScheduledJobToken {
        let token = ScheduledJobToken(id: UUID())

        // Preview-safety short-circuit. SwiftUI canvas renders construct
        // ViewModels with default args, which would register a real
        // `NSBackgroundActivityScheduler` activity (cached in the OS
        // activity database across reboots) every time the canvas
        // refreshes. Detect Xcode previews and hand back an inert token.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return token
        }

        switch rule {
        case .hourly(let stableKey):
            scheduleHourly(token: token, stableKey: stableKey, action: action)
        case let .weekly(weekday, hour, minute, timeZone, stableKey):
            scheduleWeekly(
                token: token,
                weekday: weekday,
                hour: hour,
                minute: minute,
                timeZone: timeZone,
                stableKey: stableKey,
                action: action
            )
        }
        return token
    }

    func cancel(_ token: ScheduledJobToken) {
        lock.lock()
        let activity = hourlyActivities.removeValue(forKey: token.id)
        let timer = weeklyTimers.removeValue(forKey: token.id)
        cancelledTokenIDs.insert(token.id)
        lock.unlock()
        activity?.invalidate()
        timer?.cancel()
    }

    // MARK: - Hourly (NSBackgroundActivityScheduler)

    private func scheduleHourly(
        token: ScheduledJobToken,
        stableKey: String?,
        action: @escaping @Sendable () async -> Void
    ) {
        // Stable identifiers prevent the OS activity database from
        // growing every launch (Reviewer's Scheduler nit #2 on 729b102).
        // If the caller didn't pass a key, fall back to a UUID so two
        // ad-hoc registrations don't trample each other.
        let identifier = stableKey.map { "\(bundlePrefix).hourly.\($0)" }
            ?? "\(bundlePrefix).hourly.\(token.id.uuidString)"
        let activity = NSBackgroundActivityScheduler(identifier: identifier)
        activity.repeats = true
        activity.interval = 60 * 60                      // 1 hour
        activity.tolerance = toleranceSeconds            // ±60s jitter
        activity.qualityOfService = .utility             // power-friendly
        activity.schedule { completion in
            Task.detached {
                await action()
                completion(.finished)
            }
        }
        lock.lock()
        hourlyActivities[token.id] = activity
        lock.unlock()
    }

    // MARK: - Weekly (self-rearming DispatchSourceTimer)

    private func scheduleWeekly(
        token: ScheduledJobToken,
        weekday: Int,
        hour: Int,
        minute: Int,
        timeZone: TimeZone,
        stableKey: String?,
        action: @escaping @Sendable () async -> Void
    ) {
        // Skip if the token was cancelled while we were waiting to
        // re-arm — closes the fire-then-cancel race Reviewer flagged.
        // (Reviewer's Scheduler nit #1 on 729b102.)
        lock.lock()
        if cancelledTokenIDs.contains(token.id) {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let fireDate = Self.nextFireDate(
            weekday: weekday,
            hour: hour,
            minute: minute,
            timeZone: timeZone,
            after: .now
        ) else {
            return
        }
        let interval = max(1, fireDate.timeIntervalSinceNow)

        // Note: `stableKey` is currently informational on the weekly
        // path — `DispatchSourceTimer` has no equivalent of an OS
        // activity-database identifier, so there are no orphan records
        // to worry about. The same `stableKey` lives in the LaunchAgent
        // plist label (`com.eenmachines.slate.weekly`).
        _ = stableKey

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        timer.schedule(
            deadline: .now() + interval,
            leeway: .seconds(Int(toleranceSeconds))
        )
        timer.setEventHandler { [weak self] in
            Task.detached {
                await action()
                // Re-arm for next week — but only if our token wasn't
                // cancelled during the action (or before we got here).
                self?.scheduleWeekly(
                    token: token,
                    weekday: weekday,
                    hour: hour,
                    minute: minute,
                    timeZone: timeZone,
                    stableKey: stableKey,
                    action: action
                )
            }
        }
        lock.lock()
        // Cancel any previous timer under this token (re-arm path).
        weeklyTimers.removeValue(forKey: token.id)?.cancel()
        weeklyTimers[token.id] = timer
        lock.unlock()
        timer.resume()
    }

    /// Compute the next instant matching the given weekday/hour/minute in
    /// the given timezone, strictly after `date`. DST-safe via Foundation's
    /// `Calendar.nextDate(...)`.
    static func nextFireDate(
        weekday: Int,
        hour: Int,
        minute: Int,
        timeZone: TimeZone,
        after date: Date
    ) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        return cal.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }
}

// MARK: - Stub (kept for previews + tests)

/// No-op stub used in SwiftUI previews and unit tests where we don't want
/// real timers firing. Stateless on purpose, so it's safely `Sendable`
/// without `@unchecked`.
struct SchedulerStub: Scheduling {
    func schedule(
        _ rule: ScheduleRule,
        action: @escaping @Sendable () async -> Void
    ) -> ScheduledJobToken {
        ScheduledJobToken(id: UUID())
    }

    func cancel(_ token: ScheduledJobToken) {}
}
