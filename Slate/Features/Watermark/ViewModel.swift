//
//  Watermark/ViewModel.swift
//  Slate
//

import Foundation
import SwiftUI

struct WatermarkJob: Identifiable, Hashable {
    enum Status: Hashable {
        case queued
        case processing(progress: Double)
        case done(outputURL: URL)
        case failed(message: String)

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .processing(let p): return "Processing \(Int(p * 100))%"
            case .done: return "Done"
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

    init(pipeline: any MediaProcessing = MediaPipelineStub()) {
        self.pipeline = pipeline
    }

    func chooseFiles() {
        // TODO(slate-watermark): NSOpenPanel for video UTTypes (.movie, .quickTimeMovie, .mpeg4Movie).
        // Each picked URL becomes a WatermarkJob with Branding.watermarkPayload(shootID:).
    }

    func runQueue() async {
        // TODO(slate-watermark): for each queued job, hand to MediaPipeline.embed(...)
        // with the EENMACHINES payload. Robustness target TBD with client.
    }
}
