# Changelog

All notable changes are recorded here. Versions follow [semantic versioning](https://semver.org):
`MAJOR.MINOR.PATCH` — patch for fixes, minor for features, major for breaking changes.

## [1.8.2] — 2026-10-01

### Fixed
- **Two dictations in a row no longer run together.** Stopping and starting again
  used to join the sentences with no gap — "back to back.You can see it here."
  Murmur now adds a space when the cursor is sitting straight after a word, and
  doesn't when it would be wrong: inside a bracket or quote, mid hyphenated word,
  or at the start of a line.
- **The listening popup disappearing for the rest of the session.** It was being
  placed and asked to come forward every time, correctly, and simply wasn't
  appearing — so it now checks whether it actually did, and builds a new one when
  it didn't.

## [1.9.0] — 2026-10-03

### Added
- **The last ten dictations are under the menu bar icon, as "Type Again".** If
  one didn't land — wrong window, a read-only view, anything — pick it and it is
  typed into whatever is focused now. Nothing is guessed and the clipboard is
  never used for it. The list lives in memory only and is gone when Murmur quits.

### Fixed
- **Dictating with the cursor outside a text field lost the text silently.** The
  check that decides whether there's anywhere to type was trusting a signal that
  turned out to mean nothing — every app reports it, including the ones that
  can't accept text. It now goes by what the focused thing actually is, and when
  there is nowhere to type it says so and points you at Type Again instead of
  touching your clipboard.
- **Two dictations in a row no longer run together.** A space is added when the
  cursor sits straight after a word, and not when it would be wrong: inside a
  bracket or quote, mid hyphenated word, or at the start of a line.
- **The listening popup disappearing for the rest of a session.** It now checks
  whether it actually appeared and builds a new one when it didn't.
- The last lines before Murmur quits are no longer lost from the log, which had
  made an ordinary shutdown look like the app vanishing.

### Changed
- The short-phrase word count is a menu again — 5, 10, 15, 20 or 30.

## [1.8.0] — 2026-10-01

### Added
- **Murmur updates itself.** When a new version appears it asks, and if you say
  yes it downloads, verifies and restarts into the new one. No disk image to
  mount, no dragging, no re-granting permissions.
- Before anything is installed, Murmur checks the download was signed by the
  same developer as the copy you're running and notarised by Apple, and that it
  is actually newer. A validly signed app belonging to someone else is refused,
  as is a tampered one, and so is a downgrade.
- The update offer is also on the menu bar and in Settings → About, so a check
  you dismissed isn't lost.

### Fixed
- An available update was written to the log and nowhere else, so unless you
  went looking in Settings you were never told one existed.

## [1.7.0] — 2026-10-01

### Added
- **Nothing you dictate is lost when there's nowhere to type it.** If the cursor
  isn't in a text field when you finish, Murmur copies the text to your clipboard
  and says so on screen — "Couldn't type that — copied. Press ⌘V" — instead of
  pasting into a window that ignores it.
- The same now happens, with the same message, when a password field is focused
  or when Accessibility isn't granted. Those used to end in silence or an error
  with your words gone.

### Changed
- **Short phrases now mean ten words or fewer, up from six**, and the threshold
  is a proper setting under AI Cleanup — step it anywhere from 2 to 30 words
  instead of picking from a short list. Six was too eager: it was sending 94
  real dictations straight through without cleanup.
- **Murmur no longer refuses to start when it can't find a text field.** Throwing
  away the dictation is worse than recording it and handing it back on the
  clipboard, so it records. The old behaviour is still available under
  General → Text output.
- The on-screen message after a dictation you have to act on now stays up for
  five seconds rather than two — long enough to read it and press ⌘V.

### Fixed
- **The listening popup now appears every time, immediately.** It was waiting on
  a series of questions to the app you're in before it could draw, so on a short
  dictation it often never appeared at all — which teaches you to keep talking
  and hope. It now opens at once and slides to your cursor a moment later.
- **The popup no longer lands at the top of the screen in terminals and
  editors.** It was being placed just *outside* whatever the app reported as
  focused — and in a terminal that's the entire text view, so "just below" fell
  off the screen and it ended up pinned to the top edge. It now judges by the
  size of the area rather than its label, and sits inside it, low and centred,
  when it can't find the actual cursor.
- Diagnostics recorded "no focused element" without saying which app said it,
  which was the one detail needed to widen the list of places Murmur knows it
  can't type into.

## [1.6.2] — 2026-08-29

### Fixed
- **Murmur wrongly decided your text hadn't been pasted, and took it back.** The
  check added in 1.6.0 asked macOS whether the text field had changed after
  pasting. It turns out macOS often answers with stale information — across 73
  real dictations it claimed failure 11 times, every one of them reporting the
  cursor at the very start of documents thousands of characters long. Each false
  alarm replaced whatever was on your clipboard and put an error on screen.
  Murmur no longer acts on that signal at all. Your clipboard is left alone.
- **An error message blocked the next dictation for two seconds.** Pressing the
  key while a failure was still on screen did nothing and said nothing, which
  looks exactly like the app having died.
- **New: "Copy It Again" in the menu bar.** If a dictation ever does go nowhere,
  the last transcript is one click from your clipboard — no guessing required,
  which is the part the automatic version got wrong.

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
