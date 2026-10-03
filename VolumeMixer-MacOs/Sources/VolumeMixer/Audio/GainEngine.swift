import CoreAudio
import Foundation

/// Why a gain engine is unavailable. Permission state is the interesting case:
/// macOS reports audio-capture denial by handing back working objects that
/// produce silence, so it has to be detected by inspecting samples.
enum GainEngineAvailability: Equatable {
    case ready
    /// macOS refused system audio capture. Reported by inspecting samples, since
    /// TCC denial is indistinguishable from success at every API call site.
    case permissionDenied
    case unsupportedOS
    case failed(String)

    var isReady: Bool { self == .ready }

    var summary: String {
        switch self {
        case .ready:
            return "Per-app volume is active."
        case .permissionDenied:
            return "Per-app volume needs the “System Audio Recording” permission."
        case .unsupportedOS:
            return "Per-app volume requires macOS 14.2 or later."
        case .failed(let reason):
            return "Per-app volume unavailable: \(reason)"
        }
    }
}

/// Per-application volume control, abstracted so the UI does not depend on the
/// audio graph being present. Discovery and the UI work whether or not the
/// engine can actually process audio, which keeps the app useful (and
/// debuggable) while permission is still missing.
protocol GainEngine: AnyObject {

    var availability: GainEngineAvailability { get }

    /// Begins controlling an app. Safe to call repeatedly for the same app.
    func attach(to app: AudioApp)

    /// Stops controlling an app and releases its tap, aggregate device and IOProc.
    /// Releasing the tap is what unmutes the app again.
    func detach(appID: String)

    func setGain(_ gain: Float, for appID: String)
    func setMuted(_ muted: Bool, for appID: String)

    /// Latest output peak for an app, 0...1. Read from the UI, never on the audio thread.
    func peak(for appID: String) -> Float

    /// Apps the engine is actually routing. Anything else falls through to the
    /// system mixer untouched.
    var liveAppIDs: Set<String> { get }

    /// Tears everything down. Used on shutdown and by the safety watchdog.
    func shutdown()
}

/// Stand-in used when the audio graph cannot run at all, so discovery, the
/// device picker and the master volume keep working. Every gain change is
/// accepted and remembered but applied to nothing, which is exactly the state
/// the app is in before permission is granted.
final class UnavailableGainEngine: GainEngine {

    let availability: GainEngineAvailability
    private var levels: [String: Float] = [:]
    private var muted: Set<String> = []

    init(_ availability: GainEngineAvailability) {
        self.availability = availability
    }

    func attach(to app: AudioApp) {}

    func detach(appID: String) {
        levels.removeValue(forKey: appID)
        muted.remove(appID)
    }

    func setGain(_ gain: Float, for appID: String) {
        guard !muted.contains(appID) else { return }
        levels[appID] = max(0, gain)
    }

    func setMuted(_ muted: Bool, for appID: String) {
        if muted {
            self.muted.insert(appID)
        } else {
            self.muted.remove(appID)
        }
    }

    func peak(for appID: String) -> Float { 0 }

    var liveAppIDs: Set<String> { [] }

    func shutdown() {
        levels.removeAll()
        muted.removeAll()
    }
}