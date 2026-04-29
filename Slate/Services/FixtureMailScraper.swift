//
//  FixtureMailScraper.swift
//  Slate
//
//  Reads Microsoft-Graph-shaped messages from a JSON file on disk.
//  Used for development and tests until the real `MSGraphMailScraper`
//  lands (blocked on Azure tenant / OAuth client ID — see
//  `Services/MailScraper.swift` for the open question).
//

import Foundation

struct FixtureMailScraper: MailScraping {
    let fixtureURL: URL

    init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    func fetch(_ query: MailScrapeQuery) async throws -> [GraphMessage] {
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var messages = try decoder.decode([GraphMessage].self, from: data)

        // Apply the query filters in code so the fixture file stays small + readable.
        messages = messages.filter { $0.receivedAt > query.since }
        if let needle = query.subjectContains?.lowercased(), !needle.isEmpty {
            messages = messages.filter { ($0.subject ?? "").lowercased().contains(needle) }
        }
        if let channelID = query.teamsChannelID {
            // Naive: the fixture's `to` field carries `#channel-name` for Teams;
            // real Graph uses channel IDs. Good enough for offline dev.
            messages = messages.filter { msg in
                msg.source == .teams && msg.to.contains(channelID)
            }
        }
        return messages.sorted { $0.receivedAt > $1.receivedAt }
    }

    func ensureAuthenticated() async throws {
        // Always authenticated — it's a file.
    }

    /// Convenience: read the bundled fixture under `Tests/Fixtures/Mail/`.
    /// Looks first in the app bundle, then in `Bundle.main`'s parent
    /// (so SwiftUI previews on a Mac dev machine find it).
    static func bundled(_ filename: String) -> FixtureMailScraper? {
        if let url = Bundle.main.url(forResource: filename, withExtension: "json", subdirectory: "Mail") {
            return FixtureMailScraper(fixtureURL: url)
        }
        if let url = Bundle.main.url(forResource: filename, withExtension: "json") {
            return FixtureMailScraper(fixtureURL: url)
        }
        return nil
    }
}
