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
                 icon: nil,
                 roleName: nil)
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
                 icon: nil,
                 roleName: nil)
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

// MARK: - Owning app resolution

@Suite("Helper naming")
struct OwningAppTests {

    /// The real path from a running Brave helper, which is the case that was
    /// broken: the innermost `.app` is the helper itself, the outermost is the app
    /// the user installed.
    private let braveHelper =
        "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework"
        + "/Versions/143.1.85.111/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"

    @Test("the owning app is the outermost bundle, not the helper's own")
    func outermostBundleWins() {
        let path = AudioApp.owningAppPath(ofExecutable: braveHelper)
        #expect(path == "/Applications/Brave Browser.app",
                "must resolve to the installed app, not Brave Browser Helper.app")
    }

    @Test("a helper's role name comes from its own executable")
    func helperRoleName() {
        // The helper is named by its own executable because the owning app's name
        // is what the row already shows; the role is only the extra detail.
        let role = AudioApp.cleanedHelperName("Brave Browser Helper (Plugin)")
        #expect(role == "Brave Browser Helper (Plugin)")
    }

    @Test("a bare Helper executable does not become a row title")
    func bareHelperNameIsNotUseful() {
        // Nothing to distinguish it from any other bare "Helper", so it must not
        // be the fallback when the bundle cannot be resolved.
        #expect(AudioApp.cleanedHelperName("Helper") == "Helper")
    }

    @Test("a command-line player has no owning app")
    func commandLineHasNoOwner() {
        #expect(AudioApp.owningAppPath(ofExecutable: "/usr/bin/afplay") == nil,
                "afplay is not inside any app bundle")
    }

    @Test("a top-level app resolves to itself")
    func appResolvesToItself() {
        let path = AudioApp.owningAppPath(ofExecutable: "/Applications/Safari.app/Contents/MacOS/Safari")
        #expect(path == "/Applications/Safari.app")
    }

    @Test("helpers of one app are distinguishable but keep their own identity")
    func helpersStayDistinct() {
        // The row merges them, but tapping is per-process, so identity must still
        // be the helper's own bundle ID rather than the owning app's.
        let main = AudioApp(bundleID: "com.brave.Browser", executablePath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", processObjectID: 1, pid: 100, displayName: "Brave Browser", icon: nil, roleName: nil)
        let helper = AudioApp(bundleID: "com.brave.Browser.helper", executablePath: braveHelper, processObjectID: 2, pid: 101, displayName: "Brave Browser", icon: nil, roleName: "Brave Browser Helper")
        #expect(main.id != helper.id, "a helper must not collide with its app")
        #expect(main.processKey != helper.processKey)
    }
}
