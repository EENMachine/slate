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

    /// Minimum |coefficient| we enforce after embedding. Bigger = more
    /// robust, more visible. After the (2N)² compensation in `embed` and
    /// the matched `inverseDCT` normalization, this becomes the spatial-
    /// domain peak of the perturbation in luminance units. 16 keeps the
    /// signal well above UInt8 quantization noise (~±0.5/pixel) while
    /// staying imperceptible on natural footage (<7% of one luma step).
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

        // vDSP's DCT-II/III are unnormalized: forward then inverse scales
        // by (2N) per 1-D pass, hence (2N)^2 = 256 for our 2-D 8×8 block.
        // We compensate inside `inverseDCT`, but that means the modified
        // coefficient must be pre-multiplied by the same factor so its
        // spatial-domain footprint after iDCT is on the order of `strength`
        // (otherwise UInt8 round-trip rounds the embedded sign away).
        let scale = Float((2 * blockSize) * (2 * blockSize))

        for (bitIndex, bit) in bits.enumerated() {
            let (bx, by) = blockOrigin(forBitIndex: bitIndex, imageWidth: width)
            var block = readBlock(from: output, at: (bx, by), stride: width)
            forwardDCT(&block)
            let i = coefficientRow * blockSize + coefficientCol
            block[i] = signedMagnitude(block[i], targetSign: bit ? 1 : -1) * scale
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

    /// Forward 2-D DCT-II via two passes of `vDSP_DCT_Execute`. Mutates
    /// `block` in place. `block.count` must equal `blockSize * blockSize`.
    private static func forwardDCT(_ block: inout [Float]) {
        do2DDCT(&block, kind: .forward)
    }

    private static func inverseDCT(_ block: inout [Float]) {
        do2DDCT(&block, kind: .inverse)
        // vDSP's DCT-II then DCT-III scales by 2N per 1-D pass. Apply the
        // (2N)^2 normalization here so that, in the absence of coefficient
        // edits, `forwardDCT` followed by `inverseDCT` is the identity on
        // the spatial-domain block.
        let invScale = 1.0 / Float((2 * blockSize) * (2 * blockSize))
        for k in 0..<block.count {
            block[k] *= invScale
        }
    }

    private enum DCTKind {
        case forward, inverse
    }

    /// Single-block 2-D DCT helper. Builds the 1-D vDSP setups lazily on
    /// first use and caches them for the lifetime of the process.
    private static func do2DDCT(_ block: inout [Float], kind: DCTKind) {
        guard let setup = (kind == .forward) ? Self.forwardSetup : Self.inverseSetup else {
            // Setup failure is unrecoverable — leave block untouched.
            return
        }

        var rowBuf = [Float](repeating: 0, count: blockSize)
        // Row pass.
        for r in 0..<blockSize {
            for c in 0..<blockSize { rowBuf[c] = block[r * blockSize + c] }
            var dst = [Float](repeating: 0, count: blockSize)
            rowBuf.withUnsafeBufferPointer { srcPtr in
                dst.withUnsafeMutableBufferPointer { dstPtr in
                    vDSP_DCT_Execute(setup, srcPtr.baseAddress!, dstPtr.baseAddress!)
                }
            }
            for c in 0..<blockSize { block[r * blockSize + c] = dst[c] }
        }
        var colBuf = [Float](repeating: 0, count: blockSize)
        // Column pass.
        for c in 0..<blockSize {
            for r in 0..<blockSize { colBuf[r] = block[r * blockSize + c] }
            var dst = [Float](repeating: 0, count: blockSize)
            colBuf.withUnsafeBufferPointer { srcPtr in
                dst.withUnsafeMutableBufferPointer { dstPtr in
                    vDSP_DCT_Execute(setup, srcPtr.baseAddress!, dstPtr.baseAddress!)
                }
            }
            for r in 0..<blockSize { block[r * blockSize + c] = dst[r] }
        }
    }

    /// Force the sign of a DCT coefficient to `targetSign` (±1) while
    /// guaranteeing |coefficient| ≥ `strength`, so subsequent rounding to
    /// 8-bit luminance preserves the sign on round-trip.
    private static func signedMagnitude(_ value: Float, targetSign: Int) -> Float {
        let mag = max(abs(value), strength)
        return targetSign >= 0 ? mag : -mag
    }

    // Lazily-built vDSP setups. `vDSP_DCT_CreateSetup` is expensive —
    // build once and reuse.
    private static let forwardSetup: vDSP_DFT_Setup? = vDSP_DCT_CreateSetup(
        nil, vDSP_Length(blockSize), .II
    )
    private static let inverseSetup: vDSP_DFT_Setup? = vDSP_DCT_CreateSetup(
        nil, vDSP_Length(blockSize), .III
    )
}
