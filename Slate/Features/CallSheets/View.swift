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
                    .frame(minWidth: 540)
            }
        }
        .navigationTitle("Call Sheets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.generateForSelectedVariant()
                } label: {
                    Label("Generate \(vm.selectedVariant.displayName)", systemImage: "wand.and.stars")
                }
                .help("Add a new \(vm.selectedVariant.displayName) call sheet to the list.")
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
                        description: Text("Pick a variant on the right and click Generate.")
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
        VStack(spacing: 0) {
            // Variant tabs across the top of the preview pane. Same
            // layout for each variant — only the labels differ.
            Picker("Variant", selection: $vm.selectedVariant) {
                ForEach(CallSheetVariant.allCases) { v in
                    Text(v.displayName).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // PENDING banner — prominent until Ian provides the real template.
            pendingBanner
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ScrollView {
                if let sheet = vm.selectedSheet, sheet.variant == vm.selectedVariant {
                    artifactView(sheet.artifact)
                } else {
                    artifactView(vm.previewArtifact(for: vm.selectedVariant))
                }
            }
        }
    }

    private var pendingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(TemplateEngine.pendingMarker)
                    .font(.caption.weight(.semibold))
                Text("Generic section labels shown below. Real EENMACHINES formatting locks in once Ian shares the client's template.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.yellow.opacity(0.18))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func artifactView(_ artifact: RenderedArtifact) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(artifact.header)
                    .font(.title.weight(.semibold))
                if case .callSheet(let v) = artifact.kind {
                    Text(v.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(artifact.sections, id: \.heading) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.heading.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.0)
                    Divider()
                    ForEach(section.fields) { field in
                        HStack(alignment: .firstTextBaseline) {
                            Text(field.label)
                                .frame(width: 170, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(field.value)
                                .foregroundStyle(field.value == "<TBD>" ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                        .font(.body)
                    }
                }
            }

            Divider().padding(.vertical, 8)

            // Branded footer — tasteful per Branding rules.
            HStack {
                Spacer()
                EENMACHINESWordmark(style: .artifact)
                Spacer()
            }
        }
        .padding(24)
    }
}

#Preview {
    CallSheetsView()
        .frame(width: 1100, height: 700)
}
