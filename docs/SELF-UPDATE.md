# How Murmur versions, releases, and updates itself

A self-contained description of the whole pipeline, written so it can be
implemented the same way in another macOS app. Every file path and command
below is the real one from this repository; read those files for exact code.

The parts, in the order they happen:

1. **Versioning** — one `VERSION` file is the single source of truth.
2. **Release** — a script tags, builds, signs, notarises, staples, and makes a DMG.
3. **Publish** — the DMG is attached to a GitHub Release.
4. **Check** — the app asks GitHub for newer releases, once a day.
5. **Offer** — an alert shows the notes for every version being skipped.
6. **Install** — the app downloads, verifies, swaps itself out, and relaunches.

Requirements: a paid Apple Developer account with a *Developer ID Application*
certificate, a `notarytool` keychain profile, and a public GitHub repo. No
server, no Sparkle, no extra signing key.

---

## 1. Versioning

- `VERSION` at the repo root holds the version, e.g. `1.9.1`. Nothing else
  stores it.
- `scripts/build-app.sh` writes it into the bundle:
  - `CFBundleShortVersionString` ← contents of `VERSION`
  - `CFBundleVersion` ← `git rev-list --count HEAD` (monotonic build number)
- `CHANGELOG.md` has one `## [x.y.z] — YYYY-MM-DD` section per release, newest
  first, with `### Added / Changed / Fixed`. Work in progress sits under
  `## Unreleased` until it ships.
- Semantic versioning: patch for fixes, minor for features.
- `SemanticVersion` (in `Sources/MurmurCore/UpdateChecker.swift`) parses
  `1.2.3` or `v1.2.3`, tolerates a missing patch, ignores a `-beta` suffix, and
  is `Comparable`. Every comparison in the updater uses it; never compare
  version strings.

## 2. Release — `scripts/release.sh <version>`

Refuses to proceed if:
- the working tree is dirty;
- `CHANGELOG.md` has no `## [<version>]` section;
- the tag `v<version>` already exists at a commit other than `HEAD`. This
  catches the mistake of landing more commits on a version that was already
  cut. The message tells you to either bump the version or move the tag
  deliberately.

Then it writes `VERSION`, commits only if something changed, and creates an
annotated tag `v<version>`.

## 3. Build, sign, notarise — `scripts/notarize.sh`

In order:

1. `scripts/build-app.sh release` — SwiftPM release build, assembles the
   `.app`, stamps the versions, signs with the Developer ID identity, **hardened
   runtime on** (`--options runtime`) and the entitlements file. Hardened
   runtime is mandatory for notarisation.
2. `scripts/preflight.sh` — local checks that fail fast before touching Apple:
   hardened runtime present, no debug entitlement, needed entitlements present,
   all nested code signed, `codesign --verify --deep --strict` passes, real
   identity (not ad hoc), secure timestamp present.
3. Zip the app, `xcrun notarytool submit --wait` with the keychain profile.
4. `xcrun stapler staple` the app.
5. `hdiutil create` a DMG containing the app and an `Applications` symlink.
6. Submit the DMG to notarytool too, then staple the DMG.
7. `spctl --assess --type execute --verbose=4` and print what a user's Mac
   will say. It must read `accepted` / `source=Notarized Developer ID`.

The credentials check at the top distinguishes Apple's answers, because they
mean different things:
- **HTTP 403 "A required agreement is missing or has expired"** — someone
  must sign in at developer.apple.com/account and accept the pending
  agreement. The credentials are fine. It takes a few minutes to propagate.
- **HTTP 401** — the keychain profile is wrong; re-create it.
- anything else — network.

## 4. Publish

```
git push && git push --tags
gh release create v<version> build/dist/<App>-<version>.dmg --title "v<version>" --notes "..."
```

Notes are short Markdown bullets, `- **Bold lead.** One sentence.` They are
shown inside the app later (step 5), so keep them readable as plain prose —
no headings, no tables, no links.

Never install the build on the developer's own machine as part of releasing.
The running copy and its log are the evidence used to diagnose problems.

## 5. Check and offer

`Sources/MurmurCore/UpdateChecker.swift`:

- `GET https://api.github.com/repos/<owner>/<repo>/releases?per_page=20`
  (the **list**, not `/latest`, so a user several versions behind sees all of
  them). Accept header `application/vnd.github+json`, 10 s timeout.
- Drop drafts and prereleases. Keep releases whose `tag_name` parses to a
  version **greater than the running one**. Newest is the offer.
- `combinedNotes` stacks every newer release's body, newest first, each under
  a bold `**App x.y.z**` line. Markdown headings are flattened to bold, `---`
  rules removed, because the alert renders inline markdown only.
- The `.dmg` asset's `browser_download_url` and the release `html_url` are
  taken from the response, and **validated** before use: https only, host in
  `github.com`, `www.github.com`, `objects.githubusercontent.com`,
  `release-assets.githubusercontent.com`. A URL from a network response is
  never opened or downloaded unvalidated.

Schedule (`UpdatePreference`): a check contacts GitHub only if the last
successful check was more than 24 hours ago. That rule is consulted **at
launch and then every hour** by a repeating timer — a launch-only check is a
bug, not a simplification, because a menu bar app is rarely relaunched and so
never checks again. Use an hourly tick, not a 24-hour timer (which drifts into
every two days). Record the check time only on success, so a network failure
retries on the next tick. Wait until the app is idle before showing the offer.
See `UPDATE-CHECK-FIX.md` for the full write-up.

