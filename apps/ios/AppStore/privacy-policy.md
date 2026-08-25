# Privacy Policy — phren for iOS

<!--
Publish this to https://alaarab.github.io/phren/privacy.html before
submitting. App Store Connect requires a reachable privacy policy URL, and
App Review will open it. Any static host works; the existing docs/ GitHub
Pages site is the obvious home.

Keep the "Last updated" date accurate — a policy dated before a material
change is worse than no policy.
-->

**Last updated: 1 August 2026**

phren for iOS ("the app") is a client for a knowledge store you own,
stored in a Git repository on GitHub. This policy explains what the app
does with your data. The short version: it does not send your data
anywhere except the GitHub account you connect it to.

## We do not collect your data

There is no phren account, no phren server, and no phren backend. The
developer of this app receives **no** data from it — no analytics, no
crash reporting, no telemetry, no advertising identifiers, no usage
statistics. The app contains no third-party SDKs.

## What the app stores on your device

- **Your GitHub access token**, in the iOS Keychain. It never leaves the
  device except as an authorization header sent directly to GitHub's API
  over HTTPS.
- **A local cache** of the markdown files in your store repository, so the
  app works offline and searches without a network round trip.
- **A queue of pending changes** you have made but which have not yet been
  pushed to GitHub.
- **App settings**, such as your chosen default project for quick capture
  and a short log of recent captures, so the app can tell you where a note
  or task was filed.

All of this lives in the app's private container and is removed when you
delete the app. Signing out clears the stored token.

## What the app sends, and where

The app communicates with exactly one external service: **the GitHub REST
API** (`api.github.com`), using the token you supply.

It reads the repository or repositories you select, and writes the changes
you make — findings, notes, tasks, and review decisions — back to those
repositories as commits authored by your GitHub account. Nothing is sent
to any other destination.

Your use of GitHub is governed by GitHub's own privacy policy:
https://docs.github.com/site-policy/privacy-policies

## Microphone and speech recognition

If you use voice capture, the app records audio only while you are
actively dictating, and uses Apple's Speech framework to transcribe it.

The app requests **on-device** recognition wherever the device supports
it, in which case the audio never leaves your iPhone. If on-device
recognition is unavailable, iOS may send the audio to Apple for
transcription under Apple's privacy policy. The recording is not stored;
only the resulting text becomes a note or task, and only if you save it.

You can decline microphone and speech permissions and continue to use
every other feature of the app, including typing or using the keyboard's
own dictation.

## Siri and App Intents

The app registers Siri shortcuts for adding a note or task. When you use
them, the dictated text is handled by Siri under Apple's privacy policy
and passed to the app, which writes it to your store. The developer
receives nothing.

## Children

The app is not directed at children and collects no data from anyone.

## Changes to this policy

If this policy changes materially, the updated version will be published
at this URL with a revised date, and the change will be noted in the app's
release notes.

## Contact

Questions about this policy: **ala@alaarab.com**

Source code: https://github.com/alaarab/phren
