import Foundation

/// Per-app levels, persisted across launches and keyed by bundle ID.
///
/// Identity is the bundle ID rather than the PID, because a PID changes every
/// time an app restarts while the bundle ID does not. A process with no bundle ID
/// is keyed by its executable path, which is stable across launches. Only the
/// last-resort PID key is dropped on save.
struct Settings: Codable {

    struct AppLevel: Codable, Equatable {
        var gain: Float
        var muted: Bool
    }

    var apps: [String: AppLevel] = [:]
    var masterVolume: Float?
    var lastDeviceUID: String?

    private static let fileName = "settings.json"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("VolumeMixer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else { return Settings() }
        let decoder = JSONDecoder()
        return (try? decoder.decode(Settings.self, from: data)) ?? Settings()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        // Atomic so a crash mid-write cannot leave a truncated settings file.
        try? data.write(to: Settings.fileURL, options: .atomic)
    }

    // MARK: - App levels

    func level(for appID: String) -> AppLevel {
        apps[appID] ?? AppLevel(gain: 1, muted: false)
    }

    mutating func setLevel(_ level: AppLevel, for appID: String) {
        // A PID fallback key is worthless on the next launch, and keeping them
        // would slowly fill the file with one dead entry per helper process that
        // ever played audio.
        if appID.hasPrefix("pid-") { return }
        // 1.0 unmuted is the default and not worth persisting.
        if abs(level.gain - 1) < 0.001 && !level.muted {
            apps.removeValue(forKey: appID)
        } else {
            apps[appID] = level
        }
    }

    mutating func resetAllApps() {
        apps.removeAll()
    }
}