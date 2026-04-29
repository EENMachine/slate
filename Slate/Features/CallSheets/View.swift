//
//  CallSheets/View.swift
//  Slate
//
//  Autonomous call sheet generator.
//  Variants: junket / press / executive / social.
//

import SwiftUI

struct CallSheetsView: View {
    @StateObject private var vm = CallSheetsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            HSplitView {
                sheetList
                    .frame(minWidth: 240, idealWidth: 280)
                preview
                    .frame(minWidth: 480)
            }
        }
        .navigationTitle("Call Sheets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(CallSheetVariant.allCases) { v in
                        Button(v.displayName) { vm.generate(variant: v) }
                    }
                } label: {
                    Label("Generate", systemImage: "wand.and.stars")
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Call Sheets").font(.title2.weight(.semibold))
            Spacer()
            Text("Auto-refreshing from Outlook + Teams")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var sheetList: some View {
        List(selection: $vm.selectedID) {
            Section("Today") {
                if vm.sheets.isEmpty {
                    ContentUnavailableView(
                        "No call sheets yet",
                        systemImage: "doc.text",
                        description: Text("Generate one, or wait for the scraper.")
                    )
                } else {
                    ForEach(vm.sheets) { sheet in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sheet.title).font(.body.weight(.medium))
                            Text(sheet.variant.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(sheet.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var preview: some View {
        Group {
            if let sheet = vm.selectedSheet {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(sheet.title).font(.title.weight(.semibold))
                        Text(sheet.variant.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Divider()
                        Text(sheet.body)
                            .font(.body.monospaced())
                            .textSelection(.enabled)

                        Spacer(minLength: 24)
                        // Branded footer on every generated artifact preview.
                        EENMACHINESWordmark(style: .artifact)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(24)
                }
            } else {
                ContentUnavailableView(
                    "Select a call sheet",
                    systemImage: "doc.text",
                    description: Text("Pick one from the list to preview.")
                )
            }
        }
    }
}

#Preview {
    CallSheetsView()
        .frame(width: 1000, height: 640)
}
