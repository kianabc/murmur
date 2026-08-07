# Murmur

System-wide voice-to-text for macOS. Hold a key, speak, release — cleaned text
appears at your cursor in any app.

See [SPEC.md](SPEC.md) for the design. `murmur` is a placeholder name.

## Build

```bash
./scripts/build-app.sh          # debug
open build/Murmur.app
```

Everything must run from the `.app` bundle — macOS keys TCC permissions and the
microphone prompt to a bundle identity, so a bare executable can't hold either.

To see startup logs, run the binary directly instead of via `open`:

```bash
./build/Murmur.app/Contents/MacOS/Murmur
```

## Dev CLI

Exercises the real pipeline with no microphone or permissions needed:

```bash
murmur-cli transcribe recording.aiff    # transcribe + apply corrections
murmur-cli raw recording.aiff           # transcribe only
murmur-cli learn Versell Vercel         # teach a correction
murmur-cli list                         # show the ledger
```

Build it into the bundle to run with a real bundle identity:

```bash
cp "$(swift build --show-bin-path)/murmur-cli" build/Murmur.app/Contents/MacOS/
```

Or stream the full pipeline:

```bash
log stream --predicate 'subsystem == "com.torimi.murmur"'
```

## Status

| Milestone | State |
|---|---|
| M0 — menu bar, hotkey monitor, permissions onboarding, paste path | ✅ done |
| M1 — capture → transcribe → paste | ✅ streaming via Apple `SpeechAnalyzer`, ~340 ms decode |
| M4a — correction ledger + editor UI | ✅ manual corrections, applied to every transcript |
| M2 — caret popup | — |
| M3 — cleanup pass + diff guard | — |
| M4b — automatic learning | ❌ removed by design — see SPEC.md §4 |

## Permissions

Three, each in its own System Settings pane. Onboarding walks them one at a time.

- **Microphone** — capture
- **Accessibility** — caret position and pasting
- **Input Monitoring** — the global hotkey

Ad-hoc code signing means the app's identity changes on every rebuild, so macOS
re-asks each time. A real Developer ID (SPEC.md §9) fixes that and is required
before sharing the app.

## License

MIT — see [LICENSE](LICENSE).

## Requirements

- macOS 26 or later (Apple's `SpeechAnalyzer` streaming recogniser)
- Apple Silicon
- An Anthropic API key, only if you want the AI cleanup pass — dictation works without one
