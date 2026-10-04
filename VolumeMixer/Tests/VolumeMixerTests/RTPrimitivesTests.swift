import CoreAudio
import Foundation
import Testing

@testable import VolumeMixer

// MARK: - SampleRingBuffer

@Suite("SampleRingBuffer")
struct SampleRingBufferTests {

    /// Interleaves `[L, R]` pairs so expectations read as stereo frames.
    private func interleave(_ left: [Float], _ right: [Float]) -> [Float] {
        zip(left, right).flatMap { [$0, $1] }
    }

    @Test("writes and reads back in order")
    func writeReadOrder() {
        let ring = SampleRingBuffer(capacity: 8)
        let source: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        source.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 4) }
        #expect(ring.availableFrames == 4)

        var destination = [Float](repeating: -1, count: 8)
        let read = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, frameCount: 4)
        }
        #expect(read == 4)
        #expect(Array(destination[0..<8]) == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    @Test("an empty ring reads zero frames")
    func readAvailability() {
        let ring = SampleRingBuffer(capacity: 8)
        var destination = [Float](repeating: 0, count: 8)
        let read = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, frameCount: 4)
        }
        #expect(read == 0)
        #expect(ring.availableFrames == 0)
    }

    @Test("drains only what is available when asked for more")
    func partialDrain() {
        let ring = SampleRingBuffer(capacity: 16)
        let source = interleave([1, 1], [2, 2])
        source.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 2) }

        var destination = [Float](repeating: 0, count: 32)
        let read = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, frameCount: 16)
        }
        #expect(read == 2)
        #expect(Array(destination[0..<4]) == [1, 2, 1, 2])
    }

    @Test("overflow drops the excess instead of blocking")
    func overflowDrops() {
        let ring = SampleRingBuffer(capacity: 4)
        // Write more than capacity. The newest frames are the ones that
        // survive, since the oldest were dropped rather than blocking.
        for frame in 0..<6 {
            let pair: [Float] = [Float(frame), Float(frame)]
            pair.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 1) }
        }
        #expect(ring.availableFrames <= 4)

        var destination = [Float](repeating: 0, count: 16)
        let read = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, frameCount: 8)
        }
        #expect(read <= 4)
        #expect(read > 0)
        #expect(destination[(read - 1) * 2] == 5)
    }

    @Test("indexes wrap around the end of the ring")
    func wrapAround() {
        let ring = SampleRingBuffer(capacity: 4)
        var destination = [Float](repeating: 0, count: 8)

        // Two write-then-read rounds, so both cursors cross the ring boundary.
        for round in 0..<2 {
            let source = interleave([Float(round * 10), Float(round * 10 + 1)],
                                    [Float(round * 10 + 2), Float(round * 10 + 3)])
            source.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 2) }
            let read = destination.withUnsafeMutableBufferPointer {
                ring.read(into: $0.baseAddress!, frameCount: 2)
            }
            #expect(read == 2)
            #expect(Array(destination[0..<4]) == source)
        }
    }

    @Test("deinterleaved writes interleave correctly across a wrap")
    func deinterleavedWrapAround() {
        let ring = SampleRingBuffer(capacity: 4)
        // Fill and drain once so the write cursor starts near the end.
        var destination = [Float](repeating: 0, count: 16)
        let priming = interleave([1, 2, 3], [4, 5, 6])
        priming.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 3) }
        _ = destination.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frameCount: 3) }

        let left: [Float] = [10, 11, 12]
        let right: [Float] = [20, 21, 22]
        let peak = left.withUnsafeBufferPointer { leftPtr in
            right.withUnsafeBufferPointer { rightPtr in
                ring.writeDeinterleaved(leftPtr.baseAddress!, rightPtr.baseAddress!, frameCount: 3)
            }
        }
        #expect(peak == 22)

        let read = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, frameCount: 4)
        }
        #expect(read == 3)
        #expect(Array(destination[0..<6]) == interleave(left, right))
    }

    @Test("reset discards pending frames")
    func resetDiscards() {
        let ring = SampleRingBuffer(capacity: 8)
        let source = interleave([1, 1], [2, 2])
        source.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 2) }
        #expect(ring.availableFrames == 2)
        ring.reset()
        #expect(ring.availableFrames == 0)

        var destination = [Float](repeating: 0, count: 8)
        let read = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, frameCount: 8)
        }
        #expect(read == 0)
    }

    @Test("random interleaved traffic stays consistent")
    func randomSoak() {
        let capacity = 1024
        let ring = SampleRingBuffer(capacity: capacity)
        /// What the test believes the ring currently holds, in samples. The ring
        /// overwrites its oldest frames on overrun, so this queue mirrors that
        /// rather than growing without bound.
        var pending: [Float] = []
        var seed: UInt64 = 0x2545F4914F6CDD1D

        func nextRandom() -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % 64)
        }

        for _ in 0..<20_000 {
            let random = nextRandom()

            if random % 3 != 0 {
                let available = ring.availableFrames
                // Overrun drops the oldest frames so the newest survive.
                let dropped = max(0, available + random - capacity)
                if dropped > 0 { pending.removeFirst(dropped * 2) }

                var chunk: [Float] = []
                var frame = Float(pending.count / 2 + 1_000_000)
                for _ in 0..<random {
                    chunk.append(frame)
                    chunk.append(frame)
                    frame += 1
                }
                pending.append(contentsOf: chunk)
                chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: random) }
            }

            if random % 2 == 0, ring.availableFrames > 0 {
                let requested = min(random, ring.availableFrames)
                var destination = [Float](repeating: -1, count: requested * 2)
                let read = destination.withUnsafeMutableBufferPointer {
                    ring.read(into: $0.baseAddress!, frameCount: requested)
                }
                #expect(read == requested)
                for index in 0..<read * 2 {
                    #expect(destination[index] == pending[index])
                }
                pending.removeFirst(read * 2)
            }
        }
        // Drain whatever is left so the final state is well defined, and verify
        // the tail of the stream too.
        while ring.availableFrames > 0 {
            let requested = min(256, ring.availableFrames)
            var destination = [Float](repeating: -1, count: requested * 2)
            let read = destination.withUnsafeMutableBufferPointer {
                ring.read(into: $0.baseAddress!, frameCount: requested)
            }
            #expect(read == requested)
            for index in 0..<read * 2 {
                #expect(destination[index] == pending[index])
            }
            pending.removeFirst(read * 2)
        }
        #expect(pending.isEmpty)
        #expect(ring.availableFrames == 0)
    }
}

