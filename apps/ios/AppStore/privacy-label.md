# App Privacy answers (the "nutrition label")

App Store Connect → your app → **App Privacy**. These answers are a legal
declaration about what **you, the developer**, collect. Data the user
sends to their *own* GitHub repository is not collected by you.

The distinction that matters: "collect" means transmitted off device **in
a way you or your third-party partners can access**. This app has no
server and no SDKs, so nothing qualifies.

---

## The top-level question

> Do you or your third-party partners collect data from this app?

**No — "Data Not Collected".**

Justification, if ever challenged:

- No analytics, crash reporting, or telemetry framework is linked. The app
  has zero third-party SDKs.
- The only network destination is `api.github.com`, reached with a token
  the user creates, writing to a repository the user owns. The developer
  has no access to it.
- The GitHub token is stored in the device Keychain and is never
  transmitted anywhere except to GitHub as an authorization header.
- Speech is transcribed by Apple's Speech framework, on-device wherever
  supported. The developer never receives audio or transcripts.

Answering "Data Not Collected" produces the "Data Not Collected" label,
which is accurate here and worth having.

---

## Related answers elsewhere in App Store Connect

**App Tracking Transparency** — not applicable. The app does not track, has
no advertising identifier access, and `NSPrivacyTracking` is `false` in the
privacy manifest. Do **not** add the ATT prompt.

**Export compliance (asked on every upload)** — the app uses only standard
HTTPS and the system Keychain, which is exempt. Setting
`ITSAppUsesNonExemptEncryption` to `NO` in Info.plist makes App Store
Connect stop asking. Answer: *"Does your app use encryption? — Yes, but
only standard/exempt encryption."*

**Content rights** — the app displays only content from the user's own
repository. No third-party content is bundled.

**Advertising identifier (IDFA)** — No.

---

## Keeping it true

The "Data Not Collected" answer stops being true the moment any of these
land, and the label must be updated **before** that build ships:

- any analytics or crash-reporting SDK, including Apple's own if you opt
  into receiving crash data tied to users
- a phren-operated backend or sync relay of any kind
- push notifications routed through a server you control
- any error reporting that transmits store contents or user text

The privacy manifest (`Phren/Resources/PrivacyInfo.xcprivacy`) must stay in
sync with these answers; a mismatch between the manifest and the label is a
common automated rejection.
