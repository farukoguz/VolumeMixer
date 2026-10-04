import CoreAudio
import Foundation

// MARK: - Decimation

/// Lowpass filter applied before the ring is decimated down to the mixer's rate.
///
/// The tap supplies about two frames for every frame the mixer emits, so each
/// output frame is assembled from roughly two input frames. Discarding or
/// naively averaging them folds the content above the output Nyquist frequency
/// back into the audible band -- the classic aliasing artefact -- which is
/// heard as harshness and a robotic edge on sustained material.
///
/// A short symmetric FIR running average is enough here: it is cheap enough for
/// the audio thread, it needs no coefficients table, and because the decimation
/// factor is small a handful of taps attenuates the images substantially. It is
/// a gentle lowpass rather than a brick wall, which is the right trade for music
/// where too much filtering is itself audible as loss of top end.
///
/// State is per channel and owned by the channel, since the two are drained from
/// different threads but never from two at once for the same channel.
final class DecimationFilter {

    /// Taps in the moving average. Six keeps the passband flat to roughly 0.8 of
    /// the Nyquist frequency while pushing the first image well down.
    private static let taps = 6
    /// Interleaved history: 2 channels x `taps`.
    private let history: UnsafeMutablePointer<Float>
    /// Running sums for the most recent frame, kept as fields so the filter can
    /// return both channels without allocating a tuple on the audio thread.
    private var sumL: Float = 0
    private var sumR: Float = 0

    init() {
        history = .allocate(capacity: DecimationFilter.taps * 2)
        history.initialize(repeating: 0, count: DecimationFilter.taps * 2)
    }

    deinit {
        history.deinitialize(count: DecimationFilter.taps * 2)
        history.deallocate()
    }

    /// Filters one stereo frame, returning the averaged left sample.
    ///
    /// The right sample comes from `processRight`. Returning two values from one
    /// call needs a tuple, and taking the address of a temporary for an `out`
    /// parameter is the kind of thing that quietly allocates -- which is
    /// unacceptable on the audio thread.
    ///
    /// Real-time safe: a fixed-size running sum over preallocated storage, with
    /// no allocation and no dependency on anything but the inputs.
    @inline(__always)
    func processLeft(_ left: Float, _ right: Float) -> Float {
        advance(left, right)
        return averageLeft
    }

    /// The left-channel result of the most recent `advance`.
    @inline(__always)
    var averageLeft: Float {
        sumL * Self.scale
    }

    /// The right-channel result of the most recent `advance`.
    @inline(__always)
    var averageRight: Float {
        sumR * Self.scale
    }

    private static let scale = Float(1.0) / Float(DecimationFilter.taps)

    /// Shifts the history and folds in the new frame, leaving the sums ready.
    @inline(__always)
    private func advance(_ left: Float, _ right: Float) {
        let taps = DecimationFilter.taps
        // Shift the window down by one and drop the oldest sample, which is what
        // makes it a moving average rather than a fixed set of slots. Summing the
        // window before the shift is what makes the sum correct this frame; the
        // shift then moves every retained sample one place along.
        var l: Float = 0
        var r: Float = 0
        for index in 0..<(taps - 1) {
            l += history[index * 2]
            r += history[index * 2 + 1]
        }
        for index in stride(from: taps - 1, through: 1, by: -1) {
            history[index * 2] = history[(index - 1) * 2]
            history[index * 2 + 1] = history[(index - 1) * 2 + 1]
        }
        history[0] = left
        history[1] = right
        sumL = l + left
        sumR = r + right
    }

    func reset() {
        history.initialize(repeating: 0, count: DecimationFilter.taps * 2)
    }
}

// MARK: - GainSlot

/// A single `Float` that the UI thread writes and a real-time IOProc reads.
///
/// There is no C11-atomic `Float` in Swift and `Synchronization.Atomic`
/// requires macOS 15, so the value is stored as the `Int32` bit pattern of the
/// float in a manually allocated, 64-bit-aligned slot. On arm64 an aligned
/// 32-bit load/store is a single instruction and therefore atomic; tearing
/// between producer and consumer is not possible.
///
/// This is deliberately not an `UnsafeMutablePointer<Float>` property on a
/// class: that would be a managed-reference access from the audio thread.
final class GainSlot {

