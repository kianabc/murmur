# Changelog

All notable changes are recorded here. Versions follow [semantic versioning](https://semver.org):
`MAJOR.MINOR.PATCH` — patch for fixes, minor for features, major for breaking changes.

## [1.2.1] — 2026-08-13

### Fixed
- **Murmur went deaf after the Mac slept or the audio hardware changed.** The
  microphone engine was started once and assumed to run forever, but macOS stops
  it and invalidates the tap whenever the hardware changes underneath it —
  headphones in or out, a display plugged in, a Bluetooth device connecting,
  waking from sleep. Nothing failed loudly; buffers just stopped arriving and
  every dictation came back empty. The engine now rebuilds itself when that
  happens.
- **A dictation could hang forever and lock out every one after it.** Waiting for
  the recogniser to start was the one step without a time limit, so when the
  microphone had gone quiet it never returned. The app stayed on "Transcribing…"
  and silently ignored the key from then on, which looked exactly like a crash.
  That wait is now bounded, and a watchdog releases the app if anything else ever
  strands it.
- The log now says when a key press was ignored, and why.

## [1.2.0] — 2026-08-12

### Added
- **Murmur now tells you when your API key stops working.** If your provider
  rejects it — revoked, mistyped, or out of credit — the AI Cleanup tab marks it
  **Rejected**, with the provider's own explanation and a link to get a new one.
  A warning also appears in the menu bar until you replace it.
- **A Test button** beside your saved key, so you can check it works without
  waiting to find out mid-sentence. A newly pasted key is checked automatically.

### Fixed
- A dead key used to fail silently: cleanup quietly stopped happening and the
  raw transcript went through, so it looked like the AI had simply got worse.

## [1.1.0] — 2026-08-07

### Added
- **Choose your AI provider** — Anthropic (Claude) or OpenAI (ChatGPT), each with
  three models from cheapest to most capable, with a monthly estimate beside
  each. Keys are kept per provider, so switching back doesn't lose one.
- **Spend tracking** moved into the AI Cleanup tab: last 7 days, last 30 days and
  all time, split by provider since each bills you separately.
- **A proper welcome screen** on first run, explaining the permissions macOS
  requires instead of dropping you into settings.
- Prices refresh daily, so a provider changing rates doesn't need an app update.

### Fixed
- Usage was never being recorded — cleanup ran and cost money while the tracker
  stayed at zero.
- The app stopped listening for the dictation key in some situations.
- A crash when the settings window was open during a dictation.
- Silence now says "Didn't catch that" instead of appearing to do nothing.

### Changed
- Download is ~1.3 MB, down from 57 MB.
- Requires macOS 26 or later. Below that the app installed but silently did
  nothing.

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
