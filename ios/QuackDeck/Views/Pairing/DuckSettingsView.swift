import SwiftUI

enum DuckSettingsTarget: Identifiable, Hashable {
    case paired(robotId: String)
    case demo

    var id: String {
        switch self {
        case .paired(let robotId):
            return "paired-\(robotId)"
        case .demo:
            return "demo"
        }
    }
}

struct DuckSettingsView: View {
    let appState: AppState
    let target: DuckSettingsTarget

    @State private var draftVolume: Double = 75
    @State private var isEditingVolumeSlider: Bool = false
    @State private var isSavingVolume: Bool = false
    @State private var lastNonZeroVolume: UInt8 = 70
    @State private var volumeErrorMessage: String?
    @State private var failedTargetVolume: UInt8?

    private var duckId: String {
        switch target {
        case .paired(let robotId):
            return robotId
        case .demo:
            return appState.demoSessionInstance?.currentRobotId ?? "demo-duck"
        }
    }

    private var pairedDuck: PairedDuck? {
        guard case .paired(let robotId) = target else { return nil }
        return appState.pairedDucks.first(where: { $0.robotId == robotId })
    }

    private var isTargetActive: Bool {
        switch target {
        case .demo:
            return appState.isDemoMode && appState.isActiveSessionReachableForSettings
        case .paired(let robotId):
            return !appState.isDemoMode
                && appState.currentRobotId == robotId
                && appState.isActiveSessionReachableForSettings
        }
    }

    private var duckName: String {
        if isTargetActive {
            let liveName = appState.currentDuckName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !liveName.isEmpty {
                return liveName
            }
        }
        return pairedDuck?.name ?? duckId
    }

    private var preferences: DuckPreferences {
        appState.preferences(for: duckId)
    }

    private var connectionSubtitle: String {
        switch target {
        case .demo:
            return isTargetActive ? "\(duckId) · Demo Mode" : "\(duckId) · Offline"
        case .paired:
            guard isTargetActive else {
                return "\(duckId) · Offline"
            }
            return appState.phase == .configuringWifi
                ? "\(duckId) · Connected via Bluetooth"
                : "\(duckId) · Connected on LAN"
        }
    }

    private var statusDotColor: Color {
        guard isTargetActive else { return QuackTheme.duckOrange }
        return appState.phase == .configuringWifi ? QuackTheme.warnYellow : QuackTheme.okGreen
    }

