# Submitting phren for iOS

Start here. Work top to bottom; each phase depends on the one above it.
Everything in this folder is referenced from here.

| File | What it's for |
|---|---|
| `listing.md` | Name, subtitle, description, keywords, category, URLs |
| `privacy-policy.md` | Publish to a public URL before submitting (required) |
| `support.md` | Publish to a public URL before submitting (required) |
| `review-notes.md` | Paste into App Review Information; includes the demo-account setup |
| `privacy-label.md` | The App Privacy questionnaire answers |
| `screenshots.md` | What to capture, in what order, and why |

---

## Phase 0 — Code blockers

- [ ] **Persistence hardening merged.** `PendingOpsQueue.load` and
      `LocalStore.init` previously discarded unreadable files silently,
      which would erase users' unsynced work on any schema change between
      releases. Branch: `fix/ios-persistence`. **Do not ship without
      this** — it is the one defect that destroys user data.
- [ ] **Release-readiness merged.** Export-compliance key, privacy
      manifest verified against actual API usage, version at 1.0.0,
      Release configuration builds clean, app icon has no alpha. Branch:
      `chore/ios-release-readiness`.
- [ ] Everything merged to `main` and pushed.

## Phase 1 — Apple Developer portal (manual, ~15 minutes)

Nothing below can be automated; it all lives in the portal UI.

- [ ] Register App ID **`com.phren.ios`** (Certificates, Identifiers &
      Profiles → Identifiers → App IDs)
- [ ] Register App ID **`com.phren.ios.widgets`**
- [ ] Create App Group **`group.com.phren.ios`**
- [ ] Enable the App Groups capability on **both** App IDs and assign that
      group to each
- [ ] Re-enable entitlements in the build. Unsigned builds have been using
      `CODE_SIGN_ENTITLEMENTS=` to skip the unregistered group; once the
      group exists, drop that override and confirm a signed build succeeds.
      `xcodegen generate` regenerates the entitlements files from
      `project.yml` — never hand-edit them.

> **If you'd rather ship v1 without widgets**, remove the `PhrenWidgets`
> target and the App Group entitlement from `project.yml` instead. Shipping
> widgets that can't read the shared container means shipping a feature
> that always shows placeholder content — worse than not shipping it.

## Phase 2 — Publish the two required URLs

- [ ] Publish `privacy-policy.md` → `https://alaarab.github.io/phren/privacy.html`
- [ ] Publish `support.md` → `https://alaarab.github.io/phren/support.html`
- [ ] Open both in a browser and confirm they load. App Review does check,
      and a 404 is a rejection.

## Phase 3 — Demo account

App Review cannot get past the sign-in screen without a token. Full
instructions in `review-notes.md`.

- [ ] Public demo repository seeded with a small phren store, including
      review-queue items so triage mode has content
- [ ] Fine-grained PAT for it: Contents Read and write, Metadata Read,
      **expiry at least 90 days out**
- [ ] Token pasted into App Store Connect's App Review Information
      (**not** committed to this repository)

## Phase 4 — App Store Connect record

- [ ] Create the app; bundle ID `com.phren.ios`
- [ ] **Primary category: Developer Tools** (see `listing.md` for why this
      matters more than anything else here)
- [ ] Name, subtitle, description, keywords, promotional text — all in
      `listing.md`
- [ ] Support and privacy policy URLs from Phase 2
- [ ] Age rating 4+
- [ ] **App Privacy → Data Not Collected** — see `privacy-label.md`
- [ ] Paste App Review notes from `review-notes.md`

## Phase 5 — Screenshots

- [ ] Capture the 6.9" set per `screenshots.md`, **from the demo store**
- [ ] Verify no employer names, colleagues' names, internal hostnames, or
      ticket numbers appear anywhere in frame
- [ ] Upload; confirm the first three tell the "agent memory" story

## Phase 6 — Build and upload

- [ ] Xcode → Product → Destination → **Any iOS Device**
- [ ] Product → **Archive** (Release configuration)
- [ ] Organizer → **Distribute App** → App Store Connect → Upload
- [ ] Wait for processing (usually minutes), then confirm the build appears

## Phase 7 — TestFlight first, always

- [ ] Install the TestFlight build on your own phone
- [ ] **Make offline edits, then update to a newer TestFlight build over
      the top of it, and confirm the pending queue survived.** This is the
      specific regression Phase 0 fixes; it can only be verified by a real
      update, and it is the one bug that would silently lose user data.
- [ ] Exercise triage, Siri capture from the Lock Screen, voice capture,
      widgets, and multi-store if you use it
- [ ] Confirm sign-in works from a clean install using only the demo token

## Phase 8 — Submit

- [ ] Attach the build to the version
- [ ] Submit for review
- [ ] Expect 24–48 hours

---

## Realistic risks

**Guideline 4.3 (Spam / duplicate)** — the "another AI to-do app" read.
Mitigated by the Developer Tools category, the review-queue-first
screenshots, and the review notes. Most likely rejection; easily argued.

**Guideline 4.2 (Minimum Functionality)** — the "thin client for a web
API" read. Mitigated by the offline sync engine, on-device search, App
Intents, and widgets, all named explicitly in the review notes. Airplane
Mode is the demonstration if challenged.

**Guideline 2.1 (Incomplete Information)** — an expired or wrongly scoped
demo token. The most common *avoidable* rejection. Check the token
immediately before submitting.

**Not a risk:** Guideline 4.8 (Sign in with Apple). Signing into GitHub to
reach your own repository falls under the documented exemption for clients
of a specific third-party service. Same basis every Git client ships on.

---

## After approval

- Tag the release in git and note the App Store version in `CHANGELOG.md`
- Keep `privacy-label.md` honest — the moment analytics, a backend, or
  push notifications land, the label must change **before** that build
  ships
- Register the GitHub OAuth app and fill in
  `DeviceFlowAuth.defaultClientID` to replace token-paste sign-in with a
  proper device flow. It is the biggest remaining onboarding improvement,
  and it is currently the first thing every new user has to struggle
  through.
