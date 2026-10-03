import CoreAudio
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
// MARK: - Grouping

@Suite("Row grouping")
struct GroupingTests {

    private func app(bundleID: String, executablePath: String = "", pid: pid_t) -> AudioApp {
        AudioApp(bundleID: bundleID,
                 executablePath: executablePath,
                 processObjectID: AudioObjectID(pid),
                 pid: pid,
                 displayName: "Test",
                 icon: nil)
    }

    @Test("two instances of one app become one row, not two identical rows")
    func collapsesInstances() {
        let first = app(bundleID: "", executablePath: "/usr/bin/afplay", pid: 100)
        let second = app(bundleID: "", executablePath: "/usr/bin/afplay", pid: 200)
        let other = app(bundleID: "com.apple.Safari", pid: 300)

        let groups = AppModel.groupByApp([first, other, second])
        #expect(groups.count == 2)
        #expect(groups[0].identity == "path-/usr/bin/afplay")
        #expect(groups[0].processes.count == 2)
        #expect(groups[1].identity == "com.apple.Safari")
    }

    @Test("each process still has its own key, so each gets its own tap")
    func processKeysAreDistinct() {
        let first = app(bundleID: "", executablePath: "/usr/bin/afplay", pid: 100)
        let second = app(bundleID: "", executablePath: "/usr/bin/afplay", pid: 200)
        #expect(first.id == second.id)
        #expect(first.processKey != second.processKey)
    }

    @Test("discovery order is preserved")
    func keepsOrder() {
        let apps = [app(bundleID: "b.app", pid: 1), app(bundleID: "a.app", pid: 2)]
        #expect(AppModel.groupByApp(apps).map(\.identity) == ["b.app", "a.app"])
    }
}
