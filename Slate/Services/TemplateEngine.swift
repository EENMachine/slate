//
//  TemplateEngine.swift
//  Slate
//
//  Renders generated content (call sheets, view reports) into the
//  EENMACHINES house style. Output formats today: plain text + PDF.
//
//  We need a sample of the existing client call sheet before we can
//  lock formatting (Coordinator open question, 2026-04-29).
//

import Foundation

// MARK: - Models

enum TemplateKind: Hashable {
    case callSheet(variant: CallSheetVariant)
    case weeklyViewReport
}

struct TemplateContext: Hashable {
    /// Raw key-value pairs the template can reference.
    /// e.g. ["shootTitle": "Project Aurora", "callTime": "06:30"].
    let values: [String: String]
}

struct RenderedArtifact: Hashable {
    let kind: TemplateKind
    let plainText: String
    /// Optional rendered PDF data. Nil until the PDF renderer is wired.
    let pdf: Data?
}

// MARK: - Protocol

protocol TemplateRendering: Sendable {
    /// Render a template kind against a context. Implementations are
    /// responsible for stamping the EENMACHINES branding (header / footer)
    /// per the Branding rules.
    func render(_ kind: TemplateKind, context: TemplateContext) throws -> RenderedArtifact
}

// MARK: - Stub

struct TemplateEngineStub: TemplateRendering {
    func render(_ kind: TemplateKind, context: TemplateContext) throws -> RenderedArtifact {
        // TODO(slate-templates):
        //   - Load the house-style template per kind (need real EENMACHINES sample first).
        //   - Substitute context values.
        //   - Stamp footer with `Branding.callSheetFooter` or header
        //     with `Branding.viewReportHeader` as appropriate.
        //   - Render PDF via PDFKit (`PDFDocument` from an attributed string).
        let placeholder = """
        // TODO(slate-templates): real template for \(String(describing: kind))

        \(Branding.callSheetFooter)
        """
        return RenderedArtifact(kind: kind, plainText: placeholder, pdf: nil)
    }
}
