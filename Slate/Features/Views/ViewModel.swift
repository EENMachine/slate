//
//  Views/ViewModel.swift
//  Slate
//

import Foundation
import OSLog
import SwiftUI

enum ViewPlatform: String, Codable, CaseIterable {
    case youtube   = "YouTube"
    case tiktok    = "TikTok"
    case instagram = "Instagram"
    case xTwitter  = "X / Twitter"
    case other     = "Other"
}

struct TrackedContent: Identifiable, Hashable {
    let id: UUID
    let title: String
    let platform: ViewPlatform
    let url: URL?
    let viewCount: Int

    var viewCountFormatted: String {
        viewCount.formatted(.number.notation(.compactName))
    }
}

@MainActor
final class ViewsViewModel: ObservableObject {
    @Published var tracked: [TrackedContent] = []
    @Published var nextScheduled: Date?
    @Published var latestReport: WeeklyViewReport?
    @Published var lastError: String?

    private let scheduler: any Scheduling
    private let llm: any LLMClienting
    private let sources: [any ViewSource]
    private var weeklyToken: ScheduledJobToken?

    private let log = Logger(subsystem: "com.eenmachines.slate", category: "Views")

    init(
        scheduler: any Scheduling = BackgroundActivityScheduler.shared,
        llm: any LLMClienting = AnthropicLLMClient.shared,
        sources: [any ViewSource] = [MockViewSource()]
    ) {
        self.scheduler = scheduler
        self.llm = llm
        self.sources = sources
        self.nextScheduled = Self.nextWednesday1030PT(from: .now)

        self.weeklyToken = scheduler.schedule(.wednesday1030PacificTime) { [weak self] in
            await self?.runWeeklyReportNow()
        }
    }

    deinit {
        if let token = weeklyToken {
            scheduler.cancel(token)
        }
    }

    /// Force-run the weekly report regardless of schedule.
    /// Snapshots every configured `ViewSource`, builds a report, and
    /// pushes it onto `latestReport`. PDF export is parked behind a
    /// TODO until Ian confirms the platform list.
    func runWeeklyReportNow() async {
        var collected: [ViewSnapshot] = []
        for source in sources {
            do {
                let chunk = try await source.snapshot()
                collected.append(contentsOf: chunk)
            } catch {
                lastError = "Source \(source.name) failed: \(error)"
                log.error("Source \(source.name) snapshot failed: \(String(describing: error))")
            }
        }

        let report = WeeklyViewReport(
            id: UUID(),
            generatedAt: .now,
            snapshots: collected
        )
        latestReport = report
        nextScheduled = Self.nextWednesday1030PT(from: .now)

        // Refresh the small `tracked` summary so the existing list view
        // has something to render.
        self.tracked = collected.map { snapshot in
            TrackedContent(
                id: UUID(),
                title: snapshot.title,
                platform: ViewPlatform(rawValue: snapshot.platform) ?? .other,
                url: snapshot.url,
                viewCount: snapshot.viewCount
            )
        }

        log.info("Weekly report: \(collected.count) snapshot(s), total views \(report.totalViews).")
    }

    /// User adds a link to track.
    /// TODO(slate-views): open a sheet to paste URL → resolve via the
    /// appropriate adapter once we have a real platform list.
    func promptForLink() {
        // no-op stub
    }

    // MARK: - Helpers

    /// Compute the next Wed 10:30 AM Pacific from a given moment.
    /// Pacific because the client requested it; we honor DST automatically via TimeZone.
    static func nextWednesday1030PT(from date: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        var components = DateComponents()
        components.weekday = 4   // Sunday=1, so Wednesday=4
        components.hour = 10
        components.minute = 30
        return cal.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }
}
