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
    private(set) var sawAudio = false
    /// Frames copied out of the tap and into the ring.
    private(set) var framesCopied: Int64 = 0

    init(appID: String, processObjectID: AudioObjectID) {
        self.appID = appID
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
        framesCopied &+= Int64(leftFrames)
        if peak > 0 {
            sawAudio = true
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
    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogInterval: TimeInterval = 1.0

    /// Gain/mute requested per app, applied once a channel exists. Kept here so
    /// a level set before the tap came up is not lost.
    private var pendingGain: [String: Float] = [:]
    private var pendingMute: [String: Bool] = [:]

    init() {
        // The mixer is deliberately *not* started here. An IOProc on the user's
        // default output device keeps the device active and costs power, so it
        // is created only while there is at least one app to route.
        startWatchdog()
    }

    // MARK: - GainEngine

    func attach(to app: AudioApp) {
        let appID = channelID(for: app)
        controlQueue.async { [weak self] in
            guard let self, self.channels[appID] == nil else { return }

            let channel = TapChannel(appID: appID, processObjectID: app.processObjectID)
            let status = channel.start(queue: self.tapQueue)
            guard status == noErr else {
                Log.error("tap start failed for \(appID): \(fourcc(status))")
                return
            }
            if let gain = self.pendingGain[appID] {
                channel.gain.value = gain
                if self.pendingMute[appID] != true { channel.gain.value = gain }
            }
            if self.pendingMute[appID] == true { channel.gain.value = 0 }

            self.channels[appID] = channel
            self.publishChannels()
            self.startMixerIfNeeded()
            Log.lifecycle("attached \(appID) tap=\(channel.tapID) agg=\(channel.aggregateID)")
        }
    }

    func detach(appID: String) {
        controlQueue.async { [weak self] in
            guard let self, let channel = self.channels.removeValue(forKey: appID) else { return }
            // Unpublish before stopping so the mixer stops reading the channel,
            // then hold the object alive briefly rather than immediately
            // releasing it out from under an in-flight callback.
            self.publishChannels()
            channel.stop()
            self.retire(channel)
            // With the last channel gone there is nothing to mix, so release the
            // device again.
            if self.channels.isEmpty { self.stopMixer() }
            Log.lifecycle("detached \(appID)")
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
            let clamped = max(0, gain)
            self.pendingGain[appID] = clamped
            self.pendingMute[appID] = false
            self.channels[appID]?.gain.value = clamped
        }
    }

    func setMuted(_ muted: Bool, for appID: String) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.pendingMute[appID] = muted
            let base = self.pendingGain[appID] ?? 1
            self.pendingGain[appID] = muted ? 0 : base
            self.channels[appID]?.gain.value = muted ? 0 : base
        }
    }

    func peak(for appID: String) -> Float {
        channels[appID]?.peak.value ?? 0
    }

    var liveAppIDs: Set<String> { Set(channels.keys) }

    func shutdown() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        stopMixer()
        // Never call this from the control queue: `sync` onto a queue that is
        // already draining would deadlock.
        controlQueue.sync {
            for channel in channels.values { channel.stop() }
            channels.removeAll()
            publishChannels()
            retired.removeAll()
        }
        mixScratch?.deinitialize(count: mixScratchCapacity)
        mixScratch?.deallocate()
        mixScratch = nil
        mixScratchCapacity = 0
    }

    func channelID(for app: AudioApp) -> String {
        app.bundleID.isEmpty ? "pid-\(app.pid)" : app.bundleID
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
        guard outputFormat.mSampleRate > 0, outputFormat.mChannelsPerFrame > 0 else {
            availability = .failed("invalid output format")
            return
        }
        // The mixer only handles float32, which covers built-in, USB and
        // Bluetooth outputs on current macOS.
        guard outputFormat.isFloat32 else {
            availability = .failed("output format \(outputFormat.formatCode) is not float32")
            Log.error("mixer format unsupported: \(outputFormat.formatCode)")
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
        Log.lifecycle("mixer started device=\(device) rate=\(outputFormat.mSampleRate) ch=\(outputFormat.mChannelsPerFrame)")
    }

    /// Starts the mixer only if it is not already running.
    private func startMixerIfNeeded() {
        guard mixerProcID == nil, !channels.isEmpty else { return }
        startMixer()
    }

    private func stopMixer() {
        if let proc = mixerProcID {
            _ = AudioDeviceStop(outputDevice, proc)
            _ = AudioDeviceDestroyIOProcID(outputDevice, proc)
            mixerProcID = nil
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

        let interleaved = bufferCount == 1
        let destination = firstData.assumingMemoryBound(to: Float.self)
        let destinationSamples = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frames = (interleaved ? destinationSamples / 2 : destinationSamples)

        // Clamp rather than dropping the cycle if a device ever asks for more
        // than the buffer we preallocated.
        guard frames > 0 else { return }
        let usableFrames = min(frames, mixScratchCapacity / 2)
        guard usableFrames > 0 else { return }

        var right = destination
        if !interleaved && bufferCount > 1 {
            let second = base.load(fromByteOffset: stride, as: AudioBuffer.self)
            if let secondData = second.mData {
                right = secondData.assumingMemoryBound(to: Float.self)
            }
        }

        let sampleCount = usableFrames * 2
        scratch.update(repeating: 0, count: sampleCount)

        table.forEach { object, _ in
            guard let channel = object as? TapChannel else { return }
            let framesRead = channel.ring.read(into: scratch, frameCount: usableFrames)
            guard framesRead > 0 else { return }

            let gain = channel.gain.value
            var peak: Float = 0
            var index = 0
            while index < sampleCount {
                let scaled = scratch[index] * gain
                scratch[index] = scaled
                let magnitude = abs(scaled)
                if magnitude > peak { peak = magnitude }
                index += 1
            }
            channel.peak.value = peak

            if interleaved {
                let limit = min(sampleCount, destinationSamples)
                var i = 0
                while i < limit {
                    destination[i] += scratch[i]
                    i += 1
                }
            } else {
                var frame = 0
                while frame < framesRead {
                    destination[frame] += scratch[frame * 2]
                    right[frame] += scratch[frame * 2 + 1]
                    frame += 1
                }
            }
        }
    }

    // MARK: - Watchdog

    /// The mixer can legitimately idle when nothing anywhere is playing, so
    /// "no cycles at all" is not proof of a stall. A stall only matters when we
    /// have channels that are muted and therefore need the mixer to bring them
    /// back -- and in that case silence is the failure we must avoid.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkMixerHealth()
            self.pruneRetired()
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func checkMixerHealth() {
        detectPermissionDenial()
        guard mixerProcID != nil else { return }
        let now = mixerCycles.value
        let previous = lastMixerCycle
        lastMixerCycle = now

        guard now == previous else { return }

        // The mixer is running but not being serviced. Anything tapped right now
        // is muted with no replacement path, so release everything.
        Log.error("mixer stalled: releasing \(self.channels.count) tap(s) to restore audio")
        let released = Array(channels.values)
        channels.removeAll()
        publishChannels()
        for channel in released { channel.stop() }
        stopMixer()
        // Nothing is reading the table any more, so the objects can go now.
        retired.removeAll()
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
        let audible = channels.values.contains { $0.sawAudio }
        guard copying, !audible else {
            silentTicks = 0
            return
        }
        silentTicks += 1
        // Five seconds of an "audible" app producing pure silence from a tap
        // that is demonstrably running is not a coincidence.
        if silentTicks >= 5, availability == .ready {
            availability = .permissionDenied
            Log.error("taps deliver only silence: system audio capture is not permitted")
        }
    }

    /// Rebuilds the mixer after the default output device or its format changes.
    func handleDeviceChange() {
        controlQueue.async { [weak self] in
            guard let self, self.mixerProcID != nil else { return }
            // Taps keep their own clock, so they survive a device change; only
            // the mixer has to be rebuilt around the new format.
            self.stopMixer()
            self.startMixer()
        }
    }
}