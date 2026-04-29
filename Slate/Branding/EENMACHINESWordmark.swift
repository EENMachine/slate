//
//  EENMACHINESWordmark.swift
//  Slate
//
//  Muted, low-contrast EENMACHINES wordmark. Used in:
//    - sidebar footer (tiny)
//    - About panel
//    - generated-report headers / footers
//
//  Branding rule: tasteful presence only. Never larger than the feature UI.
//

import SwiftUI

struct EENMACHINESWordmark: View {
    enum Style {
        /// Very small, sidebar-bottom usage.
        case footer
        /// Slightly larger, About panel / splash.
        case about
        /// Inline in a printed/exported artifact (call sheet, view report).
        case artifact
    }

    let style: Style

    init(style: Style = .footer) {
        self.style = style
    }

    var body: some View {
        Text(Branding.vendor)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(.secondary)
            .opacity(opacity)
            .accessibilityLabel("EENMACHINES")
    }

    // MARK: - Style mapping

    private var font: Font {
        switch style {
        case .footer:   return .system(size: 9,  weight: .medium, design: .default).smallCaps()
        case .about:    return .system(size: 13, weight: .medium, design: .default).smallCaps()
        case .artifact: return .system(size: 10, weight: .regular, design: .default).smallCaps()
        }
    }

    private var tracking: CGFloat {
        switch style {
        case .footer:   return 1.6
        case .about:    return 2.4
        case .artifact: return 1.8
        }
    }

    private var opacity: Double {
        switch style {
        case .footer:   return 0.55
        case .about:    return 0.75
        case .artifact: return 0.65
        }
    }
}

#Preview("Footer") {
    EENMACHINESWordmark(style: .footer)
        .padding()
}

#Preview("About") {
    VStack(spacing: 8) {
        Text(Branding.appName).font(.largeTitle.weight(.semibold))
        EENMACHINESWordmark(style: .about)
        Text(Branding.tagline).font(.callout).foregroundStyle(.secondary)
    }
    .padding(40)
}
