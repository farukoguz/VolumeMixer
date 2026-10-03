import Foundation
import Testing

@testable import VolumeMixer

// MARK: - Identity

@Suite("App identity")
struct AudioAppIdentityTests {

    private func app(bundleID: String, executablePath: String, pid: pid_t = 42) -> AudioApp {
        AudioApp(bundleID: bundleID,
                 executablePath: executablePath,
                 processObjectID: 1,
                 pid: pid,
                 displayName: "Test",
                 icon: nil)
    }

    @Test("a bundled app is keyed by bundle ID, which survives relaunch")
    func bundleIDWins() {
        let safari = app(bundleID: "com.apple.Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")
        #expect(safari.id == "com.apple.Safari")
        #expect(safari.hasStableIdentity)
    }

    @Test("a command-line player is keyed by its path, so afplay keeps its level")
    func pathFallback() {
        let afplay = app(bundleID: "", executablePath: "/usr/bin/afplay", pid: 95736)
        #expect(afplay.id == "path-/usr/bin/afplay")
        #expect(afplay.hasStableIdentity)
        // Two instances share a path, so only the PID would separate them. The
        // stable key is still the better trade: a dead key is worse than a
        // shared one.
        let second = app(bundleID: "", executablePath: "/usr/bin/afplay", pid: 95737)
        #expect(afplay.id == second.id)
    }

    @Test("the PID is a last resort and is reported as not worth saving")
    func pidLastResort() {
        let unknown = app(bundleID: "", executablePath: "", pid: 1234)
        #expect(unknown.id == "pid-1234")
        #expect(!unknown.hasStableIdentity)
    }
}

// MARK: - Settings

@Suite("Settings")
struct SettingsTests {

    @Test("a PID key is never saved, since it is dead on the next launch")
    func dropsPIDKeys() {
        var settings = Settings()
        settings.setLevel(Settings.AppLevel(gain: 0.3, muted: false), for: "pid-1234")
        #expect(settings.apps.isEmpty)
    }

    @Test("a path key is saved, so a command-line player keeps its level")
    func keepsPathKeys() {
        var settings = Settings()
        settings.setLevel(Settings.AppLevel(gain: 0.3, muted: false), for: "path-/usr/bin/afplay")
        #expect(settings.level(for: "path-/usr/bin/afplay").gain == 0.3)
    }

    @Test("unity and unmuted is the default and is not written out")
    func dropsDefaults() {
        var settings = Settings()
        settings.setLevel(Settings.AppLevel(gain: 1, muted: false), for: "com.apple.Safari")
        #expect(settings.apps.isEmpty)
        // Muting at unity is a real choice, so it is kept.
        settings.setLevel(Settings.AppLevel(gain: 1, muted: true), for: "com.apple.Safari")
        #expect(settings.level(for: "com.apple.Safari").muted)
    }

    @Test("an unknown app reads back as unity and unmuted")
    func unknownDefaults() {
        let settings = Settings()
        #expect(settings.level(for: "com.example.absent").gain == 1)
        #expect(!settings.level(for: "com.example.absent").muted)
    }
}