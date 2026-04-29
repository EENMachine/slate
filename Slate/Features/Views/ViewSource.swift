//
//  ViewSource.swift
//  Slate
//
//  Generic protocol for "tell me how my videos are doing this week".
//  Concrete platform sources (YouTube Data API, TikTok, Instagram
//  Graph, etc.) implement this — but the platform list is parked on
//  Ian's confirmation. Today the only impl is `MockViewSource`.
//

import Foundation

/// One observation of a single piece of content.
struct ViewSnapshot: Hashable, Codable, Identifiable {
    var id: String { "\(platform):\(title):\(observedAt.timeIntervalSince1970)" }
    let title: String
    /// Free-form platform label set by the source. We don't enum this
    /// because Ian hasn't picked the platform list yet.
    let platform: String
    let url: URL?
    let viewCount: Int
    let likeCount: Int
    let observedAt: Date
}

/// Pull current view counts for the team's tracked content.
protocol ViewSource: Sendable {
    /// Stable, human-readable source name (appears in reports).
    var name: String { get }

    /// Snapshot the source's current numbers. Called once per weekly
    /// report. Implementations should return zero entries on no-data
    /// rather than throw.
    func snapshot() async throws -> [ViewSnapshot]
}

// MARK: - Aggregation helpers

struct WeeklyViewReport: Identifiable, Hashable {
    let id: UUID
    let generatedAt: Date
    let snapshots: [ViewSnapshot]

    /// Sum of `viewCount` across all snapshots.
    var totalViews: Int {
        snapshots.reduce(0) { $0 + $1.viewCount }
    }

    /// Highest-viewing snapshot, or nil if empty.
    var topPerformer: ViewSnapshot? {
        snapshots.max(by: { $0.viewCount < $1.viewCount })
    }

    /// Per-platform totals, sorted DESC by views.
    var perPlatform: [(platform: String, totalViews: Int)] {
        let grouped = Dictionary(grouping: snapshots, by: { $0.platform })
        return grouped
            .map { (platform: $0.key, totalViews: $0.value.reduce(0) { $0 + $1.viewCount }) }
            .sorted { $0.totalViews > $1.totalViews }
    }
}