    var body: some View {
        ZStack {
            QuackTheme.inkBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusHeaderCard
                    drivingSection
                    speakerAudioSection
                }
                .padding(16)
            }
        }
        .navigationTitle("\(duckName) Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            syncDraftFromTelemetry()
        }
        .onChange(of: appState.telemetry.volumeStatus) { _, _ in
            syncDraftFromTelemetry()
        }
        .task(id: target) {
            if isTargetActive {
                await appState.refreshSpeakerVolume()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var statusHeaderCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(duckName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(QuackTheme.creamText)
                    .lineLimit(1)

                Text(connectionSubtitle)
                    .font(QuackTheme.monoValue(size: 11, weight: .medium))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                QuackHaptics.light()
                appState.resetPreferences(for: duckId)
            } label: {
                Text("Reset")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        preferences.isCustomSpeedLimit
                            ? QuackTheme.duckOrange
                            : QuackTheme.creamText.opacity(0.35)
                    )
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                preferences.isCustomSpeedLimit
                                    ? QuackTheme.duckOrange.opacity(0.16)
                                    : QuackTheme.creamText.opacity(0.06)
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.quackTouch)
            .disabled(!preferences.isCustomSpeedLimit)
            .accessibilityLabel("Reset driving speed to default")
        }
        .padding(14)
        .quackInsetCard(cornerRadius: 18)
    }

    private var drivingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("DRIVING (SAVED ON THIS IPHONE)")

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top Walk Speed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(QuackTheme.creamText)
                        Text("Caps full thumbstick forward and strafe")
                            .font(.caption)
                            .foregroundStyle(QuackTheme.creamText.opacity(0.6))
                    }

                    Spacer(minLength: 8)

                    Text(String(format: "%.2f m/s", preferences.maxLinearSpeed))
                        .font(QuackTheme.monoValue(size: 17, weight: .bold))
                        .foregroundStyle(QuackTheme.duckOrange)
                }

                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { preferences.maxLinearSpeed },
                            set: { newValue in
                                appState.updateMaxLinearSpeed(newValue, for: duckId)
                            }
                        ),
                        in: DuckPreferences.maxLinearSpeedRange,
                        step: DuckPreferences.maxLinearSpeedStep
                    )
                    .tint(QuackTheme.duckOrange)
                    .accessibilityLabel("Top walk speed")
                    .accessibilityValue(String(format: "%.2f meters per second", preferences.maxLinearSpeed))

                    HStack {
                        Text("0.05 m/s")
                        Spacer()
                        Text("0.30 m/s")
                    }
                    .font(QuackTheme.monoValue(size: 11, weight: .medium))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.5))
                }

                HStack(spacing: 8) {
                    ForEach(DuckPreferences.speedPresets, id: \.self) { preset in
                        let isSelected = abs(preferences.maxLinearSpeed - preset) < 0.001
                        Button {
                            QuackHaptics.light()
                            appState.updateMaxLinearSpeed(preset, for: duckId)
                        } label: {
                            Text(String(format: "%.2f", preset))
                                .font(QuackTheme.monoValue(size: 13, weight: .bold))
                                .foregroundStyle(isSelected ? QuackTheme.inkSurface : QuackTheme.creamText.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .frame(height: QuackTheme.minTouchTarget)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(isSelected ? QuackTheme.duckOrange : QuackTheme.creamText.opacity(0.08))
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.quackTouch)
                        .accessibilityLabel(String(format: "Set top walk speed to %.2f meters per second", preset))
                    }
                }

                Text("Default 0.30 m/s · Turn speed fixed at 1.50 rad/s")
                    .font(.caption)
                    .foregroundStyle(QuackTheme.creamText.opacity(0.5))
            }
            .padding(14)
            .quackInsetCard(cornerRadius: 18)
        }
    }

    private var speakerAudioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("SPEAKER AUDIO (STORED ON ROBOT)")
                Spacer()
                Text(volumeStatusLabel)
                    .font(QuackTheme.monoValue(size: 11, weight: .semibold))
                    .foregroundStyle(volumeStatusColor)
            }

            if !isTargetActive {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect to \(duckName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(QuackTheme.creamText)
                    Text("Speaker volume is stored on the robot. Connect to \(duckName) over Wi-Fi or Bluetooth to view or change it.")
                        .font(.caption)
                        .foregroundStyle(QuackTheme.creamText.opacity(0.6))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .quackInsetCard(cornerRadius: 18)
            } else {
                switch appState.telemetry.volumeStatus {
                case .unknown, .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(QuackTheme.acidCyan)
                            .scaleEffect(0.85)
                        Text("Reading robot speaker volume...")
                            .font(.caption)
                            .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quackInsetCard(cornerRadius: 18)

                case .unsupported:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speaker volume unavailable")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(QuackTheme.creamText)
                        Text("This robot software version does not support robot.volume.")
                            .font(.caption)
                            .foregroundStyle(QuackTheme.creamText.opacity(0.6))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quackInsetCard(cornerRadius: 18)

                case .failed(let detail):
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Could not read speaker volume")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(QuackTheme.creamText)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(QuackTheme.dangerRed)
                        Button {
                            QuackHaptics.light()
                            Task { await appState.refreshSpeakerVolume() }
                        } label: {
                            Text("Retry")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(QuackTheme.acidCyan)
                                .frame(maxWidth: .infinity)
                                .frame(height: QuackTheme.minTouchTarget)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(QuackTheme.acidCyan.opacity(0.14))
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.quackTouch)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quackInsetCard(cornerRadius: 18)

                case .loaded(let result):
                    loadedSpeakerCard(result: result)
                }
            }
        }
    }

    private func loadedSpeakerCard(result: VolumeResult) -> some View {
        let shownVolume = isEditingVolumeSlider ? Int(draftVolume.rounded()) : Int(result.volume)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speaker Volume")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(QuackTheme.creamText)
                    Text("Applied immediately and kept after reboot")
                        .font(.caption)
                        .foregroundStyle(QuackTheme.creamText.opacity(0.6))
                }

                Spacer(minLength: 8)

                Text(shownVolume == 0 ? "Muted" : "\(shownVolume)%")
                    .font(QuackTheme.monoValue(size: 17, weight: .bold))
                    .foregroundStyle(QuackTheme.acidCyan)
            }

            HStack(spacing: 10) {
                Button {
                    QuackHaptics.light()
                    let targetVol: UInt8 = result.volume == 0 ? lastNonZeroVolume : 0
                    Task { await commitVolume(targetVol) }
                } label: {
                    Image(systemName: volumeIcon(for: shownVolume))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(shownVolume == 0 ? QuackTheme.creamText.opacity(0.55) : QuackTheme.acidCyan)
                        .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                        .background(
                            Circle().fill(
                                shownVolume == 0
                                    ? QuackTheme.creamText.opacity(0.08)
                                    : QuackTheme.acidCyan.opacity(0.14)
                            )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.quackTouch)
                .disabled(isSavingVolume)
                .accessibilityLabel(result.volume == 0 ? "Unmute speaker" : "Mute speaker")

                Slider(
                    value: $draftVolume,
                    in: 0...100,
                    step: 5,
                    onEditingChanged: { editing in
                        isEditingVolumeSlider = editing
                        if !editing {
                            let targetVol = UInt8(max(0, min(100, Int(draftVolume.rounded()))))
                            if targetVol != result.volume {
                                Task { await commitVolume(targetVol) }
                            }
                        }
                    }
                )
                .tint(QuackTheme.acidCyan)
                .accessibilityLabel("Robot speaker volume")
                .accessibilityValue("\(shownVolume) percent")
            }

            HStack(spacing: 8) {
                Button {
                    Task { await appState.playTestQuack() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: QuackIcon.soundTest)
                            .font(.system(size: 14, weight: .semibold))
                        Text("Test Quack")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(QuackTheme.duckOrange)
                    .frame(maxWidth: .infinity)
                    .frame(height: QuackTheme.minTouchTarget)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(QuackTheme.duckOrange.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(QuackTheme.duckOrange.opacity(0.35), lineWidth: 1)
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.quackTouch)

                Button {
                    QuackHaptics.light()
                    let targetVol = UInt8(max(0, Int(result.volume) - 10))
                    Task { await commitVolume(targetVol) }
                } label: {
                    Image(systemName: QuackIcon.minus)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(QuackTheme.creamText)
                        .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(QuackTheme.creamText.opacity(0.10))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.quackTouch)
                .disabled(isSavingVolume || result.volume == 0)
                .accessibilityLabel("Decrease speaker volume by 10 percent")

                Button {
                    QuackHaptics.light()
                    let targetVol = UInt8(min(100, Int(result.volume) + 10))
                    Task { await commitVolume(targetVol) }
                } label: {
                    Image(systemName: QuackIcon.plus)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(QuackTheme.creamText)
                        .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(QuackTheme.creamText.opacity(0.10))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.quackTouch)
                .disabled(isSavingVolume || result.volume >= 100)
                .accessibilityLabel("Increase speaker volume by 10 percent")
            }

            if !result.applies {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: QuackIcon.statusError)
                        .font(.system(size: 13, weight: .semibold))
                    Text("Saved on robot, but this robot has no controllable speaker mixer or audio is off.")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(QuackTheme.warnYellow)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(QuackTheme.warnYellow.opacity(0.14))
                )
            }

            if let volumeErrorMessage {
                HStack(spacing: 8) {
                    Text(volumeErrorMessage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(QuackTheme.dangerRed)
                    Spacer(minLength: 6)
                    if let retryVol = failedTargetVolume {
                        Button("Retry") {
                            Task { await commitVolume(retryVol) }
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(QuackTheme.creamText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(QuackTheme.dangerRed.opacity(0.28))
                        )
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(QuackTheme.dangerRed.opacity(0.14))
                )
            }
        }
        .padding(14)
        .quackInsetCard(cornerRadius: 18)
    }

    private var volumeStatusLabel: String {
        guard isTargetActive else { return "Offline" }
        if isEditingVolumeSlider { return "Release to save" }
        if isSavingVolume { return "Saving..." }
        if volumeErrorMessage != nil { return "Error" }
        switch appState.telemetry.volumeStatus {
        case .unknown, .loading:
            return "Syncing..."
        case .loaded(let result):
            return result.applies ? "Synced" : "No mixer"
        case .unsupported:
            return "Unsupported"
        case .failed:
            return "Error"
        }
    }

    private var volumeStatusColor: Color {
        guard isTargetActive else { return QuackTheme.creamText.opacity(0.55) }
        if isEditingVolumeSlider || isSavingVolume { return QuackTheme.duckOrange }
        if volumeErrorMessage != nil { return QuackTheme.dangerRed }
        switch appState.telemetry.volumeStatus {
        case .unknown, .loading:
            return QuackTheme.creamText.opacity(0.6)
        case .loaded(let result):
            return result.applies ? QuackTheme.okGreen : QuackTheme.warnYellow
        case .unsupported:
            return QuackTheme.creamText.opacity(0.55)
        case .failed:
            return QuackTheme.dangerRed
        }
    }

    private func volumeIcon(for volume: Int) -> String {
        if volume <= 0 { return QuackIcon.volumeMuted }
        if volume < 35 { return QuackIcon.volumeLow }
        if volume < 70 { return QuackIcon.volumeMedium }
        return QuackIcon.volumeHigh
    }

    private func syncDraftFromTelemetry() {
        guard !isEditingVolumeSlider else { return }
        if case .loaded(let result) = appState.telemetry.volumeStatus {
            draftVolume = Double(result.volume)
            if result.volume > 0 {
                lastNonZeroVolume = result.volume
            }
        }
    }

    private func commitVolume(_ volume: UInt8) async {
        let clamped = min(100, volume)
        draftVolume = Double(clamped)
        volumeErrorMessage = nil
        failedTargetVolume = nil
        isSavingVolume = true
        defer { isSavingVolume = false }

        do {
            let result = try await appState.setSpeakerVolume(clamped)
            draftVolume = Double(result.volume)
            if result.volume > 0 {
                lastNonZeroVolume = result.volume
            }
        } catch is CancellationError {
            return
        } catch {
            QuackHaptics.error()
            failedTargetVolume = clamped
            if let confirmed = appState.telemetry.volumeStatus.currentVolume {
                draftVolume = Double(confirmed.volume)
                volumeErrorMessage = "\(error.localizedDescription) Reverted to \(confirmed.volume)%."
            } else {
                volumeErrorMessage = error.localizedDescription
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(QuackTheme.condensedDisplay(size: 13))
            .foregroundStyle(QuackTheme.creamText.opacity(0.65))
            .tracking(0.6)
    }
}
