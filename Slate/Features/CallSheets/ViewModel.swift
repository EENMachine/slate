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

/// One generated call sheet. The artifact carries the structured
/// sections so the view doesn't need to re-render from a context dict.
struct CallSheet: Identifiable, Hashable {
    let id: UUID
    let title: String
    let variant: CallSheetVariant
    let artifact: RenderedArtifact
    let updatedAt: Date
}

@MainActor
final class CallSheetsViewModel: ObservableObject {
    @Published var sheets: [CallSheet] = []
    @Published var selectedID: CallSheet.ID?
    @Published var selectedVariant: CallSheetVariant = .junket

    var selectedSheet: CallSheet? {
        guard let id = selectedID else { return nil }
        return sheets.first { $0.id == id }
    }

    private let mail: any MailScraping
    private let llm: any LLMClienting
    private let templates: any TemplateRendering

    init(
        mail: any MailScraping = MailScraperStub(),
        llm: any LLMClienting = LLMClientStub(),
        templates: any TemplateRendering = TemplateEngine.shared
    ) {
        self.mail = mail
        self.llm = llm
        self.templates = templates
    }

    /// Render an empty preview for a given variant — used by the empty-
    /// state UI to show what the variant will look like once filled in.
    func previewArtifact(for variant: CallSheetVariant) -> RenderedArtifact {
        let context = TemplateContext()
        // Force-try is fine here: the generic engine never throws today.
        return (try? templates.render(.callSheet(variant: variant), context: context))
            ?? RenderedArtifact(
                kind: .callSheet(variant: variant),
                header: variant.displayName,
                sections: [],
                pendingNotice: TemplateEngine.pendingMarker,
                plainText: "",
                pdf: nil
            )
    }

    /// Generate a new call sheet of the currently-selected variant.
    /// Today this populates from an empty `TemplateContext` (so every
    /// field is `<TBD>`). Real population from Mail / LLM lands when
    /// Ian provides the EENMACHINES template (open Q).
    func generateForSelectedVariant() {
        let variant = selectedVariant
        let context = sampleContext(for: variant)
        guard let artifact = try? templates.render(.callSheet(variant: variant), context: context) else {
            return
        }
        let sheet = CallSheet(
            id: UUID(),
            title: "Untitled \(variant.displayName) — \(Date.now.formatted(date: .abbreviated, time: .omitted))",
            variant: variant,
            artifact: artifact,
            updatedAt: .now
        )
        sheets.insert(sheet, at: 0)
        selectedID = sheet.id
    }

    /// Refresh all open sheets when new mail arrives.
    /// TODO(slate-callsheets): subscribe to Scheduler hourly tick +
    /// MailScraper deltas. Live update lands once we have the real
    /// EENMACHINES template to anchor against.
    func refresh() async {
        // no-op stub
    }

    // MARK: - Helpers

    /// Returns a small sample-context dictionary so the generated draft
    /// has *something* to look at. Every key is intentionally a
    /// placeholder string starting with `<…>` so it's visually obvious
    /// that the field isn't populated yet — the real fill-in flow waits
    /// on the EENMACHINES template.
    private func sampleContext(for variant: CallSheetVariant) -> TemplateContext {
        let common: [String: String] = [
            "date": Date.now.formatted(date: .complete, time: .omitted),
            "talent":   "<from Outlook thread>",
            "location": "<from location-hold email>",
        ]
        return TemplateContext(common)
    }
}
