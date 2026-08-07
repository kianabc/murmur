# Changelog

All notable changes are recorded here. Versions follow [semantic versioning](https://semver.org):
`MAJOR.MINOR.PATCH` — patch for fixes, minor for features, major for breaking changes.

## [Unreleased]

### Added
- Usage tracking: tokens sent and received, cost over the last 30 days and all time,
  with a per-model breakdown.
- Automatic update checking against GitHub Releases.

### Changed
- Minimum macOS raised to 26.0. `SpeechAnalyzer` doesn't exist below it, so older
  systems previously installed the app and got a silent no-op.
- Removed the sherpa-onnx dependency, unused since the switch to Apple's
  recogniser. Download drops from 57 MB to about 3 MB.

## [0.1.0] — 2026-08-06

First working version.

### Added
- Hold-to-talk dictation with a configurable key (Right ⌘ by default), double-tap
  to latch, Esc to cancel.
- Streaming transcription on-device via Apple's `SpeechAnalyzer`.
- Manual correction ledger — teach it a word it mishears and it fixes it everywhere.
- Optional AI cleanup: removes "um", resolves "3, sorry 4" into "4", fixes
  homophones from context, adds punctuation.
- A diff guard that rejects any cleanup that looks like invention and falls back
  to the raw transcript.
- Caret-anchored HUD with a live input-level meter.
- Text either typed into the frontmost app or copied to the clipboard.
- Tabbed settings; API key stored in the Keychain.
