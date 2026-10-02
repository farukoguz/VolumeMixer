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