    private let storage: UnsafeMutablePointer<Int32>

    init(_ initial: Float = 1.0) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: Int32(bitPattern: initial.bitPattern))
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// Real-time safe: aligned 32-bit access, no allocation, no ARC.
    @inline(__always)
    var value: Float {
        get { Float(bitPattern: UInt32(bitPattern: storage.pointee)) }
        set { storage.pointee = Int32(bitPattern: newValue.bitPattern) }
    }
}

// MARK: - PeakSlot

/// A `Float` written by the audio thread and read by the UI at frame rate.
/// Same alignment/atomicity reasoning as `GainSlot`.
final class PeakSlot {

    private let storage: UnsafeMutablePointer<Int32>

    init(_ initial: Float = 0) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: Int32(bitPattern: initial.bitPattern))
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    @inline(__always)
    var value: Float {
        get { Float(bitPattern: UInt32(bitPattern: storage.pointee)) }
        set { storage.pointee = Int32(bitPattern: newValue.bitPattern) }
    }
}

// MARK: - FrameCounter

/// A monotonically increasing counter shared between threads. Used by the
/// watchdog to tell whether the audio thread is still alive.
final class FrameCounter {

    private let storage: UnsafeMutablePointer<Int64>

    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// Real-time safe on 64-bit: aligned 64-bit access is atomic on arm64/x86-64.
    @inline(__always)
    var value: Int64 {
        get { storage.pointee }
        set { storage.pointee = newValue }
    }

    @inline(__always)
    func increment() {
        storage.pointee &+= 1
    }

    @inline(__always)
    func increment(by amount: Int64) {
        storage.pointee &+= amount
    }
}

// MARK: - AtomicFlag

/// A single boolean shared between the tap thread and the watchdog. Written at
/// most once per cycle from the audio side, read from the watchdog, so it has to
/// be a real atomic rather than a stored property: a plain `Bool` would be a data
/// race the moment the watchdog samples it mid-write.
final class AtomicFlag {

    private let storage: UnsafeMutablePointer<Int32>

    init(_ value: Bool = false) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: value ? 1 : 0)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// Real-time safe: aligned 32-bit access is atomic on arm64/x86-64.
    @inline(__always)
    var value: Bool {
        get { storage.pointee != 0 }
        set { storage.pointee = newValue ? 1 : 0 }
    }
}

/// A sample rate shared between the thread that starts a tap and the real-time
/// mix thread.
///
/// Bit-cast rather than stored as a `Double`: an aligned 64-bit load is atomic on
/// arm64 and x86-64, whereas a `Double` property would be a pair of 32-bit
/// stores that the mixer could read half-updated. The mix thread reads this every
/// cycle, so tearing here would show up as an audible pitch glitch rather than a
/// crash.
final class AtomicRate {

    private let storage: UnsafeMutablePointer<UInt64>

    init(_ value: Double = 0) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: value.bitPattern)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// Real-time safe.
    @inline(__always)
    var value: Double {
        get { Double(bitPattern: storage.pointee) }
        set { storage.pointee = newValue.bitPattern }
    }
}

// MARK: - SampleRingBuffer

/// Lock-free single-producer/single-consumer ring buffer of interleaved stereo
/// frames, used to hand audio from each app's tap IOProc to the mixer IOProc.
///
/// Design constraints, all of them real-time requirements:
///   * storage is allocated once, at init -- never on the audio thread
///   * capacity is a power of two so indices wrap with a mask
///   * indices are separate cache lines to avoid false sharing between threads
///
/// When the producer gets more than a cycle's worth of audio the ring
/// **overwrites the oldest frames** rather than dropping the new ones. Keeping
/// stale audio would make playback lag further and further behind, which is far
/// more noticeable than a dropped frame. That makes the read index shared: the
/// producer may move it forward when it overruns, and the consumer only ever
/// advances it, so the two can never disagree about which frame is next in a way
/// that reads outside the buffer.
///
/// Frame layout is interleaved `[L0, R0, L1, R1, ...]`.
final class SampleRingBuffer {

