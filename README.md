# VolumeMixer

Projects:

- [VolumeMixer](VolumeMixer) — menu bar per-app volume mixer for macOS, built on Core Audio process taps.

## Installing someone else's build

VolumeMixer is not signed with Developer ID and is not notarised, so macOS will
not open it on a fresh Mac without help. Every user does two steps by hand, once
per Mac:

1. **Open it once by hand.** macOS shows "cannot be opened because the developer
   cannot be verified". Right-click (or Control-click) Volume Mixer in Finder,
   choose **Open**, and confirm. macOS remembers the decision for that app.
2. **Grant Screen & System Audio Recording.** System Settings → Privacy &
   Security → Screen & System Audio Recording, then add Volume Mixer.

Step 2 is not optional and cannot be automated. Without it the app launches and
lists whatever is playing, but every slider does nothing and no error appears
anywhere. If a slider has no effect, check this first.

One detail worth knowing: ad-hoc and Development-signed builds have their
permission grant tied to the exact build, so a rebuild means granting it again.
Notarised builds avoid that, which is the reason to eventually sign properly.

Removing step 1 requires a paid Apple Developer Program membership and Apple
notarisation.