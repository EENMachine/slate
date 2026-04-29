//
//  MockViewSource.swift
//  Slate
//
//  Plausible weekly numbers for a visual-comms team's content. Used in
//  dev runs and previews until Ian confirms the real platform list
//  (YouTube Data API, TikTok, Instagram Graph, X/Twitter, …) and we
//  wire concrete sources.
//
//  The mock is deterministic per (week, title) so a given week's
//  report is stable across reloads — no flakiness in screenshots /
//  manual QA.
//

import Foundation

struct MockViewSource: ViewSource {
    let name: String = "Mock"

    /// Optional override for the "current week" — lets tests pin the
    /// snapshot date. Defaults to .now.
    let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func snapshot() async throws -> [ViewSnapshot] {
        let observedAt = now()
        let weekKey = ISO8601DateFormatter().string(from: observedAt).prefix(10)

        // Hand-curated list — typical visual-comms output: a brand
        // teaser, two episode shorts, a behind-the-scenes piece, and a
        // creator pickup. Numbers are deterministic-but-varied via a
        // simple hash of (week, title).
        let entries: [(title: String, platform: String, basePerf: Int, urlPath: String)] = [
            ("Aurora teaser",                "Mock-YouTube",  120_000, "aurora-teaser"),
            ("Aurora ep.01 short",           "Mock-YouTube",   42_000, "aurora-ep01"),
            ("Aurora ep.01 short",           "Mock-TikTok",    78_000, "aurora-ep01"),
            ("Behind the scenes — wardrobe", "Mock-Instagram", 26_000, "bts-wardrobe"),
            ("Talent Q&A pickup",            "Mock-TikTok",    91_000, "talent-qa"),
            ("Aurora launch teaser",         "Mock-X",          9_500, "aurora-launch"),
        ]

        return entries.map { entry in
            // Tiny deterministic perturbation per week so consecutive
            // weekly reports show plausible deltas.
            let seed = Self.smallHash("\(weekKey)|\(entry.title)|\(entry.platform)")
            let drift = Int(seed % 17_000) - 8_500     // ±8.5k
            let likes = (entry.basePerf + drift) / 24  // ~4% engagement
            let url = URL(string: "https://mock.eenmachines.example/\(entry.urlPath)")
            return ViewSnapshot(
                title: entry.title,
                platform: entry.platform,
                url: url,
                viewCount: max(0, entry.basePerf + drift),
                likeCount: max(0, likes),
                observedAt: observedAt
            )
        }
    }

    /// Tiny FNV-1a-ish hash so the perturbation is deterministic without
    /// pulling in CryptoKit. NOT cryptographically secure — fine for
    /// "vary the mock numbers slightly."
    private static func smallHash(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return h
    }
}
