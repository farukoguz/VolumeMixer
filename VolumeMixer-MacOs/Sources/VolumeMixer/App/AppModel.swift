import Combine
import CoreAudio
import Foundation
import SwiftUI

/// Observable state for the menu bar UI, and the seam between discovery, the
/// gain engine and the view layer.
///
/// Threading: discovery and the engine deliver changes on background queues;
/// everything published to the UI is marshalled onto the main actor.
@MainActor
final class AppModel: ObservableObject {

    struct Channel: Identifiable, Equatable {
        let app: AudioApp
        /// How many processes of this app are playing, all controlled together.
        var processCount: Int
        var gain: Float
        var muted: Bool
        var peak: Float
        var live: Bool
        var id: String { app.id }
    }

    // MARK: Published state

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var outputDevices: [OutputDevice] = []
    @Published var selectedDeviceUID: String = "" { didSet { onDeviceSelected() } }
    @Published var masterVolume: Double = 1.0 { didSet { onMasterVolumeChanged() } }
    @Published var masterMuted: Bool = false { didSet { SystemVolume.isMasterMuted = masterMuted } }
    @Published private(set) var engineStatus: GainEngineAvailability = .ready
    @Published private(set) var permissionHelpVisible = false

    /// Drives meter refreshes; not itself meaningful to the UI.
    @Published private var meterTick: Int = 0

    // MARK: Collaborators

    private let discovery = ProcessDiscovery()
    private let deviceMonitor = OutputDeviceMonitor()
    private var engine: GainEngine
    private var settings: Settings
    private var meterTimer: Timer?
    private var persistWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// Apps currently producing audio, as last reported by discovery.
    private var audibleApps: [AudioApp] = []
    /// Apps we have asked the engine to control, so we do not churn taps when a
    /// row merely re-renders.
    /// Process keys the engine currently has a tap for. Distinct from the channel
    /// identities: one app can hold several of these.
    private var attachedProcessKeys: Set<String> = []

    /// How long a tap is held after an app stops reporting audio.
    private let detachGrace: TimeInterval = 1.0
    /// Process keys that have gone quiet, and when. Not yet detached.
    private var pendingDetach: [String: Date] = [:]

    // MARK: - Init

    init() {
        settings = Settings.load()

        if #available(macOS 14.2, *) {
            let tapEngine = TapGainEngine()
            engine = tapEngine
            deviceMonitor.onChange = { [weak self] in
                (self?.engine as? TapGainEngine)?.handleDeviceChange()
            }
        } else {
            engine = UnavailableGainEngine(.unsupportedOS)
        }

        engineStatus = engine.availability

        discovery.onChange = { [weak self] apps in
            self?.audibleAppsChanged(apps)
        }

