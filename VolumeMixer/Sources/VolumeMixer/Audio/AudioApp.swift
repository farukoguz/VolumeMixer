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

    /// The helper's own name within its app, e.g. "Brave Browser Helper (Plugin)".
    ///
    /// Kept alongside `displayName` rather than instead of it. Several helpers of
    /// one app collapse into a single row, and without this the row cannot say
    /// what the extra processes actually are.
    let roleName: String?

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

    /// Description of the app bundle a helper process belongs to.
    struct OwningApp {
        let bundleID: String
        let name: String
        let icon: NSImage?
    }

    /// Cache of resolved owning apps, keyed by the bundle path.
    ///
    /// A browser spawns helpers continuously and every one of them resolves to the
    /// same handful of bundles, so re-reading each bundle's metadata on every
    /// poll would be wasted work on a background thread that also has to stay
    /// responsive. Bounded because bundles can come and go as apps are installed.
    private static var ownerCache: [String: OwningApp?] = [:]
    private static let ownerCacheLimit = 64

    /// The outermost `.app` bundle containing a process's executable.
    ///
    /// Outermost, not innermost: a helper's own bundle is
    /// `.../Helpers/Brave Browser Helper.app`, which would name the helper again.
    /// The bundle the user installed is the one that encloses it.
    static func owningAppPath(ofExecutable path: String) -> String? {
        var best: String?
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            if component.hasSuffix(".app") {
                // First match wins, not last.
                //
                // A helper nests its own bundle inside the app's framework
                // directory, so the path contains several `.app` components:
                //   /Applications/Brave Browser.app/.../Helpers/Brave Browser Helper.app/...
                // The outermost is the app the user installed. Taking the last
                // match instead returns the helper's own bundle, which is the bug
                // being fixed.
                if best == nil { best = current }
            }
        }
        return best
    }

    /// Resolves the app that owns a process, or nil if it is not inside one.
    static func owningApp(ofExecutable path: String) -> OwningApp? {
        guard let bundlePath = owningAppPath(ofExecutable: path) else { return nil }

        if let cached = ownerCache[bundlePath] { return cached }
        let url = URL(fileURLWithPath: bundlePath)
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        // `CFBundleDisplayName` is the user-visible name and is what Spotlight
        // shows; `NSWorkspace` supplies an icon for the bundle itself, which is
        // the real app icon rather than a generic executable glyph.
        let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        let resolved = OwningApp(bundleID: bundleID, name: name, icon: icon)

        if ownerCache.count >= ownerCacheLimit { ownerCache.removeAll() }
        ownerCache[bundlePath] = resolved
        return resolved
    }

    /// "Brave Browser Helper (Plugin)" and "Google Chrome Helper (Renderer)" read
    /// better as "Brave Browser Helper (Plugin)" -- but the bare executable names
    /// some helpers ship, like "Helper" or "Chrome Helper", add nothing, so those
    /// are dropped rather than shown.
    static func cleanedHelperName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed != "Helper", trimmed != "helper" else { return trimmed }
        return trimmed
    }

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

        // Resolve the app that owns this process before falling back to anything
        // derived from the process itself.
        //
        // A browser's audio is produced by its helper processes, not by the app
        // bundle, and those helpers are the worst possible thing to name directly:
        // LaunchServices knows nothing about them (`localizedName` is nil) and
        // their bundle IDs all end in `.helper`, so the last dot-component -- the
        // only remaining fallback -- is the literal string "helper". Every
        // browser's audio therefore appeared as a row reading "helper", with no
        // icon and nothing to tell Spotify from Chrome from Brave.
        //
        // The owning app is still unambiguous in the executable path:
        //   /Applications/Brave Browser.app/Contents/.../Helpers/Brave Browser Helper.app/...
        // so the outermost `.app` component names the app the user recognises.
        let owner = executablePath.isEmpty
            ? nil
            : Self.owningApp(ofExecutable: executablePath)

        var name: String = owner?.name ?? running?.localizedName ?? ""
        if name.isEmpty {
            if let executableName {
                name = Self.cleanedHelperName(executableName)
            } else if let lastComponent = bundleID.split(separator: ".").last {
                name = String(lastComponent)
            } else {
                name = "Process \(pid)"
            }
        }

        // Only helpers get a role. For the app itself it would just be the name
        // again.
        let isHelper = owner != nil && owner?.bundleID != bundleID
        let roleName: String? = isHelper
            ? (executableName.map(Self.cleanedHelperName) ?? nil)
            : nil

        return AudioApp(bundleID: bundleID,
                        executablePath: executablePath,
                        processObjectID: objectID,
                        pid: pid,
                        displayName: name,
                        icon: owner?.icon ?? running?.icon,
                        roleName: roleName)
    }
}