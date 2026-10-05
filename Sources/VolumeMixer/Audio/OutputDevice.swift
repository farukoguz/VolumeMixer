import Foundation
import CoreAudio

/// User-level output device controls. These are ordinary Core Audio device
/// properties and need no special permission, so the master volume and device
/// picker work regardless of whether per-app gain is available.
enum SystemVolume {

    /// Master volume on the default output device, 0...1.
    ///
    /// Devices with separate volume controls per channel expose
    /// `kAudioDevicePropertyVolumeScalar` per element rather than on the main
    /// element, so element 1 is used as a fallback.
    static func masterVolume() -> Float {
        let device = HAL.defaultSystemOutputDevice
        guard device != 0 else { return 1 }
        let scope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
        guard HAL.has(device, kAudioDevicePropertyVolumeScalar, scope) else { return 1 }

        var value: Float32 = 1
        if HAL.read(device, kAudioDevicePropertyVolumeScalar, scope,
                    kAudioObjectPropertyElementMain, into: &value) == noErr {
            return value
        }
        value = 1
        if HAL.read(device, kAudioDevicePropertyVolumeScalar, scope, 1, into: &value) == noErr {
            return value
        }
        return 1
    }

    static func setMasterVolume(_ volume: Float) {
        let device = HAL.defaultSystemOutputDevice
        guard device != 0 else { return }
        let scope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
        let clamped: Float32 = max(0, min(1, volume))

        var value = clamped
        var status = HAL.write(device, kAudioDevicePropertyVolumeScalar, scope,
                               kAudioObjectPropertyElementMain, &value)
        if status != noErr {
            value = clamped
            status = HAL.write(device, kAudioDevicePropertyVolumeScalar, scope, 1, &value)
        }
        if status != noErr { Log.error("set master volume: \(fourcc(status))") }
    }

    static var isMasterMuted: Bool {
        get {
            let device = HAL.defaultSystemOutputDevice
            guard device != 0 else { return false }
            var value: UInt32 = 0
            guard HAL.read(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                           kAudioObjectPropertyElementMain, into: &value) == noErr else { return false }
            return value == 1
        }
        set {
            let device = HAL.defaultSystemOutputDevice
            guard device != 0 else { return }
            var value: UInt32 = newValue ? 1 : 0
            let status = HAL.write(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                                   kAudioObjectPropertyElementMain, &value)
            if status != noErr { Log.error("set master mute: \(fourcc(status))") }
        }
    }
}

/// An output device offered in the picker.
struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let uid: String
}

/// Watches for the default output device or its format changing, so the mixer
/// can be rebuilt at the right moment.
final class OutputDeviceMonitor {

    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "com.volumemixer.devices")
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var listeners: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock] = [:]
    private var timer: DispatchSourceTimer?
    private var lastSignature = ""

    func start() {
        addListener(kAudioHardwarePropertyDevices)
        addListener(kAudioHardwarePropertyDefaultOutputDevice)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for (selector, block) in listeners {
            var address = OutputDeviceMonitor.globalAddress(selector)
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, block)
        }
        listeners.removeAll()
        lastSignature = ""
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func addListener(_ selector: AudioObjectPropertySelector) {
        var address = OutputDeviceMonitor.globalAddress(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.poll() }
        if AudioObjectAddPropertyListenerBlock(system, &address, queue, block) == noErr {
            listeners[selector] = block
        } else {
            Log.error("device listener \(fourcc(selector)) failed")
        }
    }

    /// The device id alone is not enough: a device can change sample rate or
    /// channel layout in place, and the mixer is built around that format.
    private func poll() {
        let device = HAL.defaultOutputDevice
        let format = device != 0 ? HAL.outputStreamFormat(device) : AudioStreamBasicDescription()
        let signature = "\(device)/\(format.mSampleRate)/\(format.mChannelsPerFrame)/\(format.mFormatID)"
        guard signature != lastSignature else { return }
        let first = lastSignature.isEmpty
        lastSignature = signature

        guard !first else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// Every device that can play audio.
    static func availableOutputs() -> [OutputDevice] {
        HAL.outputDevices().compactMap { device in
            guard let uid = HAL.deviceUID(device) else { return nil }
            return OutputDevice(id: device, name: HAL.deviceName(device) ?? uid, uid: uid)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}