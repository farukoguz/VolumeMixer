import CoreAudio
import AudioToolbox
import Foundation

/// One app's audio path: a process tap, a private aggregate device containing
/// only that tap, and an IOProc that copies its samples into a ring buffer for
/// the mixer.
///
/// Tapping starts as a *probe*: the tap is created with
/// `muteBehavior = .unmutedWhenTapped`, so the app keeps playing normally and
/// the tap runs purely as a listener. Only once real non-zero samples have been
/// seen -- proof that capture is actually permitted -- does the channel promote
/// itself to `.mutedWhenTapped` and take over the app's output.
///
/// The ordering matters. `mutedWhenTapped` silences the app for as long as the
/// tap is running, on the assumption that the mixer will put the audio back.
/// When capture permission is missing the tap still reports success and simply
/// delivers zeros, so muting first means the app is silenced by a path that is
/// going to hand back nothing. Probing first means the worst case of a denied
/// permission is that the app is briefly listened to rather than muted, which is
/// harmless.
@available(macOS 14.2, *)
final class TapChannel {

    /// Stable app identity: every process of the same app shares it, which is
    /// what lets one slider drive all of them.
    let identity: String
    /// Unique per process, including the PID, so two instances of the same binary
    /// get a tap each.
    let appID: String
    let processObjectID: AudioObjectID

    private(set) var tapID: AudioObjectID = kAudioObjectUnknown
    private(set) var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    /// Whether this channel's tap is currently silencing its app. False during
    /// the probe phase, which is what keeps an unverified tap from damaging
    /// audio. Read by the watchdog to decide whether promotion is due.
    private(set) var isMuting = false
    /// The queue the IOProc was created on, kept so promotion can rebuild the
    /// tap on the same queue without the caller having to remember it.
    private var renderQueue: DispatchQueue?

    let gain = GainSlot(1.0)
    let peak = PeakSlot(0)
    /// IO cycles served. The watchdog reads this to distinguish a live pipeline
    /// from a stalled one.
    let cycles = FrameCounter()

    let ring = SampleRingBuffer()

    /// Anti-aliasing filter state for the decimating read.
    ///
    /// This tap delivers roughly twice the frames the mixer consumes, so every
    /// output frame is built from several input frames. Simply picking one of
    /// them -- or averaging them without filtering first -- folds everything
    /// above the output Nyquist frequency back down into the audible band, which
    /// is what makes the result sound harsh and "robot"-like rather than merely
    /// coarse. A lowpass ahead of the decimation is what keeps it clean.
    let decimationFilter = DecimationFilter()

    /// The tap's sample rate, captured at start-up. The mixer runs on the output
    /// device's clock, which is a different clock, so this ratio is what lets the
    /// reader reconcile the two instead of falling behind by a frame each cycle.
    /// Written once before the IOProc starts and only read afterwards.
    let tapSampleRate = AtomicRate()

    /// True once any non-zero sample has passed through the tap. On macOS a
    /// denied audio-capture permission looks exactly like a working pipeline
    /// that happens to produce zeros, so this is how denial is detected.
    /// Atomic because the watchdog reads it from another thread.
    let sawAudio = AtomicFlag()
    /// True once this channel has been promoted from probe to muting tap, or
    /// started that way. Distinct from `sawAudio`: a muting tap can legitimately
    /// be sitting on a silent app, in which case no audio flows but nothing is
    /// wrong either.
    let isUnderMixerControl = AtomicFlag()
    /// Mix cycles that could not be filled from the ring. Any non-zero value
    /// means the mixer is failing to keep up with the tap and the app this
    /// channel is muting has holes in its output.
    let starveCount = FrameCounter()
    /// Frames the mixer has taken out of the ring. Compared against
    /// `framesCopied` to measure whether the tap really is delivering more audio
    /// than the mixer consumes, which is the difference between "the reader is
    /// not draining hard enough" and "the clocks do not match".
    let framesConsumed = FrameCounter()
    /// Low-water mark of the ring, in frames. The distance between this and a
    /// full ring is the app's buffer cushion; seeing it near zero is the direct
    /// evidence of an underrun.
    let minBuffered = AtomicRate()
    /// Frames copied out of the tap and into the ring, for the same reason.
    let framesCounter = FrameCounter()
    var framesCopied: Int64 { framesCounter.value }

    init(identity: String, processKey: String, processObjectID: AudioObjectID) {
        self.identity = identity
        self.appID = processKey
        self.processObjectID = processObjectID
    }

    func start(queue: DispatchQueue, outputRateHint: Double = 48_000) -> OSStatus {
        start(queue: queue, muting: false, outputRateHint: outputRateHint)
    }