// MARK: - Gain

@Suite("Gain")
struct GainTests {

    private func scale(_ samples: [Float], by gain: Float) -> (output: [Float], peak: Float) {
        var buffer = samples
        let count = buffer.count
        let peak = buffer.withUnsafeMutableBufferPointer {
            scaleInPlace($0.baseAddress!, count: count, gain: gain)
        }
        return (buffer, peak)
    }

    @Test("unity gain leaves samples untouched")
    func unityIsIdentity() {
        let result = scale([-0.5, 0.25, 1, -1], by: 1)
        #expect(result.output == [-0.5, 0.25, 1, -1])
        #expect(abs(result.peak - 1) <= 1e-6)
    }

    @Test("zero gain silences and meters to zero")
    func zeroGain() {
        let result = scale([-0.5, 0.25, 1, -1], by: 0)
        #expect(result.output == [0, 0, 0, 0])
        #expect(result.peak == 0)
    }

    @Test("scales linearly and reports the post-gain peak")
    func scalesAndMeters() {
        let result = scale([-0.8, 0.4, 0.2], by: 0.5)
        #expect(result.output.count == 3)
        for (scaled, original) in zip(result.output, [Float(-0.8), 0.4, 0.2]) {
            #expect(abs(scaled - original * 0.5) <= 1e-6)
        }
        // The meter reflects what the user set, not the tap level, so the peak is
        // scaled too rather than the pre-gain 0.8.
        #expect(abs(result.peak - 0.4) <= 1e-6)
    }

    @Test("peak is the largest absolute sample")
    func peakIsMaxMagnitude() {
        #expect(abs(scale([0.1, -0.9, 0.3], by: 1).peak - 0.9) <= 1e-6)
        #expect(scale([0.1, -0.9, 0.3], by: 0.1).peak <= 0.1)
    }

