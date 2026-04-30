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

// MARK: - Models — Extract diagnostics

/// In-depth diagnostic from a watermark-extraction attempt. Every field
/// is `Optional` so the caller can render partial information when the
/// payload is corrupt or truncated — even a wrong magic still tells you
/// something about whether *any* signal is present in the file.
struct ExtractDetail: Hashable {
    /// Source video URL.
    let sourceURL: URL
    /// Total raw bits requested from the carrier (before majority vote).
    let totalRawBits: Int
    /// First 32 collapsed bits (header: magic + length), useful even when
    /// later fields fail to parse.
    let headerBits: [Bool]
    /// Magic word (`0xEE4D` if the watermark was placed by Slate).
    let magic: UInt16?
    /// Whether `magic` matched the expected `WatermarkPayload.magic` value.
    let magicMatched: Bool
    /// Body length declared in the header, in bytes.
    let bodyByteCount: Int?
    /// Raw body bytes (post-majority-vote, post-magic-strip).
    let bodyBytes: [UInt8]?
    /// UTF-8 decoded body string (the actual recovered payload).
    let bodyUTF8: String?
    /// CRC-16 read from the bit stream.
    let crcReceived: UInt16?
    /// CRC-16 we computed over the header + body.
    let crcComputed: UInt16?
    /// Whether the two CRCs matched.
    let crcMatched: Bool
    /// Final decoded payload string. Non-nil only if magic + CRC + UTF-8
    /// all checked out.
    let decodedPayload: String?
    /// Human-readable error message if decoding failed at any stage.
    let errorMessage: String?
}

// MARK: - Protocol

protocol MediaProcessing: Sendable {
    /// Embed an invisible watermark and verify on roundtrip.
    func embed(_ request: WatermarkRequest) async throws -> WatermarkResult

    /// Attempt to extract a payload from a video. Returns nil if no mark
    /// is found (CRC mismatch, missing magic, etc.).
    func extract(from url: URL, expectedByteCount: Int) async throws -> String?

    /// Extract a payload with full diagnostics — every parsing step
    /// surfaces what it could and couldn't recover, so the caller can
    /// distinguish "no watermark in this file" from "watermark present
    /// but corrupted by re-encoding" from "valid watermark, payload X."
    func extractDetailed(from url: URL) async throws -> ExtractDetail
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

