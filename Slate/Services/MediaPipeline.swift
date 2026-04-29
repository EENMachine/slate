//
//  MediaPipeline.swift
//  Slate
//
//  Video processing — currently scoped to invisible watermark embed +
//  verify. FFmpeg is the likely backbone. Audit the LGPL/GPL build
//  flavors before shipping.
//

import Foundation

// MARK: - Models

struct WatermarkRequest: Hashable {
    let source: URL
    let destination: URL
    /// Default payload format: `EENMACHINES:<shootID>` — see Branding.watermarkPayload(shootID:).
    let payload: String
}

struct WatermarkResult: Hashable {
    let outputURL: URL
    /// True if a roundtrip extract recovered the payload byte-for-byte.
    let verified: Bool
}

enum MediaPipelineError: Error {
    case ffmpegMissing
    case sourceUnreadable
    case destinationUnwritable
    case embedFailed(detail: String)
    case verifyFailed(detail: String)
}

// MARK: - Protocol

protocol MediaProcessing: Sendable {
    /// Embed an invisible watermark and verify on roundtrip.
    func embed(_ request: WatermarkRequest) async throws -> WatermarkResult

    /// Attempt to extract a payload from a video. Returns nil if no mark found.
    func extract(from url: URL) async throws -> String?
}

// MARK: - Stub

struct MediaPipelineStub: MediaProcessing {
    func embed(_ request: WatermarkRequest) async throws -> WatermarkResult {
        // TODO(slate-watermark):
        //   1. Confirm robustness target with client (file-only / re-encode / screen-record).
        //   2. Pick algo (likely DCT-domain via Python sidecar `invisible-watermark`,
        //      or Swift port). Wrap the call here.
        //   3. Run an extract roundtrip and set `verified` accordingly. Never
        //      return success without a passed verify.
        throw MediaPipelineError.embedFailed(detail: "stub")
    }

    func extract(from url: URL) async throws -> String? {
        // TODO(slate-watermark): mirror the embed algorithm.
        nil
    }
}