    /// Must be a power of two.
    static let defaultCapacity = 1 << 15   // 32768 frames ~= 0.68s at 48 kHz

    /// The mixer's read target, i.e. how many input frames it consumes per
    /// output frame when the tap and the device agree. The mixer scales this by
    /// the ratio between the tap's sample rate and the device's.
    static let defaultTargetFrames = 4096   // ~85 ms at 48 kHz

    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int

    /// Producer-owned. Padded away from `readIndex` to stay on its own line.
    private let writeStorage: UnsafeMutablePointer<Int64>
    /// Consumer-owned.
    private let readStorage: UnsafeMutablePointer<Int64>
    /// Consumer-owned fractional read position, within the unread window.
    private let readPhase: UnsafeMutablePointer<Double>

    private static let cacheLine = 64

    init(capacity: Int = SampleRingBuffer.defaultCapacity) {
        precondition(capacity > 0 && capacity.nonzeroBitCount == 1, "capacity must be a power of two")
        self.capacity = capacity
        self.mask = capacity - 1

        storage = .allocate(capacity: capacity * 2)
        storage.initialize(repeating: 0, count: capacity * 2)

        // Oversize each slot by a cache line so producer and consumer indices
        // never share one.
        writeStorage = .allocate(capacity: SampleRingBuffer.cacheLine)
        writeStorage.initialize(to: 0)
        readStorage = .allocate(capacity: SampleRingBuffer.cacheLine)
        readStorage.initialize(to: 0)
        readPhase = .allocate(capacity: SampleRingBuffer.cacheLine)
        readPhase.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: capacity * 2)
        storage.deallocate()
        writeStorage.deinitialize(count: SampleRingBuffer.cacheLine)
        writeStorage.deallocate()
        readStorage.deinitialize(count: SampleRingBuffer.cacheLine)
        readStorage.deallocate()
        readPhase.deinitialize(count: SampleRingBuffer.cacheLine)
        readPhase.deallocate()
    }

    /// Real-time safe producer side. `samples` is interleaved stereo.
    /// Returns the number of frames accepted.
    ///
    /// An overrun moves the read index forward, keeping the newest frames and
    /// discarding the oldest, so a stalled consumer cannot build up latency.
    @inline(__always)
    @discardableResult
    func write(_ samples: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let write = writeStorage.pointee
        let read = readStorage.pointee
        let free = capacity - Int(write &- read)

        // Overwrite: advance the read cursor so only the newest `capacity`
        // frames remain, then treat the whole write as fitting.
        //
        // Advancing the consumer's index from the producer side looks alarming,
        // but the alternative is worse. When the consumer cannot keep up, either
        // choice loses audio; discarding the oldest frames keeps the freshest
        // audio and leaves the ring full, which the consumer's level
        // regulation then drains back down to target. Clamping the write to the
        // free space instead would leave the ring permanently full and let it
        // never recover, because the producer would only ever contribute the
        // frames that happened to fit.
        if free < frameCount {
            readStorage.pointee = write &+ Int64(frameCount) &- Int64(capacity)
        }

        let toWrite = min(frameCount, capacity)
        // `ringOffset` walks the destination while `consumed` walks the source.
        // They diverge once the write wraps past the end of the ring.
        var ringOffset = Int(write & Int64(mask))
        var consumed = 0

        while consumed < toWrite {
            let chunk = min(toWrite - consumed, capacity - ringOffset)
            (storage + ringOffset * 2).update(from: samples + consumed * 2, count: chunk * 2)
            consumed += chunk
            ringOffset = (ringOffset + chunk) & mask
        }

        writeStorage.pointee = write &+ Int64(toWrite)
        return toWrite
    }

    /// Real-time safe consumer side. Fills `out` with interleaved stereo frames.
    /// Returns the number of frames produced, which may be fewer than asked for.
    ///
    /// The mix cycle is written against this contract: it treats a short read as
    /// "nothing more available right now" and holds the previous frame rather
    /// than assuming the buffer was filled. See `readSteady`.
    @inline(__always)
    func read(into out: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        let read = readStorage.pointee
        let write = writeStorage.pointee
        let available = Int(write &- read)
        guard available > 0 else { return 0 }

        let toRead = min(frameCount, available)
        // `ringOffset` walks the source ring; `produced` walks the caller's
        // destination buffer, which is always contiguous.
        var ringOffset = Int(read & Int64(mask))
        var produced = 0

        while produced < toRead {
            let chunk = min(toRead - produced, capacity - ringOffset)
            (out + produced * 2).assign(from: storage + ringOffset * 2, count: chunk * 2)
            produced += chunk
            ringOffset = (ringOffset + chunk) & mask
        }

        // Never move the read index backwards: the producer may have advanced it
        // past us during the copy above to drop stale frames.
        let advanced = read &+ Int64(toRead)
        if advanced > readStorage.pointee { readStorage.pointee = advanced }
        return toRead
    }

    /// Reads exactly `frameCount` frames for the mixer, consuming input at
    /// `rateRatio` frames per output frame and interpolating between them.
    ///
    /// This exists because the two audio clocks in this app are not the same
    /// clock. Each tap runs on its aggregate device's clock and the mixer runs on
    /// the output device's, and they differ by a small fraction that is not zero.
    /// Reading with `read` alone cannot cope: it hands back only whole frames
    /// that are already buffered, so the mix cycle comes up short by a frame or
    /// two almost every time, the tail of the cycle is silence, and the shortfall
    /// never recovers because the reader never consumes anything extra. That
    /// repeated gap is the stuttering, chopped "robot" sound.
    ///
    /// `readPhase` carries the sub-frame remainder, so over time input frames are
    /// consumed at exactly `rateRatio` and none are skipped or replayed. A ratio
    /// above 1 drops the frames in between; below 1 interpolates across them.
    ///
    /// When input genuinely runs short the tail is faded to silence rather than
    /// cut, so the remaining fault is a dip and not a click.
    ///
    /// Returns `true` when the whole cycle was filled from real audio.
    /// Real-time safe: no allocation, no locks.
    @inline(__always)
    func readSteady(into out: UnsafeMutablePointer<Float>,
                    frameCount: Int,
                    rateRatio: Double) -> Bool {
        guard frameCount > 0 else { return true }
        let ratio = max(0.25, min(4.0, rateRatio))

        for produced in 0..<frameCount {
            let availableNow = Int(writeStorage.pointee &- readStorage.pointee)
            guard availableNow > 0 else {
                // The input ran dry part-way through this cycle. Everything up to
                // here is real audio and has already been written, so it must not
                // be thrown away: the caller is about to replace a *muted* app,
                // and discarding a good cycle here is an audible dropout in the
                // middle of a song. Only the remaining tail is silence.
                //
                // Repeating the final real sample for the tail rather than zeroing
                // would hold the waveform, which on a music signal is far more
                // audible than a gap, so the tail is genuinely silent.
                for index in (produced * 2)..<(frameCount * 2) {
                    out[index] = 0
                }
                readPhase.pointee = 0
                return false
            }

            // `readStorage` points at the current input frame and `readPhase` is
            // how far to interpolate towards the one after it.
            let base = Int(readStorage.pointee) & mask
            let next = (base + 1) & mask
            let phase = readPhase.pointee

            let l0 = storage[base * 2]
            let r0 = storage[base * 2 + 1]
            // With a single frame buffered there is nothing to interpolate
            // towards, so hold it. Requiring a lookahead frame instead would
            // shorten every read by one and truncate the mix cycle.
            let hasNext = availableNow > 1
            let l1 = hasNext ? storage[next * 2] : l0
            let r1 = hasNext ? storage[next * 2 + 1] : r0

            out[produced * 2] = Float(Double(l0) + (Double(l1) - Double(l0)) * phase)
            out[produced * 2 + 1] = Float(Double(r0) + (Double(r1) - Double(r0)) * phase)

            // Advance by whole input frames, carrying the remainder.
            let total = phase + ratio
            let advance = Int(total)
            readStorage.pointee &+= Int64(advance)
            readPhase.pointee = total - Double(advance)
        }
        return true
    }

    /// Measures how many input frames the producer delivers per frame the
    /// consumer drains, over a window, and returns the true ratio.
    ///
    /// This exists because `tapFormat.mSampleRate` cannot be trusted for this.
    /// It reports 48000 for a tap whose aggregate device is in fact running at
    /// double that, so dividing one by the other yields exactly 1.0 and every
    /// rate-based correction built on it is a no-op. The only figure that does
    /// not lie is the one measured by counting frames on both sides.
    ///
    /// Real-time safe: two integer loads and one store, no locks.
    @inline(__always)
    func measureRateRatio(produced: Int64, consumed: Int64) -> Double {
        guard consumed > 0, produced > 0 else { return 1.0 }
        let ratio = Double(produced) / Double(consumed)
        // Reported only; not used for steering. Guarded anyway so a transient
        // miscount cannot produce a nonsense figure in the log.
        return max(0.25, min(4.0, ratio))
    }

    /// Drains one mix cycle while regulating the buffer level toward a target.
    ///
    /// A fixed one-in-one-out drain is only correct when the producer and the
    /// consumer run on identical clocks. They do not: the tap is clocked by the
    /// aggregate device that contains only that tap, while the mixer is clocked
    /// by the output device. The mismatch is tiny per cycle and cumulative over
    /// time, so the level walks steadily away from where it started. If the tap
    /// is even slightly fast the ring fills, the write path starts overwriting
    /// the oldest audio, and the re-injected sound arrives hundreds of
    /// milliseconds late -- audible as a hollow, phasey copy of the original
    /// rather than as a clean repeat of it.
    ///
    /// Rather than guess a rate, this steers on the error itself: each output
    /// frame consumes a little more or a little less input to pull the level
    /// back toward `targetFrames`. That converges for any clock mismatch,
    /// including ones the two reported sample rates do not describe, and it caps
    /// how far the correction can stray so the resampling stays inaudible.
    ///
    /// Returns false when the ring ran dry part-way through the cycle, in which
    /// case the tail has been filled with silence and the prefix holds real
    /// audio.
    func readRegulated(into out: UnsafeMutablePointer<Float>,
                       frameCount: Int,
                       rateRatio: Double,
                       targetFrames: Int,
                       filter: DecimationFilter? = nil) -> Bool {
        guard frameCount > 0 else { return true }
        let ratio = max(0.25, min(4.0, rateRatio))
        // How quickly correction strength ramps with the size of the error. At
        // 1/2000 a 2000-frame error is already ~63% of full correction, so a
        // large backlog is drained decisively while a small one is corrected
        // gently.
        let correctionPerFrame = 1.0 / 2_000.0
        // Ceiling on the correction, as a multiplier on the base rate.
        //
        // Needs to exceed 1.0 because the surplus being corrected is not a small
        // clock skew: this tap delivers about twice the audio the mixer consumes,
        // so a ceiling of 1.0 -- consume at most 2x -- leaves the ring
        // permanently full. The ceiling is what lets the reader match a
        // genuinely doubled producer instead of only trimming a slow drift.
        let maxCorrection = 3.0
        // Frames of error tolerated before correcting. Sized to cover ordinary
        // callback jitter so a healthy pipeline is left completely alone.
        let deadbandFrames = max(64, targetFrames / 8)

        for produced in 0..<frameCount {
            let availableNow = Int(writeStorage.pointee &- readStorage.pointee)
            guard availableNow > 0 else {
                for index in (produced * 2)..<(frameCount * 2) {
                    out[index] = 0
                }
                readPhase.pointee = 0
                return false
            }

            let base = Int(readStorage.pointee) & mask
            let next = (base + 1) & mask
            let phase = readPhase.pointee

            let l0 = storage[base * 2]
            let r0 = storage[base * 2 + 1]
            let hasNext = availableNow > 1
            let l1 = hasNext ? storage[next * 2] : l0
            let r1 = hasNext ? storage[next * 2 + 1] : r0

            // Steer the level: too much buffered means consume faster to drain
            // it, too little means ease off so the tap can catch up.
            //
            // Nothing happens while the level is already close to target. That is
            // deliberate: in the steady state -- which is the overwhelmingly
            // common case -- the reader consumes exactly one input frame per
            // output frame and the samples reaching the mixer are the samples
            // that came out of the tap, bit for bit. Resampling even by a
            // fraction of a percent would quietly alter every app's audio and
            // break the promise that unity gain is a pass-through, so the
            // correction only engages once there is a real error to correct.
            // Only an *overfull* ring is corrected.
            //
            // Too much buffered is the failure that actually occurs: the tap runs
            // slightly fast, the level climbs, and eventually the write path
            // starts discarding audio. Too little is a different problem with a
            // different and better remedy -- a short read is already reported to
            // the caller, which fills the gap with silence, and the tap refills
            // the ring on its own within a cycle or two.
            //
            // Restricting the correction to one direction is also what keeps
            // unity gain an exact pass-through. With nothing to drain, the reader
            // consumes precisely one input frame per output frame and the samples
            // arriving at the mixer are the samples that left the tap, which is
            // the property the gain tests exist to protect.
            // Correction strength ramps with how far off target the ring is.
            //
            // A fixed small percentage cannot recover from a large backlog: the
            // tap keeps filling the ring at exactly the rate the mixer drains it,
            // so a 2% edge only ever holds the level where it is and the ring
            // stays full. The correction therefore grows with the error and is
            // allowed to reach 100% -- consuming two input frames for one output
            // frame -- while far from target, then falls away to nothing as the
            // level approaches it. Draining faster than real time is audible
            // only in proportion to how much audio is discarded, and the audio
            // being discarded is audio the user is already ~0.7 s behind on, so
            // dropping it is strictly better than continuing to play it late.
            //
            // The ramp is squared rather than linear so that correction strength
            // collapses as the level nears target. A linear ramp still applies
            // most of its strength right up to the target and sails past it,
            // which trades a full ring for an empty one. Squaring makes the
            // approach asymptotic: the last few hundred frames are corrected
            // gently enough to land on target instead of overshooting.
            let excess = Double(availableNow - targetFrames - deadbandFrames)
            let steered: Double
            if excess <= 0 {
                steered = ratio
            } else {
                let ramped = 1.0 - exp(-excess * correctionPerFrame)
                let strength = ramped * ramped * maxCorrection
                steered = ratio * (1.0 + strength)
            }
            // Lowpass before decimating, and only then.
            //
            // The filter is what stops above-Nyquist content folding back into
            // the audible band -- the harsh, artificial edge that survives even
            // when the buffer level is regulated correctly. It also attenuates
            // and delays the signal, so applying it when the tap and the mixer
            // already run one-to-one would quietly alter every app's audio and
            // break the promise that unity gain is a pass-through. The gain tests
            // exist to protect exactly that, and they fail if this is
            // unconditional.
            //
            // Decimating means consuming more than one input frame per output
            // frame, which is what `steered` reports against `ratio`.
            if let filter, steered > ratio + 0.001 {
                out[produced * 2] = filter.processLeft(l0, r0)
                out[produced * 2 + 1] = filter.averageRight
            } else {
                out[produced * 2] = Float(Double(l0) + (Double(l1) - Double(l0)) * phase)
                out[produced * 2 + 1] = Float(Double(r0) + (Double(r1) - Double(r0)) * phase)
            }

            let total = phase + steered
            let advance = Int(total)
            readStorage.pointee &+= Int64(advance)
            readPhase.pointee = total - Double(advance)
        }
        return true
    }

    /// Real-time safe producer side for a stereo mixdown tap, which delivers
    /// deinterleaved channels (one `AudioBuffer` each). Converts to the ring's
    /// interleaved layout as it goes, so no scratch buffer is required.
    ///
    /// Returns the peak absolute sample value written, which the caller uses for
    /// metering and to detect that the tap is delivering actual audio.
    @inline(__always)
    func writeDeinterleaved(_ left: UnsafePointer<Float>,
                            _ right: UnsafePointer<Float>,
                            frameCount: Int) -> Float {
        guard frameCount > 0 else { return 0 }
        let write = writeStorage.pointee
        let read = readStorage.pointee
        let free = capacity - Int(write &- read)
        if free < frameCount {
            readStorage.pointee = write &+ Int64(frameCount) &- Int64(capacity)
        }

        let toWrite = min(frameCount, capacity)
        var ringOffset = Int(write & Int64(mask))
        var consumed = 0
        var peak: Float = 0

        while consumed < toWrite {
            let chunk = min(toWrite - consumed, capacity - ringOffset)
            let destination = storage + ringOffset * 2
            var index = 0
            while index < chunk {
                let l = left[consumed + index]
                let r = right[consumed + index]
                destination[index * 2] = l
                destination[index * 2 + 1] = r
                let magnitudeL = abs(l)
                if magnitudeL > peak { peak = magnitudeL }
                let magnitudeR = abs(r)
                if magnitudeR > peak { peak = magnitudeR }
                index += 1
            }
            consumed += chunk
            ringOffset = (ringOffset + chunk) & mask
        }

        writeStorage.pointee = write &+ Int64(toWrite)
        return peak
    }

    /// Discards everything. Called when a tap is torn down so stale audio is
    /// never replayed by the mixer.
    func reset() {
        readStorage.pointee = writeStorage.pointee
        readPhase.pointee = 0
    }

    var availableFrames: Int {
        Int(writeStorage.pointee &- readStorage.pointee)
    }
}

