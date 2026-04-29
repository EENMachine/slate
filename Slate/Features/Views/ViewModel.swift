//
//  Views/ViewModel.swift
//  Slate
//

import Foundation
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

    private let scheduler: any Scheduling
    private let llm: any LLMClienting

    init(
        scheduler: any Scheduling = SchedulerStub(),
        llm: any LLMClienting = LLMClientStub()
    ) {
        self.scheduler = scheduler
        self.llm = llm
        // TODO(slate-views): register the recurring weekly job and store the next-fire date.
        self.nextScheduled = Self.nextWednesday1030PT(from: .now)
    }

    /// Force-run the weekly report regardless of schedule.
    /// TODO(slate-views): pull stats from each platform adapter, aggregate,
    /// summarize via LLMClient (prompt-cached on the report template),
    /// render PDF + post to a configurable output path.
    func runWeeklyReportNow() async {
        // no-op stub
    }

    /// User adds a link to track.
    /// TODO(slate-views): open a sheet to paste URL → resolve via the appropriate adapter.
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
