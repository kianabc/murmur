# Fix: the app never checks for updates while it's running

A short note for any app that uses the same self-update setup as Murmur
(see `SELF-UPDATE.md`). If yours checks for updates "once a day", it very
likely has this bug.

## The symptom

A new version has been out for a day or more, and the app never offers it.
Checking manually (Settings → Check now) finds it immediately.

## The cause

The update check only ran **when the app launched**:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // ...
    checkForUpdatesIfDue()   // the only call site
}
```

`checkForUpdatesIfDue()` contacts GitHub only if the last check was more than
24 hours ago. That rule is fine — but it was only ever *asked* once, at launch.

A menu bar app is started once and left running for days or weeks. So in
practice it checked on the day it was launched and then never again. In
Murmur's case: running for 25 hours, last check 26 hours earlier, a release
out for a day, no offer.

## The fix

Ask the same question once a day while the app is running. The rule inside
(daily or weekly, the user's choice in Settings; default weekly) decides
whether GitHub is actually contacted.

```swift
private var updateTimer: Timer?

func applicationDidFinishLaunching(_ notification: Notification) {
    // ...
    checkForUpdatesIfDue()
    updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.checkForUpdatesIfDue() }
    }
}

// The rule — note the hour of slack:
static var isDue: Bool {
    guard automatic else { return false }
    guard let last = lastChecked else { return true }
    return Date().timeIntervalSince(last) > frequency.interval - 60 * 60
}
```

Three details that matter:

1. **Give the rule an hour of slack.** The daily timer is scheduled at launch,
   and the launch check finishes a moment later, so every tick lands a
   fraction of a second *before* the interval is up. A strict
   `> interval` comparison then says "not due", and the next chance is a full
   day later: daily silently becomes every other day, weekly becomes eight
   days. Subtracting an hour fixes it. (Alternatively tick hourly with a
   strict rule; Murmur chose daily to keep it quiet.)

2. **Only record the check time when the check succeeded.** If the network is
   down, leave the last-check time alone so the next hourly tick tries again,
   instead of waiting a day:

   ```swift
   let found = try await UpdateChecker().check()   // throws on network failure
   UpdatePreference.lastChecked = Date()           // only reached on success
   ```

3. **Don't interrupt someone mid-task with the offer.** The offer is a modal
   alert; if the app is in the middle of something (for Murmur, a dictation),
   wait and retry in 30 seconds rather than stealing focus.

## How to confirm it works

- Log a line every time a check actually runs (`update check: looking` /
  `update check: up to date` / `update available: x.y.z`). Then the log shows
  whether the daily check is happening, rather than you having to wait for a
  release to find out.
- Unit-test the rule: not due after 22 hours on daily; **due when the tick is
  two seconds short of 24 hours** (the drift case); weekly not due at 6 days
  and due two seconds short of 7; never due when automatic checks are off.

## Note for users already on the broken version

Copies running the old code won't check on their own, so they won't find the
release containing this fix either. Anyone on an older version needs to use
"Check now" (or restart the app) once; after that it keeps itself up to date.

---

## Also worth checking in the same codebase: timeouts that don't time out

Unrelated to updates, but it's likely in any Swift app built the same way.
If you bound a slow `await` like this:

```swift
// Looks like a 3-second limit. Isn't.
await withTaskGroup(of: Bool.self) { group in
    group.addTask { await slowThing(); return true }
    group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
}
```

…it does **not** return after 3 seconds. A task group can't finish until every
child task has finished, and `cancelAll()` is only a request — anything that
ignores cancellation (waiting on another task's value, many system APIs) keeps
the whole group waiting. In Murmur this turned a "3-second" limit into a
46-second hang.

Fix: resume the caller from whichever side finishes first, using a
continuation, and let the slower side keep running on its own:

```swift
enum Deadline {
    static func race(seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = OnceGate()
            Task {
                await work()
                if gate.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() { continuation.resume(returning: false) }
            }
        }
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
```

On a timeout, cancel or tear down the abandoned work yourself, without
awaiting the teardown. Murmur's version is `Sources/MurmurCore/Deadline.swift`,
and `murmur-cli stuck-selftest` reproduces the original bug (a 0.2-second
group "timeout" that actually waited 3.2 seconds).