        masterVolume = Double(settings.masterVolume ?? SystemVolume.masterVolume())
        masterMuted = SystemVolume.isMasterMuted
        selectedDeviceUID = settings.lastDeviceUID ?? HAL.deviceUID(HAL.defaultOutputDevice) ?? ""
    }

    // MARK: - Lifecycle

    func start() {
        // Ask macOS about audio capture once per install, before anything is
        // listening, so the prompt has a chance to appear at launch. Every
        // later launch reuses the existing grant instead of asking again.
        if let tapEngine = engine as? TapGainEngine, !PermissionState.hasRequestedAudioCapture {
            // Recorded before the tap is created, so being killed mid-preflight
            // cannot leave us asking again on the next launch.
            PermissionState.hasRequestedAudioCapture = true
            // Creating and destroying a tap is a round trip into the HAL, which
            // can take tens of milliseconds and may block behind a device that
            // is slow to wake. Launch must not wait on it, so the check runs
            // alongside startup and reports back.
            let preflightQueue = DispatchQueue(label: "com.volumemixer.preflight")
            preflightQueue.async { [weak self] in
                let result = tapEngine.preflight()
                guard case .failed = result else { return }
                Task { @MainActor [weak self] in
                    self?.engineStatus = result
                }
            }
        }

        discovery.start()
        deviceMonitor.start()
        refreshDevices()

        // Meters are polled rather than pushed: the audio thread only ever
        // writes a peak into a slot, and 30 Hz is smooth enough for a UI meter
        // while keeping the main thread cheap.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func stop() {
        discovery.stop()
        deviceMonitor.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        engine.shutdown()
        persist()
    }

    // MARK: - Discovery

    private func audibleAppsChanged(_ apps: [AudioApp]) {
        audibleApps = apps
        syncChannels(for: apps)
        syncEngineAttachments(for: apps)
    }

    /// One row per app, however many processes it is running.
    ///
    /// Grouping matters for more than tidiness: two rows with the same identity
    /// would be two `Identifiable` values with the same ID in the `ForEach`, and
    /// a user dragging one of them while the other jumps would be inexplicable.
    /// Collapses an app's processes into one row each, preserving discovery order.
    nonisolated static func groupByApp(_ apps: [AudioApp]) -> [(identity: String, processes: [AudioApp])] {
        var order: [String] = []
        var members: [String: [AudioApp]] = [:]
        for app in apps {
            if members[app.id] == nil { order.append(app.id) }
            members[app.id, default: []].append(app)
        }
        return order.compactMap { identity in
            members[identity].map { (identity, $0) }
        }
    }

    private func syncChannels(for apps: [AudioApp]) {
        let liveIDs = engine.liveAppIDs
        var next: [Channel] = []
        next.reserveCapacity(apps.count)

        for (id, processes) in Self.groupByApp(apps) {
            guard let app = processes.first else { continue }
            let saved = settings.level(for: id)
            // An in-session change wins over the stored level.
            let existing = channels.first { $0.id == id }
            next.append(Channel(app: app,
                                processCount: processes.count,
                                gain: existing?.gain ?? saved.gain,
                                muted: existing?.muted ?? saved.muted,
                                peak: existing?.peak ?? 0,
                                live: liveIDs.contains(id)))
        }
        channels = next
    }

    /// Attaches taps for newly audible apps and releases taps for apps that
    /// stopped. Runs off the main actor's critical path because `attach` hops to
    /// the engine's own control queue anyway.
    private func syncEngineAttachments(for apps: [AudioApp]) {
        var desired: [String: AudioApp] = [:]
        for app in apps {
            desired[app.processKey] = app
        }

        // Switching the output device makes every app's stream migrate, and for
        // roughly a tenth of a second the app reports no output at all. Tapping
        // is what mutes an app, so releasing on that flicker lets its audio
        // through unprocessed for a moment and then re-taps it with a pop -- and
        // it cost two extra tap and aggregate devices per switch. Holding the tap
        // briefly costs nothing instead: an app that really has stopped is silent
        // anyway, and one that resumes inside the window is still correctly
        // tapped, with nothing to undo.
        let now = Date()
        for key in attachedProcessKeys where desired[key] == nil && pendingDetach[key] == nil {
            pendingDetach[key] = now
        }
        for key in desired.keys {
            // Came back inside the grace window: nothing was released.
            pendingDetach.removeValue(forKey: key)
        }

        for (key, app) in desired where !attachedProcessKeys.contains(key) {
            engine.attach(to: app)
            // Re-apply a stored level so it takes effect as soon as the tap is
            // live rather than waiting for the user to touch the slider.
            let saved = settings.level(for: app.id)
            if saved.muted {
                engine.setMuted(true, for: app.id)
            } else if abs(saved.gain - 1) > 0.001 {
                engine.setGain(saved.gain, for: app.id)
            }
        }
        attachedProcessKeys.formUnion(desired.keys)
        detachExpiredProcesses()
    }

    /// Releases taps whose app has stayed quiet for longer than the grace period.
    ///
    /// Driven by the meter timer rather than by discovery, because an app that
    /// stops and never starts again produces no further discovery event: keyed off
    /// events, its tap would be held for the rest of the session.
    private func detachExpiredProcesses() {
        guard !pendingDetach.isEmpty else { return }
        let now = Date()
        let expired = pendingDetach
            .filter { _, since in now.timeIntervalSince(since) >= detachGrace }
            .map(\.key)
        for key in expired {
            // Detach by process, not by app: one instance of an app exiting must
            // not release the tap of the instance still playing.
            engine.detach(processKey: key)
            attachedProcessKeys.remove(key)
            pendingDetach.removeValue(forKey: key)
        }
    }

    // MARK: - Meters

    private func refreshMeters() {
        // The engine can change state on its own -- permission denial is only
        // detectable by inspecting samples, so it is discovered asynchronously.
        if engine.availability != engineStatus {
            engineStatus = engine.availability
        }
        // Before the empty-channels guard: a model with nothing audible can still
        // be holding a tap through its grace period.
        detachExpiredProcesses()
        guard !channels.isEmpty else { return }
        let liveIDs = engine.liveAppIDs
        var changed = false
        var updated = channels
        for index in updated.indices {
            let id = updated[index].id
            let peak = engine.peak(for: id)
            let live = liveIDs.contains(id)
            if updated[index].peak != peak || updated[index].live != live {
                updated[index].peak = peak
                updated[index].live = live
                changed = true
            }
        }
        if changed {
            channels = updated
        }
    }

    // MARK: - User actions

    func setGain(_ value: Float, for id: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].gain = value
        if channels[index].muted { channels[index].muted = false }
        engine.setGain(value, for: id)
        var updated = settings
        updated.setLevel(Settings.AppLevel(gain: value, muted: false), for: id)
        settings = updated
        schedulePersist()
    }

    func toggleMute(for id: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        let muted = !channels[index].muted
        channels[index].muted = muted
        engine.setMuted(muted, for: id)
        var updated = settings
        updated.setLevel(Settings.AppLevel(gain: channels[index].gain, muted: muted), for: id)
        settings = updated
        schedulePersist()
    }

    func resetAllApps() {
        var updated = settings
        updated.resetAllApps()
        settings = updated
        for channel in channels {
            engine.setGain(1, for: channel.id)
            engine.setMuted(false, for: channel.id)
            if let index = channels.firstIndex(where: { $0.id == channel.id }) {
                channels[index].gain = 1
                channels[index].muted = false
            }
        }
        persist()
    }

    /// Re-attempts per-app gain after the user has granted Screen & System Audio
    /// Recording. Taps are torn down and rebuilt from scratch, because a tap that
    /// was created while capture was denied cannot start delivering samples
    /// afterwards.
    /// Rebuilds the taps with whatever permission is already granted.
    ///
    /// Deliberately does not run the preflight: the prompt has been shown once
    /// already, and re-asking is exactly what makes a permission flow feel
    /// broken. Once the user has granted access in System Settings this picks it
    /// up on the next attempt.
    func retryGainControl() {
        guard let tapEngine = engine as? TapGainEngine else { return }
        tapEngine.resetAfterDenial()
        engineStatus = .ready

        // Detach then re-attach everything currently audible. Both hops land on
        // the engine's serial control queue in order, so the taps are rebuilt
        // after the old ones are gone.
        for key in attachedProcessKeys { engine.detach(processKey: key) }
        attachedProcessKeys = []
        syncEngineAttachments(for: audibleApps)
    }

    /// Opens the exact System Settings pane that governs audio capture, so the
    /// permission prompt (which macOS only shows on demand, if at all) does not
    /// have to be hunted for.
    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Devices and master volume

    private func refreshDevices() {
        outputDevices = OutputDeviceMonitor.availableOutputs()
        let current = HAL.deviceUID(HAL.defaultOutputDevice) ?? ""
        if selectedDeviceUID.isEmpty { selectedDeviceUID = current }
    }

    private func onDeviceSelected() {
        guard let device = outputDevices.first(where: { $0.uid == selectedDeviceUID }) else { return }
        let status = HAL.setDefaultOutputDevice(device.id)
        if status != noErr { Log.error("set default output: \(fourcc(status))") }
        var updated = settings
        updated.lastDeviceUID = selectedDeviceUID
        settings = updated
        persist()
    }

    private func onMasterVolumeChanged() {
        // Applied to the HAL immediately so the slider feels live; only the
        // persisted copy is debounced.
        SystemVolume.setMasterVolume(Float(masterVolume))
        var updated = settings
        updated.masterVolume = Float(masterVolume)
        settings = updated
        schedulePersist()
    }

    /// Slider drags fire this many times a second, so writes are coalesced
    /// instead of hitting the disk on every frame.
    private func schedulePersist() {
        persistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.settings.save() }
        persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func persist() {
        persistWorkItem?.cancel()
        settings.save()
    }

    // MARK: - Derived

    /// Per-app gain needs system-audio-capture permission, and the engine also
    /// stands down if it stalls or the format is unsupported. In any of those
    /// states the rows still list apps and remember levels, but the sliders have
    /// nothing to act on, so the UI says so rather than pretending.
    var gainControlAvailable: Bool { engineStatus == .ready }
}