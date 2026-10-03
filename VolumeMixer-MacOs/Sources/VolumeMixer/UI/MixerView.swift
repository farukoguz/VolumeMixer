import SwiftUI

/// Horizontal peak meter. Sits behind the slider rather than beside it, the way
/// a hardware mixer channel strip reads.
struct MeterView: View {
    let peak: Float

    private var level: Double {
        // Perceptual curve: raw linear amplitude makes a -20 dB signal look
        // completely dead, which reads as "this app is not playing".
        let clamped = min(max(Double(peak), 0), 1)
        return pow(clamped, 0.4)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.green, Color.green, Color.yellow, Color.red],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(2, geometry.size.width * level))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.06), value: level)
    }
}

/// One application row: icon, name, meter-backed slider, mute button.
struct AppRowView: View {
    let channel: AppModel.Channel
    let onGainChange: (Float) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.app.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !channel.live {
                        // The tap has not come up for this app. Levels are stored
                        // but not being applied yet.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("Not yet routed through the audio engine")
                    }
                }

                ZStack(alignment: .leading) {
                    // Meter behind, so it reads as a channel strip.
                    MeterView(peak: channel.peak)
                        .frame(height: 5)
                    Slider(
                        value: Binding(
                            get: { Double(channel.muted ? 0 : channel.gain) },
                            set: { onGainChange(Float($0)) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.mini)
                    .tint(channel.muted ? .secondary : .accentColor)
                }
                .frame(height: 16)
            }

            Button(action: onToggleMute) {
                Image(systemName: channel.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(channel.muted ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help(channel.muted ? "Unmute" : "Mute")
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var icon: some View {
        if let icon = channel.app.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .padding(2)
        }
    }
}

/// The mixer panel shown from the menu bar.
struct MixerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !model.gainControlAvailable {
                permissionBanner
            }

            Divider()

            if model.channels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.channels) { channel in
                            AppRowView(
                                channel: channel,
                                onGainChange: { model.setGain($0, for: channel.id) },
                                onToggleMute: { model.toggleMute(for: channel.id) }
                            )
                            .padding(.horizontal, 12)
                            Divider().opacity(0.35).padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker("", selection: $model.selectedDeviceUID) {
                    ForEach(model.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 190)
            }

            HStack(spacing: 8) {
                Image(systemName: model.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(model.masterMuted ? Color.red : Color.secondary)
                    .frame(width: 16)

                Slider(
                    value: $model.masterVolume,
                    in: 0...1
                )
                .controlSize(.small)
                .onTapGesture(count: 2) { model.masterVolume = 1 }

                Text("\(Int(model.masterVolume * 100))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(12)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.engineStatus.summary)
                        .font(.system(size: 11, weight: .semibold))
                    Text("macOS gates system audio capture behind the “System Audio Recording” permission and refuses silently when it is missing, so no taps are kept open. Apps below are still detected correctly and their levels are remembered.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Open System Settings") { model.openPrivacySettings() }
                Button("Retry") { model.retryGainControl() }
            }
            .controlSize(.small)
            .font(.system(size: 11))
            .padding(.leading, 20)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("Nothing is playing")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Apps appear here while they produce audio.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Reset all") { model.resetAllApps() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .disabled(model.channels.isEmpty)

            Spacer()

            Button("Quit") { model.quit() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}