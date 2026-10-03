import CoreAudio
import Foundation
import Testing

@testable import VolumeMixer

/// Per-app gain is the one claim that cannot be checked on a machine without
/// capture permission: there is no public output meter, and confirming it by ear
/// needs Screen & System Audio Recording. These tests drive the mixer's real
/// per-channel path with ordinary memory instead, so the arithmetic behind the
/// slider is pinned down even where the hardware cannot confirm it.
struct GainPathTests {

    private let frames = 8

    /// A ramp across both channels, so a channel swap or a stride mistake cannot
    /// hide behind symmetric audio.
    private var ramp: [Float] {
        (0..<(frames * 2)).map { Float($0) / 16 }
    }

    private func makeChannel(gain: Float, samples: [Float]) -> TapChannel {
        let channel = TapChannel(identity: "test", processKey: "test", processObjectID: 1)
        channel.gain.value = gain
        samples.withUnsafeBufferPointer { source in
            _ = channel.ring.write(source.baseAddress!, frameCount: samples.count / 2)
        }
        return channel
    }

    /// Runs one mix cycle over `channels` into a freshly zeroed interleaved
    /// stereo buffer and returns what came out.
    private func mixOnce(_ channels: [TapChannel]) -> [Float] {
        let sampleCount = frames * 2
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { scratch.deallocate() }
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { destination.deallocate() }
        destination.initialize(repeating: 0, count: sampleCount)

        for channel in channels {
            TapGainEngine.mix(channel, scratch: scratch, frames: frames,
                              sampleCount: sampleCount, destination: destination,
                              right: destination, deinterleaved: false, outputChannels: 2,
                              limit: sampleCount, peakDecay: 0.5)
        }
        return Array(UnsafeBufferPointer(start: destination, count: sampleCount))
    }

    private func expect(_ actual: [Float], toEqual expected: [Float],
                        accuracy: Float = 0.0001) {
        #expect(actual.count == expected.count, "expected \(expected.count) samples, got \(actual.count)")
        for index in 0..<min(actual.count, expected.count) {
            #expect(abs(actual[index] - expected[index]) < accuracy)
        }
    }

    @Test("unity gain passes samples through unchanged")
    func unityGain() {
        expect(mixOnce([makeChannel(gain: 1.0, samples: ramp)]), toEqual: ramp)
    }

    @Test("half gain halves every sample")
    func halfGain() {
        expect(mixOnce([makeChannel(gain: 0.5, samples: ramp)]),
               toEqual: ramp.map { $0 * 0.5 })
    }

    @Test("zero gain contributes silence")
    func mutedGain() {
        expect(mixOnce([makeChannel(gain: 0, samples: ramp)]),
               toEqual: [Float](repeating: 0, count: frames * 2))
    }

    @Test("gain above unity scales rather than clamps")
    func boostedGain() {
        // Boosting past 100% is a normal thing for a mixer to offer.
        expect(mixOnce([makeChannel(gain: 1.5, samples: ramp)]),
               toEqual: ramp.map { $0 * 1.5 })
    }

    /// The property that matters most: two apps at different levels must sum. A
    /// mixer that replaced instead of adding would pass every single-app test.
    @Test("two apps at different gains sum together")
    func twoAppsSum() {
        expect(mixOnce([
            makeChannel(gain: 1.0, samples: ramp),
            makeChannel(gain: 0.5, samples: ramp),
        ]), toEqual: ramp.map { $0 * 1.5 })
    }

    @Test("muting one app leaves the others untouched")
    func muteIsIsolated() {
        expect(mixOnce([
            makeChannel(gain: 1.0, samples: ramp),
            makeChannel(gain: 0, samples: ramp),
        ]), toEqual: ramp)
    }

    @Test("three apps sum to the arithmetic total")
    func threeAppsSum() {
        expect(mixOnce([
            makeChannel(gain: 1.0, samples: ramp),
            makeChannel(gain: 0.25, samples: ramp),
            makeChannel(gain: 0.25, samples: ramp),
        ]), toEqual: ramp.map { $0 * 1.5 })
    }

    /// The meter has to reflect what the user set, not what arrived unweighted,
    /// or the slider would look broken while the audio was actually fine.
    @Test("the meter reports the post-gain level")
    func meterIsPostGain() {
        let channel = makeChannel(gain: 0.5, samples: ramp)
        let out = mixOnce([channel])
        let peak = out.max() ?? 0
        #expect(abs(peak - channel.peak.value) < 0.0001)
    }

    @Test("the meter decays when an app goes quiet")
    func meterDecays() {
        let channel = makeChannel(gain: 1.0, samples: ramp)
        let loud = mixOnce([channel]).max() ?? 0

        // A quiet app keeps its tap open and keeps delivering frames, it just
        // delivers silence. That is the case the decay exists for.
        let silence = [Float](repeating: 0, count: frames * 2)
        _ = mixOnce([makeChannel(gain: 1.0, samples: silence)])
        channel.ring.reset()
        silence.withUnsafeBufferPointer { source in
            _ = channel.ring.write(source.baseAddress!, frameCount: frames)
        }
        _ = mixOnce([channel])

        #expect(channel.peak.value < loud,
                "meter stayed at \(channel.peak.value) instead of decaying from \(loud)")
    }

    /// Mono output: one buffer, but still two channels of source. Treating it as
    /// interleaved stereo would read half the frames and write each sample twice.
    @Test("a mono destination mixes down without doubling")
    func monoDestination() {
        let channel = makeChannel(gain: 1.0, samples: ramp)
        let sampleCount = frames * 2
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { scratch.deallocate() }
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { destination.deallocate() }
        destination.initialize(repeating: 0, count: frames)

        TapGainEngine.mix(channel, scratch: scratch, frames: frames, sampleCount: sampleCount,
                          destination: destination, right: destination, deinterleaved: false,
                          outputChannels: 1, limit: frames, peakDecay: 0.5)

        let expected = (0..<frames).map { ramp[$0 * 2] + ramp[$0 * 2 + 1] }
        expect(Array(UnsafeBufferPointer(start: destination, count: frames)),
               toEqual: expected)
    }

    /// A ring that underruns must contribute nothing rather than stale audio.
    @Test("an empty channel emits nothing")
    func emptyChannel() {
        let channel = TapChannel(identity: "test", processKey: "test", processObjectID: 1)
        channel.gain.value = 1.0
        expect(mixOnce([channel]), toEqual: [Float](repeating: 0, count: frames * 2))
    }

    /// The gain a user sees must be the gain that reaches the speakers, including
    /// for an app with several processes behind one row.
    @Test("every process of one app is scaled by that app's gain")
    func multipleProcessesShareOneLevel() {
        let channels = [
            makeChannel(gain: 0.5, samples: ramp),
            makeChannel(gain: 0.5, samples: ramp),
            makeChannel(gain: 0.5, samples: ramp),
        ]
        expect(mixOnce(channels), toEqual: ramp.map { $0 * 1.5 })
    }
}