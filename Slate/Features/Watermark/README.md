# Watermark

Embeds **invisible** watermarks into video files. Default payload: `EENMACHINES:<shootID>` (see `Branding.watermarkPayload(shootID:)`).

## What this folder does today

MVP is in. **Single-keyframe, file-level invisible watermark** via 8×8 block-DCT spread-spectrum embedding on the luminance channel. Re-encoding survival is **not** a target — that decision is parked for Ian.

- `DCTWatermark.swift` — pure-math forward / inverse 2-D DCT-II via `vDSP_DCT_Execute`. Embeds one bit per 8×8 block by forcing the sign of a fixed mid-frequency coefficient (row 3, col 4, magnitude ≥ 8.0) to encode `0` or `1`. Algorithm cited in the file header (Cox et al. 1997, simplified to signed-magnitude embedding).
- `Payload.swift` — bit-level wire format: `MAGIC(16) | LEN(16) | UTF-8 body | CRC-16/CCITT(16)`, then a 5× repetition code for forward error correction. Majority vote on decode.
- `VideoFrameIO.swift` — AVFoundation glue. `AVAssetReader` pulls frames as 32BGRA, the first keyframe's luminance plane gets the watermark, then `AVAssetWriter` re-encodes with H.264 via VideoToolbox. **No FFmpeg, no x264** — see License Posture below.
- `Services/MediaPipeline.swift` — `MediaPipeline.shared` ties it together. `embed(_:)` → `WatermarkResult` carries `verified: Bool` (round-trip extracted matches the payload byte-for-byte).
- `View.swift` / `ViewModel.swift` — drag-or-pick files, queue them, run the queue. Output goes to `<source-name>-watermarked.<ext>` next to the source.

## Tests

`Tests/Watermark/`:
- `DCTWatermarkTests.swift` — round-trip on synthetic gradient planes (alternating, all-ones, all-zeros, full payload via the encoder). Bounds checks for non-block-aligned dimensions and overflowing bit counts.
- `PayloadTests.swift` — encode/decode round-trip including UTF-8 multibyte and emoji, repetition code single-bit-flip recovery, CRC mismatch detection, magic mismatch detection.

The XCTest target `SlateTests` is wired in `project.yml` and runs against the host app.

**Verified status as of 2026-04-29:** Tests are written but unrun on a Mac. Reviewer / Documentation: please run the test bundle on the first Mac build and flag anything that doesn't pass — the DCT math and the `vDSP_DCT_Execute` call shape are the most likely fragile spots.

## License posture (locked)

> **License posture (locked):** FFmpeg built **without `--enable-gpl` and without `--enable-nonfree`** — LGPL only. Link dynamically (separate `.dylib`s in `Frameworks/`), include LGPL text + offer for source. Do **not** use x264 (GPL); use Apple's VideoToolbox H.264/HEVC encoders for any re-encode step.

The MVP doesn't link FFmpeg at all — VideoToolbox's H.264 encoder is sufficient for the re-encode path. If a future iteration needs FFmpeg (e.g. format coverage), the LGPL-only build is the constraint.

## Open questions / future work

- **Robustness target** — currently file-level only. Re-encoding / screen-recording / platform-transcode survival needs an algorithm bump (e.g. wavelet-domain marks, larger payload spread across many frames). Park until Ian decides the target.
- **Sample-level passthrough** — currently we re-encode every frame. A future optimization is to splice only the modified frame into a passthrough copy of the original; needs careful `CMSampleBuffer` surgery and an open-GOP awareness check.
- **Multiple keyframes** — embedding the same payload across all I-frames would help robustness against re-encoding without changing the algorithm.
