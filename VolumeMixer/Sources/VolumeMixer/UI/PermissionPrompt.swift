import AppKit

/// A permission alert that shows itself.
///
/// The mixer lives in the menu bar, so its only other permission surface is a
/// banner inside the panel. That is a poor place to be told the app cannot work:
/// it is invisible until the user already knows to open the panel and click the
/// right row. macOS makes it worse by showing its own prompt exactly once, and
/// only in response to a tap attempt, so a user who misses it has to already know
/// that System Settings is where the answer lives.
///
/// This is the surface that was missing: an alert that appears on launch when
/// capture is unavailable, comes to the front even though the app has no windows,
/// and leads straight to the right settings pane.
///
/// The alert is ours, not macOS's. macOS decides whether to show its own prompt
/// and remembers the answer either way; showing this one repeatedly would be
/// nagging, so a dismissal puts it off for a few days.
enum PermissionPrompt {

    /// System Settings' pane for audio capture, which is where
    /// "Screen & System Audio Recording" lives.
    ///
    /// Deliberately the screen-capture pane and not the microphone one. Process
    /// taps are governed by the screen-capture TCC service, so the microphone
    /// pane is the wrong list to send the user to: Volume Mixer can be listed
    /// there and switched on, and every tap still returns silence, because
    /// granting microphone access says nothing about system audio capture.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows the alert if it is due. Returns without doing anything when the user
    /// recently dismissed it.
    ///
    /// - Parameter onRetry: rebuilds the taps, so granting access in System
    ///   Settings takes effect without relaunching.
    static func presentIfDue(onRetry: @escaping () -> Void) {
        guard !isOnBackoff else { return }
        // Presenting while one is already up nests a modal inside a modal, and
        // then their returns interleave: closing the inner one can read as a
        // button press on the outer one, which retries the taps, which are
        // refused, which presents another alert.
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "VolumeMixer needs System Audio Recording"
        alert.informativeText = """
        Per-app volume works by listening to each app's audio with macOS, which \
        needs your permission.

        Screen & System Audio Recording is off, so VolumeMixer cannot change \
        anything yet. Your other apps keep working normally either way.

        Add VolumeMixer to that list with the + button, turn it on, then press
        Try Again here.

        If VolumeMixer is already listed under Microphone, that is a different
        permission and switching it on will not help. Check the Screen & System
        Audio Recording list too.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Not Now")

        // A menu bar app has no window to own the alert, so without this the
        // alert can open behind whatever the user is doing and go unnoticed,
        // which is the failure this whole type exists to prevent.
        NSApp.activate(ignoringOtherApps: true)
        Log.lifecycle("permission alert shown")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openSettings()
        case .alertSecondButtonReturn:
            onRetry()
        default:
            PermissionState.declinePrompt()
        }
    }

    /// Re-checks the clock. A retry is a deliberate act, so it clears the backoff
    /// even if the user had dismissed the alert.
    static func retryRequested() {
        PermissionState.clearDecline()
    }

    // MARK: - Backoff

    private static var isPresenting = false
    private static let backoff: TimeInterval = 3 * 24 * 60 * 60

    private static var isOnBackoff: Bool {
        guard let declinedAt = PermissionState.lastDeclinedAt else { return false }
        return Date().timeIntervalSince(declinedAt) < backoff
    }
}