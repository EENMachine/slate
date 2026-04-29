//
//  DCTWatermark.swift
//  Slate
//
//  Block-DCT spread-spectrum watermarking on the luminance channel.
//
//  Algorithm: signed mid-frequency coefficient embedding, a simplified
//  variant of Cox et al. 1997, "Secure Spread Spectrum Watermarking for
//  Multimedia" (IEEE TIP 6:12). For each 8×8 luminance block we apply a
//  forward DCT-II, force the sign of one fixed mid-frequency coefficient
//  to encode one payload bit (with a guaranteed minimum magnitude so the
//  sign survives `Int8` round-tripping), then inverse DCT.
//
//  MVP scope (per Coordinator's open-Q note 2026-04-29):
//    - Single keyframe only (caller picks which one).
//    - File-level invisible watermark — does NOT target re-encoding /
//      screen-recording survival. That's a future-Ian decision.
//
//  This file is pure math: it operates on a Float luminance plane and
//  knows nothing about AVFoundation. See `VideoFrameIO.swift` for the
//  decode/encode glue and `Payload.swift` for the bit-level wire format.
//

import Accelerate
import Foundation

// MARK: - Public API

enum DCTWatermark {
    /// Side length of each DCT block. JPEG-style 8×8 blocks.
    static let blockSize: Int = 8

    /// Position of the mid-frequency coefficient that carries the bit.
    /// `(row=3, col=4)` is high enough to be invisible to the eye but
    /// low enough that quantization typically preserves its sign.
    static let coefficientRow: Int = 3
    static let coefficientCol: Int = 4

    /// Minimum |coefficient| we enforce in the DCT domain after embedding.
    /// With orthonormal 2-D DCT-II/III on 8×8 blocks, the spatial peak
    /// of an iDCT'd unit impulse at (i,j) where both i,j > 0 is `2/N` =
    /// 0.25, so strength=16 gives a spatial perturbation peak of ±4 luma
    /// units. That sits comfortably above UInt8 quantization noise
    /// (±0.5/pixel) and small enough to avoid clipping for any host
    /// pixel between 4 and 251 (i.e., everything except deep shadows
    /// and blown highlights, which are rare in real footage).
    static let strength: Float = 16.0

    /// Embed `bits` into the luminance plane, returning a new plane with
    /// the same dimensions. Plane stride must equal `width`.
    ///
    /// Throws if the plane has fewer 8×8 blocks than there are bits.
    static func embed(
        bits: [Bool],
        intoLuminance plane: [Float],
        width: Int,
        height: Int
    ) throws -> [Float] {
        try precheck(plane: plane, width: width, height: height, bitCount: bits.count)
        var output = plane

        for (bitIndex, bit) in bits.enumerated() {
            let (bx, by) = blockOrigin(forBitIndex: bitIndex, imageWidth: width)
            var block = readBlock(from: output, at: (bx, by), stride: width)
            forwardDCT(&block)
            let i = coefficientRow * blockSize + coefficientCol
            block[i] = signedMagnitude(block[i], targetSign: bit ? 1 : -1)
            inverseDCT(&block)
            writeBlock(block, into: &output, at: (bx, by), stride: width)
        }
        return output
    }

    /// Extract `bitCount` bits from `plane`. Reads the sign of the same
    /// mid-frequency DCT coefficient that `embed` writes.
    static func extract(
        bitCount: Int,
        fromLuminance plane: [Float],
        width: Int,
        height: Int
    ) throws -> [Bool] {
        try precheck(plane: plane, width: width, height: height, bitCount: bitCount)

        var bits: [Bool] = []
        bits.reserveCapacity(bitCount)
        for bitIndex in 0..<bitCount {
            let (bx, by) = blockOrigin(forBitIndex: bitIndex, imageWidth: width)
            var block = readBlock(from: plane, at: (bx, by), stride: width)
            forwardDCT(&block)
            let i = coefficientRow * blockSize + coefficientCol
            bits.append(block[i] >= 0)
        }
        return bits
    }

    // MARK: - Errors

    enum WatermarkError: Error, CustomStringConvertible {
        case dimensionsNotBlockAligned(width: Int, height: Int)
        case insufficientBlocks(needed: Int, available: Int)
        case dctSetupFailed

        var description: String {
            switch self {
            case .dimensionsNotBlockAligned(let w, let h):
                return "Frame \(w)×\(h) is not a multiple of \(blockSize) on both axes."
            case .insufficientBlocks(let n, let a):
                return "Need \(n) DCT blocks but frame only has \(a)."
            case .dctSetupFailed:
                return "vDSP_DCT_CreateSetup returned nil."
            }
        }
    }

    // MARK: - Internals

