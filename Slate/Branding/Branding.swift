//
//  Branding.swift
//  Slate
//
//  Single source of truth for app + vendor naming. Touch this file before
//  hard-coding any "Slate" or "EENMACHINES" string elsewhere.
//

import Foundation

enum Branding {
    /// Display name of the app.
    static let appName: String = "Slate"

    /// The client / vendor. Slate is built **by EENMACHINES, for EENMACHINES**.
    static let vendor: String = "EENMACHINES"

    /// Window title — em-dash, not hyphen. Don't "fix" this.
    static let windowTitle: String = "Slate \u{2014} EENMACHINES"

    /// Tagline used on the About panel and report headers.
    static let tagline: String = "An EENMACHINES tool."

    /// Default invisible-watermark payload format. The shoot ID is appended.
    /// Example: `EENMACHINES:SH-20260429-001`
    static func watermarkPayload(shootID: String) -> String {
        "\(vendor):\(shootID)"
    }

    /// Header line for generated weekly view reports.
    static let viewReportHeader: String = "Prepared by EENMACHINES"

    /// Footer line for generated call sheets (default until we see the real
    /// EENMACHINES template — Coordinator, 2026-04-29).
    static let callSheetFooter: String = "EENMACHINES \u{00B7} Slate"
}
