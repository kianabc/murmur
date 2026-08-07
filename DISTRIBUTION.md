# Releasing Murmur

Two one-time setup steps, then releases are a single command.

Both setup steps involve credentials, so they have to be done by hand — nothing
here should ever be pasted into a chat window, a script, or a commit.

---

## One-time setup

### Step 1 — Create a Developer ID certificate

Signing up for the Developer Program doesn't create a certificate. You make it
yourself:

1. Open **Xcode → Settings** (⌘,) → **Accounts**
2. Add your Apple ID if it isn't listed, then select your team
3. Click **Manage Certificates…**
4. Click **+** (bottom left) → **Developer ID Application**

Verify it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You want one line back, containing your name and Team ID in parentheses.

> **If "Developer ID Application" is greyed out or missing:** membership is
> probably still processing. Apple can take up to 48 hours after payment. Check
> [developer.apple.com/account](https://developer.apple.com/account) — the
> Membership section shows your status and Team ID.

> **This certificate is the one thing you can't re-create casually.** Its private
> key lives only in your login keychain. Export it (Keychain Access → right-click
> → Export) and keep the `.p12` somewhere safe. Lose it and every future update
> has to be signed by a new identity, which macOS treats as a different app.

### Step 2 — Store notarization credentials

Apple's notary service needs to authenticate as you. Use an **app-specific
password**, not your Apple ID password.

1. Go to [account.apple.com](https://account.apple.com) → **Sign-In and Security**
   → **App-Specific Passwords**
2. Create one, name it `notarytool`
3. Copy it — Apple shows it once

Then store it in your keychain. The command prompts for the password; it is
never passed as an argument, so it doesn't land in your shell history:

```bash
xcrun notarytool store-credentials "murmur" \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID"
```

Your Team ID is the 10-character code at
[developer.apple.com/account](https://developer.apple.com/account) → Membership,
and also appears in parentheses in the certificate name from step 1.

Verify:

```bash
xcrun notarytool history --keychain-profile murmur
```

An empty history is a success — it means authentication worked.

---

## Cutting a release

```bash
# 1. Write the changelog entry first — release.sh refuses to tag without one.
$EDITOR CHANGELOG.md

# 2. Bump, commit, tag
./scripts/release.sh 0.2.0
git push && git push --tags

# 3. Build, sign, notarize, staple, package
./scripts/notarize.sh

# 4. Publish
gh release create v0.2.0 build/dist/Murmur-0.2.0.dmg --notes-from-tag
```

`notarize.sh` runs `preflight.sh` before submitting, so local problems surface
in seconds instead of after a round trip to Apple.

---

## What the user experiences

| | Before notarizing | After |
|---|---|---|
| First open | Blocked → System Settings → Privacy & Security → Open Anyway | *"Murmur is an app downloaded from the Internet. Are you sure?"* → **Open** |
| Offline | — | Works. Stapling embeds the ticket, so no network check is needed. |

---

## Troubleshooting

**`notarytool` says "Team ID is not valid"** — the Apple ID isn't associated
with that team, or membership hasn't activated. Check the Membership page.

**Notarization returns `Invalid`** — get the reason:

```bash
xcrun notarytool log <submission-id> --keychain-profile murmur
```

The usual causes are a missing hardened runtime, a leftover `get-task-allow`
entitlement, or unsigned nested code. `preflight.sh` catches all three before
submission.

**Notarization succeeds but macOS still warns** — the ticket wasn't stapled, so
the Mac has to ask Apple at launch and fails when offline. Check:

```bash
xcrun stapler validate build/dist/Murmur-<version>.dmg
```

**Rebuilt and permissions reset** — expected while signing ad-hoc. Once builds
are signed with the Developer ID the identity is stable and macOS keeps the
grants.