// MARK: - Gain

/// Scales `count` interleaved samples in place by `gain` and returns the peak
/// absolute value of the result.
///
/// Pulled out of the mixer so the arithmetic the user actually hears can be
/// tested without an audio device attached, and so the hot loop has one
/// obvious definition of "what does gain mean".
@inline(__always)
func scaleInPlace(_ samples: UnsafeMutablePointer<Float>, count: Int, gain: Float) -> Float {
    guard count > 0 else { return 0 }
    var peak: Float = 0
    var index = 0
    while index < count {
        let scaled = samples[index] * gain
        samples[index] = scaled
        let magnitude = abs(scaled)
        if magnitude > peak { peak = magnitude }
        index += 1
    }
    return peak
}

// MARK: - Summation

/// Adds interleaved frames from `source` into an interleaved destination.
///
/// `limit` is the destination's capacity in samples, which may be smaller than
/// `count` if a device ever asks for more frames than were mixed.
///
/// `stride` is how many samples of destination each source frame occupies: 2 for
/// stereo, 1 for a mono device that hands us a single buffer. Without it a mono
/// output would be written twice and come out doubled.
///
/// A mono destination gets the two channels summed rather than one of them
/// picked: dropping the right channel would lose everything panned to it, which
/// is the sort of fault nobody notices until a device is plugged into a mono
/// output. Summing rather than averaging can exceed full scale for content that
/// is identical in both channels, but averaging would cost 6 dB on the centered
/// majority of music, and the levels here are under the user's control anyway.
@inline(__always)
func accumulateInterleaved(_ source: UnsafePointer<Float>,
                           count: Int,
                           into destination: UnsafeMutablePointer<Float>,
                           limit: Int,
                           stride: Int = 2) {
    let outputStride = max(1, stride)
    let frames = count / 2
    let destinationFrames = limit / outputStride
    let bound = min(frames, destinationFrames)
    var frame = 0
    while frame < bound {
        if outputStride > 1 {
            destination[frame * outputStride] += source[frame * 2]
            destination[frame * outputStride + 1] += source[frame * 2 + 1]
        } else {
            destination[frame] += source[frame * 2] + source[frame * 2 + 1]
        }
        frame += 1
    }
}

