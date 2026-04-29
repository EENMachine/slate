//
//  ActionItems/ViewModel.swift
//  Slate
//

import Foundation
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
    var done: Bool
}

@MainActor
final class ActionItemsViewModel: ObservableObject {
    @Published var items: [ActionItem] = []
    @Published var lastRefreshed: Date?

    private let mail: any MailScraping
    private let scheduler: any Scheduling
    private let llm: any LLMClienting

    init(
        mail: any MailScraping = MailScraperStub(),
        scheduler: any Scheduling = SchedulerStub(),
        llm: any LLMClienting = LLMClientStub()
    ) {
        self.mail = mail
        self.scheduler = scheduler
        self.llm = llm
        // TODO(slate-actions): register hourly tick → refreshNow().
    }

    /// Force-run the scrape regardless of schedule.
    /// TODO(slate-actions): pull last-hour Outlook + Teams deltas via MailScraper,
    /// pass into LLMClient.extractActionItems(...) with **prompt caching on the
    /// extraction system prompt** (it's stable across runs — cache it).
    /// Merge into local list, dedupe by message ID.
    func refreshNow() async {
        // no-op stub
        lastRefreshed = .now
    }

    func markDone(_ id: ActionItem.ID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].done.toggle()
    }
}
