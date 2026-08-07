# Changelog

All notable changes are recorded here. Versions follow [semantic versioning](https://semver.org):
`MAJOR.MINOR.PATCH` — patch for fixes, minor for features, major for breaking changes.

## [1.0.1] — 2026-08-07

### Changed
- The Cleanup tab is now **AI Cleanup**, and usage moved into it — what you've
  spent belongs beside the switch that causes the spending, not in a separate
  tab.
- Spend is shown as three cards: last 7 days, last 30 days, and all time, with
  the cost as the headline figure and tokens as supporting detail.
- The settings window is taller and resizable so nothing is clipped.

### Fixed
- First launch now opens Settings on the Permissions tab when setup is
  incomplete. Since permissions moved into Settings, a first run with the
  microphone or Accessibility ungranted showed nothing at all — only a menu bar
  icon that appeared to do nothing. Only a failing hotkey triggered the prompt,
  so the two permissions a new user is most likely to be missing were silent.
- The permissions footer now says what to do, not just what's missing.

## [1.0.0] — 2026-08-07

First public release. Signed with a Developer ID and notarised by Apple, so it
installs without any security warnings.

### Dictation
- Hold-to-talk with a configurable key (Right ⌘ by default), double-tap to latch,
  Esc to cancel.
- Streaming transcription on-device via Apple's `SpeechAnalyzer`. Audio never
  leaves your Mac.
- Text is typed at your cursor in any app, or copied to the clipboard if you'd
  rather not grant Accessibility.
- Floating panel anchored beside the caret, with a level meter driven by the real
  microphone signal.

### Getting it right
- Correction ledger: teach it a word it mishears and it's fixed everywhere.
  Corrections are only ever added by you — nothing is inferred from your edits.
- Optional AI cleanup removes "um", resolves "3, sorry 4" into "4", fixes
  homophones from context, and adds punctuation.
- A diff guard compares every cleanup against the raw transcript and discards
  anything that looks like invention rather than editing. A wrong-but-honest
  transcript beats a confident fabrication.

### Settings
- Tabbed: General, Cleanup, Corrections, Usage, Permissions, About.
- Usage tracking — tokens sent and received, cost over 30 days and all time,
  broken down by model. Prices are snapshotted per request, so past costs never
  change if pricing does.
- API key held in the Keychain, read once per launch and never written elsewhere.
- Daily update check against GitHub Releases. It tells you; it never installs
  anything on its own.

### Requirements
- macOS 26 or later, Apple Silicon.
- An Anthropic API key only if you want AI cleanup. Dictation works without one.