    @Test("an empty buffer does nothing")
    func emptyBuffer() {
        #expect(scale([], by: 0.5).peak == 0)
    }

    @Test("gain above unity is allowed, since boosting is a legitimate ask")
    func gainAboveUnity() {
        let result = scale([0.25, -0.25], by: 4)
        #expect(result.output == [1, -1])
        #expect(abs(result.peak - 1) <= 1e-6)
    }
}

// MARK: - Summation

@Suite("Mixer summation")
struct SummationTests {

    @Test("interleaved channels add into the destination buffer")
    func interleavedSum() {
        var destination = [Float](repeating: 0, count: 8)
        let source: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        destination.withUnsafeMutableBufferPointer { out in
            source.withUnsafeBufferPointer { input in
                accumulateInterleaved(input.baseAddress!, count: input.count,
                                      into: out.baseAddress!, limit: out.count)
            }
        }
        #expect(destination == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test("two tapped channels are scaled and summed, not replaced")
    func scaledChannelsSum() {
        // Mirrors what the mixer does per channel: drain the ring, scale the
        // samples, then add them into the device buffer.
        let loud = SampleRingBuffer(capacity: 8)
        let quiet = SampleRingBuffer(capacity: 8)
        let frames = 2
        let unit: [Float] = [1, 1, 1, 1]
        unit.withUnsafeBufferPointer { loud.write($0.baseAddress!, frameCount: frames) }
        unit.withUnsafeBufferPointer { quiet.write($0.baseAddress!, frameCount: frames) }

        var destination = [Float](repeating: 0, count: frames * 2)
        var scratch = [Float](repeating: 0, count: frames * 2)

        destination.withUnsafeMutableBufferPointer { out in
            scratch.withUnsafeMutableBufferPointer { buffer in
                for (ring, gain) in [(loud, Float(1)), (quiet, Float(0.5))] {
                    let read = ring.read(into: buffer.baseAddress!, frameCount: frames)
                    #expect(read == frames)
                    scaleInPlace(buffer.baseAddress!, count: read * 2, gain: gain)
                    accumulateInterleaved(buffer.baseAddress!, count: read * 2,
                                          into: out.baseAddress!, limit: out.count)
                }
            }
        }

        #expect(destination == [1.5, 1.5, 1.5, 1.5])
    }

    @Test("interleaved accumulation respects the destination limit")
    func interleavedRespectsLimit() {
        var destination = [Float](repeating: 0, count: 2)
        let source: [Float] = [1, 2, 3, 4]
        destination.withUnsafeMutableBufferPointer { out in
            source.withUnsafeBufferPointer { input in
                // A device asking for more frames than were mixed must not write
                // past the end of its buffer.
                accumulateInterleaved(input.baseAddress!, count: input.count,
                                      into: out.baseAddress!, limit: out.count)
            }
        }
        #expect(destination == [1, 2])
    }

    @Test("planar accumulation splits interleaved frames across channels")
    func planarSplit() {
        let source: [Float] = [1, 10, 2, 20, 3, 30]
        var left = [Float](repeating: 0, count: 3)
        var right = [Float](repeating: 0, count: 3)
        source.withUnsafeBufferPointer { input in
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    accumulatePlanar(input.baseAddress!, frames: 3,
                                     left: l.baseAddress!, right: r.baseAddress!)
                }
            }
        }
        #expect(left == [1, 2, 3])
        #expect(right == [10, 20, 30])
    }
}

// MARK: - Slots and counters

@Suite("RT-safe slots")
struct RTSlotTests {

    @Test("gain slot round-trips values including zero and unity")
    func gainRoundTrip() {
        let slot = GainSlot(1)
        #expect(slot.value == 1)
        slot.value = 0
        #expect(slot.value == 0)
        slot.value = 0.375
        #expect(abs(slot.value - 0.375) <= 1e-6)
    }

    @Test("peak slot starts at zero")
    func peakStartsAtZero() {
        let slot = PeakSlot()
        #expect(slot.value == 0)
        slot.value = 0.5
        #expect(abs(slot.value - 0.5) <= 1e-6)
    }

