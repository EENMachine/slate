//
//  VideoFrameIO.swift
//  Slate
//
//  AVFoundation glue for the watermark pipeline. Reads a video, hands
//  the first keyframe's luminance plane to `DCTWatermark.embed`, then
//  re-encodes the (modified-frame + passthrough rest) through Apple's
//  VideoToolbox H.264 / HEVC encoder.
//
//  License posture: Apple's VideoToolbox encoders only — no FFmpeg, no
//  x264 (GPL). See `Slate/Features/Watermark/README.md` for the locked
//  posture.
//
//  MVP scope: the simplest correct shape. We re-encode the entire video
//  using `AVAssetWriter`, swapping in the modified pixel buffer for the
//  first keyframe. A future optimization is sample-level passthrough
//  with single-frame substitution; that needs more careful CMSampleBuffer
//  surgery and is parked behind a TODO.
//

import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - Concurrency helpers

/// Atomic single-shot gate. `consume()` returns `true` exactly once across
/// all callers; subsequent calls return `false`. Used to guarantee a
/// `CheckedContinuation` is resumed at most once even when AVFoundation's
/// `requestMediaDataWhenReady` re-fires its callback after an error path.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed: Bool = false

    var isConsumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return consumed
    }

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}

/// Tiny mutable counter box so the encode-loop closure can share state
/// without `var` capture diagnostics in strict-concurrency mode.
private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}

enum VideoFrameIO {
    enum IOError: Error, CustomStringConvertible {
        case noVideoTrack
        case readerSetupFailed(any Error)
        case writerSetupFailed(any Error)
        case readSampleFailed
        case noPixelBuffer
        case unsupportedPixelFormat(OSType)
        case writerStartFailed(any Error?)
        case writerAppendFailed(any Error?)
        case writerFinalizeFailed(any Error?)

        var description: String {
            switch self {
            case .noVideoTrack:                return "Source has no video track."
            case .readerSetupFailed(let e):    return "AVAssetReader setup failed: \(e)"
            case .writerSetupFailed(let e):    return "AVAssetWriter setup failed: \(e)"
            case .readSampleFailed:            return "AVAssetReader.copyNextSampleBuffer returned nil unexpectedly."
            case .noPixelBuffer:               return "Sample buffer had no CVPixelBuffer."
            case .unsupportedPixelFormat(let f): return "Pixel format \(f) is not 32BGRA — reader settings should have forced this."
            case .writerStartFailed(let e):    return "AVAssetWriter.startWriting failed: \(String(describing: e))"
            case .writerAppendFailed(let e):   return "AVAssetWriterInput.append failed: \(String(describing: e))"
            case .writerFinalizeFailed(let e): return "AVAssetWriter.finishWriting failed: \(String(describing: e))"
            }
        }
    }

    // MARK: - Embed

    /// Read `source`, embed `bits` in the luminance plane of the first
    /// video frame, write the result to `destination`.
    ///
    /// Throws on any AVFoundation error. Caller is responsible for
    /// ensuring `destination` is writable and not the same URL as
    /// `source` (we won't overwrite in-place).
    static func embed(
        bits: [Bool],
        source: URL,
        destination: URL
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw IOError.noVideoTrack
        }