/// Adds interleaved stereo frames from `source` into a deinterleaved pair of
/// destination buffers.
@inline(__always)
func accumulatePlanar(_ source: UnsafePointer<Float>,
                     frames: Int,
                     left: UnsafeMutablePointer<Float>,
                     right: UnsafeMutablePointer<Float>) {
    var frame = 0
    while frame < frames {
        left[frame] += source[frame * 2]
        right[frame] += source[frame * 2 + 1]
        frame += 1
    }
}

// MARK: - Format support

/// Whether a stream format is one this engine can actually process.
///
/// The tap side is read with `assumingMemoryBound(to: Float.self)`, and the
/// output side is mixed by `scaleInPlace`. Both silently produce garbage rather
/// than failing if handed something else, so the format is checked once at setup
/// and a mismatch refuses the tap instead of creating noise.
func isSupportedMixFormat(_ format: AudioStreamBasicDescription) -> Bool {
    guard format.mFormatID == kAudioFormatLinearPCM else { return false }
    guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return false }
    // Packed is *required*, not forbidden: it means each sample is stored in a
    // whole 32-bit container, which is what makes reading the buffer as
    // `Float` valid. Unpacked 32-bit float would be bit-packed and garbage.
    guard format.mFormatFlags & kAudioFormatFlagIsPacked != 0 else { return false }
    // Interleaving is deliberately not constrained: the mixer handles both a
    // single interleaved buffer and one buffer per channel.
    guard format.mBitsPerChannel == 32 else { return false }
    guard format.mChannelsPerFrame == 1 || format.mChannelsPerFrame == 2 else { return false }
    return true
}

