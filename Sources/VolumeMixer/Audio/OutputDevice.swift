import Foundation
import AudioToolbox
import CoreAudio

/// User-level output device controls. These are ordinary Core Audio device
/// properties and need no special permission, so the master volume and device
/// picker work regardless of whether per-app gain is available.
///
/// Everything here acts on the default *output* device, the one the user is
/// listening to. The default *system* output device is where alerts play, and
/// it can be a different device: with AirPods selected and sound effects left on
/// the built-in speakers, using it made the slider change the speakers instead.
enum SystemVolume {

    private static let scope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)

    /// Whether the output device has a volume control at all. Many HDMI and
    /// DisplayPort monitors do not.
    static var hasVolumeControl: Bool {
        let device = HAL.defaultOutputDevice
        return device != 0
            && HAL.isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
    }

    /// Master volume on the default output device, 0...1.
    ///
    /// The virtual main volume rather than `kAudioDevicePropertyVolumeScalar`:
    /// devices such as AirPods only have per-channel controls, and writing one
    /// channel's scalar changed the left side alone. The virtual control drives
    /// whichever controls the device has and keeps the balance between them.
    static func masterVolume() -> Float {
        let device = HAL.defaultOutputDevice
        guard device != 0 else { return 1 }
        var value: Float32 = 1
        guard HAL.read(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope,
                       into: &value) == noErr else { return 1 }
        return max(0, min(1, value))
    }

    static func setMasterVolume(_ volume: Float) {
        let device = HAL.defaultOutputDevice
        guard device != 0 else { return }
        var value: Float32 = max(0, min(1, volume))
        let status = HAL.write(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope,
                               kAudioObjectPropertyElementMain, &value)
        if status != noErr { Log.error("set master volume: \(fourcc(status))") }
    }

    static var isMasterMuted: Bool {
        get {
            let device = HAL.defaultOutputDevice
            guard device != 0 else { return false }
            var value: UInt32 = 0
            guard HAL.read(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                           kAudioObjectPropertyElementMain, into: &value) == noErr else { return false }
            return value == 1
        }
        set {
            let device = HAL.defaultOutputDevice
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

    /// The default output device or its format changed. Delivered on main.
    var onChange: (() -> Void)?
    /// A device was added or removed, e.g. headphones connected without becoming
    /// the default. Delivered on main. Kept apart from `onChange` so the mixer is
    /// not rebuilt for a device nothing is playing through.
    var onDevicesChange: (() -> Void)?

    private let queue = DispatchQueue(label: "com.volumemixer.devices")
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var listeners: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock] = [:]
    private var timer: DispatchSourceTimer?
    private var lastSignature = ""

    /// State is owned by `queue`, so the first poll cannot race the timer.
    func start() {
        queue.async { [self] in
            addListener(kAudioHardwarePropertyDevices)
            addListener(kAudioHardwarePropertyDefaultOutputDevice)

            // Fires immediately, so this is also the initial poll.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2.0)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            for (selector, block) in listeners {
                var address = OutputDeviceMonitor.globalAddress(selector)
                AudioObjectRemovePropertyListenerBlock(system, &address, queue, block)
            }
            listeners.removeAll()
            lastSignature = ""
        }
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
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            if selector == kAudioHardwarePropertyDevices {
                DispatchQueue.main.async { [weak self] in self?.onDevicesChange?() }
            }
            self?.poll()
        }
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