# Architecture and engineering notes

How the mixer works, and why it is built the way it is. Nothing here is needed to
*use* Volume Mixer — see the [README](../README.md) for that. This file is for
someone changing the code, and it records the reasoning behind decisions that look
strange until you know what went wrong without them.

## How it works

```
audible process ──▶ process tap (mute-while-tapped) ──▶ RT-safe ring
                                                                  │
default output ◀── tap-only aggregate device ◀── one mixer IOProc ◀┘
                     gain + peak metering, sum of all channels
```

- **Discovery** (`Sources/VolumeMixer/Audio/ProcessDiscovery.swift`) enumerates core-audio processes,
  installs `AudioObjectAddPropertyListenerBlock` for start/remove notifications,
  polls every 2s, verifies liveness with `kill(pid, 0)`, and excludes its own PID.
  This is what makes command-line players such as `afplay` show up.
- **Identity** (`Sources/VolumeMixer/Audio/AudioApp.swift`) is bundle ID, else executable path, else PID
  — one definition used by the engine, the UI and the settings file alike. The path
  comes from `proc_pidpath`, because LaunchServices knows nothing about a plain
  command-line process: for `afplay` both `localizedName` and `executableURL` are
  nil, which would otherwise leave it named "Process 95736" and keyed by a PID that
  is dead on the next launch. Only the last-resort PID key is refused on save.
- **One row per app, one tap per process.** A tap reads one process object and mutes
  only that process, so an app running several processes needs a tap each — two
  `afplay` instances, a browser plus its audio helpers. Leaving one untapped would
  mean it kept playing at full volume while its sibling was muted, and the slider
  would only control half the app. So channels are keyed per process, the UI groups
  them into a single row per app (with a `×N` badge), and gain, mute and metering
  apply across every process in the group.
- **Tap** (`Sources/VolumeMixer/Audio/TapGainEngine.swift`) — one `CATapDescription(
  stereoMixdownOfProcesses:)` per app, plus one private aggregate device that is
  *only* the taps. The physical output device is never a subdevice: putting a tap
  on the device you are also writing to fights the HAL over the clock and crackles.
- **Drift compensation** — taps free-run on their own clock, so
  `kAudioSubTapDriftCompensationKey = true` is set. Without it the mix drifts
  against the device and you get periodic clicks.
- **Auto start** — `kAudioAggregateDeviceTapAutoStartKey = true`, otherwise taps
  start muted and stay that way until something plays.
- **Real time safety** (`Sources/VolumeMixer/Audio/RTPrimitives.swift`) — the IOProc allocates nothing
  and takes no locks. Each tap is drained into a preallocated ring buffer (overwrite
  when overrun) and the mixer reads a lock-free `ChannelTable`, so an attachment or
  a UI poll can never block the audio thread. Torn-down channels are kept alive for
  5s so an in-flight callback can never dereference freed memory.
- **Lazy mixer** — no IOProc exists while no app is routed, so an idle app does not
  keep the output device awake. The mixer is rebuilt when the default device
  changes; taps survive, because they own their own clock.
- **Formats are checked, not assumed** — the tap IOProc reinterprets buffers as
  float, so both the tap's and the device's format are verified as packed float32
  mono/stereo before anything starts. The tap's *interleave* is read from its
  format rather than inferred from how many buffers arrived: a stereo tap delivers
  one interleaved buffer, and reading it as a planar pair halves the rate and pairs
  the wrong channels. That one produced audio that played, at the wrong speed, with
  the right channel silent, and every buffer count check passed it. A mismatch is refused with a reason instead
  of producing noise, and the mixer distinguishes a mono single-buffer device from
  a deinterleaved stereo pair so a mono output is not summed into itself. A mono
  destination folds the right channel into the left rather than dropping it, so
  nothing disappears when something is plugged into a mono output.
- **Recovery** — the watchdog runs on its own queue, not on the control queue, so it
  can still release taps if a HAL call is stuck. Engine state shared between the
  control queue, the watchdog and the UI is guarded by a recursive lock that the
  audio thread never touches. A freshly started mixer is given a grace period before
  the watchdog can call it stalled, because waking a dock takes longer than the
  watchdog interval and a mixer that has not produced its first cycle yet is not a
  stalled one.
