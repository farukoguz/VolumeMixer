import Foundation
import os

/// Diagnostics. Audio faults on macOS are usually silent -- a failed HAL call
/// hands back a valid object that produces zeros, and TCC denial reports noErr
/// at every call site -- so this logs generously rather than quietly.
///
/// Messages are taken as plain `String` rather than `OSLogMessage` so callers do
/// not have to thread os-log interpolation types through every layer. None of
/// these are on the real-time path.
enum Log {

    private static let audioLogger = Logger(subsystem: "com.volumemixer.app", category: "audio")
    private static let lifecycleLogger = Logger(subsystem: "com.volumemixer.app", category: "lifecycle")

    /// Set `VM_DEBUG_LOG=1` to also write to stdout. os_log is unavailable when
    /// the app is launched from a bundle with no console attached, which makes
    /// a hung audio path very hard to diagnose.
    private static let echoesToStdout = ProcessInfo.processInfo.environment["VM_DEBUG_LOG"] == "1"

    private static func write(_ logger: Logger, _ message: String) {
        logger.log("\(message, privacy: .public)")
        if echoesToStdout { print("[log] \(message)"); fflush(stdout) }
    }

    static func audio(_ message: String) { write(audioLogger, message) }
    static func lifecycle(_ message: String) { write(lifecycleLogger, message) }

    static func error(_ message: String) {
        audioLogger.error("\(message, privacy: .public)")
        if echoesToStdout { print("[error] \(message)"); fflush(stdout) }
    }

    #if DEBUG
    static func debug(_ message: String) {
        audioLogger.debug("\(message, privacy: .public)")
        if echoesToStdout { print("[debug] \(message)"); fflush(stdout) }
    }
    #else
    static func debug(_ message: String) {}
    #endif
}

/// Renders an OSStatus as its four-character code, e.g. `'who?'`, `'!obj'`.
/// Core Audio error codes are far more legible than their integer form.
@inline(__always)
func fourcc(_ status: OSStatus) -> String {
    fourcc(UInt32(bitPattern: status))
}

/// Overload for raw FourCC values such as `AudioObjectPropertySelector`, where
/// the integer *is* the code rather than a status to be inspected.
@inline(__always)
func fourcc(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
    ]
    return bytes.map { (b: UInt8) in (b > 32 && b < 127) ? String(UnicodeScalar(b)) : "." }.joined()
}