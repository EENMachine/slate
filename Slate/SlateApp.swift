//
//  SlateApp.swift
//  Slate — an EENMACHINES tool
//
//  App entry point. Owns the single main window and the sidebar navigation
//  that switches between the four feature modules.
//

import SwiftUI

@main
struct SlateApp: App {
    /// Shared key state. Drives the API-key setup sheet and exposes
    /// `clear()` so any view can invalidate and re-prompt.
    @StateObject private var keyState = APIKeyState()

    var body: some Scene {
        WindowGroup(Branding.windowTitle) {
            RootView()
                .frame(minWidth: 980, minHeight: 640)
                .environmentObject(keyState)
                .sheet(isPresented: .init(
                    get: { !keyState.hasKey },
                    set: { _ in /* dismissal happens via keyState.hasKey flip */ }
                )) {
                    APIKeySetupView()
                        .environmentObject(keyState)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            // Replace the default About panel with one that shows the EENMACHINES wordmark.
            CommandGroup(replacing: .appInfo) {
                Button("About \(Branding.appName)") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: Branding.appName,
                        .credits: NSAttributedString(
                            string: "An \(Branding.vendor) tool.",
                            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
                        )
                    ])
                }
            }
            // Settings menu: re-prompt for API key (delete + show sheet).
            CommandGroup(after: .appInfo) {
                Button("Reset Anthropic API Key…") {
                    keyState.clear()
                }
            }
        }
    }
}

// MARK: - Root navigation

/// The four sidebar destinations. One per feature module.
enum SlateDestination: String, CaseIterable, Identifiable, Hashable {
    case callSheets   = "Call Sheets"
    case views        = "Views"
    case watermark    = "Watermark"
    case actionItems  = "Action Items"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .callSheets:  return "doc.text.fill"
        case .views:       return "chart.line.uptrend.xyaxis"
        case .watermark:   return "drop.fill"
        case .actionItems: return "checklist"
        }
    }
}

struct RootView: View {
    @State private var selection: SlateDestination = .callSheets

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Modules") {
                    ForEach(SlateDestination.allCases) { dest in
                        Label(dest.rawValue, systemImage: dest.systemImage)
                            .tag(dest)
                    }
                }
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)

            // Tasteful EENMACHINES presence — small, low-contrast, never shouting.
            EENMACHINESWordmark(style: .footer)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .callSheets:   CallSheetsView()
        case .views:        ViewsView()
        case .watermark:    WatermarkView()
        case .actionItems:  ActionItemsView()
        }
    }
}