// MARK: - ChannelTable

/// A fixed-capacity, lock-free table of live audio channels that a real-time
/// thread can read without retaining, releasing or locking.
///
/// The obvious approach -- handing the audio thread a Swift `[TapChannel]` --
/// is not real-time safe, because reading an array element bumps a reference
/// count, which can allocate. Instead the control queue publishes
/// `Unmanaged` pointers into a preallocated buffer and then bumps an atomic
/// count; the audio thread reads the pointers and calls `takeUnretainedValue()`,
/// which touches no refcounts. Lifetime is owned by the engine's own
/// dictionary, so the pointers stay valid for as long as they are published.
final class ChannelTable {

    /// Well above the number of apps that realistically play audio at once.
    static let capacity = 64

    private let slots: UnsafeMutablePointer<Unmanaged<AnyObject>?>
    private let countStorage: UnsafeMutablePointer<Int32>

    init() {
        slots = .allocate(capacity: ChannelTable.capacity)
        slots.initialize(repeating: nil, count: ChannelTable.capacity)
        countStorage = .allocate(capacity: 1)
        countStorage.initialize(to: 0)
    }

    deinit {
        slots.deinitialize(count: ChannelTable.capacity)
        slots.deallocate()
        countStorage.deinitialize(count: 1)
        countStorage.deallocate()
    }

