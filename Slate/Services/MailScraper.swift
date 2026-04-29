//
//  MailScraper.swift
//  Slate
//
//  Microsoft Graph reader. Used by CallSheets and ActionItems to pull
//  Outlook mail + Teams chat deltas. Auth is delegated OAuth via MSAL —
//  see entitlements.plist for the OAuth TODO.
//

import Foundation

// MARK: - Models

struct GraphMessage: Identifiable, Hashable, Codable {
    enum Source: String, Codable { case outlook, teams }

    let id: String          // Graph message ID — used for dedupe.
    let source: Source
    let from: String
    let to: [String]
    let subject: String?
    let body: String
    let receivedAt: Date
    let webURL: URL?
}

struct MailScrapeQuery: Hashable {
    /// Only return messages received after this instant.
    var since: Date
    /// Optional subject substring filter (case-insensitive).
    var subjectContains: String?
    /// Optional Teams channel filter — Graph channel ID.
    var teamsChannelID: String?
}

// MARK: - Protocol

protocol MailScraping: Sendable {
    /// Fetch Outlook + Teams messages matching the query.
    func fetch(_ query: MailScrapeQuery) async throws -> [GraphMessage]

    /// Begin or resume an OAuth session. Throws if the user cancels.
    func ensureAuthenticated() async throws
}

// MARK: - Stub

/// No-op stub used by the scaffolded ViewModels. Replace with a real
/// `MSGraphMailScraper` when the Microsoft Graph integration lands.
struct MailScraperStub: MailScraping {
    func fetch(_ query: MailScrapeQuery) async throws -> [GraphMessage] {
        // TODO(slate-mail): MSAL token → GET /me/messages?$filter=receivedDateTime ge ...
        // and /me/chats/getAllMessages — merge, dedupe, return sorted DESC.
        []
    }

    func ensureAuthenticated() async throws {
        // TODO(slate-mail): MSAL.acquireTokenInteractively(scopes: [
        //   "Mail.Read", "Chat.Read", "ChannelMessage.Read.All"
        // ])
    }
}
