//
//  ActionItems/ViewModel.swift
//  Slate
//

import Foundation
import OSLog
import SwiftUI

enum ActionItemPriority: String, CaseIterable, Codable {
    case overdue
    case today
    case thisWeek
    case later

    var label: String {
        switch self {
        case .overdue:  return "Overdue"
        case .today:    return "Today"
        case .thisWeek: return "This Week"
        case .later:    return "Later"
        }
    }
}

enum ActionItemSource: String, Codable {
    case outlook
    case teams

    var label: String {
        switch self {
        case .outlook: return "Outlook"
        case .teams:   return "Teams"
        }
    }

    var systemImage: String {
        switch self {
        case .outlook: return "envelope"
        case .teams:   return "bubble.left.and.bubble.right"
        }
    }
}

struct ActionItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let respondTo: String?
    let dueAt: Date?
    let priority: ActionItemPriority
    let source: ActionItemSource
    /// Graph message ID — used to dedupe across refreshes.
    let sourceMessageID: String
    var done: Bool
}

@MainActor
final class ActionItemsViewModel: ObservableObject {
    @Published var items: [ActionItem] = []
    @Published var lastRefreshed: Date?
    /// Surfaces the most recent refresh error (e.g. missing API key).
    @Published var lastError: String?

    private let mail: any MailScraping
    private let scheduler: any Scheduling
    private let llm: any LLMClienting
    private var hourlyToken: ScheduledJobToken?

    private let log = Logger(subsystem: "com.eenmachines.slate", category: "ActionItems")

    /// Tracks the most recent message-fetch cutoff so subsequent refreshes
    /// only see new messages.
    private var lastFetchSince: Date

    init(
        mail: any MailScraping = ActionItemsViewModel.defaultMailScraper(),
        scheduler: any Scheduling = BackgroundActivityScheduler.shared,
        llm: any LLMClienting = AnthropicLLMClient.shared,
        warmStart: Bool = true
    ) {
        self.mail = mail
        self.scheduler = scheduler
        self.llm = llm
        // First refresh pulls everything from the last 24h.
        self.lastFetchSince = Date().addingTimeInterval(-24 * 60 * 60)

        self.hourlyToken = scheduler.schedule(.hourlyActionItems) { [weak self] in
            await self?.refreshNow()
        }

        // Skip warm-start in SwiftUI previews so the canvas doesn't try
        // to hit the Anthropic API on every refresh.
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        if warmStart && !isPreview {
            Task { [weak self] in
                await self?.refreshNow()
            }
        }
    }

    deinit {
        if let token = hourlyToken {
            scheduler.cancel(token)
        }
    }

    /// Force-run the scrape regardless of schedule.
    func refreshNow() async {
        let now = Date()
        let query = MailScrapeQuery(since: lastFetchSince, subjectContains: nil, teamsChannelID: nil)

        let messages: [GraphMessage]
        do {
            messages = try await mail.fetch(query)
        } catch {
            lastError = "Mail fetch failed: \(error)"
            log.error("Mail fetch failed: \(String(describing: error))")
            return
        }

        guard !messages.isEmpty else {
            lastRefreshed = now
            lastError = nil
            return
        }

        // Skip extraction if we have no LLM key — better than throwing on every tick.
        let hasKey = (try? LLMKeychain.loadAPIKey()) != nil
        guard hasKey else {
            log.notice("Skipping extraction — no Anthropic key in Keychain.")
            lastRefreshed = now
            return
        }

        do {
            let json = try Self.encodeMessagesForLLM(messages)
            let drafts = try await llm.extractActionItems(
                systemPrompt: ActionItemsPrompts.extractionSystemPrompt,
                newMessagesJSON: json
            )
            let mapped = drafts.compactMap { Self.makeActionItem(from: $0) }
            // Dedupe by source message ID.
            let existingIDs = Set(items.map(\.sourceMessageID))
            let fresh = mapped.filter { !existingIDs.contains($0.sourceMessageID) }
            items.append(contentsOf: fresh)
            lastFetchSince = now
            lastRefreshed = now
            lastError = nil
            log.info("Extracted \(fresh.count) new action item(s) from \(messages.count) message(s).")
        } catch {
            lastError = "LLM extraction failed: \(error)"
            log.error("LLM extraction failed: \(String(describing: error))")
        }
    }

    func markDone(_ id: ActionItem.ID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].done.toggle()
    }

    // MARK: - Helpers

    private static func encodeMessagesForLLM(_ messages: [GraphMessage]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys keeps the user-payload bytes deterministic — not
        // strictly required for cache-friendliness (volatile content
        // sits AFTER the cacheable system prompt), but useful for diffs.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(messages)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func makeActionItem(from draft: LLMActionItemDraft) -> ActionItem? {
        guard let priority = ActionItemPriority(rawValue: draft.priority),
              let source = ActionItemSource(rawValue: draft.source) else {
            return nil
        }
        let due: Date? = draft.dueAtISO8601.flatMap { ISO8601DateFormatter().date(from: $0) }
        return ActionItem(
            id: UUID(),
            title: draft.title,
            respondTo: draft.respondTo,
            dueAt: due,
            priority: priority,
            source: source,
            sourceMessageID: draft.sourceMessageID,
            done: false
        )
    }

    /// Default mail scraper — uses the bundled JSON fixture during dev,
    /// which does not require Microsoft Graph auth. Real
    /// `MSGraphMailScraper` lands when Ian provides the Azure tenant /
    /// OAuth client ID (open Q in the scratchpad).
    static func defaultMailScraper() -> any MailScraping {
        if let scraper = FixtureMailScraper.bundled("2026-04-29-inbox") {
            return scraper
        }
        return MailScraperStub()
    }
}
