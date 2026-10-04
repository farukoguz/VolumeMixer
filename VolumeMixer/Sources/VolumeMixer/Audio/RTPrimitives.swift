import CoreAudio
import Foundation

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

    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int

    /// Producer-owned. Padded away from `readIndex` to stay on its own line.
    private let writeStorage: UnsafeMutablePointer<Int64>
    /// Consumer-owned.
    private let readStorage: UnsafeMutablePointer<Int64>

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
    }

    deinit {
        storage.deinitialize(count: capacity * 2)
        storage.deallocate()
        writeStorage.deinitialize(count: SampleRingBuffer.cacheLine)
        writeStorage.deallocate()
        readStorage.deinitialize(count: SampleRingBuffer.cacheLine)
        readStorage.deallocate()
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

        if free < frameCount {
            // Overwrite: advance the read cursor so only the newest `capacity`
            // frames remain, then treat the whole write as fitting.
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
    /// Returns the number of frames produced.
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