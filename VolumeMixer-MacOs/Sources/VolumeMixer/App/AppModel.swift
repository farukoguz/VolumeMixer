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
        var gain: Float
        var muted: Bool
        var peak: Float
        var live: Bool
        var id: String { app.bundleID.isEmpty ? "pid-\(app.pid)" : app.bundleID }
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
    private var attachedIDs: Set<String> = []

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

    private func syncChannels(for apps: [AudioApp]) {
        let liveIDs = Set(engine.liveAppIDs)
        var next: [Channel] = []
        next.reserveCapacity(apps.count)

        for app in apps {
            let id = app.bundleID.isEmpty ? "pid-\(app.pid)" : app.bundleID
            let saved = settings.level(for: id)
            // A level is only shown as user-set if it was actually persisted;
            // otherwise the app is at unity.
            let gain = saved.gain
            let muted = saved.muted
            let existing = channels.first { $0.id == id }
            next.append(Channel(app: app,
                                gain: existing?.gain ?? gain,
                                muted: existing?.muted ?? muted,
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
            let id = app.bundleID.isEmpty ? "pid-\(app.pid)" : app.bundleID
            desired[id] = app
        }

        for id in attachedIDs where desired[id] == nil {
            engine.detach(appID: id)
        }
        for (id, app) in desired where !attachedIDs.contains(id) {
            engine.attach(to: app)
            // Re-apply a stored level so it takes effect as soon as the tap is
            // live rather than waiting for the user to touch the slider.
            let saved = settings.level(for: id)
            if saved.muted {
                engine.setMuted(true, for: id)
            } else if abs(saved.gain - 1) > 0.001 {
                engine.setGain(saved.gain, for: id)
            }
        }
        attachedIDs = Set(desired.keys)
    }

    // MARK: - Meters

    private func refreshMeters() {
        // The engine can change state on its own -- permission denial is only
        // detectable by inspecting samples, so it is discovered asynchronously.
        if engine.availability != engineStatus {
            engineStatus = engine.availability
        }
        guard !channels.isEmpty else { return }
        let liveIDs = Set(engine.liveAppIDs)
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

    /// Per-app gain needs system-audio-capture permission. Until that is
    /// granted the rows still list and track, but the sliders have nothing to
    /// act on, so the UI says so rather than pretending.
    var gainControlAvailable: Bool {
        if case .permissionRequired = engineStatus { return false }
        if case .permissionDenied = engineStatus { return false }
        return true
    }
}