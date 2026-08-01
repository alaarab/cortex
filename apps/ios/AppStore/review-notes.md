# App Review notes

Paste the **Notes** section into App Store Connect → the version's *App
Review Information* → Notes. Fill in the demo credentials first.

The purpose of these notes is to pre-empt the two rejections this app is
most likely to attract: being mistaken for a generic AI to-do app
(Guideline 4.3, Spam / duplicate), and being read as a thin wrapper around
a web service (Guideline 4.2, Minimum Functionality).

---

## Demo account — REQUIRED

App Review cannot get past the first screen without a working token. Do
this before submitting:

1. Create a GitHub account for review, or use a dedicated repository on
   your own account.
2. Create a **public** repository seeded with a small phren store —
   `phren.root.yaml`, two or three project folders, each with a
   `FINDINGS.md`, `tasks.md`, `notes/`, and a `review.md` containing a
   handful of queue items so triage mode has something to show.
3. Create a fine-grained PAT scoped to that repository with
   **Contents: Read and write** + **Metadata: Read**, with an expiry
   **at least 90 days out** — a token that expires mid-review is a
   rejection.
4. Put the token in the "Password" field of App Review Information (the
   username field can be the GitHub account name).

Use a **public** demo repository. It removes any chance the reviewer's
network or token scope blocks access, and there is nothing sensitive in
a demo store.

> **Do not commit the demo token to this repository.** Paste it directly
> into App Store Connect.

---

## Notes

```
WHAT THIS APP IS

phren for iOS is the companion app for phren, an open-source knowledge
layer for AI coding agents, published on npm as @phren/cli
(https://github.com/alaarab/phren).

AI coding agents accumulate knowledge as they work. phren stores that
knowledge as markdown in a Git repository the user owns. This app is the
mobile client for reviewing and governing that knowledge: approving or
rejecting findings the agents captured automatically, and adding notes and
tasks on the go.

It is not a general-purpose notes or to-do app. Tasks and notes are two of
several surfaces over a developer's knowledge store; the primary surface is
the review queue, where a developer accepts or discards what their agents
have learned.


ARCHITECTURE — NO BACKEND

There is no phren account and no phren server. The app talks directly to
the GitHub REST API using a personal access token the user supplies, which
is stored only in the device Keychain. We collect no data of any kind: no
analytics, no crash reporting, no telemetry, no third-party SDKs.


HOW TO SIGN IN

On the first screen, tap "Connect with a GitHub token" and paste the token
provided in the App Review Information above. The repository picker will
then list the demo store; select it and the app syncs.

Note: the "Sign in with GitHub" OAuth button is intentionally hidden in
this build because the OAuth application is not yet registered. The token
path is the supported sign-in method for version 1.0.


WHAT TO TRY

1. Projects tab — the demo store's projects, with counts of findings,
   tasks, notes and pending review items.
2. Review tab, then the Triage button (stacked-squares icon, top right) —
   full-screen review: swipe right to approve a finding, left to reject,
   with undo. This is the app's primary feature.
3. Tasks tab — Active/Queue/Done sections; tap a completed task's
   checkmark to reopen it; long-press any row for edit and delete.
4. Search tab — on-device search across the whole store, no network.
5. Settings — per-store health (sync state, pending writes), recent
   captures and their destinations, and quick-capture defaults.
6. Optional: the microphone button on the Projects tab dictates a note or
   task using on-device speech recognition. Siri shortcuts ("Add a phren
   task") do the same hands-free. Both are optional; declining the
   microphone and speech permissions leaves every other feature working.


ON GUIDELINE 4.2 (MINIMUM FUNCTIONALITY)

The app is not a web view or a thin API wrapper. Substantial native
functionality includes: an offline-first sync engine with a local cache, a
pending-operation queue and conflict resolution; an on-device search index;
markdown parsers and serialisers that reproduce the CLI's file formats
byte-for-byte; App Intents for Siri; and Home Screen and Lock Screen
widgets. Every edit works with no network connection and syncs later.


ON GUIDELINE 4.8 (SIGN IN WITH APPLE)

The app does not offer third-party or social login for account creation.
It authenticates to GitHub so the user can access their own existing
repository, which is the documented exemption for apps that are clients
for a specific third-party service. No account is created by this app.


PERMISSIONS

- Microphone and Speech Recognition: only for the optional voice-capture
  feature, requested at first use, and only while the user is dictating.
  On-device recognition is requested wherever the device supports it.
- No location, contacts, photos, notifications, or tracking of any kind.
- App Tracking Transparency is not applicable; the app does not track.
```

---

## If a rejection arrives anyway

**4.3 Spam / "this is a to-do app"** — reply pointing at the review queue
as the primary surface, the open-source CLI it accompanies, and the
Developer Tools category. Offer a short screen recording of a triage
session; it makes the distinction obvious in a way text does not.

**4.2 Minimum Functionality** — reply with the offline behaviour: turn on
Airplane Mode, make edits, watch them queue and then sync. That is the
demonstration that settles it.

**2.1 Incomplete Information** — almost always the demo token. Check it
hasn't expired or been revoked, reissue with a longer expiry, resubmit.
