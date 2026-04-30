//
//  WatermarkPipelineIntegrationTests.swift
//  SlateTests
//
//  End-to-end integration test for the watermark feature. Synthesizes a
//  small H.264 video at test time (no fixture bundling, no network
//  download), runs the full pipeline `WatermarkPayload.encode` →
//  `VideoFrameIO.embed` → file-on-disk → `VideoFrameIO.extractBits` →
//  `WatermarkPayload.decode`, and asserts the recovered payload matches.
//
//  This is the test the unit suite couldn't be: it exercises
//  `AVAssetReader`, `AVAssetWriter`, VideoToolbox H.264 encoding, the
//  `CVPixelBuffer` ↔ luminance-plane round-trip, and the actual on-disk
//  file integrity — none of which the in-memory unit tests cover.
//

import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest
@testable import Slate

final class WatermarkPipelineIntegrationTests: XCTestCase {

    /// Round-trip a known payload through the full pipeline on a real
    /// video file. Must match exactly after embed → encode → decode.
    func testEndToEnd_realVideoFile_payloadSurvives() async throws {
        let payload = "INTEGRATION_TEST_42"
        let work = try makeWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: work) }

        let sourceURL = work.appendingPathComponent("source.mov")
        let destinationURL = work.appendingPathComponent("watermarked.mov")

        try await synthesizeSampleVideo(at: sourceURL, frameCount: 10, width: 640, height: 480)

        let bits = try WatermarkPayload.encode(payload)
        try await VideoFrameIO.embed(bits: bits, source: sourceURL, destination: destinationURL)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destinationURL.path),
            "VideoFrameIO.embed did not write the destination file."
        )

        let bitCount = WatermarkPayload.bitCount(forPayloadByteCount: payload.utf8.count)
        let recoveredBits = try await VideoFrameIO.extractBits(bitCount: bitCount, from: destinationURL)
        let recovered = try WatermarkPayload.decode(recoveredBits)

        XCTAssertEqual(
            recovered, payload,
            "Payload round-trip through the file-on-disk pipeline did not match the embedded value."
        )
    }

    // MARK: - Test fixture: synthesize a real H.264 video on disk

    /// Build a small H.264 .mov from a sequence of synthesized BGRA frames.
    /// Each frame is a smooth gradient so DCT blocks have well-conditioned
    /// content (mirrors what the unit tests exercise but as a real video).
    private func synthesizeSampleVideo(
        at url: URL,
        frameCount: Int,
        width: Int,
        height: Int
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 1
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelAttrs
        )
        guard writer.canAdd(input) else {
            throw NSError(
                domain: "WatermarkPipelineIntegrationTests",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Writer rejected video input"]
            )
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(
                domain: "WatermarkPipelineIntegrationTests",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter.startWriting returned false"]
            )
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 30
        for i in 0..<frameCount {
            // Wait until the input is ready for more data, with a tight
            // bound to avoid hanging the test on a stuck encoder.
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                if Date() > deadline {
                    throw NSError(
                        domain: "WatermarkPipelineIntegrationTests",
                        code: -12,
                        userInfo: [NSLocalizedDescriptionKey: "Encoder never became ready for frame \(i)"]
                    )
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            let pb = try makeGradientPixelBuffer(
                width: width, height: height, frameIndex: i, pool: adaptor.pixelBufferPool
            )
            let pts = CMTime(value: CMTimeValue(i), timescale: timescale)
            if !adaptor.append(pb, withPresentationTime: pts) {
                throw writer.error ?? NSError(
                    domain: "WatermarkPipelineIntegrationTests",
                    code: -13,
                    userInfo: [NSLocalizedDescriptionKey: "Adaptor.append failed at frame \(i)"]
                )
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? NSError(
                domain: "WatermarkPipelineIntegrationTests",
                code: -14,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter.finishWriting failed"]
            )
        }
    }

    /// Build a single BGRA pixel buffer containing a smooth gradient.
    /// `frameIndex` shifts the gradient slightly so consecutive frames
    /// aren't byte-identical (avoids any encoder dedup edge cases).
    private func makeGradientPixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var maybe: CVPixelBuffer?
        let status: CVReturn
        if let pool = pool {
            status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybe)
        } else {
            status = CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &maybe
            )
        }
        guard status == kCVReturnSuccess, let pb = maybe else {
            throw NSError(
                domain: "WatermarkPipelineIntegrationTests",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed status=\(status)"]
            )
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw NSError(
                domain: "WatermarkPipelineIntegrationTests",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferGetBaseAddress returned nil"]
            )
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let bufferPointer = base.assumingMemoryBound(to: UInt8.self)
        let offset = UInt8(frameIndex & 0x0F)

        for y in 0..<height {
            let row = bufferPointer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let v = UInt8((x &+ y &+ Int(offset)) & 0xFF)
                let p = row.advanced(by: x * 4)
                p[0] = v   // B
                p[1] = v   // G
                p[2] = v   // R
                p[3] = 255 // A
            }
        }
        return pb
    }

    // MARK: - Test fixture: temp directory

    private func makeWorkingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-watermark-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