    private static func precheck(
        plane: [Float],
        width: Int,
        height: Int,
        bitCount: Int
    ) throws {
        guard width % blockSize == 0, height % blockSize == 0 else {
            throw WatermarkError.dimensionsNotBlockAligned(width: width, height: height)
        }
        let blocksPerRow = width / blockSize
        let totalBlocks = blocksPerRow * (height / blockSize)
        guard bitCount <= totalBlocks else {
            throw WatermarkError.insufficientBlocks(needed: bitCount, available: totalBlocks)
        }
        precondition(plane.count == width * height, "Plane size must equal width*height (no stride padding).")
    }

    private static func blockOrigin(forBitIndex bitIndex: Int, imageWidth: Int) -> (x: Int, y: Int) {
        let blocksPerRow = imageWidth / blockSize
        let bx = (bitIndex % blocksPerRow) * blockSize
        let by = (bitIndex / blocksPerRow) * blockSize
        return (bx, by)
    }

    private static func readBlock(from plane: [Float], at origin: (x: Int, y: Int), stride: Int) -> [Float] {
        var out = [Float](repeating: 0, count: blockSize * blockSize)
        for r in 0..<blockSize {
            let srcStart = (origin.y + r) * stride + origin.x
            let dstStart = r * blockSize
            for c in 0..<blockSize {
                out[dstStart + c] = plane[srcStart + c]
            }
        }
        return out
    }

    private static func writeBlock(_ block: [Float], into plane: inout [Float], at origin: (x: Int, y: Int), stride: Int) {
        for r in 0..<blockSize {
            let dstStart = (origin.y + r) * stride + origin.x
            let srcStart = r * blockSize
            for c in 0..<blockSize {
                plane[dstStart + c] = block[srcStart + c]
            }
        }
    }

    /// Manual orthonormal 2-D DCT-II / DCT-III implementation. We can't
    /// use `vDSP_DCT_Execute` here because Apple's vDSP only supports DCT
    /// lengths of `f × 2^n` with `n ≥ 4` (i.e., min length 16). For our
    /// 8×8 blocks the vDSP setup silently returns nil, and the wrapper
    /// becomes a no-op — which is exactly the bug that made every
    /// watermark "DCT-domain" embed actually run in spatial domain and
    /// produced the broken UInt8-quantization behavior. The orthonormal
    /// form below is its own inverse: `inverseDCT(forwardDCT(x)) == x`
    /// to floating-point precision, with no scaling factor required.
    private static func forwardDCT(_ block: inout [Float]) {
        block = manual2D(block, inverse: false)
    }

    private static func inverseDCT(_ block: inout [Float]) {
        block = manual2D(block, inverse: true)
    }

    private static func manual2D(_ block: [Float], inverse: Bool) -> [Float] {
        let N = blockSize
        // Row pass first.
        var afterRows = [Float](repeating: 0, count: N * N)
        for r in 0..<N {
            var row = [Float](repeating: 0, count: N)
            for c in 0..<N { row[c] = block[r * N + c] }
            let transformed = manual1D(row, inverse: inverse)
            for c in 0..<N { afterRows[r * N + c] = transformed[c] }
        }
        // Column pass.
        var result = [Float](repeating: 0, count: N * N)
        for c in 0..<N {
            var col = [Float](repeating: 0, count: N)
            for r in 0..<N { col[r] = afterRows[r * N + c] }
            let transformed = manual1D(col, inverse: inverse)
            for r in 0..<N { result[r * N + c] = transformed[r] }
        }
        return result
    }

    /// 1-D orthonormal DCT-II (forward) or DCT-III (inverse). N = `blockSize`.
    private static func manual1D(_ x: [Float], inverse: Bool) -> [Float] {
        let N = x.count
        let a0 = Float(1.0 / Foundation.sqrt(Double(N)))
        let a1 = Float(Foundation.sqrt(2.0 / Double(N)))
        var y = [Float](repeating: 0, count: N)
        if !inverse {
            // Forward: y[k] = α(k) · Σ_n x[n] · cos((2n+1)·k·π / 2N)
            for k in 0..<N {
                var sum: Float = 0
                for n in 0..<N {
                    let angle = Double(2 * n + 1) * Double(k) * .pi / Double(2 * N)
                    sum += x[n] * Float(cos(angle))
                }
                y[k] = (k == 0 ? a0 : a1) * sum
            }
        } else {
            // Inverse: y[n] = Σ_k α(k) · X[k] · cos((2n+1)·k·π / 2N)
            for n in 0..<N {
                var sum: Float = 0
                for k in 0..<N {
                    let alpha = (k == 0) ? a0 : a1
                    let angle = Double(2 * n + 1) * Double(k) * .pi / Double(2 * N)
                    sum += alpha * x[k] * Float(cos(angle))
                }
                y[n] = sum
            }
        }
        return y
    }

    /// Force the sign of a DCT coefficient to `targetSign` (±1) while
    /// guaranteeing |coefficient| ≥ `strength`, so subsequent rounding to
    /// 8-bit luminance preserves the sign on round-trip.
    private static func signedMagnitude(_ value: Float, targetSign: Int) -> Float {
        let mag = max(abs(value), strength)
        return targetSign >= 0 ? mag : -mag
    }
}
