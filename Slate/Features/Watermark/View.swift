//
//  Watermark/View.swift
//  Slate
//
//  Invisible video watermarking.
//

import SwiftUI
import UniformTypeIdentifiers

struct WatermarkView: View {
    @StateObject private var vm = WatermarkViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputCard
                    payloadCard
                    queueCard
                }
                .padding(20)
            }
        }
        .navigationTitle("Watermark")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.runQueue() }
                } label: {
                    Label("Process Queue", systemImage: "play.fill")
                }
                .disabled(vm.queue.isEmpty)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Watermark").font(.title2.weight(.semibold))
            Spacer()
            Text("Invisible \u{00B7} default payload: \(Branding.watermarkPayload(shootID: "<shootID>"))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var inputCard: some View {
        GroupBox("Input") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Drop video files here, or click to choose.")
                    .foregroundStyle(.secondary)
                Button("Choose Files…") { vm.chooseFiles() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var payloadCard: some View {
        GroupBox("Payload") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Shoot ID") {
                    TextField("SH-YYYYMMDD-NNN", text: $vm.shootID)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                LabeledContent("Payload") {
                    Text(Branding.watermarkPayload(shootID: vm.shootID.isEmpty ? "<shootID>" : vm.shootID))
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var queueCard: some View {
        GroupBox("Queue") {
            if vm.queue.isEmpty {
                Text("No files queued.")
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(vm.queue) { job in
                        HStack {
                            Image(systemName: "film")
                            Text(job.sourceURL.lastPathComponent)
                            Spacer()
                            Text(job.status.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }
        }
    }
}

#Preview {
    WatermarkView().frame(width: 1000, height: 640)
}
