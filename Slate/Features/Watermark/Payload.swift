//
//  Payload.swift
//  Slate
//
//  Wire format for the watermark payload — turns the
//  `EENMACHINES:<shootID>` string into a bit array suitable for
//  `DCTWatermark.embed`, and back.
//
//  Format (all big-endian within each block):
//
//      [ MAGIC: 16 bits ][ LEN: 16 bits ][ UTF-8 bytes ][ CRC-16: 16 bits ]
//
//  Then each bit is repeated `repetitionFactor` times (default 5) for
//  forward error correction. Decode majority-votes each group of N. Crude
//  but effective at the MVP "no re-encoding survival" target.
//

import Foundation

enum WatermarkPayload {
    /// Anti-collision constant. ASCII `EM` (EENMACHINES) flipped on its head.
    static let magic: UInt16 = 0xEE_4D
    /// Bits per logical bit, for the repetition code. Odd so majority voting
    /// is unambiguous.
    static let repetitionFactor: Int = 5
    /// CRC-16/CCITT (XMODEM) polynomial.
    private static let crcPoly: UInt16 = 0x1021

    enum PayloadError: Error, CustomStringConvertible {
        case payloadTooLarge(byteCount: Int)
        case truncatedHeader
        case badMagic(found: UInt16)
        case truncatedBody(needed: Int, got: Int)
        case crcMismatch(expected: UInt16, got: UInt16)
        case invalidUTF8

        var description: String {
            switch self {
            case .payloadTooLarge(let n): return "Payload \(n) bytes exceeds the 16-bit length field."
            case .truncatedHeader:        return "Bit stream too short to contain a header."
            case .badMagic(let m):        return "Magic mismatch: got 0x\(String(m, radix: 16, uppercase: true))."
            case .truncatedBody(let n, let g): return "Expected \(n) body bits, only \(g) present."
            case .crcMismatch(let e, let g):
                return "CRC mismatch: expected 0x\(String(e, radix: 16, uppercase: true)), got 0x\(String(g, radix: 16, uppercase: true))."
            case .invalidUTF8:            return "Decoded bytes are not valid UTF-8."
            }
        }
    }

    // MARK: - Encode

    /// Convert a payload string into the bit stream that
    /// `DCTWatermark.embed` consumes.
    static func encode(_ payload: String) throws -> [Bool] {
        let bytes = Array(payload.utf8)
        guard bytes.count <= Int(UInt16.max) else {
            throw PayloadError.payloadTooLarge(byteCount: bytes.count)
        }

        var headerAndBody: [UInt8] = []
        headerAndBody.reserveCapacity(4 + bytes.count + 2)
        headerAndBody.append(UInt8((magic >> 8) & 0xFF))
        headerAndBody.append(UInt8(magic & 0xFF))
        let len = UInt16(bytes.count)
        headerAndBody.append(UInt8((len >> 8) & 0xFF))
        headerAndBody.append(UInt8(len & 0xFF))
        headerAndBody.append(contentsOf: bytes)

        let crc = crc16(headerAndBody)
        headerAndBody.append(UInt8((crc >> 8) & 0xFF))
        headerAndBody.append(UInt8(crc & 0xFF))

        let rawBits = bitsFromBytes(headerAndBody)
        return repeatBits(rawBits, factor: repetitionFactor)
    }

    /// Decode a bit stream produced by `encode(_:)`.
    static func decode(_ bits: [Bool]) throws -> String {
        let collapsed = majorityVote(bits, factor: repetitionFactor)
        let bytes = bytesFromBits(collapsed)

        guard bytes.count >= 4 else { throw PayloadError.truncatedHeader }
        let receivedMagic = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard receivedMagic == magic else {
            throw PayloadError.badMagic(found: receivedMagic)
        }
        let len = Int((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
        guard bytes.count >= 4 + len + 2 else {
            throw PayloadError.truncatedBody(needed: 4 + len + 2, got: bytes.count)
        }

        let bodyEnd = 4 + len
        let body = Array(bytes[4..<bodyEnd])
        let crcReceived = (UInt16(bytes[bodyEnd]) << 8) | UInt16(bytes[bodyEnd + 1])

        // Recompute CRC over magic+len+body.
        let crcExpected = crc16(Array(bytes[0..<bodyEnd]))
        guard crcExpected == crcReceived else {
            throw PayloadError.crcMismatch(expected: crcExpected, got: crcReceived)
        }

        guard let str = String(bytes: body, encoding: .utf8) else {
            throw PayloadError.invalidUTF8
        }
        return str
    }

    /// Total number of bits the encoder will emit for a payload of `byteCount` UTF-8 bytes.
    static func bitCount(forPayloadByteCount byteCount: Int) -> Int {
        // 2 bytes magic + 2 bytes len + N bytes body + 2 bytes CRC = N+6 bytes.
        // Each byte = 8 bits, then repetition factor.
        (byteCount + 6) * 8 * repetitionFactor
    }

    // MARK: - Bit / byte conversion (MSB-first)

    static func bitsFromBytes(_ bytes: [UInt8]) -> [Bool] {
        var bits: [Bool] = []
        bits.reserveCapacity(bytes.count * 8)
        for byte in bytes {
            for i in (0..<8).reversed() {
                bits.append((byte >> i) & 1 == 1)
            }
        }
        return bits
    }

    static func bytesFromBits(_ bits: [Bool]) -> [UInt8] {
        let usableBitCount = (bits.count / 8) * 8
        var bytes: [UInt8] = []
        bytes.reserveCapacity(usableBitCount / 8)
        var i = 0
        while i < usableBitCount {
            var byte: UInt8 = 0
            for j in 0..<8 {
                if bits[i + j] { byte |= 1 << (7 - j) }
            }
            bytes.append(byte)
            i += 8
        }
        return bytes
    }

    // MARK: - Repetition code

    private static func repeatBits(_ bits: [Bool], factor: Int) -> [Bool] {
        var out: [Bool] = []
        out.reserveCapacity(bits.count * factor)
        for b in bits {
            for _ in 0..<factor { out.append(b) }
        }
        return out
    }

    private static func majorityVote(_ bits: [Bool], factor: Int) -> [Bool] {
        guard factor > 0, bits.count >= factor else { return [] }
        let groupCount = bits.count / factor
        var out: [Bool] = []
        out.reserveCapacity(groupCount)
        for g in 0..<groupCount {
            var ones = 0
            for k in 0..<factor where bits[g * factor + k] { ones += 1 }
            out.append(ones * 2 > factor)
        }
        return out
    }

    // MARK: - CRC-16/CCITT-XMODEM

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ crcPoly
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }
}