Offer (`Sources/MurmurUI/UpdateProgressWindow.swift`, `UpdateOfferAlert`):
an `NSAlert`, "Update and Restart" / "Later", with the combined notes in an
accessory `NSTextView` rendered through
`AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)` so
`**bold**` is bold and `- ` becomes `•`. The offer is also reachable from the
menu bar item ("Update to x.y.z…") and a button in Settings, so a dismissed
alert is not the only chance. An accessory (menu-bar-only) app must call
`NSApp.activate()` before `runModal()` or the alert stays behind other windows.

## 6. Install — `Sources/MurmurCore/Updater.swift`

This is the most dangerous code in the app: it fetches something from the
internet and runs it, and the thing it replaces already holds Accessibility,
Input Monitoring and the microphone. Those permissions survive the swap
precisely because the code signature matches, so **the signature check is the
whole security model**. Nothing from the download is executed, opened, or
moved into place until every check below passes.

`stage(update, onProgress:)`:

1. Reject a download URL that fails the host validation above.
2. Make a private work directory (`0700`) under the temp directory.
3. **Stream** the DMG down with `URLSession.bytes(from:)`, writing in 64 KB
   chunks and reporting a percentage from `expectedContentLength`.
   (`download(from:)` gives no progress; several silent seconds reads as a
   hang, and a hang during an update is what makes people force-quit.)
4. `hdiutil attach <dmg> -nobrowse -readonly -mountpoint <dir>`; detach in a
   `defer`.
5. `verifyForInstall(app)` on the app inside the image:
   - `codesign --verify --deep --strict` must pass.
   - `codesign -dvv` output must contain `TeamIdentifier=<OUR TEAM ID>`
     **literally**. A valid Developer ID signature belonging to someone else
     is the obvious attack and must be refused.
   - `spctl -a -t exec -vv` must succeed **and** its output must contain
     `source=Notarized Developer ID`. `accepted` alone is not enough.
   - `CFBundleShortVersionString` inside the bundle must parse and be
     strictly greater than the running version — no downgrades, so an old
     release cannot be replayed to reintroduce a fixed bug.
6. `ditto` the verified app to a staging path (the image is read-only and
   about to be detached). Return the staged URL.

Progress callbacks carry a phase string and an optional fraction:
"Downloading App x.y.z… 74%", "Checking the download…",
"Verified. Preparing to restart…", "Restarting…". The app shows them in a
small floating window (`UpdateProgressWindow`) with an `NSProgressIndicator`
that is indeterminate when the fraction is nil.

`relaunch(replacing:with:)` — an app cannot reliably replace itself while
running (resources loaded after the swap come from the new bundle, and macOS
may kill a process whose signed bundle vanished underneath it). So the swap is
handed to a detached shell script written to the same private directory:

```sh
#!/bin/sh
while kill -0 <our pid> 2>/dev/null; do sleep 0.2; done
/usr/bin/ditto "<staged>/App.app" "/Applications/App.app"
/usr/bin/open -a "/Applications/App.app"
/bin/rm -rf "<work dir>"
```

Every path in it is one the app created; nothing from the network reaches
that string. It is launched with `Process` and the app calls
`NSApp.terminate(nil)`. `/Applications` is writable by admin users, so no
privileged helper is needed.

On any failure: close the progress window, log the reason, show an alert that
says the app is still running and unchanged, and offer to open the releases
page (validated URL). The user can always fall back to the DMG.

Things that interact with the updater and must be in place:

- **Duplicate-instance guard** at launch: if another copy with the same bundle
  ID is running, ask it to `terminate()`, and `forceTerminate()` after two
  seconds if it has not gone. Otherwise a relaunch can leave two menu bar
  icons.
- **Log flush on exit**: if logging is asynchronous, flush it in
  `applicationWillTerminate`, or the last lines before the relaunch are lost
  and a normal quit looks like a crash.
- **Clean-exit flag**: set a "session open" default at launch and clear it on
  a clean quit. At the next launch, an open flag means the previous run died;
  say so in the log. (Replacing a running app by hand triggers this; the
  self-updater does not, because it waits for the process to exit.)

## Tests that exist for this

`murmur-cli updater-selftest` runs the verification against **real bundles**,
not mocks:
- `/System/Applications/Calculator.app` — valid, Apple-notarised, wrong team
  → must be refused.
- our own notarised build → accepted.
- our own build with one byte changed → refused (signature does not verify).
- our own build against a higher "current" version → refused (downgrade).

`murmur-cli stage-update` downloads, verifies and stages the live latest
release exactly as the app would, printing every progress step, and stops
short of the relaunch.

`murmur-cli notes-since <version>` prints what a user on that version would be
shown, and confirms the renderer produces bold runs and leaves no asterisks.

`version-selftest` covers `SemanticVersion` parsing and the note flattening.

## Pitfalls met along the way

- Tagging a version and then committing more work "into" it. The tag then
  describes less than the changelog says. `release.sh` now refuses; move the
  tag deliberately or bump.
- Appending to a changelog entry across sessions leaves duplicate `### Fixed`
  headings. Keep one per section.
- Reporting an available update only in a log file. Nobody reads it; the user
  installed by hand for weeks.
- Showing markdown in `NSAlert.informativeText`. It is plain text.
- Assuming the first launch after an update will re-prompt for permissions. It
  will not, as long as the signing identity is unchanged — which is exactly why
  the Team ID check must be literal.
