# VolumeMixer

Per-app volume for macOS. A row per app, with its own slider, mute button and live
level meter — no virtual audio driver, no kernel extension.

Built on Core Audio process taps. Your output device, its volume and its selection
stay under your control; only the *mixing* of app audio is replaced.

Requires **macOS 14.2 or newer**.

## Install

1. Download the **VolumeMixer** disk image from
   [Releases](https://github.com/farukoguz/VolumeMixer/releases) and open it.
2. Drag **Volume Mixer** onto the **Applications** shortcut, then eject the disk.
3. Right-click Volume Mixer in Applications and choose **Open**. macOS will
   otherwise say it cannot verify the developer — this build is not notarised, so
   the step is expected, and macOS remembers it after the first time.
4. System Settings → Privacy & Security → **Screen & System Audio Recording** →
   add Volume Mixer.

Volume Mixer then lives in the menu bar, not the Dock — look for the speaker icon
next to the clock.

> **If a slider does nothing, step 4 is almost certainly why.** The app launches and
> lists whatever is playing, so a missing permission looks like a broken app rather
> than a misconfigured one. Nothing reports an error.

Each release page lists a SHA-256 checksum for its disk image. Worth checking, since
this build is not notarised and macOS has no way to tell you whether what you
downloaded is what was published:

```sh
shasum -a 256 ~/Downloads/VolumeMixer-*.dmg
```

The name has to match the checksum exactly. A mismatch means the download is
truncated or altered — do not open it.

To uninstall, drag it from Applications to the Trash.

## Build from source

```sh
swift test              # 75 tests, no audio hardware needed
./Scripts/build-app.sh  # assembles build/VolumeMixer.app
```

No certificate is needed; the build signs ad-hoc unless the keychain has one.

For how it works and why, see [docs/architecture.md](docs/architecture.md).

## Known limitations

- **Per-browser-tab volume is not possible.** Chromium mixes every tab in one
  process, so you get one row for the browser.
- **Several instances of one app share a row and a level.**
- **Output devices that are not float32 are rejected** rather than converted.
- **Does not affect DRM output** or an app's own offline rendering.

## Licence

MIT.
