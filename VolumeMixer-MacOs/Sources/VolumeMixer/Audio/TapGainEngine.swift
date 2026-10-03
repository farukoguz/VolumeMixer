import CoreAudio
import AudioToolbox
import Foundation

/// One app's audio path: a process tap, a private aggregate device containing
/// only that tap, and an IOProc that copies its samples into a ring buffer for
/// the mixer.
///
/// The tap's `muteBehavior` is `mutedWhenTapped`: the app is silenced from the
/// speakers only while this IOProc is reading the tap, so it is never heard
/// twice and never silently swallowed either.
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

    let gain = GainSlot(1.0)
    let peak = PeakSlot(0)
    /// IO cycles served. The watchdog reads this to distinguish a live pipeline
    /// from a stalled one.
    let cycles = FrameCounter()

    let ring = SampleRingBuffer()

    /// True once any non-zero sample has passed through the tap. On macOS a
    /// denied audio-capture permission looks exactly like a working pipeline
    /// that happens to produce zeros, so this is how denial is detected.
    /// Atomic because the watchdog reads it from another thread.
    let sawAudio = AtomicFlag()
    /// Frames copied out of the tap and into the ring, for the same reason.
    let framesCounter = FrameCounter()
    var framesCopied: Int64 { framesCounter.value }

    init(identity: String, processKey: String, processObjectID: AudioObjectID) {
        self.identity = identity
        self.appID = processKey
        self.processObjectID = processObjectID
    }

    func start(queue: DispatchQueue) -> OSStatus {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        let uuid = UUID()
        description.uuid = uuid
        description.name = "VolumeMixer-\(appID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

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
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: uuid.uuidString,
                    // Required, not optional. Without it CoreAudio resamples on
                    // every cycle to reconcile the tap clock against the
                    // aggregate clock, which is audible as periodic crackling in
                    // *all* system audio, not just the tapped app.
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

        var newIOProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProc, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            self?.render(inputData)
        }
        guard procStatus == noErr, let ioProc = newIOProc else {
            stop()
            return procStatus
        }
        ioProcID = ioProc

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
        peak.value = 0
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
    private let watchdogInterval: TimeInterval = 1.0

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

    // MARK: - GainEngine

    func attach(to app: AudioApp) {
        let identity = app.id
        controlQueue.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.stateLock.withLock {
                let channel = TapChannel(identity: identity,
                                         processKey: app.processKey,
                                         processObjectID: app.processObjectID)
                guard self.channels[channel.appID] == nil else { return }
                let status = channel.start(queue: self.tapQueue)
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
        if wasRunning { Log.lifecycle("mixer stopped") }
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
                    peakDecay: Float) {
        let framesRead = channel.ring.read(into: scratch, frameCount: frames)
        guard framesRead > 0 else { return }

        let mixed = scaleInPlace(scratch, count: sampleCount, gain: channel.gain.value)
        // Decay instead of latching, otherwise a meter pins at the last
        // non-zero peak for as long as the app stays routed.
        channel.peak.value = max(mixed, channel.peak.value * peakDecay)

        if deinterleaved {
            accumulatePlanar(scratch, frames: framesRead, left: destination, right: right)
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
    private func detectPermissionDenial() {
        guard mixerProcID != nil, !channels.isEmpty else {
            silentTicks = 0
            return
        }
        let copying = channels.values.contains { $0.framesCopied > 0 }
        let audible = channels.values.contains { $0.sawAudio.value }
        guard copying, !audible else {
            silentTicks = 0
            return
        }
        silentTicks += 1
        // Five seconds of an "audible" app producing pure silence from a tap
        // that is demonstrably running is not a coincidence.
        guard silentTicks >= 5, availability == .ready else { return }
        availability = .permissionDenied
        Log.error("taps deliver only silence: releasing taps, system audio capture is not permitted")

        // A tap mutes its app while it is being read. Whatever CoreAudio decides
        // a denied tap means, the only safe response is to stop tapping: if the
        // mute engaged we have been silencing apps, and if it did not we were
        // reinjecting nothing for no reason. Either way, releasing them restores
        // ordinary system audio.
        releaseAllTaps(reason: "permission denied")
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