<div align="center">

<img src="assets/logo.svg" width="90" alt="No Blast logo"/>

# No Blast

**Lock your apps with your face.**<br>
Hide sensitive apps behind a blur until you look at the camera, and unlock your Mac's lock screen with a glance.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-black?style=for-the-badge&logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Native-0071E3?style=for-the-badge&logo=apple&logoColor=white)
![Privacy](https://img.shields.io/badge/100%25-On--Device-34C759?style=for-the-badge&logo=shield&logoColor=white)

</div>

No Blast is a fork of [Hey Mac](https://github.com/iharshitmaurya/HeyMac) by Harshit Maurya (MIT).

## Features

- **App Lock:** chosen apps are covered by a blur until you are recognized, or pass Touch ID / your password.
  Relock right away, after 5–15 minutes, or some minutes after you switch away.
- **Lock-screen unlock:** wake the Mac, look at it, and No Blast types your login password for you.
  The camera runs at most three 30-second windows per lock, then waits until someone touches the Mac or the
  display wakes again.
- **Notch island:** feedback during a scan, from the notch or a pill on Macs without one.

## Install

> If macOS blocks No Blast, open **System Settings → Privacy & Security → Open Anyway**.

Download the latest `NoBlast.dmg` from
[Releases](https://github.com/OshOEz/no-blast/releases/latest/download/NoBlast.dmg) and drag **No Blast** into
Applications.

## Privacy

- Recognition runs on the Mac (Core ML). No image, face data or password leaves it.
- No photo of your face is stored: only a numeric embedding, encrypted with a key kept in the macOS Keychain.
- The camera is on only while a check is running, and its light shows it.

## What it protects against, and what it doesn't

App Lock is a **deterrent** against someone using your unlocked Mac, not a vault:

- A locked app keeps running and its files stay readable on disk.
- `screencapture -l <window id>` can capture a window underneath the blur.
- Someone with Terminal access (Terminal can't be locked, so you can always recover) can stop No Blast with
  `launchctl`.

Liveness detection looks at a single RGB camera frame (no depth sensor). It rejects ordinary photos and phone
screens, not a well-made replay or 3D mask.

Lock-screen unlock stores your login password (AES-GCM, key in the Keychain) and types it with synthetic key
events:

- A program with **Input Monitoring** permission can record it as it is typed.
- Builds signed ad-hoc (no Developer ID) identify the app by bundle ID only; another local program signed with the
  same ID could read the Keychain key. Use a signed build, or leave lock-screen unlock off, if that matters to you.

## Uninstall

Menu bar icon → **Settings… → About → Uninstall…** removes the app, face data, saved password and settings.
Dragging the app to the Trash leaves that data on the Mac.

## Build

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
scripts/build-app.sh 0.1.0   # dist/NoBlast.app and dist/NoBlast-0.1.0.dmg
```

## License

MIT (see `LICENSE`). Model and asset licenses are listed in `THIRD_PARTY_NOTICES.md`; the face-recognition
weights are for **non-commercial use only**.
