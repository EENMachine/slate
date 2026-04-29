//
//  TemplateEngine.swift
//  Slate
//
//  Renders generated content (call sheets, view reports) into the
//  EENMACHINES house style. Output formats today: structured Sections
//  + plain text. PDF rendering is parked behind a TODO until we see
//  the real EENMACHINES template (Coordinator open Q, 2026-04-29).
//
//  This is the GENERIC FALLBACK — every artifact carries a "PENDING
//  EENMACHINES TEMPLATE" marker until Ian provides the client's real
//  call sheet doc and we lock formatting.
//

import Foundation

// MARK: - Models

enum TemplateKind: Hashable {
    case callSheet(variant: CallSheetVariant)
    case weeklyViewReport
}

struct TemplateContext: Hashable {
    /// Free-form key-value pairs the template can reference. Missing
    /// keys render as `<TBD>` so the call-sheet UI shows what still
    /// needs to be filled in.
    let values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func value(_ key: String) -> String {
        values[key] ?? "<TBD>"
    }
}

/// One section of a rendered artifact. Maps cleanly to a SwiftUI
/// `Section` in the call-sheet view.
struct TemplateSection: Hashable {
    let heading: String
    let fields: [Field]

    struct Field: Hashable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }
}

struct RenderedArtifact: Hashable {
    let kind: TemplateKind
    /// Branded header line. e.g. `Branding.viewReportHeader` for view
    /// reports. Empty for call sheets — the variant heading carries it.
    let header: String
    let sections: [TemplateSection]
    /// Always non-empty. UI surfaces this prominently until Ian provides
    /// the real EENMACHINES template.
    let pendingNotice: String
    /// Human-readable plaintext rendering, used for clipboard / quick-copy.
    let plainText: String
    /// Optional rendered PDF. Nil until PDF rendering lands.
    let pdf: Data?
}

// MARK: - Protocol

protocol TemplateRendering: Sendable {
    func render(_ kind: TemplateKind, context: TemplateContext) throws -> RenderedArtifact
}

// MARK: - Real generic implementation

/// MVP renderer. Returns a structured `RenderedArtifact` with variant-
/// specific section labels populated from `context`. No LLM in this
/// path — the LLM hookup lands when we have the real EENMACHINES
/// template to anchor against.
struct TemplateEngine: TemplateRendering {
    static let shared = TemplateEngine()

    static let pendingMarker: String = "PENDING EENMACHINES TEMPLATE — generic layout"

    func render(_ kind: TemplateKind, context: TemplateContext) throws -> RenderedArtifact {
        switch kind {
        case .callSheet(let variant):
            return renderCallSheet(variant: variant, context: context)
        case .weeklyViewReport:
            return renderWeeklyViewReport(context: context)
        }
    }

    // MARK: - Call sheets

    private func renderCallSheet(variant: CallSheetVariant, context: TemplateContext) -> RenderedArtifact {
        let sections = variant.templateSections.map { section in
            TemplateSection(
                heading: section.heading,
                fields: section.fields.map { field in
                    TemplateSection.Field(label: field.label, value: context.value(field.contextKey))
                }
            )
        }
        let plainText = formatPlainText(
            title: variant.displayName,
            sections: sections,
            footer: Branding.callSheetFooter
        )
        return RenderedArtifact(
            kind: .callSheet(variant: variant),
            header: variant.displayName,
            sections: sections,
            pendingNotice: Self.pendingMarker,
            plainText: plainText,
            pdf: nil
        )
    }

    // MARK: - Weekly view report

    private func renderWeeklyViewReport(context: TemplateContext) -> RenderedArtifact {
        let sections: [TemplateSection] = [
            TemplateSection(heading: "Headline", fields: [
                .init(label: "Week of",      value: context.value("weekOf")),
                .init(label: "Total views",  value: context.value("totalViews")),
                .init(label: "Top performer", value: context.value("topPerformer")),
            ]),
            TemplateSection(heading: "Per-platform", fields: [
                .init(label: "Mock",         value: context.value("mockPlatformLine")),
            ]),
            TemplateSection(heading: "Notes", fields: [
                .init(label: "Observation",  value: context.value("notes")),
            ]),
        ]
        let plainText = formatPlainText(
            title: "Weekly View Report",
            sections: sections,
            footer: Branding.viewReportHeader
        )
        return RenderedArtifact(
            kind: .weeklyViewReport,
            header: Branding.viewReportHeader,
            sections: sections,
            pendingNotice: "PENDING EENMACHINES TEMPLATE — generic layout",
            plainText: plainText,
            pdf: nil
        )
    }

    // MARK: - Plain-text rendering

