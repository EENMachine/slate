//
//  CallSheets/ViewModel.swift
//  Slate
//

import Foundation
import SwiftUI

/// The four template variants the client asked for.
enum CallSheetVariant: String, CaseIterable, Identifiable, Codable {
    case junket
    case press
    case executive
    case social

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .junket:    return "Press Junket"
        case .press:     return "Press Event"
        case .executive: return "Executive"
        case .social:    return "Social"
        }
    }
}

struct CallSheet: Identifiable, Hashable {
    let id: UUID
    let title: String
    let variant: CallSheetVariant
    let body: String
    let updatedAt: Date
}

@MainActor
final class CallSheetsViewModel: ObservableObject {
    @Published var sheets: [CallSheet] = []
    @Published var selectedID: CallSheet.ID?

    var selectedSheet: CallSheet? {
        guard let id = selectedID else { return nil }
        return sheets.first { $0.id == id }
    }

    // Wired up by the dependency container later.
    private let mail: any MailScraping
    private let llm: any LLMClienting
    private let templates: any TemplateRendering

    init(
        mail: any MailScraping = MailScraperStub(),
        llm: any LLMClienting = LLMClientStub(),
        templates: any TemplateRendering = TemplateEngineStub()
    ) {
        self.mail = mail
        self.llm = llm
        self.templates = templates
    }

    /// Trigger a new call sheet generation for the chosen variant.
    /// TODO(slate-callsheets): pull recent shoot context from MailScraper,
    /// summarize via LLMClient (with prompt caching on the variant template),
    /// then render via TemplateEngine. Persist in local store.
    func generate(variant: CallSheetVariant) {
        // Placeholder so the UI has something to render in previews.
        let placeholder = CallSheet(
            id: UUID(),
            title: "Untitled \(variant.displayName) — \(Date.now.formatted(date: .abbreviated, time: .omitted))",
            variant: variant,
            body: "// TODO(slate-callsheets): real content\n\nGenerated body will appear here once MailScraper + LLMClient + TemplateEngine are wired up.",
            updatedAt: .now
        )
        sheets.insert(placeholder, at: 0)
        selectedID = placeholder.id
    }

    /// Refresh all open sheets when new mail arrives.
    /// TODO(slate-callsheets): subscribe to Scheduler hourly tick + MailScraper deltas.
    func refresh() async {
        // no-op stub
    }
}