    /// Creates the tap and starts reading it.
    ///
    /// `muting` selects the tap's `muteBehavior`. Callers pass `false` for the
    /// probe phase and `true` only after the probe has confirmed that real
    /// samples are arriving.
    func start(queue: DispatchQueue, muting: Bool, outputRateHint: Double = 48_000) -> OSStatus {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        let uuid = UUID()
        description.uuid = uuid
        description.name = "VolumeMixer-\(appID)"
        description.isPrivate = true
        // `.unmuted` rather than `.mutedWhenTapped` during the probe: this tap
        // only listens. Under `.mutedWhenTapped` CoreAudio silences the app for
        // as long as anything reads the tap, so a probe would mute the app while
        // having nothing to replace it with if permission turns out to be denied.
        description.muteBehavior = muting ? .mutedWhenTapped : .unmuted
        isMuting = muting
        isUnderMixerControl.value = muting
        // 0 until first observed: the audio thread lowers it, and an
        // initial sentinel of "infinity" prints as garbage in the health log.
        minBuffered.value = 0
        starveCount.value = 0
        framesConsumed.value = 0

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else { return tapStatus }
        tapID = newTapID

        // The aggregate deliberately contains *only* the tap. Adding the real
        // output device as a sub-device pins the aggregate to that device's
        // sample rate and channel layout, which breaks when e.g. AirPods drop
        // to 24 kHz mono for HFP calls: `AudioDeviceStart` then reports success
        // while the IOProc delivers nothing.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer-\(appID)",
            kAudioAggregateDeviceUIDKey: "com.volumemixer.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            // Pin the aggregate to the output device's rate.
            //
            // Without this the tap aggregate is clocked at roughly double the
            // output device's rate: measured production against consumption came
            // out at 2.02 even though both devices reported 48000 Hz. The mixer
            // then has to discard half of every cycle, which is a decimation with
            // no anti-aliasing filter and is what leaves the sound harsh and
            // wrong even once the buffer level is right.
            //
            // Naming a main sub-device rate gives the aggregate a clock to run
            // at, matching the device that will actually play the result.
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: uuid.uuidString,
                    // Required, not optional. Without it CoreAudio resamples on
                    // every cycle to reconcile the tap clock against the
                    // aggregate clock, which is audible as periodic crackling in
                    // *all* system audio, not just the tapped app.
                    //
                    // Measured: disabling this does not change the production
                    // ratio, which stays at 2.01x, so the doubling is not
                    // CoreAudio resampling and there is nothing to gain by
                    // turning it off.
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            stop()
            return aggregateStatus
        }
        aggregateID = newAggregateID

        // Pin the aggregate to the output device's rate.
        //
        // Left to itself, CoreAudio clocks this tap-only aggregate at roughly
        // twice the output device's rate: measured production against consumption
        // came out at 2.02 while both devices reported 48000 Hz. The mixer then
        // has to discard half of every cycle, which is an unfiltered decimation
        // and is what leaves the sound harsh and wrong even when the buffer level
        // is correct. Setting the nominal rate gives the aggregate a clock to run
        // at that matches the device that will play the result.
        // Float64, not Float32: `kAudioDevicePropertyNominalSampleRate` is an
        // `AudioStreamBasicDescription::mSampleRate` field, which is a double.
        // Writing a 4-byte Float is rejected with '!siz' (bad property size).
        var rate = outputRateHint
        let rateStatus = HAL.write(newAggregateID, kAudioDevicePropertyNominalSampleRate,
                                   kAudioObjectPropertyScopeGlobal,
                                   kAudioObjectPropertyElementMain, &rate)
        if rateStatus != noErr {
            Log.error("tap \(appID): could not pin aggregate rate to \(outputRateHint) Hz "
                      + "(fourcc \(fourcc(rateStatus))); tap will run at CoreAudio's choice")
        }

        // `render` reinterprets the tap's buffers as Float. Confirm that first,
        // because a mismatch would be noise rather than an error.
        let tapFormat = HAL.streamFormat(of: aggregateID, scope: kAudioObjectPropertyScopeInput)
        guard isSupportedMixFormat(tapFormat) else {
            Log.error("tap \(appID) format unsupported: "
                      + "id=\(tapFormat.mFormatID) flags=\(tapFormat.mFormatFlags) "
                      + "bits=\(tapFormat.mBitsPerChannel) ch=\(tapFormat.mChannelsPerFrame)")
            stop()
            return kAudio_ParamError
        }
        // `tapFormat.mSampleRate` reports the format's nominal rate, which for
        // this aggregate is not the rate the device actually runs at: the
        // production/consumption ratio shows the tap delivering about twice the
        // frames the mixer consumes while both formats claim 48000 Hz. Read the
        // device's real rate instead, which is the only figure that describes the
        // clock the IOProc is actually driven by.
        var actualRate = tapFormat.mSampleRate
        var deviceRate = Double(0)
        if HAL.read(aggregateID, kAudioDevicePropertyActualSampleRate,
                    into: &deviceRate) == noErr, deviceRate > 0 {
            actualRate = deviceRate
        }
        Log.lifecycle(String(format: "tap %@: format says %.1f Hz, device runs %.1f Hz",
                             appID, tapFormat.mSampleRate, actualRate))
        tapSampleRate.value = actualRate

