//
//  APIKeySetupView.swift
//  Slate
//
//  Modal shown at first launch (or any launch where the Anthropic API key
//  isn't in Keychain). Stores the key via `LLMKeychain.saveAPIKey`. Never
//  echoes the key back to the UI after save.
//

import SwiftUI

/// Tracks whether Slate has a usable Anthropic key in Keychain. Owned by
/// `SlateApp` and passed through `@EnvironmentObject` so any view can
/// trigger re-prompt (e.g. an API-rate-limit error path that wants to
/// invalidate and re-collect the key).
@MainActor
final class APIKeyState: ObservableObject {
    @Published var hasKey: Bool

    init() {
        self.hasKey = (try? LLMKeychain.loadAPIKey()) != nil
    }

    /// Re-read the keychain. Useful after the user pastes a key in another
    /// process (rare) or after a forced delete.
    func refresh() {
        hasKey = (try? LLMKeychain.loadAPIKey()) != nil
    }

    func clear() {
        LLMKeychain.deleteAPIKey()
        hasKey = false
    }
}

struct APIKeySetupView: View {
    @EnvironmentObject private var state: APIKeyState
    @Environment(\.dismiss) private var dismiss

    @State private var key: String = ""
    @State private var saveError: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text("Slate uses the Anthropic API for call-sheet drafting and action-item extraction. Paste your API key below — Slate stores it in macOS Keychain, scoped to this app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .font(.body.monospaced())

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Link("Where do I get a key?",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)

                Spacer()

                // "Skip for now" flips the in-memory key gate without persisting
                // anything to Keychain. LLM features will fail at call time with
                // a clear error, but the rest of the UI is fully usable for
                // testing and demoing. The key prompt returns next launch.
                Button("Skip for now") {
                    state.hasKey = true
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save Key")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedKey.isEmpty || isSaving)
            }

            Divider()

            // Branded footer — tasteful per Branding rules.
            HStack {
                EENMACHINESWordmark(style: .footer)
                Spacer()
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connect Anthropic")
                .font(.title2.weight(.semibold))
            Text("Required for \(Branding.appName) to draft call sheets and extract action items.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        let key = trimmedKey
        guard !key.isEmpty else { return }
        isSaving = true
        saveError = nil
        do {
            try LLMKeychain.saveAPIKey(key)
            state.hasKey = true
            dismiss()
        } catch {
            saveError = "Couldn't save key: \(error)"
        }
        isSaving = false
    }
}

#Preview {
    APIKeySetupView()
        .environmentObject(APIKeyState())
}
