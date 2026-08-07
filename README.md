# Murmur

Talk instead of typing. Hold a key, say what you mean, let go — the text appears
wherever your cursor is, in any app.

Murmur also cleans up how people actually talk. Say *"I'm trying to, um, write my
bike — sorry, ride my motorcycle to work"* and what gets typed is:

> I'm trying to ride my motorcycle to work.

The "um" is gone, and it worked out you meant *ride*, not *write*.

---

> **⚠️ No download available yet.** The first release hasn't been published.
> Until then the only way to run Murmur is [building it yourself](#building-it-yourself),
> which needs Xcode. This section will work as soon as v0.1.0 ships.

## Installing

**You need:** a Mac with Apple Silicon (M1 or newer) running **macOS 26 or later**.
Not sure? Click the  menu → About This Mac.

### 1. Download

Go to the [latest release](https://github.com/kianabc/murmur/releases/latest) and
download **Murmur.dmg**.

### 2. Install

Open the downloaded file and drag **Murmur** into your **Applications** folder.
That's the whole install.

### 3. Open it

Open Applications and double-click **Murmur**.

Murmur has no window and no Dock icon — it lives in your **menu bar**, at the top
right of your screen. Look for a small microphone icon. That icon is how you get
to everything.

### 4. Give it three permissions

macOS won't let any app listen to your microphone or type for you without
permission. Murmur will walk you through it, and you only do this once.

| Permission | Why Murmur needs it |
|---|---|
| **Microphone** | To hear you. Your voice is transcribed on your own Mac and is never uploaded. |
| **Accessibility** | To type the text where your cursor is. |
| **Input Monitoring** | To notice your dictation key while you're using another app. |

For each one, macOS opens System Settings and you flip a switch next to
**Murmur**. Then come back to Murmur and click **Check again**.

It's fiddly, and that's Apple's design, not a mistake on your part. Every app of
this kind requires the same three.

> Don't want to grant Accessibility? You don't have to. In Murmur's settings,
> under **General → Text output**, choose **Copy to clipboard only**. Then Murmur
> copies the text and you paste it yourself with ⌘V.

### 5. Try it

Hold down the **right ⌘ key**, say something, and let go.

A small panel appears near your cursor while you talk, showing the words as it
hears them. When you release the key, the finished text is typed for you.

That's it. You're done.

---

## Everyday use

| What you want | What to do |
|---|---|
| Dictate a sentence | Hold **right ⌘**, speak, let go |
| Dictate something long | **Double-tap** right ⌘ to keep recording, tap again to stop |
| Cancel without typing | Press **Esc** while recording |
| Change any setting | Click the menu bar icon → **Settings** |

Prefer a different key? **Settings → General → Dictation key**. Right ⌘ is the
default because nothing else on macOS uses it.

## Making it smarter (optional)

### Teach it words it gets wrong

Names and jargon trip up every dictation app. If it keeps hearing "Versell" when
you say "Vercel", tell it once:

**Settings → Corrections** → type what it heard, type what you meant, click
**Add**. Fixed everywhere, from then on.

Nothing is ever learned behind your back. Murmur only uses corrections you typed
in yourself.

### Turn on AI cleanup

This is what removes the "um"s, fixes *write/ride*, and adds punctuation. It
needs an [Anthropic API key](https://console.anthropic.com/settings/keys), which
you pay for separately.

**Settings → Cleanup** → paste your key.

It costs roughly **$1.50 a month** if you dictate around 2,000 words a day. The
**Usage** tab shows exactly what you've spent, so there are no surprises.

Without a key, Murmur still works — it just types what you said, unedited.

## Your privacy

- **Your voice never leaves your Mac.** Transcription happens on-device.
- **Text is only sent anywhere if you turn on AI cleanup**, and then only the
  transcript — never audio.
- **No accounts, no telemetry, no analytics.** Nothing is collected.
- Your API key is stored in the macOS **Keychain**, the same place Safari keeps
  passwords.

## If something goes wrong

**The menu bar icon isn't there.** Open Applications and launch Murmur again.
It has no Dock icon by design.

**Nothing happens when I hold the key.** Check **Settings → Permissions**. Input
Monitoring is almost always the missing one.

**macOS says Murmur "cannot be opened".** You're on a build that Apple hasn't
verified. Open **System Settings → Privacy & Security**, scroll down, and click
**Open Anyway** next to the message about Murmur.

**The text goes to the clipboard instead of getting typed.** Accessibility isn't
granted, or **Settings → General → Text output** is set to clipboard-only.

**It's mishearing a particular word.** Teach it under **Settings → Corrections**.

Still stuck? [Open an issue](https://github.com/kianabc/murmur/issues) and
include what you see in the log at
`~/Library/Logs/Murmur/murmur.log`.

---

## Building it yourself

Needs Xcode and macOS 26+.

```bash
git clone https://github.com/kianabc/murmur.git
cd murmur
./scripts/build-app.sh release
open build/Murmur.app
```

Watch what it's doing:

```bash
tail -f ~/Library/Logs/Murmur/murmur.log
```

A locally-built copy is signed ad-hoc, so macOS re-asks for permissions on every
rebuild. `scripts/make-signing-cert.sh` sets up a stable local identity that
stops that.

## How it works

Apple's on-device `SpeechAnalyzer` streams a transcript while you speak. That raw
text passes through your saved corrections, then optionally through a cleanup
model, then into whatever app you're using.

The cleanup step is guarded: every result is compared against the raw transcript,
and anything that looks like invention rather than editing is thrown away in
favour of the original. A wrong-but-honest transcript beats a confident
fabrication in your email.

[SPEC.md](SPEC.md) has the full design, including the parts that turned out
wrong and why.

## Versioning

Versions follow [semantic versioning](https://semver.org). Every change is
recorded in [CHANGELOG.md](CHANGELOG.md). Murmur checks GitHub once a day for a
newer release and tells you — it never installs anything by itself.

## License

MIT — see [LICENSE](LICENSE). Do what you like with it.
