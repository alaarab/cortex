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

- [x] **Persistence hardening is in the app.** Unreadable queue/cache state
      is preserved with a reported issue. Queue schemas 1 and 2 remain
      readable by schema 3. Verify an actual upgrade with queued offline work
      using [the device checklist](DEVICE_CHECKLIST.md).
- [x] **Release configuration is present.** Export-compliance key, privacy
      manifest, 1.0.0 versions, and app icon are in the repository.
- [ ] Complete a signed Release archive and the device checklist.
- [ ] Everything merged to `main` and pushed.

## Phase 1 — Apple Developer portal (manual, ~15 minutes)

Xcode automatic provisioning can register identifiers and fetch profiles for
an authenticated team. The September 2026 check obtained profiles for both
targets with the App Group. Verify these for the account used to distribute:

- [ ] Register App ID **`com.phren.ios`** (Certificates, Identifiers &
      Profiles → Identifiers → App IDs)
- [ ] Register App ID **`com.phren.ios.widgets`**
- [ ] Create App Group **`group.com.phren.ios`**
- [ ] Enable the App Groups capability on **both** App IDs and assign that
      group to each
- [ ] Confirm a signed build succeeds with the declared entitlements.
      Unsigned CI uses `CODE_SIGNING_ALLOWED=NO`; a release must retain the group.
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

Alternatively, configure `Config/Local.xcconfig` and run
`python3 scripts/release.py --build-number <next-number> --upload` from
`apps/ios`. It checks the team/OAuth settings, archives with App Groups intact,
and uploads. `--allow-token-sign-in` permits a build before OAuth registration.
An `errSecInternalComponent` signing failure needs signing-key access resolved
in the Mac's login keychain; do not strip entitlements to bypass it.

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
- Register the GitHub OAuth app and set `PHREN_GITHUB_CLIENT_ID` in the
  build configuration to enable a
  proper device flow. It is the biggest remaining onboarding improvement,
  and it is currently the first thing every new user has to struggle
  through.
