import Foundation

/// Remembers that the Screen & System Audio Recording prompt has already been
/// shown.
///
/// The preflight tap is the only thing in this app that can make macOS display
/// that prompt, because tap creation is what TCC evaluates. macOS keys the
/// decision to the bundle's identity, so running the preflight on every launch
/// would ask again on every launch -- the behaviour that makes permission
/// dialogs feel broken.
///
/// Once the prompt has been shown, taps simply reuse whatever was granted: a
/// user who grants access in System Settings starts working on the next launch
/// without another prompt, and a user who denied it keeps system audio working
/// because the taps get released.
///
/// This lives in `UserDefaults` rather than `settings.json` because it is
/// operational state, not a user preference, and because it must survive even if
/// the app is killed mid-preflight.
enum PermissionState {

    private static let key = "hasRequestedAudioCapture"

    static var hasRequestedAudioCapture: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}