        var newIOProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProc, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            self?.render(inputData)
        }
        guard procStatus == noErr, let ioProc = newIOProc else {
            stop()
            return procStatus
        }
        ioProcID = ioProc
        renderQueue = queue

        let startStatus = AudioDeviceStart(aggregateID, ioProc)
        guard startStatus == noErr else {
            stop()
            return startStatus
        }
        return noErr
    }

    /// Real-time thread. Pure copy, no allocation, no locks, no ARC.
    private func render(_ inputData: UnsafePointer<AudioBufferList>) {
        cycles.increment()

        let bufferCount = Int(inputData.pointee.mNumberBuffers)
        guard bufferCount > 0 else { return }

        // Pull the first two buffers out without allocating. Stereo mixdown
        // taps deliver one buffer per channel.
        let base = UnsafeRawPointer(inputData)
            .advanced(by: MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!)
        let stride = MemoryLayout<AudioBuffer>.stride

        let leftBuffer = base.load(fromByteOffset: 0, as: AudioBuffer.self)
        guard let leftData = leftBuffer.mData else { return }
        let left = leftData.assumingMemoryBound(to: Float.self)
        let leftFrames = Int(leftBuffer.mDataByteSize) / MemoryLayout<Float>.size
        guard leftFrames > 0 else { return }

        var right = left
        if bufferCount > 1 {
            let rightBuffer = base.load(fromByteOffset: stride, as: AudioBuffer.self)
            if let rightData = rightBuffer.mData {
                right = rightData.assumingMemoryBound(to: Float.self)
            }
        }
        // Mono sources are duplicated to both channels by the mixdown tap; if
        // the HAL hands us one buffer anyway, `right` aliases `left`, which
        // produces exactly that duplication.

        let peak = ring.writeDeinterleaved(left, right, frameCount: leftFrames)
        framesCounter.increment(by: Int64(leftFrames))
        if peak > 0 {
            sawAudio.value = true
        }
    }

    /// Rebuilds this channel's tap with `muteBehavior = .mutedWhenTapped`,
    /// handing the app's output over to the mixer.
    ///
    /// Called on the control queue once another tap has proven that capture
    /// works. The teardown-then-rebuild is deliberate: `muteBehavior` is fixed at
    /// tap creation, so the tap has to be replaced rather than reconfigured.
    /// Samples buffered by the probe are dropped, which costs a fraction of a
    /// second of audio at the moment of promotion and is inaudible because the
    /// app was still audible on its own right up until that instant.
    func promoteToMuting(outputRateHint: Double = 48_000) {
        guard !isMuting, tapID != kAudioObjectUnknown else { return }
        let queue = renderQueue
        // Promote only with the ring already holding a real cushion. Without this
        // the tap starts muting while its replacement buffer is still nearly
        // empty, so the first cycles after promotion starve and the app is
        // briefly silent even though capture works perfectly. A fraction of a
        // second of latency in exchange for never starting mid-hole.
        guard ring.availableFrames >= Self.primingFrames else { return }
        stop()
        guard let queue else { return }
        let status = start(queue: queue, muting: true, outputRateHint: outputRateHint)
        if status != noErr {
            Log.error("promote \(appID) to muting failed: \(fourcc(status)); audio left untouched")
            isMuting = false
        }
    }

    /// Frames the ring must hold before a probe may start muting. Roughly 40 ms
    /// at 48 kHz: long enough that the mixer has a cushion to absorb a late
    /// cycle, short enough to be inaudible as added latency.
    private static let primingFrames = 2048

    func stop() {
        if let ioProc = ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProc)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        ring.reset()
        decimationFilter.reset()
        peak.value = 0
        // A stopped channel is not under mixer control whatever it was before:
        // nothing is reading the tap, so the app is playing on its own again.
        isUnderMixerControl.value = false
        isMuting = false
    }
}

/// Applies per-application gain by tapping each app, scaling it, and re-injecting
/// the result into the system's output device.
///
///     app ─▶ [process tap, muted-when-tapped] ─▶ tap-only aggregate ─▶ IOProc
///            (copies into ring buffer)                                    │
///                                                                       ▼
///     speakers ◀── output device IOProc ◀── sums + scales every ring ────┘
///
/// Gain is applied in the mixer rather than in the tap, so the meter shows the
/// post-gain level the user actually set, and the tap thread stays a plain copy.
///
/// The watchdog is the safety property that matters most: taps mute their app
/// while being read, so if the mixer ever stopped running, every tapped app
/// would stay silent. The watchdog destroys all taps in that case, returning
/// every app to normal output at the cost of gain control. Sound wins.
@available(macOS 14.2, *)
final class TapGainEngine: GainEngine {

    /// Read from the UI thread, written from the control queue, so it is guarded
    /// rather than a bare stored property. This is a control path, never the
    /// audio thread, so a lock here is free.
    var availability: GainEngineAvailability {
        get { availabilityLock.withLock { _availability } }
        set { availabilityLock.withLock { _availability = newValue } }
    }
    private let availabilityLock = NSLock()
    private var _availability: GainEngineAvailability = .ready

    private let controlQueue = DispatchQueue(label: "com.volumemixer.engine")
    /// The watchdog deliberately does not share the control queue: taps mute the
    /// apps they read, so recovery must still be possible if a HAL call on that
    /// queue is stuck.
    private let watchdogQueue = DispatchQueue(label: "com.volumemixer.engine.watchdog")
    private let tapQueue = DispatchQueue(label: "com.volumemixer.tap.rt", qos: .userInteractive)
    private let mixerQueue = DispatchQueue(label: "com.volumemixer.mixer.rt", qos: .userInteractive)

    /// Owns every live channel, and therefore keeps the pointers published in
    /// `table` valid.
    private var channels: [String: TapChannel] = [:]
    /// Channels removed from `channels` but kept alive briefly, so a mixer
    /// callback that already read the old channel count cannot dereference a
    /// deallocated object. Pruned by the watchdog tick.
    private var retired: [(channel: TapChannel, deadline: DispatchTime)] = []
    private let table = ChannelTable()

    // Mixer output side.
    private var outputDevice: AudioObjectID = kAudioObjectUnknown
    private var mixerProcID: AudioDeviceIOProcID?
    private let mixerCycles = FrameCounter()
    private var outputFormat = AudioStreamBasicDescription()

    /// Preallocated summation buffer for the mixer.
    private var mixScratch: UnsafeMutablePointer<Float>?
    private var mixScratchCapacity = 0

