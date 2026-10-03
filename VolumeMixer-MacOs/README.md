# VolumeMixer

A menu bar per-app volume mixer for macOS 14.2+, built on Core Audio process taps.

List every app that is producing audio, move its slider, mute it, watch its level —
without installing a virtual audio driver or a kernel extension. The system output
device, its volume and its selection stay under your control; the mixer only
replaces the *mixing* of app audio, not the device itself.

## Requirements

- macOS 14.2 or newer. `AudioHardwareCreateProcessTap` was introduced in 14.2, and it
  is the only supported way to observe and re-inject per-application audio.
- Screen & System Audio Recording permission (see [Permissions](#permissions)).

## Build and run

```bash
swift build            # library/binary check
swift test             # 24 tests, no hardware required
./Scripts/build-app.sh # assembles build/VolumeMixer.app
open build/VolumeMixer.app
```

`Scripts/build-app.sh` builds a real `.app` bundle and ad-hoc signs it. The bundle is
mandatory, not cosmetic: macOS gates process taps on the `kTCCServiceAudioCapture`
TCC service, which is keyed on the bundle's `Info.plist` and code signature. Running
the bare SwiftPM binary gives you a *silent* tap — every Core Audio call returns
`noErr` while all buffers are zeros.

Set `VM_DEBUG_LOG=1` to mirror lifecycle and error logs to stdout:

```bash
VM_DEBUG_LOG=1 ./build/VolumeMixer.app/Contents/MacOS/VolumeMixer
```

## Permissions

On first launch the app creates a short-lived global tap. It is never read, so it
cannot affect audio, but creating it is what makes macOS evaluate the capture
permission while you are looking at the app. Grant **Screen & System Audio
Recording** for VolumeMixer in System Settings → Privacy & Security, then quit and
relaunch the app.

**The prompt happens once.** The preflight runs on the first launch only, recorded
in `UserDefaults`, because tap creation is the only thing macOS evaluates and
running it every launch would ask every launch. Every later launch goes straight to
per-app taps, which reuse whatever was granted: grant access in System Settings and
the next launch works with no further prompting, and the **Retry** button
deliberately does not re-ask either. The preflight runs off the main thread, since
creating a tap is a HAL round trip that must not hold up launch.

TCC denial is reported as *success* at every API call site: taps are created, the
aggregate device starts, and the buffers contain zeros. VolumeMixer therefore
decides permission by inspecting samples — five consecutive seconds of taps that
copy frames but never contain a non-zero value is treated as denial. At that point
it releases every tap, restores normal system audio, and switches the panel to a
warning with **Open System Settings** and **Retry** buttons.

This matters beyond the UI: a tap mutes the app it reads (`CATapMuteBehavior
.mutedWhenTapped`), so taps that deliver silence without permission would leave
apps silent. Releasing them is what restores audio.

## How it works

```
audible process ──▶ process tap (mute-while-tapped) ──▶ RT-safe ring
                                                                  │
default output ◀── tap-only aggregate device ◀── one mixer IOProc ◀┘
                     gain + peak metering, sum of all channels
```

- **Discovery** (`Audio/ProcessDiscovery.swift`) enumerates core-audio processes,
  installs `AudioObjectAddPropertyListenerBlock` for start/remove notifications,
  polls every 2s, verifies liveness with `kill(pid, 0)`, and excludes its own PID.
  This is what makes command-line players such as `afplay` show up.
- **Identity** (`Audio/AudioApp.swift`) is bundle ID, else executable path, else PID
  — one definition used by the engine, the UI and the settings file alike. The path
  comes from `proc_pidpath`, because LaunchServices knows nothing about a plain
  command-line process: for `afplay` both `localizedName` and `executableURL` are
  nil, which would otherwise leave it named "Process 95736" and keyed by a PID that
  is dead on the next launch. Only the last-resort PID key is refused on save.
- **Tap** (`Audio/TapGainEngine.swift`) — one `CATapDescription(
  stereoMixdownOfProcesses:)` per app, plus one private aggregate device that is
  *only* the taps. The physical output device is never a subdevice: putting a tap
  on the device you are also writing to fights the HAL over the clock and crackles.
- **Drift compensation** — taps free-run on their own clock, so
  `kAudioSubTapDriftCompensationKey = true` is set. Without it the mix drifts
  against the device and you get periodic clicks.
- **Auto start** — `kAudioAggregateDeviceTapAutoStartKey = true`, otherwise taps
  start muted and stay that way until something plays.
- **Real time safety** (`Audio/RTPrimitives.swift`) — the IOProc allocates nothing
  and takes no locks. Each tap is drained into a preallocated ring buffer (overwrite
  when overrun) and the mixer reads a lock-free `ChannelTable`, so an attachment or
  a UI poll can never block the audio thread. Torn-down channels are kept alive for
  5s so an in-flight callback can never dereference freed memory.
- **Lazy mixer** — no IOProc exists while no app is routed, so an idle app does not
  keep the output device awake. The mixer is rebuilt when the default device
  changes; taps survive, because they own their own clock.
- **Formats are checked, not assumed** — the tap IOProc reinterprets buffers as
  float, so both the tap's and the device's format are verified as packed float32
  mono/stereo before anything starts. A mismatch is refused with a reason instead
  of producing noise, and the mixer distinguishes a mono single-buffer device from
  a deinterleaved stereo pair so a mono output is not summed into itself.
- **Recovery** — the watchdog runs on its own queue, not on the control queue, so it
  can still release taps if a HAL call is stuck. Engine state shared between the
  control queue, the watchdog and the UI is guarded by a recursive lock that the
  audio thread never touches.

## Tests

`swift test` runs 40 tests covering what can be verified without audio hardware or
permission:

- ring buffer: write/read, wraparound, overwrite-on-overrun, frame accounting
- lock-free slots, counters and the atomic flag
- `ChannelTable` growth, publication, and capacity limits
- gain scaling, including the silence-preserving and unmute cases
- the mixer's summation contract, which is what keeps two channels from replacing
  each other instead of adding
- mono destination handling, where a naive stereo stride would double every sample
- stream-format acceptance, including integer, unpacked and surround rejections
- app identity, and that a PID key is never persisted

## Current status

Verified by running against real hardware:

- process discovery, including apps that start after launch
- tap and aggregate-device creation and teardown, repeatedly
- lazy mixer start, and mixer teardown when the last app goes quiet
- silence-based permission-denial detection and tap release
- the real tap format passing validation
- the permission prompt appearing once and not again
- a command-line player attaching under `path-/usr/bin/afplay`
- 40 unit tests

Not yet verified end to end, and it needs a signed build to check:

- **actual per-app gain and mute.** This is the whole point of the project and it
  needs a real Team ID signature plus Screen & System Audio Recording granted. An
  ad-hoc build has `TeamIdentifier=not set`, which is enough for taps to be created
  but the panel cannot be given a reason to appear to work when capture is denied,
  and audible output cannot be confirmed without an authorized capture tap to
  measure with.

Known limitations:

- two instances of the same command-line binary share one level, since identity is
  the executable path
- device channels that are not float32 are rejected rather than converted
- per-app volume does not affect an app's own offline rendering or DRM output

## Layout

| Path | Role |
| --- | --- |
| `App/VolumeMixerApp.swift` | `@main`, `MenuBarExtra`, launch and termination |
| `App/AppModel.swift` | UI state, attachment sync, persistence, permission retry |
| `Audio/ProcessDiscovery.swift` | process enumeration and liveness |
| `Audio/TapGainEngine.swift` | taps, aggregate devices, mixer, watchdog |
| `Audio/RTPrimitives.swift` | ring buffer, slots, channel table, gain/sum helpers |
| `Audio/GainEngine.swift` | engine protocol, availability states |
| `Audio/OutputDevice.swift` | default device and system volume |
| `Support/HAL.swift` | typed Core Audio property access |
| `Support/PermissionState.swift` | records that the capture prompt was shown |
| `Support/Log.swift` | os_log plus optional stdout mirroring |
| `UI/MixerView.swift` | menu bar panel |