//
//  Watermark/ViewModel.swift
//  Slate
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct WatermarkJob: Identifiable, Hashable {
    enum Status: Hashable {
        case queued
        case processing(progress: Double)
        case done(outputURL: URL, verified: Bool)
        case failed(message: String)

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .processing(let p): return "Processing \(Int(p * 100))%"
            case .done(_, let verified): return verified ? "Done \u{2713}" : "Done (verify failed)"
            case .failed(let m): return "Failed — \(m)"
            }
        }
    }

    let id: UUID
    let sourceURL: URL
    let payload: String
    var status: Status
}

@MainActor
final class WatermarkViewModel: ObservableObject {
    @Published var shootID: String = ""
    @Published var queue: [WatermarkJob] = []

    private let pipeline: any MediaProcessing

    init(pipeline: any MediaProcessing = MediaPipeline.shared) {
        self.pipeline = pipeline
    }

    /// Open an NSOpenPanel to add video files to the queue. Each becomes
    /// a `WatermarkJob` with the current shoot-ID payload.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.title = "Choose video files to watermark"
        guard panel.runModal() == .OK else { return }

        let payload = Branding.watermarkPayload(
            shootID: shootID.isEmpty ? "UNTITLED" : shootID
        )
        let newJobs: [WatermarkJob] = panel.urls.map { url in
            WatermarkJob(
                id: UUID(),
                sourceURL: url,
                payload: payload,
                status: .queued
            )
        }
        queue.append(contentsOf: newJobs)
    }

    /// Process every queued job sequentially. Cancels would land here in
    /// a future iteration; for now this runs to completion.
    func runQueue() async {
        for index in queue.indices {
            guard case .queued = queue[index].status else { continue }
            await process(jobIndex: index)
        }
    }

    private func process(jobIndex: Int) async {
        guard queue.indices.contains(jobIndex) else { return }
        let job = queue[jobIndex]
        queue[jobIndex].status = .processing(progress: 0)

        let destination = Self.outputURL(for: job.sourceURL)
        let request = WatermarkRequest(
            source: job.sourceURL,
            destination: destination,
            payload: job.payload
        )

        do {
            let result = try await pipeline.embed(request)
            queue[jobIndex].status = .done(outputURL: result.outputURL, verified: result.verified)
        } catch {
            queue[jobIndex].status = .failed(message: "\(error)")
        }
    }

    /// Compute the destination URL for a given source by appending
    /// `-watermarked` before the extension.
    static func outputURL(for source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let dir = source.deletingLastPathComponent()
        let newName = "\(base)-watermarked.\(ext.isEmpty ? "mp4" : ext)"
        return dir.appendingPathComponent(newName)
    }
}