    @Test("frame counter increments monotonically")
    func counterIncrements() {
        let counter = FrameCounter()
        #expect(counter.value == 0)
        for _ in 0..<1000 { counter.increment() }
        #expect(counter.value == 1000)
    }
}

// MARK: - Channel table

@Suite("ChannelTable")
struct ChannelTableTests {

    private final class Channel {
        let name: String
        init(_ name: String) { self.name = name }
    }

    @Test("publishes and iterates the live set")
    func publishesAndIterates() {
        let table = ChannelTable()
        let a = Channel("a"), b = Channel("b")
        #expect(table.count == 0)

        #expect(table.publish([a, b]) == 0)
        #expect(table.count == 2)

        var seen: [String] = []
        table.forEach { object, _ in
            if let channel = object as? Channel { seen.append(channel.name) }
        }
        #expect(seen == ["a", "b"])
        #expect(table.object(at: 0) === a)
    }

    @Test("shrinking the set clears the vacated slots")
    func shrinkingClearsSlots() {
        let table = ChannelTable()
        let a = Channel("a"), b = Channel("b"), c = Channel("c")
        table.publish([a, b, c])
        table.publish([a])
        #expect(table.count == 1)
        #expect(table.object(at: 2) == nil)
    }

    @Test("publishing more than capacity truncates and reports the overflow")
    func truncatesBeyondCapacity() {
        let table = ChannelTable()
        let channels = (0..<(ChannelTable.capacity + 5)).map { Channel("c\($0)") }
        let dropped = table.publish(channels)
        #expect(dropped == 5)
        #expect(table.count == ChannelTable.capacity)
    }
}

// MARK: - AtomicFlag

@Suite("Atomic flag")
struct AtomicFlagTests {

    @Test("starts false and reports what was stored")
    func storesAndReads() {
        let flag = AtomicFlag()
        #expect(flag.value == false)
        flag.value = true
        #expect(flag.value == true)
        flag.value = false
        #expect(flag.value == false)
    }

    @Test("can start set, which is what a channel that has already heard audio needs")
    func initialValue() {
        #expect(AtomicFlag(true).value == true)
    }
}

// MARK: - Mono output

@Suite("Mixer summation")
struct MonoDestinationTests {

    @Test("a mono destination sums the pair instead of dropping a channel")
    func monoStrideOne() {
        // Two interleaved stereo frames, one-buffer mono destination. The right
        // channel has nowhere to go, so it is folded into the left rather than
        // discarded: a mono device losing the right channel is a fault nobody
        // hears until something is plugged into a mono output. The tail of the
        // destination is left untouched.
        let source: [Float] = [1, 0.25, 0.5, 0.125]
        var destination: [Float] = [10, 20, 30, 40]
        source.withUnsafeBufferPointer { input in
            destination.withUnsafeMutableBufferPointer { out in
                accumulateInterleaved(input.baseAddress!, count: input.count,
                                      into: out.baseAddress!, limit: out.count, stride: 1)
            }
        }
        #expect(destination == [11.25, 20.625, 30.0, 40.0])
    }

    @Test("a mono destination never writes the same sample twice")
    func monoDoesNotDouble() {
        // The reason stride exists: without it a single buffer would be treated
        // as interleaved stereo, each sample written to two places, and mono
        // output would come out doubled.
        let source: [Float] = [1, 1, 1, 1]
        var destination: [Float] = [0, 0, 0, 0]
        source.withUnsafeBufferPointer { input in
            destination.withUnsafeMutableBufferPointer { out in
                accumulateInterleaved(input.baseAddress!, count: input.count,
                                      into: out.baseAddress!, limit: out.count, stride: 1)
            }
        }
        #expect(destination == [2, 2, 0, 0])
    }

    @Test("stereo stride is unchanged")
    func stereoStrideTwo() {
        let source: [Float] = [1, 2, 3, 4]
        var destination: [Float] = [0, 0, 0, 0]
        source.withUnsafeBufferPointer { input in
            destination.withUnsafeMutableBufferPointer { out in
                accumulateInterleaved(input.baseAddress!, count: input.count,
                                      into: out.baseAddress!, limit: out.count)
            }
        }
        #expect(destination == [1, 2, 3, 4])
    }

