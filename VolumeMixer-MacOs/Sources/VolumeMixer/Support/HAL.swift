import CoreAudio
import AudioToolbox
import Foundation

/// Typed wrappers over the Core Audio HAL.
///
/// Every helper here is written to be called from an IOProc: no allocation, no
/// locking, no Objective-C message sends.
enum HAL {

    // MARK: - Property access

    /// Reads a fixed-size property into caller-provided storage.
    ///
    /// Core Audio fills the buffer we hand it, so on failure the caller's
    /// existing value survives. Doing it this way (rather than through a
    /// byte array) keeps the storage correctly aligned and avoids
    /// `loadUnaligned`, which traps on non-`BitwiseCopyable` types such as
    /// `AudioStreamBasicDescription`.
    @inline(__always)
    static func read<T>(_ object: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                        into value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
    }

    static func write<T>(_ object: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                         _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var copy = value
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &copy) {
            AudioObjectSetPropertyData(object, &address, 0, nil, size, $0)
        }
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// Reads a `CFString`-valued property.
    ///
    /// Despite the `Get` in the name, Core Audio returns these +1 (the Create
    /// Rule applies), so the value is consumed as a managed reference.
    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// Reads an array-of-`AudioObjectID` property, sized first then filled.
    static func readIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBufferPointer {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    // MARK: - Process objects

    /// Every audio process object Core Audio knows about. This is a superset --
    /// it includes processes that have touched Core Audio but are not currently
    /// making sound, so it must be filtered by `isRunningOutput`.
    static func allProcessObjects() -> [AudioObjectID] {
        readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    /// True only while the process is actively rendering output audio. This is
    /// the signal that gates the mixer list.
    @inline(__always)
    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        let status = read(object, kAudioProcessPropertyIsRunningOutput, into: &running)
        return status == noErr && running == 1
    }

    static func pid(of object: AudioObjectID) -> pid_t? {
        var value: pid_t = 0
        guard read(object, kAudioProcessPropertyPID, into: &value) == noErr, value > 0 else { return nil }
        return value
    }

    static func bundleID(of object: AudioObjectID) -> String? {
        readString(object, kAudioProcessPropertyBundleID)
    }

    // MARK: - Devices

    static var defaultOutputDevice: AudioObjectID {
        var device: AudioObjectID = 0
        _ = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        return device
    }

    static var defaultSystemOutputDevice: AudioObjectID {
        var device: AudioObjectID = 0
        _ = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, into: &device)
        return device
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        readString(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioObjectID) -> String? {
        readString(device, kAudioObjectPropertyName)
    }

    /// All devices capable of output.
    static func outputDevices() -> [AudioObjectID] {
        let all = readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        // A device with no output streams can still appear in the global list
        // (aggregate devices, input-only interfaces), so filter on streams.
        return all.filter { device in
            let scope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
            return has(device, kAudioDevicePropertyStreams, scope)
                && !readIDs(device, kAudioDevicePropertyStreams, scope).isEmpty
        }
    }

    static func setDefaultOutputDevice(_ device: AudioObjectID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = device
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                       UInt32(MemoryLayout<AudioObjectID>.size), $0)
        }
    }

    /// The device's current output stream format. Sample rate here is the rate
    /// the mixer must run at.
    static func outputStreamFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription {
        streamFormat(of: device, scope: kAudioObjectPropertyScopeOutput)
    }

    /// The format a device delivers in the given scope. Read rather than assumed:
    /// the tap side has to be checked because the tap IOProc reinterprets its
    /// buffers as float, which would be noise rather than an error on a mismatch.
    static func streamFormat(of device: AudioObjectID,
                             scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        _ = read(device, kAudioDevicePropertyStreamFormat, scope, into: &format)
        return format
    }

    // MARK: - Buffer lists

    /// Walks the buffers of an `AudioBufferList`.
    ///
    /// There is no `UnsafeAudioBufferListPointer` in this SDK (the mutable
    /// variant exists, the immutable one does not), and IOBlocks hand input
    /// buffers over as `UnsafePointer`. The flexible array member is reached
    /// manually.
    ///
    /// Safe to call from a real-time thread: no allocation, no Foundation.
    @inline(__always)
    static func forEachBuffer(_ list: UnsafePointer<AudioBufferList>,
                              _ body: (UnsafeMutableRawPointer, Int) -> Void) {
        let count = Int(list.pointee.mNumberBuffers)
        guard count > 0 else { return }
        let base = UnsafeRawPointer(list).advanced(by: MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!)
        let stride = MemoryLayout<AudioBuffer>.stride
        var index = 0
        while index < count {
            let buffer = base.load(fromByteOffset: index * stride, as: AudioBuffer.self)
            if let data = buffer.mData { body(data, Int(buffer.mDataByteSize)) }
            index += 1
        }
    }

    /// Same, for the mutable list IOBlocks use for output.
    @inline(__always)
    static func forEachMutableBuffer(_ list: UnsafeMutablePointer<AudioBufferList>,
                                     _ body: (UnsafeMutableRawPointer, Int) -> Void) {
        forEachBuffer(UnsafePointer(list), body)
    }
}

extension AudioStreamBasicDescription {
    var isFloat32: Bool { mFormatID == kAudioFormatLinearPCM && (mFormatFlags & kAudioFormatFlagIsFloat) != 0 }
    var isInterleaved: Bool { (mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 }

    var formatCode: String {
        let value = mFormatID
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        return bytes.map { (b: UInt8) in (b > 32 && b < 127) ? String(UnicodeScalar(b)) : "." }.joined()
    }
}