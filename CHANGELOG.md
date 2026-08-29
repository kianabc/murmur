# Changelog

All notable changes are recorded here. Versions follow [semantic versioning](https://semver.org):
`MAJOR.MINOR.PATCH` — patch for fixes, minor for features, major for breaking changes.

## [1.6.1] — 2026-08-29

### Changed
- **The microphone is no longer held open.** It used to stay open for the life of
  the app so dictation could start instantly, which meant macOS showed its orange
  microphone indicator permanently — and that indicator was telling the truth.
  Murmur now opens the microphone when you start dictating and releases it the
  moment you stop, so the indicator appears only while it's genuinely listening.
  Opening costs about 55 ms.
- The old behaviour is still available under **General → Microphone** if you'd
  rather have the fastest possible start.

### Note
- With the microphone opening on demand there is nothing recorded from before you
  press the key, so begin speaking once the popup appears. Under the always-open
  setting, the rolling buffer still catches a word begun as you reach for the key.

## [1.6.0] — 2026-08-14

### Fixed
- **The "crashes" were not crashes.** When the audio hardware changed, the engine
  sometimes failed to restart — and the single retry never ran, because a failed
  start leaves the engine claiming to be running and every retry believed it.
  Murmur stayed alive and completely deaf until it was quit and reopened. It now
  retries with backoff, and watches for the symptom every silent failure shares:
  no microphone data arriving. If the input goes quiet, it rebuilds itself.
- **The listening popup sometimes appeared only when you let go of the key.**
  Finding your cursor means asking the other app a series of questions, and those
  were being asked before the popup was allowed to draw. The popup now opens
  first and moves to your cursor a moment later, and those questions can no
  longer take more than a moment each.
- **A dictation that failed to paste is no longer lost.** The clipboard used to
  be restored a fraction of a second after pasting, taking the transcript with it
  if the paste hadn't landed. When Murmur can see that nothing was inserted, it
  leaves the text on the clipboard and tells you to press ⌘V. It only does this
  on proof — when it can't tell, your clipboard is left exactly as it was.
- Cleanups that began with the speaker's own "Okay" or "Sure" were being thrown
  away as if the model had added a preamble. You were paying for those.

### Added
- **Cleanup now formats structure it can hear.** Spoken lists become numbered or
  bulleted lines, dictated emails get their greeting, body and sign-off on
  separate lines, and a change of subject starts a new paragraph. Structure that
  wasn't spoken is still treated as invention and rejected.
- Every run records how the last one ended. An unclean exit is called out by name
  at the next launch, fatal signals are captured with a backtrace, and any crash
  report macOS wrote is folded into Murmur's own log.

## [1.5.0] — 2026-08-13

### Added
- **Don't start when there's nowhere to type**, under General → Text output. If
  the key is held with no text field focused, the dictation would end in nothing,
  so it doesn't begin. It only refuses when it's certain — apps describe
  themselves inconsistently, and a wrong refusal is worse than a pointless
  recording, so silence from an app means go ahead.

### Fixed
- **The popup was invisible in some apps**, fullscreen ones especially, even
  though dictation worked and the text arrived. When Murmur can find the window
  but not the caret, it was placing the popup just outside the window — which for
  a fullscreen window is off the edge of the screen, leaving it clamped into a
  corner nowhere near where you're looking. It now sits at the bottom of the
  window, where macOS puts its own dictation indicator.
- The log records which method found your cursor, so "I never see the popup" is
  answerable.

## [1.4.0] — 2026-08-13

### Added
- **Short phrases skip the AI**, under AI Cleanup. "Change it to 15" has nothing
  in it for a model to fix, so it goes straight through with no wait and no cost,
  while longer dictations are still cleaned up. On by default at six words or
  fewer; the threshold is yours to set, and the whole thing switches off.

## [1.3.0] — 2026-08-13

### Added
- **A hold delay before recording starts**, under General → Hotkey. Default
  200 ms, and it costs you no words — Murmur keeps a rolling buffer of what you
  said just before, so the audio from during the delay is still there.

### Fixed
- **Shortcuts using the dictation key no longer start a dictation.** With Right ⌥
  as your key, ⌘⌥ and ⌥⌦ both popped the recorder open. A press arriving with
  another modifier already held is now never a dictation, and a press has to
  survive the hold delay untouched by any other key before it counts.
- A single quick tap no longer starts a recording so short nothing could be said
  in it. Two quick taps still latch.

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