    func extractDetailed(from url: URL) async throws -> ExtractDetail {
        // Two-pass extraction: read just enough bits for the header
        // (magic + length, 4 bytes = 32 raw bits = 160 bits with rep=5),
        // parse the declared body length, then read the full payload.
        let headerRawBytes = 4
        let headerBitCount = WatermarkPayload.bitCount(forPayloadByteCount: 0) // header + 0 body + CRC
            // bitCount(0) = (0 + 6) * 8 * 5 = 240 bits — slightly larger than needed but covers the header cleanly.

        // First read: enough to learn the body length.
        let headerStream: [Bool]
        do {
            headerStream = try await VideoFrameIO.extractBits(bitCount: headerBitCount, from: url)
        } catch {
            return ExtractDetail(
                sourceURL: url,
                totalRawBits: 0,
                headerBits: [],
                magic: nil, magicMatched: false,
                bodyByteCount: nil, bodyBytes: nil, bodyUTF8: nil,
                crcReceived: nil, crcComputed: nil, crcMatched: false,
                decodedPayload: nil,
                errorMessage: "Could not read carrier from video: \(error)"
            )
        }

        let collapsedHeader = WatermarkPayload.majorityVoteBits(headerStream)
        let headerBytes = WatermarkPayload.bytesFromBits(collapsedHeader)
        let firstFour = Array(headerBytes.prefix(4))
        let firstThirtyTwo = Array(collapsedHeader.prefix(32))

        guard firstFour.count >= 4 else {
            return ExtractDetail(
                sourceURL: url,
                totalRawBits: headerBitCount,
                headerBits: firstThirtyTwo,
                magic: nil, magicMatched: false,
                bodyByteCount: nil, bodyBytes: nil, bodyUTF8: nil,
                crcReceived: nil, crcComputed: nil, crcMatched: false,
                decodedPayload: nil,
                errorMessage: "Header truncated — only \(firstFour.count) of 4 header bytes recovered."
            )
        }

        let receivedMagic = (UInt16(firstFour[0]) << 8) | UInt16(firstFour[1])
        let magicMatched = receivedMagic == WatermarkPayload.magic
        let declaredLen = Int((UInt16(firstFour[2]) << 8) | UInt16(firstFour[3]))

        if !magicMatched {
            return ExtractDetail(
                sourceURL: url,
                totalRawBits: headerBitCount,
                headerBits: firstThirtyTwo,
                magic: receivedMagic, magicMatched: false,
                bodyByteCount: nil, bodyBytes: nil, bodyUTF8: nil,
                crcReceived: nil, crcComputed: nil, crcMatched: false,
                decodedPayload: nil,
                errorMessage: "No watermark detected (magic 0x\(String(receivedMagic, radix: 16, uppercase: true)) ≠ expected 0x\(String(WatermarkPayload.magic, radix: 16, uppercase: true)))."
            )
        }

        // Second read: full payload now that we know the body length.
        let totalBits = WatermarkPayload.bitCount(forPayloadByteCount: declaredLen)
        let fullStream: [Bool]
        do {
            fullStream = try await VideoFrameIO.extractBits(bitCount: totalBits, from: url)
        } catch {
            return ExtractDetail(
                sourceURL: url,
                totalRawBits: headerBitCount,
                headerBits: firstThirtyTwo,
                magic: receivedMagic, magicMatched: true,
                bodyByteCount: declaredLen, bodyBytes: nil, bodyUTF8: nil,
                crcReceived: nil, crcComputed: nil, crcMatched: false,
                decodedPayload: nil,
                errorMessage: "Body read failed (declared \(declaredLen) bytes): \(error)"
            )
        }

        let collapsedFull = WatermarkPayload.majorityVoteBits(fullStream)
        let fullBytes = WatermarkPayload.bytesFromBits(collapsedFull)
        guard fullBytes.count >= 4 + declaredLen + 2 else {
            return ExtractDetail(
                sourceURL: url,
                totalRawBits: totalBits,
                headerBits: firstThirtyTwo,
                magic: receivedMagic, magicMatched: true,
                bodyByteCount: declaredLen, bodyBytes: nil, bodyUTF8: nil,
                crcReceived: nil, crcComputed: nil, crcMatched: false,
                decodedPayload: nil,
                errorMessage: "Body truncated — needed \(4 + declaredLen + 2) bytes, got \(fullBytes.count)."
            )
        }

        let bodyEnd = 4 + declaredLen
        let body = Array(fullBytes[4..<bodyEnd])
        let crcReceived = (UInt16(fullBytes[bodyEnd]) << 8) | UInt16(fullBytes[bodyEnd + 1])
        let crcComputed = WatermarkPayload.crc16Public(Array(fullBytes[0..<bodyEnd]))
        let crcMatched = crcReceived == crcComputed
        let bodyString = String(bytes: body, encoding: .utf8)

        let decoded = (crcMatched && bodyString != nil) ? bodyString : nil
        let err: String?
        if !crcMatched {
            err = "CRC mismatch: expected 0x\(String(crcComputed, radix: 16, uppercase: true)), got 0x\(String(crcReceived, radix: 16, uppercase: true)) — payload likely corrupted by re-encoding."
        } else if bodyString == nil {
            err = "CRC matched but body bytes are not valid UTF-8."
        } else {
            err = nil
        }

        return ExtractDetail(
            sourceURL: url,
            totalRawBits: totalBits,
            headerBits: firstThirtyTwo,
            magic: receivedMagic, magicMatched: true,
            bodyByteCount: declaredLen,
            bodyBytes: body,
            bodyUTF8: bodyString,
            crcReceived: crcReceived,
            crcComputed: crcComputed,
            crcMatched: crcMatched,
            decodedPayload: decoded,
            errorMessage: err
        )
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
    func extractDetailed(from url: URL) async throws -> ExtractDetail {
        ExtractDetail(
            sourceURL: url,
            totalRawBits: 0,
            headerBits: [],
            magic: nil, magicMatched: false,
            bodyByteCount: nil, bodyBytes: nil, bodyUTF8: nil,
            crcReceived: nil, crcComputed: nil, crcMatched: false,
            decodedPayload: nil,
            errorMessage: "stub"
        )
    }
}
