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

        // FALSE bit
        let modifiedF = try DCTWatermark.embed(bits: [false], intoLuminance: plane, width: w, height: h)
        let deltaF = (0..<8).flatMap { r in (0..<8).map { c in modifiedF[r * w + c] - plane[r * w + c] } }

        // TRUE bit
        let modifiedT = try DCTWatermark.embed(bits: [true], intoLuminance: plane, width: w, height: h)
        let deltaT = (0..<8).flatMap { r in (0..<8).map { c in modifiedT[r * w + c] - plane[r * w + c] } }

        // Per-pixel snapshot of first row for each
        let rowF = deltaF[0..<8].map { String(format: "%.2f", $0) }.joined(separator: ",")
        let rowT = deltaT[0..<8].map { String(format: "%.2f", $0) }.joined(separator: ",")

        let pF = (min: deltaF.min() ?? 0, max: deltaF.max() ?? 0)
        let pT = (min: deltaT.min() ?? 0, max: deltaT.max() ?? 0)

        // Plane row 0, block 0
        let planeRow = (0..<8).map { String(plane[$0]) }.joined(separator: ",")

        XCTFail("DIAG: planeRow0=[\(planeRow)] | FALSE delta range=[\(pF.min)..\(pF.max)] row0=[\(rowF)] | TRUE delta range=[\(pT.min)..\(pT.max)] row0=[\(rowT)]")
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
