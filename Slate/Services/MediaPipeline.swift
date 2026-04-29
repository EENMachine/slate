//
//  MediaPipeline.swift
//  Slate
//
//  Video processing — currently scoped to MVP invisible watermark embed
//  + verify on a single keyframe. License posture: Apple's VideoToolbox
//  encoders only (LGPL-clean). See Slate/Features/Watermark/README.md
//  for the locked posture.
//

import Foundation

// MARK: - Models

struct WatermarkRequest: Hashable {
    let source: URL
    let destination: URL
    /// Default payload format: `EENMACHINES:<shootID>` — see
    /// `Branding.watermarkPayload(shootID:)`.
    let payload: String
}

struct WatermarkResult: Hashable {
    let outputURL: URL
    /// True if a roundtrip extract recovered the payload byte-for-byte.
    let verified: Bool
    /// What the verifier read back. May differ from the requested payload
    /// if the roundtrip lost bits — useful for debugging encoder choices.
    let recoveredPayload: String?
}

enum MediaPipelineError: Error, CustomStringConvertible {
    case sourceUnreadable(URL)
    case destinationUnwritable(URL)
    case embedFailed(detail: String)
    case verifyFailed(detail: String)

    var description: String {
        switch self {
        case .sourceUnreadable(let u):     return "Cannot read source video at \(u.path)."
        case .destinationUnwritable(let u): return "Cannot write to destination at \(u.path)."
        case .embedFailed(let d):          return "Watermark embed failed: \(d)"
        case .verifyFailed(let d):         return "Watermark verify failed: \(d)"
        }
    }
}

// MARK: - Protocol

protocol MediaProcessing: Sendable {
    /// Embed an invisible watermark and verify on roundtrip.
    func embed(_ request: WatermarkRequest) async throws -> WatermarkResult

    /// Attempt to extract a payload from a video. Returns nil if no mark
    /// is found (CRC mismatch, missing magic, etc.).
    func extract(from url: URL, expectedByteCount: Int) async throws -> String?
}

// MARK: - Real implementation

/// MVP pipeline: single-keyframe luminance DCT watermark via Apple's
/// VideoToolbox H.264 encoder. No FFmpeg, no x264.
struct MediaPipeline: MediaProcessing {
    static let shared = MediaPipeline()

    func embed(_ request: WatermarkRequest) async throws -> WatermarkResult {
        guard FileManager.default.isReadableFile(atPath: request.source.path) else {
            throw MediaPipelineError.sourceUnreadable(request.source)
        }

        // 1. Encode the payload string into a bit stream.
        let bits: [Bool]
        do {
            bits = try WatermarkPayload.encode(request.payload)
        } catch {
            throw MediaPipelineError.embedFailed(detail: "payload encode: \(error)")
        }

        // 2. Write the modified video.
        do {
            try await VideoFrameIO.embed(
                bits: bits,
                source: request.source,
                destination: request.destination
            )
        } catch {
            throw MediaPipelineError.embedFailed(detail: "video write: \(error)")
        }

        // 3. Roundtrip verify. Never call success without this.
        let recovered = try? await Self.verify(
            url: request.destination,
            expectedByteCount: request.payload.utf8.count
        )
        let matches = recovered == request.payload
        return WatermarkResult(
            outputURL: request.destination,
            verified: matches,
            recoveredPayload: recovered
        )
    }

    func extract(from url: URL, expectedByteCount: Int) async throws -> String? {
        try await Self.verify(url: url, expectedByteCount: expectedByteCount)
    }

    private static func verify(url: URL, expectedByteCount: Int) async throws -> String? {
        let totalBits = WatermarkPayload.bitCount(forPayloadByteCount: expectedByteCount)
        let bits = try await VideoFrameIO.extractBits(bitCount: totalBits, from: url)
        return try? WatermarkPayload.decode(bits)
    }
}

// MARK: - Stub (kept for previews + tests)

struct MediaPipelineStub: MediaProcessing {
    func embed(_ request: WatermarkRequest) async throws -> WatermarkResult {
        WatermarkResult(outputURL: request.destination, verified: false, recoveredPayload: nil)
    }
    func extract(from url: URL, expectedByteCount: Int) async throws -> String? {
        nil
    }
}