    /// Control-queue side. Truncates if the table is full, which the caller logs.
    /// Publishes the count last so the audio thread never sees a half-written
    /// table.
    @discardableResult
    func publish(_ channels: [AnyObject]) -> Int {
        let writeCount = min(channels.count, ChannelTable.capacity)
        for index in 0..<writeCount {
            slots[index] = Unmanaged.passUnretained(channels[index])
        }
        // Clear slots the previous, larger set occupied. Guard the bounds: the
        // previous count may exceed what actually fits, and an inverted range
        // traps.
        let previousCount = min(Int(countStorage.pointee), ChannelTable.capacity)
        if writeCount < previousCount {
            for index in writeCount..<previousCount { slots[index] = nil }
        }
        countStorage.pointee = Int32(writeCount)
        return channels.count - writeCount
    }

    var count: Int { Int(countStorage.pointee) }

    /// Real-time safe reader. No retain, no release, no allocation.
    @inline(__always)
    func object(at index: Int) -> AnyObject? {
        slots[index]?.takeUnretainedValue()
    }

    /// Iterates the published channels without touching reference counts.
    @inline(__always)
    func forEach(_ body: (AnyObject, Int) -> Void) {
        let n = Int(countStorage.pointee)
        guard n > 0 else { return }
        var index = 0
        while index < n {
            if let object = slots[index]?.takeUnretainedValue() { body(object, index) }
            index += 1
        }
    }
}