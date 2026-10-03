import CoreAudio
import Foundation

/// Diagnostic that measures the level of everything the system is playing, by
/// way of a global tap.
///
/// This exists because per-app gain cannot be verified any other way without
/// permission: Core Audio offers no public output meter, so the only way to ask
/// "is that slider actually doing anything" is to listen to the result. A global
/// tap is the same mechanism the engine already uses per app, and it is not
/// played back anywhere, so it cannot influence what is measured.
///
/// Temporary: remove once the gain path has been confirmed on hardware.
final class SystemAudioMeter {

    /// Most recent window's RMS. Written on the tap thread, read from the sweep.
    private let level = PeakSlot()
    /// Windows measured, so the sweep can tell "quiet" from "not running".
    private let windows = FrameCounter()

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.volumemixer.meter")

    /// Accumulator for the current window. Tap-thread only.
    private var sumOfSquares: Double = 0
    private var samplesInWindow: Int = 0
    private let windowSamples = 4800

    var isRunning: Bool { ioProc != nil }

    /// RMS of the most recently completed 100 ms window, 0...~1.
    var rms: Float { level.value }

    /// RMS in decibels, which is the only form in which a halving is legible.
    var decibels: Float {
        let value = rms
        return value > 0.000_001 ? 20 * log10(value) : -120
    }

    @discardableResult
    func start() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "VolumeMixer-SelfTest"
        description.isPrivate = true
        // Not muted: a diagnostic has to hear the system, including the audio the
        // engine is reinjecting.
        description.muteBehavior = .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateProcessTap(description, &newTapID) == noErr,
              newTapID != kAudioObjectUnknown else {
            Log.error("self-test: global tap could not be created")
            return false
        }
        tapID = newTapID

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer-SelfTest",
            kAudioAggregateDeviceUIDKey: "com.volumemixer.selftest.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary,
                                                 &newAggregateID) == noErr,
              newAggregateID != kAudioObjectUnknown else {
            Log.error("self-test: aggregate device could not be created")
            stop()
            return false
        }
        aggregateID = newAggregateID

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            self?.consume(inputData)
        }
        guard procStatus == noErr, let created = proc else {
            Log.error("self-test: IOProc could not be created")
            stop()
            return false
        }
        ioProc = created

        let startStatus = AudioDeviceStart(aggregateID, created)
        guard startStatus == noErr else {
            Log.error("self-test: meter could not be started: \(startStatus)")
            stop()
            return false
        }
        Log.lifecycle("self-test: global meter running")
        return true
    }

    func stop() {
        if let proc = ioProc, aggregateID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateID, proc)
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProc = nil
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// Tap thread. Sums squares into a fixed window and publishes the RMS when
    /// the window closes. No allocation, no locks.
    private func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        let bufferCount = Int(inputData.pointee.mNumberBuffers)
        guard bufferCount > 0 else { return }

        let base = UnsafeRawPointer(inputData)
            .advanced(by: MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!)
        let stride = MemoryLayout<AudioBuffer>.stride

        for index in 0..<min(bufferCount, 2) {
            let buffer = base.load(fromByteOffset: stride * index, as: AudioBuffer.self)
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            var position = 0
            while position < count {
                let value = Double(samples[position])
                sumOfSquares += value * value
                position += 1
                samplesInWindow += 1
                if samplesInWindow >= windowSamples {
                    let mean = sumOfSquares / Double(samplesInWindow)
                    level.value = Float(sqrt(mean))
                    sumOfSquares = 0
                    samplesInWindow = 0
                    windows.increment()
                }
            }
        }
    }
}