import AppKit
import SwiftUI

/// A menu-bar-only per-application volume mixer for macOS.
///
/// macOS has no equivalent of Windows' `IAudioSessionManager`: the public Core
/// Audio SDK exposes process discovery but no per-app volume setter. Gain is
/// applied by tapping each app's output (macOS 14.2+), scaling it, and mixing
/// the result back into the default output device.
@main
struct VolumeMixerApp: App {

    /// Discovery has to run from launch, not when the panel is first opened: apps
    /// that started playing in the meantime would be missing from the list, and
    /// a tap cannot be created retroactively.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MixerView(model: delegate.model)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Taps mute the apps they read, so teardown has to actually run rather
        // than relying on process exit.
        model.stop()
    }
}