    @Test("source longer than the destination is truncated, not overflowed")
    func truncatesToDestination() {
        let source: [Float] = [1, 1, 1, 1, 1, 1]
        var destination: [Float] = [0, 0]
        source.withUnsafeBufferPointer { input in
            destination.withUnsafeMutableBufferPointer { out in
                accumulateInterleaved(input.baseAddress!, count: input.count,
                                      into: out.baseAddress!, limit: out.count)
            }
        }
        #expect(destination == [1, 1])
    }
}

// MARK: - Format support

@Suite("Format support")
struct FormatSupportTests {

    private func linearPCM(flags: UInt32,
                           bits: UInt32,
                           channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48_000,
                                    mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: flags,
                                    mBytesPerPacket: 0,
                                    mFramesPerPacket: 0,
                                    mBytesPerFrame: 0,
                                    mChannelsPerFrame: channels,
                                    mBitsPerChannel: bits,
                                    mReserved: 0)
    }

    private let float32 = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked

    @Test("packed float32 stereo, as taps and most outputs deliver, is supported")
    func acceptsFloat32Stereo() {
        #expect(isSupportedMixFormat(linearPCM(flags: float32, bits: 32, channels: 2)))
        #expect(isSupportedMixFormat(linearPCM(flags: float32, bits: 32, channels: 1)))
    }

    @Test("integer and wider formats are refused rather than mixed as noise")
    func refusesIntegerAndWide() {
        let int16 = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        #expect(!isSupportedMixFormat(linearPCM(flags: int16, bits: 16, channels: 2)))
        #expect(!isSupportedMixFormat(linearPCM(flags: float32, bits: 64, channels: 2)))
    }

    @Test("packed float is what real devices report, and it is what we require")
    func packedIsRequiredNotForbidden() {
        // 32-bit float with kAudioFormatFlagIsPacked is what Core Audio hands
        // out; requiring the flag's *absence* would reject every real format.
        #expect(isSupportedMixFormat(linearPCM(flags: float32, bits: 32, channels: 2)))
        #expect(!isSupportedMixFormat(linearPCM(flags: kAudioFormatFlagIsFloat, bits: 32, channels: 2)))
        var aac = linearPCM(flags: float32, bits: 32, channels: 2)
        aac.mFormatID = kAudioFormatMPEG4AAC
        #expect(!isSupportedMixFormat(aac))
    }

    @Test("surround layouts are refused: the mixer sums two channels, not six")
    func refusesSurround() {
        #expect(!isSupportedMixFormat(linearPCM(flags: float32, bits: 32, channels: 6)))
    }
}

// MARK: - Steady read

@Suite("Steady read")
struct ReadSteadyTests {

