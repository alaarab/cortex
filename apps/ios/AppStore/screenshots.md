# Screenshot plan

Screenshots decide what the app *is* before anyone reads a word. The whole
job here is to not look like a to-do app. Lead with the review queue.

## What Apple requires

- **6.9" iPhone** (1320 × 2868 portrait) — **required**. A 16 Pro Max or
  the matching simulator produces these natively.
- 6.5" and other sizes are optional; App Store Connect scales the 6.9"
  set down. Skip them for v1.
- 3 to 10 images. **Only the first two or three are visible without
  scrolling** — those carry the entire positioning argument.
- No alpha channel. No device frames required (Apple scales raw captures
  fine).
- iPad screenshots are not needed — the app is `TARGETED_DEVICE_FAMILY: 1`
  (iPhone only).

## The set, in order

Order is the message. Findings and review first, capture later, tasks last
or not at all.

**1 — Triage mode, mid-swipe.** A finding card tilted right with the green
APPROVE stamp visible, progress reading something like "12 of 87". This is
the app's thesis in one image: a developer judging what their agent
learned. It must be screenshot one.

Caption: *Approve or discard what your agents learned.*

**2 — A project's findings.** Real technical content — the collapsed
5-line cards with a `[pattern]` or `[architecture]` tag chip visible. The
text should be visibly *engineering* knowledge, not errands. Something
like the Angular `@Directive()` finding or a build-tooling pitfall reads
instantly as developer tooling.

Caption: *Your agents' knowledge, in a repo you own.*

**3 — Projects list.** Multiple projects with their findings / tasks /
notes / review counts, and the live sync indicator. Shows scale and that
this sits on top of real work.

Caption: *Every project your agents work on.*

**4 — Siri capture.** The Siri interface with "Add a phren task" and the
confirmation naming the destination project. Sells hands-free capture and
the OS integration.

Caption: *Capture from the Lock Screen, hands-free.*

**5 — Store health in Settings.** Sync state, pending writes, read-only
warnings. Signals seriousness and that it handles multi-repo setups.

Caption: *Know exactly what synced, and what didn't.*

**6 (optional) — Search.** On-device search results across projects.

Caption: *Search everything, offline.*

## Rules for the content on screen

- **Use the demo store, not your real one.** Screenshots are public
  forever. Nothing from a work repository, no employer names, no
  colleagues' names, no internal hostnames or ticket numbers.
- Findings on screen should be genuinely readable technical statements —
  a blurred or lorem-ipsum screenshot reads as a fake app.
- Status bar: full battery, full signal, a clean time. The simulator gives
  you this for free (`xcrun simctl status_bar` can override it).
- Dark theme throughout — it's the app's identity and it's what ships.

## Capturing

Simulator is easier than a device and gives exact pixel sizes:

```
# boot a 6.9" device
xcrun simctl list devicetypes | grep "Pro Max"
xcrun simctl boot "iPhone 16 Pro Max"

# clean status bar
xcrun simctl status_bar "iPhone 16 Pro Max" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3

# capture
xcrun simctl io "iPhone 16 Pro Max" screenshot ~/Desktop/phren-01.png
```

Triage mid-swipe can't be captured by holding a gesture in the simulator
easily — either capture it on device (volume-up + side button while
dragging), or temporarily seed the drag offset in a debug build to freeze
the card mid-tilt.

Save the final set to `apps/ios/AppStore/screenshots/` (gitignored if they
get large; otherwise commit them — they're small PNGs and worth versioning
alongside the copy).

## App preview video (optional, skip for v1)

A 15–30s video of a triage session would be the single most persuasive
asset — and the best answer to a 4.3 "this is a to-do app" rejection. Worth
adding for 1.1 once the app has settled.
