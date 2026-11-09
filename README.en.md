# Google Remote Voice Input for Mac

[简体中文](README.md)

Turn the **Chromecast with Google TV Voice Remote** (Bluetooth name "Chromecast Remote") into a wireless microphone and remote for your Mac: hold the voice button and speak, and your voice tool (such as Doubao Input Method) types the text; the other buttons can be mapped to arrow keys, Return, Back, volume and other Mac actions.

> **This is a community fork, not the official release.** This repository is forked from the open-source project [SayAll](https://github.com/HD838A/remote-mic-app) (`GPL-3.0-only`) and adds Google remote support to the public build that does not include the official private components. It is not affiliated with, authorized or endorsed by SayAll or Google. "Google", "Chromecast" and "Google TV" are trademarks of their respective owners and are used here only to describe compatible hardware.

## Features

- **Hold to talk**: hold the voice button to speak and release to stop. Your voice tool writes the recognized text into the focused field.
- **Press to talk**: or switch to press once to start and press again to stop.
- **14 ordinary buttons**: D-pad, OK, Back, Home, Power, Volume up/down, Mute, Input, YouTube and Netflix, each configurable in Button Mapping.
- **First-run guide**: walks you through permissions, remote connection, a button check and a voice test.
- Uses only public macOS Bluetooth and HID APIs and never reads private data from other apps.

## Requirements

| Item | Requirement |
| --- | --- |
| Remote | Chromecast with Google TV Voice Remote (shown as "Chromecast Remote" in Bluetooth settings) |
| Mac | Apple silicon (M series), macOS 14 or later |
| Voice tool | Doubao Input Method (tested); other tools that start voice input with Fn and let you choose a microphone should work |
| Virtual microphone | The `MiRemoteV 2ch` audio device (see Setup below) |

## Download

Download the latest `.dmg` from this repository's [Releases](../../releases) page.

> No installer has been published yet. It will appear on the Releases page once available.

The installer is a **community build that is not notarized by Apple**, so macOS blocks it the first time:

1. Open the `.dmg` and drag the app into Applications.
2. In Applications, **right-click the app → Open**, then click Open again in the dialog.
3. If it is still blocked, open System Settings → Privacy & Security and click Open Anyway near the bottom.

If you prefer, build it yourself from source (see Build from source below).

## Setup

1. **Pair the remote**: open System Settings → Bluetooth, hold the remote's Back and Home buttons together until the light blinks, then connect "Chromecast Remote".
2. **Install the `MiRemoteV 2ch` virtual microphone**: the remote's audio reaches your voice tool through this virtual audio device. The community installer does not include it yet; if your Mac does not have it, build and install it from source (`scripts/build-doubao-driver.sh`).
3. **Grant permissions**: on first launch, follow the guide to grant Bluetooth, Input Monitoring and Accessibility, then quit and reopen the app.
4. **Follow the guide**: choose the Chromecast remote → press OK or an arrow key to confirm the connection → choose your voice tool → say a sentence to test.

## Using Doubao Input Method

In Doubao Input Method settings:

- Use **Fn** as the voice shortcut;
- **Hold to talk**: choose Hold to talk in the app and use Doubao's long-press mode;
- **Press to talk**: choose Press to talk in the app and use Doubao's hands-free mode;
- Turn on global voice activation;
- Choose **MiRemoteV 2ch** as the microphone.

If Doubao's recording panel does not appear while you hold the voice button, the Doubao shortcut or mode is almost always the cause. Check the items above first.

## Known limitations

- The installer is not notarized, so you must allow it manually the first time.
- Left, Right, YouTube and Netflix mappings, hold-to-repeat, and button reset after a Bluetooth disconnect have not all been verified on real hardware.
- Apple silicon only; Intel Macs are untested.
- The community build has no official crash reporting and no official automatic updates.

Please report problems as an [Issue](../../issues) in this repository. Attaching logs from the app's File → Open Log Folder makes troubleshooting much easier.

## Build from source

Xcode is required.

```bash
git clone https://github.com/itinglight/remote-mic-app.git
```

```bash
cd remote-mic-app && git switch feat/public-chromecast-remote
```

```bash
CONFIGURATION=release SAYALL_PRIVATE_PLATFORM_MODE=public REQUIRE_SIRI_REMOTE_SIGNING=0 ./scripts/build-app.sh
```

The app is written to `dist/SayAll.app` (ad-hoc signed, for personal use only).

## Differences from the official release

| | Official SayAll | This community fork |
| --- | --- | --- |
| Google remote | Requires official private components | Open-source implementation (`Sources/RemoteMic/ChromecastPublicRemoteDriver.swift`) |
| Xiaomi and Apple remotes | Supported | Not tested here; use the official release |
| Signing and notarization | Developer ID signed and notarized by Apple | Not notarized |
| Download | [sayall.app](https://sayall.app/en/) | This repository's Releases |

If you use a Xiaomi Bluetooth remote or an Apple remote, use the [official release](https://sayall.app/en/).

## License and attribution

- The software code is licensed under `GPL-3.0-only`; see [LICENSE.md](LICENSE.md). This repository is a modified version of [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app); see the commit history for the changes.
- The official app logo and app icon are not covered by the GPL, and forks may not use them as their own branding; see [LOGO-LICENSE.en.md](LOGO-LICENSE.en.md).
- The Google remote protocol draws on public notes from the open-source project vibe-mote (MIT), with macOS hardware testing taking precedence.
- See [COPYRIGHT.md](COPYRIGHT.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full copyright and third-party information.

## Developer documentation

Developers and contributors should start with the [documentation index](DOCUMENTATION.md).