        // 1. Reader: pull frames as 32BGRA.
        let reader: AVAssetReader
        let readerOutput: AVAssetReaderTrackOutput
        do {
            reader = try AVAssetReader(asset: asset)
            readerOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            readerOutput.alwaysCopiesSampleData = false
            reader.add(readerOutput)
        } catch {
            throw IOError.readerSetupFailed(error)
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))

        // 2. Writer: H.264 via VideoToolbox (LGPL-clean).
        let writer: AVAssetWriter
        let writerInput: AVAssetWriterInput
        let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor
        do {
            // Best-effort cleanup of stale destination file.
            try? FileManager.default.removeItem(at: destination)

            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(width * height * 8, 2_000_000),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ]
            ]
            writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            writerInput.expectsMediaDataInRealTime = false
            writerInput.transform = preferredTransform

            let sourceBufferAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: writerInput,
                sourcePixelBufferAttributes: sourceBufferAttrs
            )
            writer.add(writerInput)
        } catch {
            throw IOError.writerSetupFailed(error)
        }

        guard reader.startReading() else {
            throw IOError.readerSetupFailed(reader.error ?? NSError(domain: "VideoFrameIO", code: -1))
        }
        guard writer.startWriting() else {
            throw IOError.writerStartFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // 3. Walk frames. Modify the first keyframe; passthrough the rest.
        let frameIndexBox = CounterBox()
        let resumeGuard = ResumeGuard()
        _ = nominalFrameRate  // reserved for future timing logic

        let queue = DispatchQueue(label: "com.eenmachines.slate.watermark.encode")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            // Single-shot finalizer. `requestMediaDataWhenReady` keeps
            // calling its callback until the input is marked finished —
            // so every error path needs to mark finished AND must guard
            // against a follow-up re-entry that would double-resume the
            // continuation. ResumeGuard atomically gates resume.
            let finalize: (Error?) -> Void = { error in
                guard resumeGuard.consume() else { return }
                writerInput.markAsFinished()
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume(returning: ())
                    } else {
                        cont.resume(throwing: IOError.writerFinalizeFailed(writer.error))
                    }
                }
            }

            writerInput.requestMediaDataWhenReady(on: queue) {
                if resumeGuard.isConsumed { return }
                while writerInput.isReadyForMoreMediaData {
                    if resumeGuard.isConsumed { return }

                    guard let sample = readerOutput.copyNextSampleBuffer() else {
                        // End of stream or reader error.
                        if reader.status == .failed {
                            finalize(IOError.readerSetupFailed(reader.error ?? NSError(domain: "VideoFrameIO", code: -2)))
                        } else {
                            finalize(nil)
                        }
                        return
                    }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let appended: Bool
                    if frameIndexBox.value == 0 {
                        // The keyframe — embed bits.
                        do {
                            let modifiedBuffer = try Self.embedBitsIntoFirstFrame(
                                sample: sample,
                                bits: bits,
                                pixelBufferPool: pixelAdaptor.pixelBufferPool
                            )
                            appended = pixelAdaptor.append(modifiedBuffer, withPresentationTime: pts)
                        } catch {
                            finalize(error)
                            return
                        }
                    } else {
                        // Passthrough. Copy into a pool-allocated buffer
                        // because the reader's CVPixelBuffer may not be
                        // compatible with the writer's expected pool, and
                        // passing it directly can either fail the append
                        // or trigger an opaque internal copy.
                        guard let src = CMSampleBufferGetImageBuffer(sample) else {
                            finalize(IOError.noPixelBuffer)
                            return
                        }
                        do {
                            let copy = try Self.copyIntoPool(src: src, pool: pixelAdaptor.pixelBufferPool)
                            appended = pixelAdaptor.append(copy, withPresentationTime: pts)
                        } catch {
                            finalize(error)
                            return
                        }
                    }

                    if !appended {
                        finalize(IOError.writerAppendFailed(writer.error))
                        return
                    }
                    frameIndexBox.increment()
                }
            }
        }
    }

    /// Copy `src` into a fresh pool-allocated CVPixelBuffer. Caller owns
    /// the returned buffer's lifetime — the writer adaptor will retain it.
    private static func copyIntoPool(
        src: CVPixelBuffer,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var dest: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dest)
        }
        if dest == nil {
            // Fall back to a one-off allocation matching the source format.
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(src),
                kCVPixelBufferWidthKey:           CVPixelBufferGetWidth(src),
                kCVPixelBufferHeightKey:          CVPixelBufferGetHeight(src),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferCreate(
                nil,
                CVPixelBufferGetWidth(src),
                CVPixelBufferGetHeight(src),
                CVPixelBufferGetPixelFormatType(src),
                attrs as CFDictionary,
                &dest
            )
        }
        guard let dst = dest else {
            throw IOError.noPixelBuffer
        }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        let height = CVPixelBufferGetHeight(src)
        let srcStride = CVPixelBufferGetBytesPerRow(src)
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        guard
            let srcBase = CVPixelBufferGetBaseAddress(src),
            let dstBase = CVPixelBufferGetBaseAddress(dst)
        else {
            throw IOError.noPixelBuffer
        }
        let bytesPerRow = min(srcStride, dstStride)
        for row in 0..<height {
            let srcRow = srcBase.advanced(by: row * srcStride)
            let dstRow = dstBase.advanced(by: row * dstStride)
            memcpy(dstRow, srcRow, bytesPerRow)
        }
        return dst
    }

    // MARK: - Extract

    /// Read `source`, return the bits decoded out of the first keyframe.
    /// The caller must know how many bits to read (see
    /// `WatermarkPayload.bitCount(forPayloadByteCount:)`).
    static func extractBits(
        bitCount: Int,
        from source: URL
    ) async throws -> [Bool] {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw IOError.noVideoTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw IOError.readerSetupFailed(reader.error ?? NSError(domain: "VideoFrameIO", code: -3))
        }
        guard let firstSample = output.copyNextSampleBuffer() else {
            throw IOError.readSampleFailed
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
            throw IOError.noPixelBuffer
        }
        let (luminance, w, h) = try Self.luminanceFromBGRA(pixelBuffer)
        return try DCTWatermark.extract(bitCount: bitCount, fromLuminance: luminance, width: w, height: h)
    }

    // MARK: - Internals

    /// Build a modified pixel buffer for the first keyframe with the
    /// watermark embedded in the luminance plane.
    private static func embedBitsIntoFirstFrame(
        sample: CMSampleBuffer,
        bits: [Bool],
        pixelBufferPool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        guard let inputBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw IOError.noPixelBuffer
        }
        let (luminance, width, height) = try luminanceFromBGRA(inputBuffer)
        // Trim to block-aligned dimensions if needed. MVP requirement:
        // dimensions must be multiples of 8. AVFoundation almost always
        // gives us multiples of 16, but bail loudly if not.
        let modified = try DCTWatermark.embed(
            bits: bits,
            intoLuminance: luminance,
            width: width,
            height: height
        )
        return try bgraPixelBuffer(
            replacingLuminance: modified,
            in: inputBuffer,
            width: width,
            height: height,
            pool: pixelBufferPool
        )
    }

    /// Convert a 32BGRA pixel buffer to a Float luminance plane using
    /// Rec. 709 weights (Y = 0.2126·R + 0.7152·G + 0.0722·B). Returns
    /// `(plane, width, height)`.
    static func luminanceFromBGRA(_ buffer: CVPixelBuffer) throws -> (plane: [Float], width: Int, height: Int) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA else {
            throw IOError.unsupportedPixelFormat(format)
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw IOError.noPixelBuffer
        }

        var plane = [Float](repeating: 0, count: width * height)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                let b = Float(bytes[offset])
                let g = Float(bytes[offset + 1])
                let r = Float(bytes[offset + 2])
                plane[y * width + x] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        return (plane, width, height)
    }

    /// Round-trip a luminance plane back into a 32BGRA pixel buffer by
    /// re-encoding the per-pixel chrominance from the original buffer
    /// and substituting the new luma. Approximate; visually
    /// imperceptible deltas (<1 LSB on most pixels) are acceptable for
    /// the MVP.
    static func bgraPixelBuffer(
        replacingLuminance luma: [Float],
        in source: CVPixelBuffer,
        width: Int,
        height: Int,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        }
        if out == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        }
        guard let buffer = out else { throw IOError.noPixelBuffer }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard
            let srcBase = CVPixelBufferGetBaseAddress(source),
            let dstBase = CVPixelBufferGetBaseAddress(buffer)
        else {
            throw IOError.noPixelBuffer
        }
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)
        let srcBytes = srcBase.assumingMemoryBound(to: UInt8.self)
        let dstBytes = dstBase.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let srcOff = y * srcStride + x * 4
                let dstOff = y * dstStride + x * 4
                let b = Float(srcBytes[srcOff])
                let g = Float(srcBytes[srcOff + 1])
                let r = Float(srcBytes[srcOff + 2])
                let a = srcBytes[srcOff + 3]
                let yOld = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let yNew = max(0, min(255, luma[y * width + x]))
                let dy = yNew - yOld
                // Apply the luma delta to all three channels uniformly so
                // the chrominance is preserved (in additive RGB, equal
                // deltas across channels move only luma).
                dstBytes[dstOff]     = UInt8(max(0, min(255, b + dy)))
                dstBytes[dstOff + 1] = UInt8(max(0, min(255, g + dy)))
                dstBytes[dstOff + 2] = UInt8(max(0, min(255, r + dy)))
                dstBytes[dstOff + 3] = a
            }
        }
        return buffer
    }
}
