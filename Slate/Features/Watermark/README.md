# Watermark

Embeds **invisible** watermarks into video files. Default payload: `EENMACHINES:<shootID>` (see `Branding.watermarkPayload(shootID:)`).

## What this folder is right now

A scaffold.

- `View.swift` — input (drag-drop / picker), payload preview, queue, process-queue toolbar action.
- `ViewModel.swift` — `WatermarkJob` model with status enum (queued / processing / done / failed).

## TODO(slate-watermark)

1. **Robustness target** — confirm with client. Options, hardest to easiest:
   - survives screen-recording (very hard, needs DCT/wavelet domain marks),
   - survives re-encoding / platform transcodes,
   - file-level only.
   Algorithm choice depends on the answer.
2. Pick an implementation path:
   - Swift port of an open-source `invisible-watermark` style algo, or
   - Python sidecar with `invisible-watermark` (PyTorch dep) called via XPC, or
   - FFmpeg with a custom filter chain.
3. Wire `MediaPipeline.embed(payload:into:outputTo:)`.
4. Output directory: user-selected via the `user-selected.read-write` entitlement.
5. Verify the watermark on a roundtrip before declaring success.
6. License audit — FFmpeg LGPL/GPL implications for distribution. Loop in Reviewer.
