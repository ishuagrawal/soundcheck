import SwiftUI

struct MixerView: View {
    @Bindable var model: MixerModel
    var onSizeChange: (CGSize) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 340
    static let inset: CGFloat = 16
    private static let rowHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 16)
            OutputSection(model: model).padding(.bottom, 14)
            separator
            if model.enabled {
                appHeader.padding(.top, 14).padding(.bottom, 10)
                if model.isBypassed { pausedNotice.padding(.bottom, 10) }
                appList
            } else {
                setup
            }
            if let error = model.error { errorNotice(error).padding(.top, 10) }
            separator.padding(.top, 12)
            footer.padding(.top, 6)
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 16).padding(.bottom, 8)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        // The window animates to the measured height; pin content to the top so
        // it doesn't recenter while the frame is between sizes. `minHeight: 0`
        // matters when growing: without it, content taller than the window is
        // centered and the header jumps up by half the difference.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .animation(motion, value: model.showAllApps)
        .animation(motion, value: model.visibleApps.map(\.id))
        .animation(motion, value: model.isBypassed)
        .animation(motion, value: model.error)
    }

    /// Shared with the panel's frame animation so the list and the window move together.
    static let resizeDuration = 0.3
    private var motion: Animation? { reduceMotion ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: Self.resizeDuration) }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 2)
    }

    private var status: String {
        if model.audioConnectionStalled { return "Audio unavailable · mix saved" }
        return model.status
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Soundcheck").font(.system(size: 15, weight: .semibold))
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .contentTransition(.numericText()).lineLimit(1)
            }
            Spacer(minLength: 8)
            moreMenu
        }
        .accessibilityElement(children: .contain)
    }

    private var moreMenu: some View {
        Menu {
            if model.enabled {
                Button(model.isBypassed ? "Resume App Volume" : "Pause App Volume",
                       systemImage: model.isBypassed ? "play" : "pause") { model.toggleBypass() }
                Button("Reset All Apps", systemImage: "arrow.counterclockwise") { model.resetAll() }
                    .disabled(model.changedCount == 0)
                Divider()
            }
            Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Button("Audio Access…", systemImage: "lock.shield") { model.openAudioPrivacy() }
            Divider()
            Text("Soundcheck \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            Button("Quit Soundcheck", systemImage: "power") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .buttonStyle(CircleButtonStyle())
        .modifier(HoverCircle())
        .accessibilityLabel("More options")
        .help("More options")
    }

    // MARK: Apps

    private var appHeader: some View {
        HStack(alignment: .center) {
            SectionTitle("Apps")
            Spacer()
            Picker("Show", selection: $model.showAllApps) {
                Text("Playing").tag(false)
                Text("All").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            .help("Show apps using audio, or every running app")
        }
    }

    @ViewBuilder private var appList: some View {
        let visible = model.visibleApps
        if visible.isEmpty {
            emptyState
        } else {
            let content = CGFloat(visible.count) * (Self.rowHeight + Self.rowSpacing) - Self.rowSpacing
            let visibleIDs = Set(visible.map(\.id))
            let lastVisibleID = visible.last?.id
            ScrollView {
                VStack(spacing: 0) {
                    // Keep every app's position stable and clip rows as they collapse,
                    // so filtering cannot draw one row over another.
                    ForEach(model.apps) { app in
                        let shown = visibleIDs.contains(app.id)
                        let height = shown ? Self.rowHeight + (app.id == lastVisibleID ? 0 : Self.rowSpacing) : 0
                        ZStack(alignment: .top) {
                            if shown {
                                AppVolumeRow(app: app, model: model).frame(height: Self.rowHeight)
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: height, alignment: .top)
                        .clipped()
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(visible.count > 8 ? .automatic : .hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(content + 4, 8 * (Self.rowHeight + Self.rowSpacing)))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .regular)).foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("Nothing is playing").font(.system(size: 13, weight: .medium))
            Text("Apps appear here when they make sound.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Button("Show All Apps") { model.showAllApps = true }
                .buttonStyle(.link).font(.system(size: 11.5, weight: .medium)).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
    }

    private var setup: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("A volume for every app").font(.system(size: 15, weight: .semibold))
            Text("Keep music up and everything else a little quieter. Soundcheck needs audio access to adjust each app.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: model.requestAccess) {
                HStack(spacing: 7) {
                    if model.isRequestingAccess { ProgressView().controlSize(.small) }
                    Text(model.isRequestingAccess ? "Waiting for macOS…" : "Enable App Volume")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .disabled(model.isRequestingAccess).padding(.top, 6)
            Label("Audio stays on your Mac. Nothing is recorded.", systemImage: "lock.fill")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 18).padding(.horizontal, 6)
    }

    private var pausedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
            Text("App volume is paused").font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Resume") { model.toggleBypass() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
        .background(.primary.opacity(0.05), in: .capsule)
    }

    private func errorNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11.5))
            HStack(spacing: 8) {
                Spacer()
                Button("Audio Access…") { model.openAudioPrivacy() }
                if model.audioConnectionStalled {
                    Button("Quit Soundcheck") { NSApp.terminate(nil) }
                } else {
                    Button("Try Again") { model.error = nil; model.requestAccess() }
                }
            }
            .controlSize(.small).buttonStyle(.bordered)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private var footer: some View {
        MenuRowButton(title: "Sound Settings…") { model.openSoundSettings() }
    }
}

// MARK: - Output

private struct OutputSection: View {
    @Bindable var model: MixerModel

    private var speakerSymbol: String {
        model.outputMuted || model.outputVolume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                SectionTitle("Output")
                Spacer(minLength: 8)
                deviceMenu
            }
            if model.outputCanChangeVolume {
                HStack(spacing: 10) {
                    Button(action: model.toggleOutputMute) {
                        Image(systemName: speakerSymbol, variableValue: model.outputMuted ? 0 : model.outputVolume)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.outputMuted ? .secondary : .primary)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(CircleButtonStyle(filled: true))
                    .disabled(!model.outputCanMute)
                    .accessibilityLabel(model.outputMuted ? "Unmute output" : "Mute output")
                    .help(model.outputMuted ? "Unmute" : "Mute")
                    VolumeSlider(value: Binding(get: { model.outputVolume }, set: model.setOutputVolume),
                                 tint: .accentColor, label: "Output volume", muted: model.outputMuted)
                        .overlay(alignment: .trailing) {
                            ValueLabel(value: model.outputVolume, muted: model.outputMuted).padding(.trailing, 12)
                        }
                }
            } else {
                Text("Use your device’s own volume controls.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(model.outputs) { device in
                Toggle(isOn: Binding(get: { device.id == model.outputID }, set: { if $0 { model.setOutput(device.id) } })) {
                    Label(device.name, systemImage: device.symbol)
                }
            }
            Divider()
            Button("Sound Settings…") { model.openSoundSettings() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.currentOutput?.symbol ?? "speaker.wave.2")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                // Inline so borderless menu labels keep the chevron.
                Text("\(model.currentOutput?.name ?? "No Output")  \(Image(systemName: "chevron.up.chevron.down"))")
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Output device: \(model.currentOutput?.name ?? "None")")
        .help("Choose output device")
    }
}

// MARK: - App row

private struct AppVolumeRow: View {
    @Bindable var app: AppAudio
    let model: MixerModel
    @State private var hoveringIcon = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var muted: Bool { app.preference.isMuted }
    /// Muted or dragged to 0%: the row shows the muted look either way (dimmed icon,
    /// badge, name, and slider; no glow or level bars). The value still reads 0%.
    private var silent: Bool { app.preference.isSilent }
    @Environment(\.colorScheme) private var colorScheme
    private var ink: Color { colorScheme == .dark ? app.accent.mix(with: .white, by: 0.55) : app.accent.mix(with: .black, by: 0.25) }
    private var glowing: Bool { !silent && !model.isBypassed && model.isPanelVisible && app.error == nil }
    private var detail: String? {
        if let error = app.error { return error }
        if model.audioConnectionStalled { return "Waiting for audio" }
        if app.preference.needsProcessing && !app.controlled && !model.isBypassed { return "Applying saved volume…" }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            muteButton
            VolumeSlider(value: Binding(get: { app.preference.volume }, set: { model.setVolume($0, for: app) }),
                         tint: app.accent, label: "\(app.name) volume", muted: silent)
                .overlay {
                    ZStack {
                        LevelGlow(level: glowing ? app.activity.level : 0, volume: app.preference.volume, tint: app.accent)
                        labels
                    }
                    .allowsHitTesting(false)
                }
        }
        .disabled(model.isBypassed)
        .opacity(model.isBypassed ? 0.55 : 1)
        .help(detail ?? "")
        .contextMenu {
            Button(silent ? "Unmute" : "Mute", systemImage: silent ? "speaker.wave.2" : "speaker.slash") { model.toggleMute(app) }
            Button("Reset to 100%", systemImage: "arrow.counterclockwise") { model.reset(app) }
                .disabled(!app.preference.needsProcessing)
            if let error = app.error { Divider(); Text(error) }
        }
    }

    private var muteButton: some View {
        Button { model.toggleMute(app) } label: {
            Image(nsImage: app.icon).resizable().interpolation(.high)
                .frame(width: 28, height: 28)
                .saturation(silent ? 0 : 1).opacity(silent ? 0.55 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if silent || hoveringIcon {
                        Image(systemName: silent ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(silent ? Color.white : Color.primary)
                            .frame(width: 15, height: 15)
                            .background(silent ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.regularMaterial), in: .circle)
                            .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                            .offset(x: 3, y: 3)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hoveringIcon = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: hoveringIcon)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: silent)
        .accessibilityLabel("\(silent ? "Unmute" : "Mute") \(app.name)")
        .help(silent ? "Unmute \(app.name)" : "Mute \(app.name)")
    }

    /// Room left for the name beside the level strip and value. Applied to every
    /// row, playing or not, so all names truncate at the same point.
    private static let nameWidth: CGFloat = {
        let capsule = MixerView.width - 2 * MixerView.inset - 28 - 10
        return capsule - 2 * 12 - ActivityBars.width - 32 - 2 * 8 - 4
    }()

    private var labels: some View {
        HStack(spacing: 8) {
            Text(app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                .foregroundStyle(silent ? .secondary : .primary)
                .frame(maxWidth: Self.nameWidth, alignment: .leading)
            Spacer(minLength: 4)
            if app.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
            } else if glowing && app.activity.hasHistory {
                ActivityBars(activity: app.activity, color: ink, paused: !model.isPanelVisible)
                    .frame(height: 14)
                    .transition(.opacity)
            }
            ValueLabel(value: app.preference.volume, muted: muted)
        }
        .padding(.leading, 12).padding(.trailing, 12)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: glowing && app.activity.hasHistory)
    }
}

/// Activity shown as light inside the fill instead of a separate meter: the
/// leading edge of the fill glows with the app's measured level and fades when
/// the app goes quiet. It sits in the same geometry as the slider fill.
private struct LevelGlow: View {
    let level: Float
    let volume: Double
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let fill = VolumeSlider.fillWidth(volume, in: proxy.size.width, height: height)
            let ink = colorScheme == .dark ? tint.mix(with: .white, by: 0.45) : tint.mix(with: .white, by: 0.2)
            let glow = min(fill, max(height * 2.2, fill * 0.55))
            Rectangle()
                .fill(LinearGradient(stops: [
                    .init(color: ink.opacity(0), location: 0),
                    .init(color: ink.opacity(colorScheme == .dark ? 0.55 : 0.5), location: 1)
                ], startPoint: .leading, endPoint: .trailing))
                .frame(width: glow, height: height)
                .offset(x: fill - glow)
                .frame(width: proxy.size.width, height: height, alignment: .leading)
                // The slider fill's shape: a capsule ending at the fill edge, clipped to the track.
                .mask(alignment: .leading) {
                    Capsule().frame(width: fill + height, height: height).offset(x: -height)
                }
                .clipShape(Capsule())
                .opacity(Double(min(1, level * 1.35)))
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared pieces

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ValueLabel: View {
    let value: Double
    let muted: Bool
    var body: some View {
        Text(muted ? "Muted" : "\(Int((value * 100).rounded()))%")
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
            .frame(minWidth: 32, alignment: .trailing)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A full-width row that highlights on hover, like the last item of a system menu extra.
private struct MenuRowButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 26)
                .background(.primary.opacity(hovering ? 0.08 : 0), in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }
}

private struct CircleButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? .primary : .tertiary)
            .background(.primary.opacity(configuration.isPressed ? 0.16 : (filled ? 0.08 : 0)), in: .circle)
            .contentShape(.circle)
    }
}

private struct HoverCircle: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(.primary.opacity(hovering ? 0.08 : 0), in: .circle)
            .onHover { hovering = $0 }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}
