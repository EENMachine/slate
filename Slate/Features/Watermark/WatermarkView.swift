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
                    Divider().padding(.vertical, 4)
                    extractCard
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
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task { await vm.runExtractQueue() }
                } label: {
                    Label("Run Extract Queue", systemImage: "magnifyingglass")
                }
                .disabled(vm.extractQueue.isEmpty)
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

    // MARK: - Extract section

    private var extractCard: some View {
        GroupBox(label: Label("Extract", systemImage: "magnifyingglass")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Drop any video here to look for an embedded watermark. Works on watermarked, re-encoded, or unrelated files — diagnostic output explains what was found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Choose Files…") { vm.chooseExtractFiles() }
                    Button {
                        Task { await vm.runExtractQueue() }
                    } label: {
                        Label("Run Extract", systemImage: "play.fill")
                    }
                    .disabled(vm.extractQueue.isEmpty)
                }

                if vm.extractQueue.isEmpty {
                    Text("No files queued for extraction.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.extractQueue) { job in
                            extractRow(job)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func extractRow(_ job: ExtractJob) -> some View {
        DisclosureGroup {
            extractDetailView(for: job)
                .padding(.top, 6)
        } label: {
            HStack {
                Image(systemName: extractIcon(for: job))
                    .foregroundStyle(extractIconColor(for: job))
                Text(job.sourceURL.lastPathComponent)
                    .font(.body.monospaced())
                Spacer()
                Text(job.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func extractDetailView(for job: ExtractJob) -> some View {
        switch job.status {
        case .queued, .processing:
            Text("Waiting for run…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
        case .done(let detail):
            extractDetailCard(detail)
        }
    }

    @ViewBuilder
    private func extractDetailCard(_ d: ExtractDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Decoded payload", d.decodedPayload ?? "—",
                color: d.decodedPayload != nil ? .green : .secondary,
                mono: d.decodedPayload != nil)

            row("Magic",
                d.magic.map { "0x\(String($0, radix: 16, uppercase: true))" } ?? "—",
                color: d.magicMatched ? .green : .red,
                mono: true)

            if let len = d.bodyByteCount {
                row("Body length", "\(len) bytes")
            }

            if let body = d.bodyBytes {
                row("Body bytes (hex)",
                    body.map { String(format: "%02X", $0) }.joined(separator: " "),
                    mono: true)
            }

            if let s = d.bodyUTF8 {
                row("Body (UTF-8)", s, mono: true)
            }

            if let received = d.crcReceived, let computed = d.crcComputed {
                row("CRC",
                    "received 0x\(String(received, radix: 16, uppercase: true)) · computed 0x\(String(computed, radix: 16, uppercase: true))",
                    color: d.crcMatched ? .green : .red,
                    mono: true)
            }

            row("Bits read", "\(d.totalRawBits) raw")

            if !d.headerBits.isEmpty {
                row("Header (32 bits, post-vote)",
                    d.headerBits.map { $0 ? "1" : "0" }.joined(),
                    mono: true)
            }

            if let err = d.errorMessage, d.decodedPayload == nil {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(6)
    }

    private func row(_ label: String, _ value: String,
                     color: Color = .primary, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    private func extractIcon(for job: ExtractJob) -> String {
        switch job.status {
        case .queued, .processing: return "doc.viewfinder"
        case .done(let d):
            if d.decodedPayload != nil { return "checkmark.seal.fill" }
            if d.magicMatched { return "exclamationmark.triangle.fill" }
            return "questionmark.circle"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func extractIconColor(for job: ExtractJob) -> Color {
        switch job.status {
        case .queued, .processing: return .secondary
        case .done(let d):
            if d.decodedPayload != nil { return .green }
            if d.magicMatched { return .orange }
            return .secondary
        case .failed: return .red
        }
    }
}

#Preview {
    WatermarkView().frame(width: 1000, height: 640)
}
