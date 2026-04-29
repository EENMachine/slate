//
//  PayloadTests.swift
//  SlateTests
//

import XCTest
@testable import Slate

final class PayloadTests: XCTestCase {
    func testRoundTrip_simpleASCII() throws {
        let original = "EENMACHINES:SH-20260429-001"
        let bits = try WatermarkPayload.encode(original)
        let decoded = try WatermarkPayload.decode(bits)
        XCTAssertEqual(decoded, original)
    }

    func testRoundTrip_emptyString() throws {
        let bits = try WatermarkPayload.encode("")
        let decoded = try WatermarkPayload.decode(bits)
        XCTAssertEqual(decoded, "")
    }

    func testRoundTrip_utf8Multibyte() throws {
        let original = "EENMACHINES:Café-007 \u{1F3AC}"  // includes emoji + accent
        let bits = try WatermarkPayload.encode(original)
        let decoded = try WatermarkPayload.decode(bits)
        XCTAssertEqual(decoded, original)
    }

    func testRepetitionCode_correctsSingleBitFlipPerGroup() throws {
        let original = "ABC"
        var bits = try WatermarkPayload.encode(original)
        // Flip one bit in each repetition group of 5 — majority vote
        // should still recover the original.
        let factor = WatermarkPayload.repetitionFactor
        var i = 0
        while i + factor <= bits.count {
            bits[i].toggle()
            i += factor
        }
        let decoded = try WatermarkPayload.decode(bits)
        XCTAssertEqual(decoded, original)
    }

    func testCRCMismatch_throws() throws {
        let original = "abc"
        var bits = try WatermarkPayload.encode(original)
        // Corrupt every bit in one group — flips the underlying logical
        // bit and breaks the CRC.
        let factor = WatermarkPayload.repetitionFactor
        let flipBase = (bits.count / factor / 2) * factor
        for k in 0..<factor { bits[flipBase + k].toggle() }
        XCTAssertThrowsError(try WatermarkPayload.decode(bits))
    }

    func testBadMagic_throws() throws {
        var bits = try WatermarkPayload.encode("hello")
        // Corrupt the first repetition group hard so majority vote flips
        // the very first logical bit, ruining the magic word.
        for k in 0..<WatermarkPayload.repetitionFactor {
            bits[k].toggle()
        }
        XCTAssertThrowsError(try WatermarkPayload.decode(bits))
    }

    func testBitCount_predictionMatchesEncode() throws {
        for byteCount in [0, 1, 5, 27, 200] {
            let payload = String(repeating: "x", count: byteCount)
            let bits = try WatermarkPayload.encode(payload)
            XCTAssertEqual(
                bits.count,
                WatermarkPayload.bitCount(forPayloadByteCount: byteCount),
                "Mismatch for \(byteCount)-byte payload"
            )
        }
    }

    func testBitsBytesRoundTrip() {
        let originalBytes: [UInt8] = [0x00, 0xFF, 0xEE, 0x4D, 0x42, 0x99, 0x01, 0x80]
        let bits = WatermarkPayload.bitsFromBytes(originalBytes)
        XCTAssertEqual(bits.count, originalBytes.count * 8)
        let recovered = WatermarkPayload.bytesFromBits(bits)
        XCTAssertEqual(recovered, originalBytes)
    }
}