    private func formatPlainText(title: String, sections: [TemplateSection], footer: String) -> String {
        var lines: [String] = []
        lines.append(title.uppercased())
        lines.append(String(repeating: "=", count: title.count))
        lines.append("")
        lines.append("\(Self.pendingMarker)")
        lines.append("")
        for section in sections {
            lines.append(section.heading.uppercased())
            lines.append(String(repeating: "-", count: section.heading.count))
            for field in section.fields {
                lines.append("  \(field.label): \(field.value)")
            }
            lines.append("")
        }
        lines.append(footer)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Variant section schema (labels only; values come from context)

extension CallSheetVariant {
    /// Variant-specific section/field structure. Same shape across
    /// variants (Schedule / People / Logistics / Notes) but with
    /// variant-tuned labels so a junket sheet doesn't talk about
    /// "creator pickup" etc.
    struct SectionSpec: Hashable {
        let heading: String
        let fields: [FieldSpec]
    }

    struct FieldSpec: Hashable {
        let label: String
        /// Key into `TemplateContext.values`.
        let contextKey: String
    }

    var templateSections: [SectionSpec] {
        switch self {
        case .junket:    return CallSheetSchemas.junket
        case .press:     return CallSheetSchemas.press
        case .executive: return CallSheetSchemas.executive
        case .social:    return CallSheetSchemas.social
        }
    }
}

private enum CallSheetSchemas {
    static let junket: [CallSheetVariant.SectionSpec] = [
        .init(heading: "Schedule", fields: [
            .init(label: "Date",                  contextKey: "date"),
            .init(label: "Press window",          contextKey: "pressWindow"),
            .init(label: "Talent rotation start", contextKey: "talentRotationStart"),
            .init(label: "Wrap target",           contextKey: "wrapTarget"),
        ]),
        .init(heading: "People", fields: [
            .init(label: "Talent",                contextKey: "talent"),
            .init(label: "Publicist",             contextKey: "publicist"),
            .init(label: "Media outlets",         contextKey: "mediaOutlets"),
            .init(label: "On-camera moderator",   contextKey: "moderator"),
        ]),
        .init(heading: "Logistics", fields: [
            .init(label: "Location",              contextKey: "location"),
            .init(label: "Holding room",          contextKey: "holdingRoom"),
            .init(label: "Glam call",             contextKey: "glamCall"),
            .init(label: "Press kit drop",        contextKey: "pressKitDrop"),
        ]),
        .init(heading: "Notes", fields: [
            .init(label: "Talking points",        contextKey: "talkingPoints"),
            .init(label: "Embargoes",             contextKey: "embargoes"),
        ]),
    ]

    static let press: [CallSheetVariant.SectionSpec] = [
        .init(heading: "Schedule", fields: [
            .init(label: "Date",                  contextKey: "date"),
            .init(label: "Red-carpet open",       contextKey: "redCarpetOpen"),
            .init(label: "Step-and-repeat",       contextKey: "stepAndRepeat"),
            .init(label: "Talent arrival window", contextKey: "talentArrival"),
        ]),
        .init(heading: "People", fields: [
            .init(label: "Talent",                contextKey: "talent"),
            .init(label: "Publicist",             contextKey: "publicist"),
            .init(label: "Press credentials",     contextKey: "pressCredentials"),
            .init(label: "Photo pool",            contextKey: "photoPool"),
        ]),
        .init(heading: "Logistics", fields: [
            .init(label: "Venue",                 contextKey: "venue"),
            .init(label: "Greenroom",             contextKey: "greenroom"),
            .init(label: "Security lead",         contextKey: "securityLead"),
            .init(label: "Photo zone",            contextKey: "photoZone"),
        ]),
        .init(heading: "Notes", fields: [
            .init(label: "Embargo + posting",     contextKey: "embargoAndPosting"),
            .init(label: "Off-record windows",    contextKey: "offRecord"),
        ]),
    ]

    static let executive: [CallSheetVariant.SectionSpec] = [
        .init(heading: "Schedule", fields: [
            .init(label: "Date",                  contextKey: "date"),
            .init(label: "Principal call",        contextKey: "principalCall"),
            .init(label: "Off-record window",     contextKey: "offRecord"),
            .init(label: "Wrap target",           contextKey: "wrapTarget"),
        ]),
        .init(heading: "People", fields: [
            .init(label: "Principal",             contextKey: "principal"),
            .init(label: "Chief of staff",        contextKey: "chiefOfStaff"),
            .init(label: "Comms lead",            contextKey: "commsLead"),
        ]),
        .init(heading: "Logistics", fields: [
            .init(label: "Location",              contextKey: "location"),
            .init(label: "Greenroom",             contextKey: "greenroom"),
            .init(label: "Security",              contextKey: "security"),
            .init(label: "Crew on set",           contextKey: "crewOnSet"),
        ]),
        .init(heading: "Notes", fields: [
            .init(label: "Approved messages",     contextKey: "approvedMessages"),
            .init(label: "No-go topics",          contextKey: "noGoTopics"),
        ]),
    ]

    static let social: [CallSheetVariant.SectionSpec] = [
        .init(heading: "Schedule", fields: [
            .init(label: "Date",                  contextKey: "date"),
            .init(label: "Creator pickup",        contextKey: "creatorPickup"),
            .init(label: "On-camera windows",     contextKey: "onCameraWindows"),
        ]),
        .init(heading: "People", fields: [
            .init(label: "Creator",               contextKey: "creator"),
            .init(label: "Producer",              contextKey: "producer"),
            .init(label: "Minimal crew",          contextKey: "crew"),
        ]),
        .init(heading: "Logistics", fields: [
            .init(label: "Location",              contextKey: "location"),
            .init(label: "Asset deliverables",    contextKey: "assetDeliverables"),
            .init(label: "Platform specs",        contextKey: "platformSpecs"),
            .init(label: "Captions / subs",       contextKey: "captions"),
        ]),
        .init(heading: "Notes", fields: [
            .init(label: "Tone",                  contextKey: "tone"),
            .init(label: "Posting cadence",       contextKey: "postingCadence"),
        ]),
    ]
}

// MARK: - Stub (kept for previews + tests)

struct TemplateEngineStub: TemplateRendering {
    func render(_ kind: TemplateKind, context: TemplateContext) throws -> RenderedArtifact {
        // Delegates to the real engine — the stub exists only so previews
        // and tests can swap it out if they want a hardcoded shape.
        try TemplateEngine.shared.render(kind, context: context)
    }
}