    private var lastMixerCycle: Int64 = 0
    /// Consecutive watchdog ticks spent with taps that copy frames but never see
    /// a non-zero sample, which is how audio-capture denial looks from here.
    private var silentTicks = 0
    /// Watchdog ticks of a silent tap before it is released. Each tick is a
    /// second, and each is also a second the user cannot hear that app.
    /// Watchdog ticks needed before silence is called a denied permission. The
    /// tick is now 100 ms, so three ticks is 300 ms rather than three seconds.
    /// Cutting the detection window was previously unsafe because a muted tap
    /// made every tick cost the user silence; probes do not mute, so detecting
    /// the refusal fast costs nothing and keeps a broken tap from lingering.
    private static let denialTicks = 3
    /// How long a freshly started mixer is given to produce its first cycle.
    private let mixerStartupGrace: TimeInterval = 3
    /// Deadline before which a missing cycle is not yet a stall.
    private var mixerStartDeadline = Date.distantPast

    private var watchdogTimer: DispatchSourceTimer?
    /// `quit()` stops the model and `applicationWillTerminate` stops it again,
    /// so shutdown has to survive being called twice. It also has to make later
    /// attaches impossible: a tap created after the watchdog is gone would mute
    /// an app with no way left to release it.
    private var isShutDown = false
    /// 100 ms. The watchdog only promotes probes and tears down denied taps, and
    /// a probe that has not been promoted yet is not muting anything, so acting
    /// on this timescale is harmless. At 1 s, priming took a second to notice
    /// and gain control arrived visibly late after launch.
    private let watchdogInterval: TimeInterval = 0.1

    /// The level the user chose per app, held separately from mute so that
    /// unmuting restores what was there before. Kept here rather than in the UI
    /// because a level set before the tap exists still has to be applied.
    private var levels: [String: Float] = [:]
    private var muteFlags: [String: Bool] = [:]

    /// Guards everything the control queue, the watchdog and the UI all touch:
    /// the channel set, the mixer handles, and the stored levels.
    ///
    /// It is *not* on the audio path. The mixer reads the lock-free
    /// `ChannelTable` and the per-channel slots, so it never waits on this. The
    /// watchdog has to be able to take it even when the control queue is stuck
    /// inside a HAL call, which is why the watchdog runs on its own queue rather
    /// than as work on `controlQueue`.
    private let stateLock = NSRecursiveLock()

    /// The value the engine actually wants for an app right now.
    private func effectiveGain(_ appID: String) -> Float {
        (muteFlags[appID] ?? false) ? 0 : (levels[appID] ?? 1)
    }

    init() {
        // The mixer is deliberately *not* started here. An IOProc on the user's
        // default output device keeps the device active and costs power, so it
        // is created only while there is at least one app to route.
        startWatchdog()
    }

    /// Level the reader steers the ring back toward, in frames.
    ///
    /// Small on purpose. This is the latency the mixer adds to every tapped app,
    /// so it is also the delay between those apps and everything else on the
    /// system: 20 ms is enough to absorb a jittery callback without being
    /// perceptible as the app being out of time with the rest of the desktop.
    static let targetBufferFrames = 1024

    // MARK: - GainEngine

