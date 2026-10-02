import AppKit
import CoreAudio
import Darwin
import Foundation

/// Watches Core Audio for the set of processes that are actively producing
/// sound, and pushes updates when that set changes.
///
/// Two mechanisms, deliberately combined:
///   * property listeners give immediate, event-driven updates, so a row appears
///     the instant an app starts playing and disappears when it stops
///   * a slow poll backstops the listeners, because HAL listener delivery is not
///     guaranteed across every device and process-state transition
///
/// Listener removal is keyed per object: Core Audio takes exactly one block per
/// registration, and each process object needs its own block, so they are tracked
/// as pairs rather than in one flat array.
final class ProcessDiscovery {

    /// Called on the main queue whenever the audible-app set changes.
    var onChange: (([AudioApp]) -> Void)?

    private let queue = DispatchQueue(label: "com.volumemixer.discovery")
    private let pollInterval: TimeInterval = 1.0

    private var lastSignature: [String] = []
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var systemListeners: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock] = [:]
    private var timer: DispatchSourceTimer?
    private var isRunning = false

    /// Snapshots of anything expensive, keyed by pid.
    private var descriptorCache: [pid_t: AudioApp] = [:]

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // The process object list itself changes as apps launch and exit; that
        // is the signal to subscribe to any newly appeared objects.
        addSystemListener(kAudioHardwarePropertyProcessObjectList)
        installProcessListeners()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer

        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        removeAllListeners()
        lastSignature = []
        descriptorCache.removeAll()
    }

    // MARK: - Listeners

    private var runningOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) {
        var address = globalAddress(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        if status == noErr {
            systemListeners[selector] = block
        } else {
            Log.error("add listener \(fourcc(selector)): \(fourcc(status))")
        }
    }

    /// Subscribes to `IsRunningOutput` on every process object, so a dormant
    /// client is reported the moment it starts making sound.
    private func installProcessListeners() {
        var address = runningOutputAddress
        var installed = 0

        for object in HAL.allProcessObjects() {
            guard processListeners[object] == nil else { continue }
            guard AudioObjectHasProperty(object, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleChange()
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                processListeners[object] = block
                installed += 1
            }
        }

        // Objects for exited processes can no longer change state, so drop them.
        let live = Set(HAL.allProcessObjects())
        for object in processListeners.keys where !live.contains(object) {
            var removalAddress = runningOutputAddress
            AudioObjectRemovePropertyListenerBlock(object, &removalAddress, queue, processListeners[object]!)
            processListeners.removeValue(forKey: object)
        }

        if installed > 0 {
            Log.lifecycle("installed \(installed) process listener(s)")
        }
    }

    private func removeAllListeners() {
        var processAddress = runningOutputAddress
        for (object, block) in processListeners {
            AudioObjectRemovePropertyListenerBlock(object, &processAddress, queue, block)
        }
        processListeners.removeAll()

        for (selector, block) in systemListeners {
            var address = globalAddress(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        systemListeners.removeAll()
    }

    /// Listeners can fire in bursts; coalesce onto the discovery queue so a
    /// rapid start/stop does not rebuild the snapshot many times over.
    private func handleChange() {
        queue.async { [weak self] in
            self?.installProcessListeners()
            self?.refresh()
        }
    }

    // MARK: - Snapshot

    /// Computes the current audible set and notifies only when it actually
    /// changed, so the UI is not rebuilt needlessly.
    private func refresh() {
        let apps = audibleApps()
        let signature = apps.map { "\($0.bundleID)#\($0.pid)" }
        guard signature != lastSignature else { return }
        lastSignature = signature

        DispatchQueue.main.async { [weak self] in
            self?.onChange?(apps)
        }
    }

    /// The list of apps currently rendering output audio.
    ///
    /// `kAudioHardwarePropertyProcessObjectList` is a superset that accumulates
    /// dormant clients, so every entry is gated on `IsRunningOutput`. That filter
    /// is what makes this list the short "what is making sound right now" set
    /// rather than a wall of every app that has ever touched Core Audio.
    private func audibleApps() -> [AudioApp] {
        var result: [AudioApp] = []

        for object in HAL.allProcessObjects() {
            guard HAL.isRunningOutput(object) else { continue }
            guard let pid = HAL.pid(of: object), pid > 0, isAlive(pid) else { continue }

            if let cached = descriptorCache[pid], cached.processObjectID == object {
                result.append(cached)
            } else if let app = AudioApp.make(objectID: object) {
                descriptorCache[pid] = app
                result.append(app)
            }
        }

        // Drop cache entries for processes that no longer appear at all, so the
        // dictionary cannot grow without bound.
        let seen = Set(result.map(\.pid))
        if descriptorCache.count > seen.count + 32 {
            descriptorCache = descriptorCache.filter { seen.contains($0.key) }
        }

        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Liveness check for a listed process.
    ///
    /// `NSWorkspace.runningApplications` is not usable here: it only knows about
    /// LaunchServices-registered apps, so the command-line players that people
    /// actually want to mix -- afplay, ffmpeg, mpv -- are missing from it
    /// entirely. Signal 0 asks the kernel directly, and `EPERM` means the
    /// process exists but belongs to another user.
    private func isAlive(_ pid: pid_t) -> Bool {
        if pid == getpid() { return true }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Current audible set, for callers outside the change callback.
    func currentApps() -> [AudioApp] {
        audibleApps()
    }
}