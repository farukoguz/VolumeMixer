# Security policy

## Reporting a vulnerability

Please report vulnerabilities through
[GitHub's private vulnerability reporting](https://github.com/farukoguz/VolumeMixer/security/advisories/new)
rather than a public issue. Reports reach the maintainer directly and stay private
until a fix is available.

If that form is unavailable, open a **private** advisory or contact the maintainer
through the profile linked from the commit history. Please do not disclose the
details publicly before a fix ships.

## What counts as security-relevant

Volume Mixer installs a Core Audio process tap and can mute or alter the audio of
other running applications. Treat anything that would let it do more than that as
in scope:

- reading or writing outside the audio path of the processes it taps
- turning the mixer into a confused deputy for another app's data
- a malicious app or page able to drive Volume Mixer's controls without user intent
- privilege escalation through the build, signing or install scripts
- secrets, signing material or machine-identifying data leaking into a release

Out of scope: audio quality bugs, crashes with no security impact, and the
documented [known limitations](README.md#known-limitations).

## Supported versions

The latest published release is the supported one. Report issues against
[the newest release](https://github.com/farukoguz/VolumeMixer/releases/latest);
older builds are not patched.
