import Foundation

/// Remembers that VolumeMixer has already asked for audio capture.
///
/// The flag exists so the app does not poke TCC on every launch. It is not what
/// makes macOS prompt: creating a process tap returns `noErr` whether or not
/// access was granted, so a tap cannot reliably provoke the dialog. On a build
/// with no signing identity TCC declines without a dialog and without adding the
/// app to System Settings at all, which is why the app also carries its own
/// alert rather than trusting a prompt to appear.
///
/// Once the flag is set, taps simply reuse whatever was granted: a user who
/// grants access in System Settings starts working without another prompt, and a
/// user who did not keeps system audio working because the taps get released.
///
/// This lives in `UserDefaults` rather than `settings.json` because it is
/// operational state, not a user preference, and because it must survive even if
/// the app is killed mid-preflight.
enum PermissionState {

    private static let key = "hasRequestedAudioCapture"
    private static let declinedAtKey = "audioCapturePromptDeclinedAt"
    private static let deniedAtKey = "audioCaptureDeniedAt"

    static var hasRequestedAudioCapture: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// When the user last dismissed our own permission alert.
    ///
    /// This is separate from `hasRequestedAudioCapture` because the two record
    /// different things. That flag says macOS was asked once and now remembers the
    /// answer; this says the user looked at the alert and chose to come back
    /// later. Keeping them apart is what lets the app stay visible about the
    /// permission without re-asking on every launch.
    static var lastDeclinedAt: Date? {
        get { UserDefaults.standard.object(forKey: declinedAtKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: declinedAtKey) }
    }

    static func declinePrompt() {
        lastDeclinedAt = Date()
    }

    static func clearDecline() {
        lastDeclinedAt = nil
    }

    /// When a tap was last caught delivering nothing but silence, meaning macOS
    /// is withholding capture.
    ///
    /// Recorded so a later launch can skip the check entirely. The check costs
    /// the user real audio: a tap mutes the app it reads, so every launch that
    /// rediscovers the refusal spends seconds muting whatever happens to be
    /// playing. Believing the earlier answer keeps that from happening once per
    /// launch, and a user who has since granted access clears it by hitting Retry.
    static var captureDeniedAt: Date? {
        get { UserDefaults.standard.object(forKey: deniedAtKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: deniedAtKey) }
    }

    static func recordDenial() {
        captureDeniedAt = Date()
    }

    static func clearDenial() {
        captureDeniedAt = nil
    }
}