- **Grace before releasing a tap** — switching the output device makes every app's
  stream migrate, and for about a tenth of a second the app reports no output at
  all. Releasing a tap on that flicker would let the audio through unprocessed and
  then re-tap it with a pop, so a tap is held for a second first. An app that really
  has stopped is silent anyway, and one that resumes inside the window is still
  correctly tapped with nothing to undo.

## Tests

`swift test` runs 75 tests covering what can be verified without audio hardware or
permission:

- ring buffer: write/read, wraparound, overwrite-on-overrun, frame accounting
- lock-free slots, counters and the atomic flag
- `ChannelTable` growth, publication, and capacity limits
- gain scaling, including the silence-preserving and unmute cases
- the mixer's summation contract, which is what keeps two channels from replacing
  each other instead of adding
- mono destination handling, where a naive stereo stride would double every sample,
  and where the right channel must be folded in rather than dropped
- the per-app gain path itself, driven through the mixer's real per-channel code:
  unity, half, boost, mute, and two or three apps summing to the arithmetic total,
  with the meter reporting the post-gain level and decaying when an app goes quiet
- stream-format acceptance, including integer, unpacked and surround rejections
- app identity, and that a PID key is never persisted

## Verifying gain and mute

Everything else in this project can be checked from logs. Whether moving a slider
actually changes what comes out of the speakers cannot, because Core Audio
publishes no output meter for the system. So the check is to listen to the result:
`Scripts/verify-gain.sh` plays a tone through the mixer and measures the system
level with a global tap at unity, at half gain, muted, and restored again.

A working gain path reads about -6 dB at half, silence when muted, and back to
unity afterwards:

```
self-test VERDICT gain=works (-6.0 dB at half, expected about -6) mute=works (-90.0 dB) restore=works
```

The script drives the same `setGain` and `setMuted` calls the UI does, so it
covers the real path rather than a private back door. It reports
`inconclusive` when it measures nothing at all, which distinguishes "the gain
path is wrong" from "capture was refused" — a distinction worth keeping, because
the second is much easier to hit.

It is off unless `VM_SELFTEST` is set, and it is kept in the tree rather than
deleted after a successful run: it is the only way to check the feature that
matters, so throwing it away would leave nothing to re-verify with after the next
change.

Two things to know before running it:

- It does not rebuild the app, on purpose. A build signed with a throwaway
  identity is identified by its code hash, so rebuilding makes macOS treat it as a
  different app and silently drops the grant. Build first, grant, then measure.
- It needs Screen & System Audio Recording granted to `build/VolumeMixer.app`, and
  a signed build for the grant to survive the next rebuild.

## Current status

Verified by running against real hardware:

- process discovery, including apps that start after launch
- seven concurrent audio processes, each getting its own tap and aggregate device
- tap and aggregate-device creation and teardown, repeatedly
- lazy mixer start, and mixer teardown when the last app goes quiet
- one app stopping while another keeps playing: the tap is released without
  disturbing the mixer
- switching the default output device in both directions: the mixer is rebuilt
  once per switch and the taps survive
- twelve rapid start/stop cycles with balanced attach and detach, no errors
- silence-based permission-denial detection and tap release, including releasing
  every tap at once
- the real tap format passing validation
- the permission prompt appearing once and not again
- a command-line player attaching under `path-/usr/bin/afplay`
- 75 unit tests

- per-app gain and mute, heard: the mix path is verified arithmetically in
  `GainPathTests` and end-to-end on a permitted build

Still open:

- **Nothing that blocks using the app.** Per-app gain, mute and metering are
  verified against real hardware and by ear. Two rough edges remain, both
  understood:
  - The ring buffer usually sits near empty, because the corrected tap delivers
    frames slightly faster than the mixer consumes them and overfull reads are
    dropped to stay real-time safe. Audible for a moment, self-correcting.
  - Per-browser-tab control is not possible from process taps. Chromium renders
    audio in a single `audio.mojom.AudioService` process, and the renderer
    processes are absent from Core Audio entirely, so one tap cannot tell two
    tabs apart. Separating them needs a browser extension or DevTools access.

## Signing notes

Two things cost real time here and are worth writing down:

- **An ad-hoc build's permission grant does not survive a rebuild.** The grant is
  possible, but macOS records it against the exact code it saw, so change one byte
  and it must be given again. An Apple Development or Developer ID signature is
  what makes a grant durable, which is why signing still wins by default.
