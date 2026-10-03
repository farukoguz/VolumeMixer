import AppKit
import CoreAudio
import Foundation

/// One application that is currently producing audio.
struct AudioApp: Identifiable, Equatable {

    /// Stable identity across launches, so saved levels survive restarts.
    /// Empty for helper processes with no bundle identifier.
    let bundleID: String
    /// Absolute executable path, e.g. `/usr/bin/afplay`. Unlike a PID this is
    /// the same on the next launch, so it is what identifies a command-line
    /// player. Empty only if the path cannot be read at all.
    let executablePath: String
    let processObjectID: AudioObjectID
    let pid: pid_t
    let displayName: String
    let icon: NSImage?

    /// Identity used for persisted settings and for talking to the engine.
    ///
    /// Bundle ID first, then executable path, then the PID. The order matters:
    /// two instances of the same binary share a path, so the PID is what
    /// separates them, but a PID-keyed level is worthless on the next launch.
    /// `pid-` keys are therefore the only ones Settings refuses to save.
    var id: String {
        if !bundleID.isEmpty { return bundleID }
        if !executablePath.isEmpty { return "path-\(executablePath)" }
        return Self.volatileIDPrefix + "\(pid)"
    }

    /// Marks the one identity that is not worth persisting, because it dies with
    /// the process. Shared with `Settings`, which only ever holds the string.
    static let volatileIDPrefix = "pid-"

    /// Whether this identity is worth persisting across launches.
    var hasStableIdentity: Bool { !id.hasPrefix(Self.volatileIDPrefix) }

    /// Uniquely identifies *this process*, unlike `id` which identifies the app.
    ///
    /// Needed because a tap reads one process object and mutes only that process.
    /// Keying channels by `id` alone would leave a second instance of the same app
    /// untapped: playing at full volume, unaffected by the slider, while its
    /// sibling was muted.
    var processKey: String { "\(id)#\(pid)" }

    /// Reads the full descriptor for a process object. Returns nil if the object
    /// has already gone away, which happens routinely -- apps exit between the
    /// moment they appear in the list and the moment we interrogate them.
    static func make(objectID: AudioObjectID) -> AudioApp? {
        guard let pid = HAL.pid(of: objectID), pid > 0 else { return nil }
        let bundleID = HAL.bundleID(of: objectID) ?? ""
        let executablePath = HAL.executablePath(of: objectID) ?? ""
        let running = NSRunningApplication(processIdentifier: pid)
        // A command-line player has no LaunchServices name at all, so the
        // executable's last component is what makes it "afplay" instead of
        // "Process 95736".
        let executableName = executablePath.split(separator: "/").last.map(String.init)
        let name = running?.localizedName
            ?? bundleID.split(separator: ".").last.map(String.init)
            ?? executableName
            ?? "Process \(pid)"
        return AudioApp(bundleID: bundleID,
                        executablePath: executablePath,
                        processObjectID: objectID,
                        pid: pid,
                        displayName: name,
                        icon: running?.icon)
    }
}