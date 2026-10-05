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
/// ## Processes versus apps
///
/// An app can be more than one process: two `afplay` instances, a browser and its
/// audio helpers, anything with an XPC service. Each process needs its own tap,
/// because a tap reads one process object and mutes only that process. If a second
/// process were left untapped it would keep playing at full volume while its
/// sibling was muted, and the slider would control only half the app.
///
/// So the engine taps per *process* (`attach`/`detach`, keyed by process) and
/// controls per *app* (`setGain`, `setMuted`, `peak`, keyed by app identity). One
/// slider, every process of that app.
protocol GainEngine: AnyObject {

    var availability: GainEngineAvailability { get }

    /// Begins controlling one process of an app. Safe to call repeatedly for the
    /// same process.
    func attach(to app: AudioApp)

    /// Stops controlling one process and releases its tap, aggregate device and
    /// IOProc. Releasing the tap is what unmutes that process again.
    func detach(processKey: String)

    /// Applies to every process of the app at once.
    func setGain(_ gain: Float, for appID: String)
    func setMuted(_ muted: Bool, for appID: String)

    /// Loudest output peak across an app's processes, 0...1. Read from the UI,
    /// never on the audio thread.
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

    func detach(processKey: String) {
        // Levels are per app, so nothing is forgotten when one process of an app
        // goes away while another keeps playing.
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