    func attach(to app: AudioApp) {
        let identity = app.id
        controlQueue.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.stateLock.withLock {
                // A tap mutes the app it reads. Once capture has been shown not to
                // work, tapping again buys nothing and costs the user their
                // audio: without this the next app to play was muted and then,
                // because the watchdog only reports a denial once, never released.
                guard self.availability != .permissionDenied else { return }
                let channel = TapChannel(identity: identity,
                                         processKey: app.processKey,
                                         processObjectID: app.processObjectID)
                guard self.channels[channel.appID] == nil else { return }
                // Start muted only once capture has been proven this session. Until then
                // the tap is a passive probe, so an app whose audio we cannot
                // capture keeps playing instead of being silenced.
                let status = channel.start(queue: self.tapQueue, muting: self.captureProven)
                guard status == noErr else {
                    Log.error("tap start failed for \(channel.appID): \(fourcc(status))")
                    return
                }
                // Applied per process, from the app-level level, so a second
                // instance joining later is already at the right volume.
                channel.gain.value = self.effectiveGain(identity)

                self.channels[channel.appID] = channel
                self.publishChannels()
                self.startMixerIfNeeded()
                Log.lifecycle("attached \(channel.appID) [\(identity)] "
                              + "tap=\(channel.tapID) agg=\(channel.aggregateID)")
            }
        }
    }

    func detach(processKey: String) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                guard let channel = self.channels.removeValue(forKey: processKey) else { return }
                // Unpublish before stopping so the mixer stops reading the
                // channel, then hold the object alive briefly rather than
                // immediately releasing it out from under an in-flight callback.
                self.publishChannels()
                channel.stop()
                self.retire(channel)
                // With the last channel gone there is nothing to mix, so release
                // the device again.
                if self.channels.isEmpty { self.stopMixer() }
                Log.lifecycle("detached \(processKey) [\(channel.identity)]")
            }
        }
    }

    /// Holds a torn-down channel alive for `retention` seconds. A mixer cycle is
    /// at most a few milliseconds, so this is far longer than any read of a
    /// stale channel count can last.
    private func retire(_ channel: TapChannel) {
        retired.append((channel, DispatchTime.now() + .seconds(5)))
    }

    private func pruneRetired() {
        let now = DispatchTime.now()
        retired.removeAll { $0.deadline < now }
    }

    func setGain(_ gain: Float, for appID: String) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                self.levels[appID] = max(0, gain)
                // Moving the slider is an unmute, which is what every mixer does.
                self.muteFlags[appID] = false
                let effective = self.effectiveGain(appID)
                for channel in self.channels.values where channel.identity == appID {
                    channel.gain.value = effective
                }
            }
        }
    }

    func setMuted(_ muted: Bool, for appID: String) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                self.muteFlags[appID] = muted
                // The stored level is left alone so unmuting restores it.
                let effective = self.effectiveGain(appID)
                for channel in self.channels.values where channel.identity == appID {
                    channel.gain.value = effective
                }
            }
        }
    }

    func peak(for appID: String) -> Float {
        // Read from the UI thread while the control queue may be mutating the
        // dictionary, so this takes the state lock. The peak itself is a plain
        // aligned read, so it costs nothing on the audio thread. One app can have
        // several processes, and the loudest one is what the row should show.
        stateLock.withLock {
            channels.values
                .filter { $0.identity == appID }
                .reduce(Float(0)) { max($0, $1.peak.value) }
        }
    }

    var liveAppIDs: Set<String> {
        stateLock.withLock { Set(channels.values.map(\.identity)) }
    }

    func shutdown() {
        stateLock.withLock { isShutDown = true }
        watchdogTimer?.cancel()
        watchdogTimer = nil
        // Never call this from the control queue: `sync` onto a queue that is
        // already draining would deadlock.
        controlQueue.sync {
            stateLock.withLock {
                stopMixer()
                for channel in channels.values { channel.stop() }
                channels.removeAll()
                publishChannels()
                retired.removeAll()
                mixScratch?.deinitialize(count: mixScratchCapacity)
                mixScratch?.deallocate()
                mixScratch = nil
                mixScratchCapacity = 0
            }
        }
    }

    // MARK: - Preflight

    /// Creates and immediately destroys a global tap at launch.
    ///
    /// It is never read, so it cannot affect audio, but creating it is what makes
    /// macOS evaluate the audio-capture permission. Doing this at startup means
    /// the user is asked while they are looking at the app, instead of the first
    /// tap silently delivering zeros later with no explanation.
    ///
    /// Called exactly once per install -- see `PermissionState`. Every later
    /// launch goes straight to per-app taps, which reuse the existing grant
    /// without prompting again.
    ///
    /// A tap that creates cleanly is not proof that capture is permitted -- TCC
    /// denial is reported as success -- so this only reports hard API failures.
    /// Whether samples actually flow is decided by inspecting them.
    func preflight() -> GainEngineAvailability {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "VolumeMixer-Preflight"
        description.isPrivate = true

        var tapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            Log.error("preflight tap: \(fourcc(status))")
            return .failed("audio capture unavailable (\(fourcc(status)))")
        }
        _ = AudioHardwareDestroyProcessTap(tapID)
        Log.lifecycle("preflight tap created and released")
        return .ready
    }

    // MARK: - Channel publication

    private func publishChannels() {
        let dropped = table.publish(Array(channels.values))
        if dropped > 0 {
            Log.error("channel table full: dropped \(dropped) app(s), capacity=\(ChannelTable.capacity)")
        }
    }

    // MARK: - Mixer

    private func startMixer() {
        stopMixer()

        let device = HAL.defaultOutputDevice
        guard device != 0 else {
            availability = .failed("no output device")
            return
        }

        outputFormat = HAL.outputStreamFormat(device)
        // The mixer only handles float32, which covers built-in, USB and
        // Bluetooth outputs on current macOS. Anything else is refused rather
        // than mixed as noise.
        guard outputFormat.mSampleRate > 0, isSupportedMixFormat(outputFormat) else {
            availability = .failed("output format \(outputFormat.mFormatID) "
                                   + "unsupported (\(outputFormat.mChannelsPerFrame)ch, "
                                   + "\(outputFormat.mBitsPerChannel)bit)")
            Log.error("mixer format unsupported: id=\(outputFormat.mFormatID) "
                      + "ch=\(outputFormat.mChannelsPerFrame) bits=\(outputFormat.mBitsPerChannel)")
            return
        }

        outputDevice = device
        ensureScratchCapacity(frames: 8192)

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, mixerQueue) { [weak self] _, _, _, outputData, _ in
            self?.mix(outputData)
        }
        guard status == noErr, let ioProc = proc else {
            Log.error("mixer IOProc: \(fourcc(status))")
            availability = .failed(fourcc(status))
            return
        }
        mixerProcID = ioProc

        let startStatus = AudioDeviceStart(device, ioProc)
        guard startStatus == noErr else {
            Log.error("mixer start: \(fourcc(startStatus))")
            _ = AudioDeviceDestroyIOProcID(device, ioProc)
            mixerProcID = nil
            availability = .failed(fourcc(startStatus))
            return
        }
        lastMixerCycle = mixerCycles.value
        // Waking a dock or a Bluetooth device takes seconds, and the first
        // IOProc cycle only arrives once it is awake. Without this the watchdog
        // would see no cycles, call it a stall, and release every tap for a
        // mixer that is merely still starting.
        mixerStartDeadline = Date().addingTimeInterval(mixerStartupGrace)
        // A previous failure (an unsupported device, say) should not stick once
        // the device has been replaced with something that works.
        availability = .ready
        Log.lifecycle("mixer started device=\(device) rate=\(outputFormat.mSampleRate) ch=\(outputFormat.mChannelsPerFrame)")
    }

    /// Starts the mixer only if it is not already running.
    private func startMixerIfNeeded() {
        guard mixerProcID == nil, !channels.isEmpty else { return }
        startMixer()
    }

    private func stopMixer() {
        let wasRunning = mixerProcID != nil
        // No longer running, so nothing to stall; also stops the grace period
        // from carrying over into an unrelated later start.
        mixerStartDeadline = .distantPast
        if let proc = mixerProcID {
            _ = AudioDeviceStop(outputDevice, proc)
            _ = AudioDeviceDestroyIOProcID(outputDevice, proc)
            mixerProcID = nil
        }
        if wasRunning {
            // Dump per-channel buffer health on shutdown. This is the only
            // place that can report it safely: the audio thread cannot log, and
            // by the time anyone is asking why the audio was wrong the cycles
            // that caused it are long gone.
            for channel in channels.values where channel.isUnderMixerControl.value {
                let starved = channel.starveCount.value
                let low = channel.minBuffered.value
                Log.lifecycle(String(
                    format: "channel %@: starved %lld cycle(s), low-water %.0f frames",
                    channel.appID, starved, low))
            }
            Log.lifecycle("mixer stopped")
        }
        outputDevice = kAudioObjectUnknown
        lastMixerCycle = mixerCycles.value
    }

    /// Allocates and initializes the summation buffer. Called only from the
    /// control queue, never from the audio thread; the audio thread only ever
    /// rewrites its contents via `update(repeating:)`.
    private func ensureScratchCapacity(frames: Int) {
        let needed = frames * 2
        guard needed > mixScratchCapacity else { return }
        mixScratch?.deinitialize(count: mixScratchCapacity)
        mixScratch?.deallocate()
        let fresh = UnsafeMutablePointer<Float>.allocate(capacity: needed)
        fresh.initialize(repeating: 0, count: needed)
        mixScratch = fresh
        mixScratchCapacity = needed
    }

    /// Real-time thread. Drains every channel, applies that channel's gain,
    /// measures the post-gain peak for the meter, and sums into the device.
    ///
    /// Gain is applied here rather than in each tap so the meter reflects what
    /// the user set, and so a tap thread stays a pure copy that cannot glitch.
    /// Per-cycle multiplier that makes a meter fall by roughly 20 dB per second,
    /// derived from how many frames this cycle covered.
    @inline(__always)
    private var peakDecay: Float {
        let seconds = outputFormat.mSampleRate > 0
            ? Double(mixFramesThisCycle) / outputFormat.mSampleRate : 0
        return Float(pow(0.1, seconds))
    }

    private var mixFramesThisCycle: Int = 512

    private func mix(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        mixerCycles.increment()

        guard table.count > 0, let scratch = mixScratch else { return }
        let bufferCount = Int(outputData.pointee.mNumberBuffers)
        guard bufferCount > 0 else { return }

        // Walk the output buffer list without allocating. An interleaved device
        // reports one buffer of `frames * channels` samples; a deinterleaved one
        // reports one buffer per channel of `frames` samples each.
        let base = UnsafeRawPointer(outputData)
            .advanced(by: MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!)
        let stride = MemoryLayout<AudioBuffer>.stride
        let first = base.load(fromByteOffset: 0, as: AudioBuffer.self)
        guard let firstData = first.mData else { return }

        // One buffer means interleaved: stereo in a single buffer, or mono in a
        // single buffer. More than one means one buffer per channel.
        // A single buffer holds all channels interleaved. Which stride that is
        // comes from the stream format, not the buffer list: a mono device also
        // reports one buffer, and treating it as stereo would read half the
        // buffer as frame count and write each sample twice.
        let interleaved = bufferCount == 1
        let outputChannels = max(1, min(Int(outputFormat.mChannelsPerFrame), 2))
        let destination = firstData.assumingMemoryBound(to: Float.self)
        let destinationSamples = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frames = destinationSamples / (interleaved ? outputChannels : 1)

        // Clamp rather than dropping the cycle if a device ever asks for more
        // than the buffer we preallocated.
        guard frames > 0 else { return }
        let usableFrames = min(frames, mixScratchCapacity / 2)
        guard usableFrames > 0 else { return }

        // For a deinterleaved stereo destination the right channel lives in its
        // own buffer. Anything else (including mono, where there is none) stays
        // aliased to `left`, and `accumulateInterleaved` then writes each sample
        // once instead of adding the same buffer to itself.
        var right = destination
        if !interleaved && bufferCount > 1 {
            let second = base.load(fromByteOffset: stride, as: AudioBuffer.self)
            if let secondData = second.mData {
                right = secondData.assumingMemoryBound(to: Float.self)
            }
        }
        let deinterleaved = !interleaved && bufferCount > 1

        mixFramesThisCycle = usableFrames
        let sampleCount = usableFrames * 2
        scratch.update(repeating: 0, count: sampleCount)

        table.forEach { object, _ in
            guard let channel = object as? TapChannel else { return }
            // Only channels whose tap is actually muting may be summed.
            //
            // A probe tap is created with `.unmuted`, so the app is already
            // playing through the hardware on its own. Adding its samples here
            // would put the same audio into the output a second time, a fraction
            // of a millisecond apart. Two copies of one signal offset in time is
            // comb filtering, which is heard as a hollow, phasey, "robotic"
            // version of the original -- and it is most audible on sustained
            // material like a pad or a held vocal, which is exactly where a
            // listener notices the sound has changed.
            guard channel.isUnderMixerControl.value else { return }
            TapGainEngine.mix(channel, scratch: scratch, frames: usableFrames,
                              sampleCount: sampleCount, destination: destination, right: right,
                              deinterleaved: deinterleaved, outputChannels: outputChannels,
                              limit: destinationSamples, peakDecay: peakDecay)
        }
    }

    /// One channel's contribution to a mix cycle: drain, scale, meter, accumulate.
    ///
    /// Split out of `mix` so that the gain path can be tested against real code
    /// instead of a reimplementation of it in the test. Per-app gain is the one
    /// claim that cannot be checked on a machine with no capture permission, so
    /// the arithmetic that implements it is worth pinning down here.
    ///
    /// Real-time safe: no allocation, no locks, no Objective-C.
    @inline(__always)
    static func mix(_ channel: TapChannel,
                    scratch: UnsafeMutablePointer<Float>,
                    frames: Int,
                    sampleCount: Int,
                    destination: UnsafeMutablePointer<Float>,
                    right: UnsafeMutablePointer<Float>,
                    deinterleaved: Bool,
                    outputChannels: Int,
                    limit: Int,
                    peakDecay: Float,
                    outputRate: Double = 0) {
        // Input frames to consume per output frame.
        //
        // Not derived from the reported sample rates. `tapFormat.mSampleRate`
        // reads 48000 Hz while the tap's aggregate device actually delivers
        // roughly 96000, so the ratio computed from the two rates comes out as
        // exactly 1.0 and no correction is ever applied -- which is why an
        // earlier version of this correction appeared to do nothing.
        //
        // What actually holds the level is the buffer itself: the level is a
        // direct measure of the surplus, and steering on it needs no knowledge of
        // either clock. The measured production/consumption ratio is logged so
        // the relationship stays visible instead of being inferred.
        let measured = channel.ring.measureRateRatio(produced: channel.framesCopied,
                                                     consumed: channel.framesConsumed.value)
        _ = measured
        let ratio = 1.0

        // Always sum the cycle. This tap has its app muted, so whatever the reader
        // did not fill is silence that would otherwise not be heard at all, and
        // the real prefix must not be discarded just because the tail was short.
        // Returning early on a short read -- which is what this used to do --
        // threw away the good part of every underrun, turning a momentary
        // shortfall into a hole in the middle of the music.
        let buffered = channel.ring.availableFrames
        // Regulate toward a target level rather than draining a fixed one frame
        // per frame. The two clocks differ slightly and always will, so a fixed
        // drain walks the level away until the ring is full and the write path
        // starts overwriting audio -- which is heard as the app's sound arriving
        // hundreds of milliseconds late and phasey against everything else.
        let complete = channel.ring.readRegulated(into: scratch, frameCount: frames,
                                                  rateRatio: ratio,
                                                  targetFrames: Self.targetBufferFrames,
                                                  filter: channel.decimationFilter)
        channel.framesConsumed.increment(by: Int64(frames))
        if !complete { channel.starveCount.increment() }
        // Track the worst cushion seen without ever raising it again: a plain
        // `min` on the audio thread would be a read-modify-write, so the
        // comparison is done here and only lowered values are stored.
        if Double(buffered) < channel.minBuffered.value {
            channel.minBuffered.value = Double(buffered)
        }

        let mixed = scaleInPlace(scratch, count: sampleCount, gain: channel.gain.value)
        // A complete cycle reports its own level. A short one reports a decaying
        // value instead, because the silence the reader wrote is not the app
        // going quiet and metering it as such would make the level jump around
        // during a dropout.
        channel.peak.value = complete
            ? max(mixed, channel.peak.value * peakDecay)
            : channel.peak.value * peakDecay

        if deinterleaved {
            accumulatePlanar(scratch, frames: frames, left: destination, right: right)
        } else {
            accumulateInterleaved(scratch, count: sampleCount, into: destination,
                                  limit: limit, stride: outputChannels)
        }
    }

    // MARK: - Watchdog

    /// The mixer can legitimately idle when nothing anywhere is playing, so
    /// "no cycles at all" is not proof of a stall. A stall only matters when we
    /// have channels that are muted and therefore need the mixer to bring them
    /// back -- and in that case silence is the failure we must avoid.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                self.checkMixerHealth()
                self.pruneRetired()
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func checkMixerHealth() {
        guard !isShutDown else { return }
        detectPermissionDenial()
        guard mixerProcID != nil else { return }
        let now = mixerCycles.value
        let previous = lastMixerCycle
        lastMixerCycle = now

        guard now == previous else { return }
        // A mixer that has only just been created has not necessarily produced a
        // cycle yet, so silence here is not yet evidence of a stall.
        guard Date() >= mixerStartDeadline else { return }

        // The mixer is running but not being serviced. Anything tapped right now
        // is muted with no replacement path, so release everything.
        releaseAllTaps(reason: "mixer stalled")
        availability = .failed("mixer stalled; audio restored, gain disabled")
    }

    /// CoreAudio reports a denied audio-capture permission as success
    /// everywhere: every call returns `noErr`, the tap delivers buffers on time,
    /// and the samples are all zero. The only way to tell that apart from a
    /// genuinely silent app is to watch for taps that move frames but never move
    /// them anywhere.
    ///
    /// Each tick does one of two things per channel:
    ///
    /// - A probe that has seen real audio is promoted to a muting tap. Promotion
    ///   is what hands control of the app's output to the mixer, so it only
    ///   happens once the replacement path is known to carry audio.
    /// - A probe that has moved frames but never produced any is evidence of a
    ///   denied permission, and is torn down. Tearing down a probe is silent by
    ///   construction, because a probe never muted anything.
    private func detectPermissionDenial() {
        guard mixerProcID != nil, !channels.isEmpty else {
            silentTicks = 0
            return
        }
        let copying = channels.values.contains { $0.framesCopied > 0 }
        let audible = channels.values.contains { $0.sawAudio.value }
        // Silence only counts as a denied permission while some channel is still
        // a probe. Once capture has been proven, a channel that goes quiet is
        // most likely an app that simply stopped playing, and tearing every tap
        // down on that basis would kill gain control for apps that are merely
        // idle.
        let probing = channels.values.contains { !$0.isUnderMixerControl.value }
        guard copying, !audible, probing else {
            silentTicks = 0
            // At least one tap is proven good, which also proves the permission
            // is granted. Any probe still lingering can safely go to muting now,
            // because its samples have somewhere to go.
            if audible {
                noteCaptureProven()
                promoteVerifiedProbes()
            }
            return
        }
        silentTicks += 1
        // Three seconds of a tapped app producing pure silence from a tap that is
        // demonstrably running is not a coincidence. This threshold is also the
        // length of time the user spends hearing nothing, because the tap has
        // muted the app for the duration, so it is a damage figure rather than a
        // confidence figure.
        guard silentTicks >= Self.denialTicks else { return }
        if availability == .ready {
            availability = .permissionDenied
            Log.error("taps deliver only silence: system audio capture is not permitted")
        }

        // A tap mutes its app while it is being read. Whatever CoreAudio decides
        // a denied tap means, the only safe response is to stop tapping: if the
        // mute engaged we have been silencing apps, and if it did not we were
        // reinjecting nothing for no reason. Either way, releasing them restores
        // ordinary system audio.
        //
        // This runs for every silent tap, not only the first. Holding a tap that
        // has never produced a sample would leave that app muted with nothing
        // replacing it, which is worse than the condition being detected.
        releaseAllTaps(reason: "taps deliver only silence")
    }

    /// Rebuilds probe taps as muting taps now that capture has been proven.
    ///
    /// Safe because promotion only runs once some tap has carried non-zero
    /// samples: the permission is granted and the mixer is demonstrably moving
    /// real audio, so taking over an app's output is a swap rather than a loss.
    private func promoteVerifiedProbes() {
        let pending = channels.values.filter { !$0.isMuting }
        reportBufferHealth()
        guard !pending.isEmpty else { return }
        for channel in pending {
            Log.lifecycle("promoting verified tap to muting: \(channel.appID)")
            channel.promoteToMuting()
        }
    }

    /// Reports buffer health periodically while the mixer runs.
    ///
    /// The shutdown dump is too late to be useful when the problem is "the sound
    /// is wrong right now": by then the user has already formed an opinion and
    /// the cycles in question are gone. Reporting every couple of seconds gives a
    /// live view of whether the mixer is keeping up with the taps, which is the
    /// question that actually distinguishes an underrun from correct behaviour.
    private var lastHealthReport = Date.distantPast

    private func reportBufferHealth() {
        let now = Date()
        guard now.timeIntervalSince(lastHealthReport) >= 2 else { return }
        lastHealthReport = now
        for channel in channels.values {
            let role = channel.isUnderMixerControl.value ? "muting" : "probe"
            // `net` is the diagnostic that matters: frames arriving from the tap
            // per frame the mixer consumes. Anything persistently above 1.0 is
            // surplus audio that has nowhere to go, and since the reader is
            // already correcting hard, a sustained surplus means the two are not
            // actually running at the same rate and the reported sample rates are
            // not describing the real relationship between the clocks.
            let net = channel.framesCopied > 0
                ? Double(channel.framesCopied) / Double(max(1, channel.framesConsumed.value))
                : 0
            Log.lifecycle(String(
                format: "health %@ [%@]: starved %lld, low %.0f, buffered %d, tap %.0f Hz, copied %lld consumed %lld, ratio %.5f",
                channel.appID, role, channel.starveCount.value,
                channel.minBuffered.value, channel.ring.availableFrames,
                channel.tapSampleRate.value,
                channel.framesCopied, channel.framesConsumed.value, net))
        }
    }

    /// Latches the fact that capture is known to work, so channels attached
    /// later start directly as muting taps instead of probing.
    ///
    /// Probing every newly attached app would work, but it would also mean each
    /// one starts out listening rather than under mixer control -- briefly louder
    /// than the user's slider says. Once any tap has proven the permission,
    /// attachment can go straight to the controlled state.
    private var captureProven = false

    private func noteCaptureProven() {
        guard !captureProven else { return }
        captureProven = true
        Log.lifecycle("audio capture proven; new taps will mute from the start")
    }

    /// Destroys every tap and stops the mixer. This is the single recovery path
    /// for any state where the audio graph cannot be trusted.
    private func releaseAllTaps(reason: String) {
        let released = Array(channels.values)
        channels.removeAll()
        // Unpublish before destroying, so the mixer stops reading the channels
        // before their taps go away.
        publishChannels()
        for channel in released {
            channel.stop()
            retire(channel)
        }
        stopMixer()
        Log.lifecycle("released \(released.count) tap(s): \(reason)")
    }

    /// Starts the session already knowing capture is not permitted.
    ///
    /// Set from a denial recorded by an earlier launch. Opening taps again would
    /// only mute whichever app is playing for the length of the detection window
    /// before the app reached the conclusion it already has on file.
    func suppressTaps() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                self.silentTicks = 0
                self.availability = .permissionDenied
            }
            Log.lifecycle("capture already known to be unavailable: not opening any taps")
        }
    }

    /// Clears a detected denial so the taps can be tried again, after the user
    /// has granted permission in System Settings.
    func resetAfterDenial() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                self.silentTicks = 0
                self.availability = .ready
                Log.lifecycle("retrying taps after a permission denial")
            }
        }
    }

    /// Rebuilds the mixer after the default output device or its format changes.
    func handleDeviceChange() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                guard self.mixerProcID != nil else { return }
                // Taps keep their own clock, so they survive a device change;
                // only the mixer has to be rebuilt around the new format.
                self.stopMixer()
                self.startMixer()
            }
        }
    }
}