- **An imported certificate needs its intermediate.** Importing a `.p12` can
  report success and still leave `security find-identity` showing zero valid
  identities, with `CSSMERR_TP_NOT_TRUSTED`, because the
  Apple Worldwide Developer Relations intermediate is not in the keychain. Xcode
  normally installs it as a side effect of creating certificates, so an
  out-of-band import has to fetch it from `apple.com/certificateauthority` and
  install it too, or codesign cannot build a chain.

Known limitations:

- several instances of one binary share a single row and level, which is what a
  per-app mixer should do, but each instance does get its own tap, so one instance
  cannot be singled out
- device channels that are not float32 are rejected rather than converted
- per-app volume does not affect an app's own offline rendering or DRM output

## Layout

Paths are from the repository root, which is also the SwiftPM package root.

| Path | Role |
| --- | --- |
| `Package.swift` | package manifest; the only build configuration there is |
| `Sources/VolumeMixer/App/VolumeMixerApp.swift` | `@main`, `MenuBarExtra`, launch and termination |
| `Sources/VolumeMixer/App/AppModel.swift` | UI state, attachment sync, persistence, permission retry |
| `Sources/VolumeMixer/Audio/ProcessDiscovery.swift` | process enumeration and liveness |
| `Sources/VolumeMixer/Audio/TapGainEngine.swift` | taps, aggregate devices, mixer, watchdog |
| `Sources/VolumeMixer/Audio/RTPrimitives.swift` | ring buffer, slots, channel table, gain/sum helpers |
| `Sources/VolumeMixer/Audio/GainEngine.swift` | engine protocol, availability states |
| `Sources/VolumeMixer/Audio/AudioApp.swift` | app identity, display name, icon, grouping |
| `Sources/VolumeMixer/Audio/OutputDevice.swift` | default device and system volume |
| `Sources/VolumeMixer/Support/HAL.swift` | typed Core Audio property access |
| `Sources/VolumeMixer/Support/PermissionState.swift` | records that the capture prompt was shown |
| `Sources/VolumeMixer/Support/Settings.swift` | persisted per-app volume and mute |
| `Sources/VolumeMixer/Support/Log.swift` | os_log plus optional stdout mirroring |
| `Sources/VolumeMixer/UI/MixerView.swift` | menu bar panel |
| `Sources/VolumeMixer/UI/PermissionPrompt.swift` | the permission alert, which has no window to live in |
| `Sources/VolumeMixer/Diagnostics/SystemAudioMeter.swift` | global tap that measures system level, for `verify-gain.sh` |
| `Scripts/build-app.sh` | assembles and signs the bundle |
| `Scripts/install.sh` | installs to /Applications and verifies the copy |
| `Scripts/package.sh` | zips a build for someone else, with instructions |
| `Scripts/make-dmg.sh` | builds the .dmg installer a release page serves |
| `Scripts/setup-signing.sh` | one-time keychain trust for `codesign` |
| `Scripts/verify-gain.sh` | measures the gain path against real audio |
| `Scripts/diagnose.sh`, `Scripts/observe.sh` | tap and lifecycle logging |
| `Scripts/make-icon.swift` | draws `Resources/AppIcon.icns` from code |
| `Resources/AppIcon.icns` | the bundle icon, named by `CFBundleIconFile` |
| `Resources/Info.plist` | bundle identity and the two privacy usage strings |
| `VolumeMixer.app` | the built app, committed so it can be downloaded |

`build/VolumeMixer.app` and `VolumeMixer.app` are both ignored by git except where
the built app is deliberately committed. The one in `build/` is your working copy
and gets overwritten by the next `build-app.sh`; the committed one is the artefact
that ships, and `git status` will show it as modified whenever you rebuild.

## Regenerating the icon

```sh
./Scripts/make-icon.swift
```

The icon is drawn with Core Graphics rather than checked in as binary art, so it
can be reviewed as a diff. The generator renders every size from one 1024-unit
description and then fails loudly rather than quietly producing a wrong picture:
it asserts that every parsed path lands inside the body, that the mark is
centred, and — because an arc at partial opacity is invisible to any brightness
threshold — that the composited mark stays inside the body and is not lopsided.
