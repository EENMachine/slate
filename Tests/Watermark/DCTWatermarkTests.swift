//
//  DCTWatermarkTests.swift
//  SlateTests
//
//  Pure-math round-trip tests on synthetic luminance planes. No real
//  video — that's covered by integration tests on a Mac (TODO).
//

import XCTest
@testable import Slate

final class DCTWatermarkTests: XCTestCase {
    /// 64×64 plane = 64 8×8 blocks = capacity for 64 bits before any
    /// repetition. Uses a smooth gradient so the DCT response is well-
    /// conditioned.
    private func gradientPlane(width: Int, height: Int) -> [Float] {
        var plane = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                plane[y * width + x] = Float((x + y) & 0xFF)
            }
        }
        return plane
    }

    func testRoundTrip_alternatingBits() throws {
        let w = 64, h = 64
        let plane = gradientPlane(width: w, height: h)
        let bits = (0..<32).map { $0 % 2 == 0 }
        let modified = try DCTWatermark.embed(bits: bits, intoLuminance: plane, width: w, height: h)
        let recovered = try DCTWatermark.extract(bitCount: bits.count, fromLuminance: modified, width: w, height: h)
        XCTAssertEqual(recovered, bits)
    }

    func testRoundTrip_allOnes() throws {
        let w = 64, h = 64
        let plane = gradientPlane(width: w, height: h)
        let bits = [Bool](repeating: true, count: 16)
        let modified = try DCTWatermark.embed(bits: bits, intoLuminance: plane, width: w, height: h)
        let recovered = try DCTWatermark.extract(bitCount: bits.count, fromLuminance: modified, width: w, height: h)
        XCTAssertEqual(recovered, bits)
    }

    /// Embed → clamp/round through 8-bit unsigned (the same lossy step
    /// the real video pipeline takes when writing back a luminance plane
    /// to a `CVPixelBuffer`) → extract. Strength=8.0 should keep the sign
    /// of the embedded coefficient through this rounding.
    func testRoundTrip_survivesUInt8Quantization() throws {
        let w = 64, h = 64
        let plane = gradientPlane(width: w, height: h)
        let bits = (0..<32).map { $0 % 3 == 0 }
        let modified = try DCTWatermark.embed(
            bits: bits,
            intoLuminance: plane,
            width: w,
            height: h
        )
        // Simulate the 8-bit luma round-trip: clamp to [0,255], round,
        // truncate to UInt8, lift back to Float.
        let quantized = modified.map { value -> Float in
            Float(UInt8(max(0, min(255, value.rounded()))))
        }
        let recovered = try DCTWatermark.extract(
            bitCount: bits.count,
            fromLuminance: quantized,
            width: w,
            height: h
        )
        XCTAssertEqual(
            recovered, bits,
            "Strength \(DCTWatermark.strength) should survive 8-bit luma round-trip."
        )
    }

    func testRoundTrip_allZeros() throws {
        let w = 64, h = 64
        let plane = gradientPlane(width: w, height: h)
        let bits = [Bool](repeating: false, count: 16)
        let modified = try DCTWatermark.embed(bits: bits, intoLuminance: plane, width: w, height: h)
        let recovered = try DCTWatermark.extract(bitCount: bits.count, fromLuminance: modified, width: w, height: h)
        XCTAssertEqual(recovered, bits)
    }

    /// DIAGNOSTIC: Surface the actual spatial perturbation magnitude and
    /// the post-quantization extracted-coefficient sign for a single -bit
    /// block so we can see which assumption in the embed/extract math is
    /// wrong. Failure messages contain the actual numbers.
    func testDiagnostic_singleNegativeBit_block1() throws {
        let w = 64, h = 64
        let plane = gradientPlane(width: w, height: h)

        // Embed a single FALSE bit at block 0 (origin 0,0). To isolate
        // block-0 behavior, use just one bit.
        let modified0 = try DCTWatermark.embed(bits: [false], intoLuminance: plane, width: w, height: h)
        let delta0 = zip(modified0, plane).map { $0 - $1 }
        let block0Delta = (0..<8).flatMap { r in (0..<8).map { c in delta0[r * w + c] } }
        let block0Peak = block0Delta.map(abs).max() ?? 0
        let block0Min = block0Delta.min() ?? 0
        let block0Max = block0Delta.max() ?? 0

        // Quantize and extract.
        let quantized0 = modified0.map { Float(UInt8(max(0, min(255, $0.rounded())))) }
        let recovered0 = try DCTWatermark.extract(bitCount: 1, fromLuminance: quantized0, width: w, height: h)

        // Forward-DCT the quantized block 0 manually to see the actual
        // (3,4) coefficient at extract time.
        var rawBlock = [Float](repeating: 0, count: 64)
        for r in 0..<8 { for c in 0..<8 { rawBlock[r * 8 + c] = quantized0[r * w + c] } }
        // We can't call private forwardDCT, but extract reads sign of
        // coefficient — use the recovered value to infer.

        XCTFail("DIAGNOSTIC block 0 (bit=false, sign=-1): perturbation peak=\(block0Peak), min=\(block0Min), max=\(block0Max), recovered=\(recovered0[0])")
    }

    func testRejectsNonBlockAlignedDimensions() {
        let plane = [Float](repeating: 128, count: 70 * 64)
        XCTAssertThrowsError(
            try DCTWatermark.embed(
                bits: [true],
                intoLuminance: plane,
                width: 70,
                height: 64
            )
        )
    }

    func testRejectsOverflowingBitCount() {
        let plane = [Float](repeating: 128, count: 16 * 16)  // 4 blocks
        XCTAssertThrowsError(
            try DCTWatermark.embed(
                bits: [Bool](repeating: true, count: 5),
                intoLuminance: plane,
                width: 16,
                height: 16
            )
        )
    }

    /// End-to-end with the Payload layer: encode an EENMACHINES payload,
    /// embed in a synthetic plane, extract, decode. This is the full
    /// round-trip a user would experience minus AVFoundation's lossy
    /// 8-bit pixel stage (which the integration test on Mac will cover).
    func testFullPayloadRoundTrip_inMemory() throws {
        let payload = "EENMACHINES:SH-20260429-001"
        let bits = try WatermarkPayload.encode(payload)
        // Need enough blocks for `bits.count` bits. Each block holds 1 bit,
        // so size the plane to fit. Round up to a square 8-multiple.
        let blocksPerSide = Int(ceil(sqrt(Double(bits.count))))
        let side = blocksPerSide * DCTWatermark.blockSize
        let plane = gradientPlane(width: side, height: side)

        let modified = try DCTWatermark.embed(bits: bits, intoLuminance: plane, width: side, height: side)
        let recoveredBits = try DCTWatermark.extract(bitCount: bits.count, fromLuminance: modified, width: side, height: side)
        let recovered = try WatermarkPayload.decode(recoveredBits)
        XCTAssertEqual(recovered, payload)
    }
}
