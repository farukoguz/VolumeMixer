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

`Scripts/build-app.sh` builds a real `.app` bundle and signs it with the first
signing identity in the keychain, falling back to ad-hoc with a warning if there
is none. That distinction decides whether the app can work at all: macOS will not
grant Screen & System Audio Recording to a build with no Team ID, so an unsigned
build looks fine right up until it silently produces silence. The bundle is
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

**The app tells you itself.** Because it lives in the menu bar, the panel banner
is a poor place to discover that the app cannot work, so the app also puts up an
alert of its own: it appears as soon as capture is known to be unavailable, comes
to the front even though the app has no windows, and offers **Open System
Settings**, **Try Again**, and **Not Now**. The alert is not macOS's prompt, and
macOS still decides whether to show that one; this is the surface that survives the
prompt being missed. Declining puts it off for three days rather than forever, so
it cannot become nagging, and **Retry** clears the pause because asking again is a
deliberate act.

One honest limitation: denial can only be *observed* when an app is actually
playing, because silence from a permitted tap and silence from a refused one look
identical until there is audio to look at. The alert therefore appears the first
time something plays without permission, not at launch.

TCC denial is reported as *success* at every API call site: taps are created, the
aggregate device starts, and the buffers contain zeros. VolumeMixer therefore
decides permission by inspecting samples — three consecutive seconds of taps that
copy frames but never contain a non-zero value is treated as denial. At that point
it releases every tap, restores normal system audio, and switches the panel to a
warning with **Open System Settings** and **Retry** buttons.

This matters beyond the UI: a tap mutes the app it reads (`CATapMuteBehavior
.mutedWhenTapped`), so taps that deliver silence without permission would leave
apps silent. Releasing them is what restores audio.

Because a denial is discovered *by* silencing something, detection has a cost, so
it is paid once rather than every launch:

- Detection takes three seconds, not five. The threshold is a measure of how long
  the user hears nothing, not of how sure the app is.
- A denial is latched. Once known, no further tap is opened until **Retry**, so an
  app that starts playing later is never muted behind the app's back.
- A denial is recorded in `UserDefaults`. The next launch opens no taps at all and
  goes straight to the banner, because re-deriving the same answer would silence
  whatever happened to be playing.
- Any tap that is silent is released, whatever the current state is. Holding one
  would leave that app muted with nothing in its place.

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
- **One row per app, one tap per process.** A tap reads one process object and mutes
  only that process, so an app running several processes needs a tap each — two
  `afplay` instances, a browser plus its audio helpers. Leaving one untapped would
  mean it kept playing at full volume while its sibling was muted, and the slider
  would only control half the app. So channels are keyed per process, the UI groups
  them into a single row per app (with a `×N` badge), and gain, mute and metering
  apply across every process in the group.
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

`swift test` runs 56 tests covering what can be verified without audio hardware or
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
- 56 unit tests

Still open:

- **actual per-app gain and mute, heard.** The arithmetic is verified against the
  real mix path in `GainPathTests`, so what the slider does to samples is settled.
  What is unverified is the last link: that Core Audio delivers tapped samples to
  a permitted build. `Scripts/verify-gain.sh` above reports the level at unity,
  half, muted and restored, and still reads `inconclusive: nothing measured at
  unity` on this machine — the grant has not been turned on in System Settings.

  Everything needed for that grant is now in place: the app is signed with a Team
  ID, which is the condition macOS actually enforces. While the build was ad-hoc,
  TCC would not grant this permission at all — taps were created, every buffer
  was zero, the app never appeared in the list, and nothing reported a refusal.
  One toggle in System Settings is all that is left.

### Signing notes

Two things cost real time here and are worth writing down:

- **An ad-hoc build cannot be granted this permission.** `TeamIdentifier=not set`
  leaves macOS with no developer to attribute the app to. The failure is silent,
  so it is worth checking `codesign -dv` before blaming the audio path.
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
| `Diagnostics/SystemAudioMeter.swift` | global tap that measures system level, for `verify-gain.sh` |