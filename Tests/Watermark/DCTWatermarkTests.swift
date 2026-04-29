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

    /// DIAGNOSTIC v3: Test embed→extract on a block with a CONSTANT plane
    /// (no gradient) so any bit-dependent behavior is unambiguous, and
    /// also test multi-bit embed to compare against single-bit.
    func testDiagnostic_singleNegativeBit_block1() throws {
        let w = 64, h = 64

        // Constant plane (value 128) — eliminates host (3,4) coefficient
        // contamination entirely, isolates the embed perturbation.
        let constPlane = [Float](repeating: 128, count: w * h)

        let modConstF = try DCTWatermark.embed(bits: [false], intoLuminance: constPlane, width: w, height: h)
        let modConstT = try DCTWatermark.embed(bits: [true], intoLuminance: constPlane, width: w, height: h)
        let constRowF = (0..<8).map { String(format: "%.2f", modConstF[$0]) }.joined(separator: ",")
        let constRowT = (0..<8).map { String(format: "%.2f", modConstT[$0]) }.joined(separator: ",")

        // Multi-bit on constant plane: bit 0 = false, bit 1 = true.
        let modMulti = try DCTWatermark.embed(bits: [false, true], intoLuminance: constPlane, width: w, height: h)
        let multiRow0 = (0..<8).map { String(format: "%.2f", modMulti[$0]) }.joined(separator: ",")
        let multiRow0_block1 = (8..<16).map { String(format: "%.2f", modMulti[$0]) }.joined(separator: ",")

        // Recover from multi-bit
        let recoveredMulti = try DCTWatermark.extract(bitCount: 2, fromLuminance: modMulti, width: w, height: h)

        XCTFail("DIAG v3: const plane=128 | 1-bit FALSE row0=[\(constRowF)] | 1-bit TRUE row0=[\(constRowT)] | 2-bit [false,true] row0 b0=[\(multiRow0)] b1=[\(multiRow0_block1)] recovered=\(recoveredMulti)")
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