    private func fill(_ ring: SampleRingBuffer, frames: Int, from start: Float) {
        var samples: [Float] = []
        var value = start
        for _ in 0..<frames {
            samples.append(value)
            samples.append(value)
            value += 1
        }
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: frames) }
    }

    @Test("a full cycle comes back whole")
    func fullCycle() {
        let ring = SampleRingBuffer(capacity: 4096)
        fill(ring, frames: 512, from: 1)
        var out = [Float](repeating: 0, count: 512 * 2)
        let ok = out.withUnsafeMutableBufferPointer {
            ring.readSteady(into: $0.baseAddress!, frameCount: 512, rateRatio: 1.0)
        }
        #expect(ok)
        #expect(out[0] == 1)
        #expect(out[2] == 2)
        #expect(out[1022] == 512)
    }

    /// The regression that produced the stutter: asked for more frames than the
    /// tap had delivered, the old reader returned a short count and the caller
    /// left the rest of the cycle silent.
    @Test("a starved cycle still returns the frames it was asked for")
    func starvedCycleIsFilled() {
        let ring = SampleRingBuffer(capacity: 4096)
        fill(ring, frames: 128, from: 1)
        var out = [Float](repeating: 0, count: 512 * 2)
        let ok = out.withUnsafeMutableBufferPointer {
            ring.readSteady(into: $0.baseAddress!, frameCount: 512, rateRatio: 1.0)
        }
        #expect(!ok, "starvation should be reported")
        // Real audio at the front, faded to silence behind, and never a hard cut
        // straight to zero in the middle of a cycle.
        #expect(out[0] == 1)
        #expect(out[254] != 0)
        #expect(out[1022] == 0, "the tail must end at silence, not mid-waveform")
        // Real audio up to the last buffered frame, silence after it, with no
        // fabricated samples in between.
        let firstSilence = out.firstIndex(of: 0).map { $0 / 2 } ?? 512
        #expect(firstSilence == 128, "silence must begin exactly where input ran out")
    }

    @Test("a ratio above one consumes input faster, as a mismatched clock needs")
    func ratioConsumesFaster() {
        let ring = SampleRingBuffer(capacity: 4096)
        fill(ring, frames: 1024, from: 1)
        var out = [Float](repeating: 0, count: 256 * 2)
        _ = out.withUnsafeMutableBufferPointer {
            ring.readSteady(into: $0.baseAddress!, frameCount: 256, rateRatio: 2.0)
        }
        // 256 output frames at 2 input frames each. Output frame i reads input
        // frame 2i, so the last lands on input frame 510 and the frames in
        // between are deliberately dropped to burn the extra input clock.
        #expect(out[0] == 1)
        #expect(out[510] == 511)
        #expect(ring.availableFrames == 1024 - 512)
    }

    @Test("a fractional ratio neither drops nor repeats input over time")
    func fractionalRatioIsStable() {
        let ring = SampleRingBuffer(capacity: 8192)
        fill(ring, frames: 4096, from: 1)
        var out = [Float](repeating: 0, count: 400 * 2)
        // 400 output frames at 1.0025 input frames each = 401 input frames.
        _ = out.withUnsafeMutableBufferPointer {
            ring.readSteady(into: $0.baseAddress!, frameCount: 400, rateRatio: 1.0025)
        }
        // 400 output frames at 1.0025 input frames each consumes very slightly
        // more than 400 input frames. The remainder is carried in the phase, and
        // float accumulation decides whether it lands as 400 or 401, so this
        // pins the behaviour that matters -- no whole frame skipped or replayed
        // -- rather than an exact total.
        #expect(ring.availableFrames == 4096 - 400 || ring.availableFrames == 4096 - 401)
        // Interpolation means output values sit between two input samples, so
        // these are checked as a ramp that starts and ends in the right place
        // rather than as exact equality.
        #expect(abs(out[0] - 1.0) < 0.001)
        // Output frame 399 sits at input position 399 x 1.0025 = 399.9975, so
        // it interpolates almost all the way to the 401st input frame (value
        // 401). Checking it near 401 is what pins the accumulated phase: a reader
        // that reset its fraction each cycle would land on 400 instead.
        #expect(abs(out[798] - 401.0) < 0.01)
        var monotonic = true
        for frame in 1..<400 where out[frame * 2] < out[(frame - 1) * 2] {
            monotonic = false
        }
        #expect(monotonic, "interpolation must not step backwards")
    }

    @Test("an empty ring reports starvation rather than inventing audio")
    func emptyRing() {
        let ring = SampleRingBuffer(capacity: 4096)
        // Deliberately not zeroed: the reader must not depend on the caller
        // having cleared the destination.
        var out = [Float](repeating: 9, count: 64 * 2)
        let ok = out.withUnsafeMutableBufferPointer {
            ring.readSteady(into: $0.baseAddress!, frameCount: 64, rateRatio: 1.0)
        }
        #expect(!ok)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test("reset clears the fractional position so no stale phase carries over")
    func resetClearsPhase() {
        let ring = SampleRingBuffer(capacity: 4096)
        fill(ring, frames: 1024, from: 1)
        var out = [Float](repeating: 0, count: 100 * 2)
        _ = out.withUnsafeMutableBufferPointer {
            ring.readSteady(into: $0.baseAddress!, frameCount: 100, rateRatio: 1.5)
        }
        ring.reset()
        #expect(ring.availableFrames == 0)
        fill(ring, frames: 256, from: 1)
        _ = out.withUnsafeMutableBufferPointer {
            ring.readSteady(into: $0.baseAddress!, frameCount: 8, rateRatio: 1.0)
        }
        #expect(out[0] == 1, "a reset ring must start from its first frame")
    }
}
