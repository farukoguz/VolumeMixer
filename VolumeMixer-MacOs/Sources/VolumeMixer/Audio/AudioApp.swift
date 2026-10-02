import AppKit
import CoreAudio
import Foundation

/// One application that is currently producing audio.
struct AudioApp: Identifiable, Equatable {

    /// Stable identity across launches, so saved levels survive restarts.
    /// Empty for helper processes with no bundle identifier.
    let bundleID: String
    let processObjectID: AudioObjectID
    let pid: pid_t
    let displayName: String
    let icon: NSImage?

    /// Identity used for persisted settings and for talking to the engine.
    /// Bundle ID when there is one, otherwise the PID: an unidentified helper
    /// has nothing stable to key on, and its level is not worth persisting.
    var id: String { bundleID.isEmpty ? "pid-\(pid)" : bundleID }

    /// Reads the full descriptor for a process object. Returns nil if the object
    /// has already gone away, which happens routinely -- apps exit between the
    /// moment they appear in the list and the moment we interrogate them.
    static func make(objectID: AudioObjectID) -> AudioApp? {
        guard let pid = HAL.pid(of: objectID), pid > 0 else { return nil }
        let bundleID = HAL.bundleID(of: objectID) ?? ""
        let running = NSRunningApplication(processIdentifier: pid)
        let name = running?.localizedName
            ?? bundleID.split(separator: ".").last.map(String.init)
            ?? "Process \(pid)"
        return AudioApp(bundleID: bundleID,
                        processObjectID: objectID,
                        pid: pid,
                        displayName: name,
                        icon: running?.icon)
    }
}