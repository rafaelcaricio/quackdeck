import SwiftUI

struct DucksSheetView: View {
    let appState: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var setupTarget: SetupTarget?
    @State private var settingsTarget: DuckSettingsTarget?
    @State private var showWifiSetup: Bool = false
    @State private var showLicenses: Bool = false
    @State private var duckPendingForget: PairedDuck?
    @State private var actionError: String?

    init(appState: AppState) {
        self.appState = appState
    }

    private struct SetupTarget: Identifiable, Hashable {
        let id = UUID()
        let peripheralId: UUID?
        let name: String?
    }

    var body: some View {
        NavigationStack {
            ZStack {
                QuackTheme.inkBg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let active = appState.activeSession, !appState.isDemoMode {
                            activeRobotSection(active)
                        }

                        demoModeCard

                        pairedDucksSection

                        nearbyBleSection

                        Button {
                            setupTarget = SetupTarget(peripheralId: nil, name: nil)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: QuackIcon.qrScanner)
                                    .font(.system(size: 17, weight: .semibold))
                                Text("Pair with Setup Code")
                                    .font(.body.weight(.bold))
                            }
                            .foregroundStyle(QuackTheme.inkSurface)
                            .frame(maxWidth: .infinity)
                            .frame(height: QuackTheme.primaryButtonHeight)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(QuackTheme.duckOrange)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.quackTouch)

                        licensesLinkRow
                    }
                    .padding(16)
                }
            }
            .navigationTitle("My Ducks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        appState.stopBleScan()
                        appState.isDucksSheetPresented = false
                        dismiss()
                    }
                    .foregroundStyle(QuackTheme.duckOrange)
                    .fontWeight(.semibold)
                }
            }
            .navigationDestination(item: $setupTarget) { target in
                SetupCodeEntryView(
                    appState: appState,
                    targetPeripheralId: target.peripheralId,
                    targetName: target.name,
                    onOpenWifiSetup: {
                        setupTarget = nil
                        showWifiSetup = true
                    },
                    onConnected: {
                        appState.stopBleScan()
                        appState.isDucksSheetPresented = false
                        dismiss()
                    }
                )
            }
            .navigationDestination(isPresented: $showWifiSetup) {
                WifiSetupView(appState: appState)
            }
            .navigationDestination(isPresented: $showLicenses) {
                LicensesView()
            }
            .navigationDestination(item: $settingsTarget) { target in
                DuckSettingsView(appState: appState, target: target)
            }
            .alert("Forget Duck?", isPresented: Binding(
                get: { duckPendingForget != nil },
                set: { if !$0 { duckPendingForget = nil } }
            )) {
                Button("Cancel", role: .cancel) { duckPendingForget = nil }
                Button("Forget", role: .destructive) {
                    if let duck = duckPendingForget {
                        do {
                            try appState.forgetDuck(duck)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                    duckPendingForget = nil
                }
            } message: {
                if let duck = duckPendingForget {
                    Text("Remove \(duck.name) and its saved key from this iPhone?")
                }
            }
            .alert("Connection Notice", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .onAppear {
                appState.startBleScan()
            }
            .onDisappear {
                if setupTarget == nil && settingsTarget == nil && !showWifiSetup && !showLicenses {
                    appState.stopBleScan()
                }
            }
            .onChange(of: appState.isDucksSheetPresented) { _, presented in
                if !presented {
                    appState.stopBleScan()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func activeRobotSection(_ session: any RobotSessionTransport) -> some View {
        let phaseError: String? = {
            if case .error(let detail) = session.phase { return detail }
            return nil
        }()
        let displayedError = session.telemetry.lastError ?? phaseError

        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("ACTIVE DUCK")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(session.phase.isConnected ? QuackTheme.okGreen : (session.telemetry.isPoweredOff ? QuackTheme.creamText.opacity(0.35) : QuackTheme.warnYellow))
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.currentDuckName)
                            .font(.headline)
                            .foregroundStyle(QuackTheme.creamText)

                        let statusLabel = session.telemetry.isPoweredOff && session.phase == .disconnected
                            ? "Powered Off"
                            : session.phase.shortLabel
                        Text("\(statusLabel)\(session.currentIpAddress.map { " · \($0)" } ?? "")")
                            .font(QuackTheme.monoValue(size: 12, weight: .medium))
                            .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.2f m/s", appState.activeMaxLinearSpeed))
                            .font(QuackTheme.monoValue(size: 11, weight: .semibold))
                            .foregroundStyle(QuackTheme.duckOrange)
                        if let vol = session.telemetry.volumeStatus.currentVolume {
                            Text("Vol \(vol.volume)%")
                                .font(QuackTheme.monoValue(size: 11, weight: .semibold))
                                .foregroundStyle(QuackTheme.acidCyan)
                        }
                    }
                }

                if let activeRobotId = session.currentRobotId ?? appState.lastConnectedDuck?.robotId {
                    let speedSummary = String(format: "%.2f m/s", appState.activeMaxLinearSpeed)
                    let volumeSummary = session.telemetry.volumeStatus.currentVolume.map { " · \($0.volume)%" } ?? ""

                    Button {
                        QuackHaptics.light()
                        settingsTarget = .paired(robotId: activeRobotId)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: QuackIcon.settings)
                                .font(.system(size: 15, weight: .semibold))
                            Text("Duck Settings")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(speedSummary)\(volumeSummary)")
                                .font(QuackTheme.monoValue(size: 12, weight: .medium))
                                .foregroundStyle(QuackTheme.duckOrange.opacity(0.9))
                            Image(systemName: QuackIcon.chevronRight)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(QuackTheme.duckOrange)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: QuackTheme.secondaryButtonHeight)
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
                }

                if session.telemetry.isAutoReconnecting {
                    let attempt = max(1, session.telemetry.reconnectAttempt)
                    let reconnectText: String = {
                        if let secs = session.telemetry.nextRetrySeconds, secs > 0 {
                            return "Auto-retrying in \(secs)s (attempt \(attempt))"
                        }
                        return "Reconnecting (attempt \(attempt))..."
                    }()
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(QuackTheme.warnYellow)
                        Text(reconnectText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(QuackTheme.warnYellow)
                    }
                }

                if let err = displayedError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(QuackTheme.dangerRed)
                }

                Button {
                    QuackHaptics.medium()
                    Task { await appState.forceReconnect() }
                } label: {
                    HStack(spacing: 8) {
                        if appState.isRetryingConnection {
                            ProgressView()
                                .controlSize(.small)
                                .tint(QuackTheme.duckOrange)
                        } else {
                            Image(systemName: QuackIcon.refresh)
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text(appState.isRetryingConnection ? "Reconnecting..." : (session.telemetry.isPoweredOff ? "Reconnect" : "Force Reconnect"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(QuackTheme.duckOrange)
                    .frame(maxWidth: .infinity)
                    .frame(height: QuackTheme.secondaryButtonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(QuackTheme.duckOrange.opacity(0.16))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.quackTouch)
                .disabled(appState.isRetryingConnection)

                HStack(spacing: 12) {
                    Button {
                        showWifiSetup = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: QuackIcon.wifi)
                                .font(.system(size: 15, weight: .semibold))
                            Text("Wi-Fi Setup")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(QuackTheme.acidCyan)
                        .frame(maxWidth: .infinity)
                        .frame(height: QuackTheme.secondaryButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(QuackTheme.acidCyan.opacity(0.14))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.quackTouch)

                    Button {
                        Task { await appState.disconnect() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: QuackIcon.disconnect)
                                .font(.system(size: 15, weight: .semibold))
                            Text("Disconnect")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(QuackTheme.dangerRed)
                        .frame(maxWidth: .infinity)
                        .frame(height: QuackTheme.secondaryButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(QuackTheme.dangerRed.opacity(0.14))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.quackTouch)
                }
            }
            .padding(14)
            .quackInsetCard(cornerRadius: 18)
        }
    }

    private var demoModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Offline Demo Mode")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(QuackTheme.creamText)
                    Text("Simulate video, ToF, IMUs, and joints without hardware")
                        .font(.caption)
                        .foregroundStyle(QuackTheme.creamText.opacity(0.6))
                }

                Spacer(minLength: 8)

                Toggle("", isOn: Binding(
                    get: { appState.isDemoMode },
                    set: { enabled in
                        if enabled {
                            appState.stopBleScan()
                            appState.startDemoMode()
                            dismiss()
                        } else {
                            Task { await appState.disconnect() }
                        }
                    }
                ))
                .labelsHidden()
                .tint(QuackTheme.duckOrange)
            }

            if appState.isDemoMode {
                let speedSummary = String(format: "%.2f m/s", appState.activeMaxLinearSpeed)
                let volumeSummary = appState.telemetry.volumeStatus.currentVolume.map { " · \($0.volume)%" } ?? ""

                Button {
                    QuackHaptics.light()
                    settingsTarget = .demo
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: QuackIcon.settings)
                            .font(.system(size: 15, weight: .semibold))
                        Text("Demo Settings")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(speedSummary)\(volumeSummary)")
                            .font(QuackTheme.monoValue(size: 12, weight: .medium))
                            .foregroundStyle(QuackTheme.duckOrange.opacity(0.9))
                        Image(systemName: QuackIcon.chevronRight)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(QuackTheme.duckOrange)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: QuackTheme.secondaryButtonHeight)
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
            }
        }
        .padding(14)
        .quackInsetCard(cornerRadius: 18)
    }

    private var pairedDucksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("PAIRED DUCKS")

            if appState.pairedDucks.isEmpty {
                Text("No saved ducks yet. Pick a nearby Bluetooth duck or enter a setup code.")
                    .font(.caption)
                    .foregroundStyle(QuackTheme.creamText.opacity(0.55))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quackInsetCard(cornerRadius: 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appState.pairedDucks.enumerated()), id: \.element.id) { idx, duck in
                        pairedDuckRow(duck)
                        if idx < appState.pairedDucks.count - 1 {
                            Divider().overlay(QuackTheme.subtleBorder)
                        }
                    }
                }
                .quackInsetCard(cornerRadius: 18)
            }
        }
    }

    private func pairedDuckRow(_ duck: PairedDuck) -> some View {
        let isCurrent = !appState.isDemoMode && appState.currentRobotId == duck.robotId
        let isRowConnecting = appState.connectingRobotId == duck.robotId
        return HStack(spacing: QuackTheme.controlSpacing) {
            Button {
                Task {
                    await appState.connectToPairedDuck(duck)
                    if appState.phase == .configuringWifi {
                        showWifiSetup = true
                    } else if appState.phase.isConnected {
                        appState.stopBleScan()
                        appState.isDucksSheetPresented = false
                        dismiss()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if isRowConnecting {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(QuackTheme.duckOrange)
                            .frame(width: 9, height: 9)
                    } else {
                        Circle()
                            .fill(isCurrent && appState.isConnected ? QuackTheme.okGreen : QuackTheme.duckOrange)
                            .frame(width: 9, height: 9)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(duck.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(QuackTheme.creamText)
                            Text(duck.robotId)
                                .font(QuackTheme.monoValue(size: 11, weight: .medium))
                                .foregroundStyle(QuackTheme.duckOrange)
                        }
                        let baseDetail = duck.lastIp ?? "No saved IP · connects via Bluetooth"
                        let detailText = duck.preferences.isCustomSpeedLimit
                            ? "\(baseDetail) · Max \(String(format: "%.2f", duck.preferences.maxLinearSpeed)) m/s"
                            : baseDetail
                        Text(isRowConnecting ? "Connecting..." : detailText)
                            .font(QuackTheme.monoValue(size: 11, weight: .regular))
                            .foregroundStyle(isRowConnecting ? QuackTheme.duckOrange : QuackTheme.creamText.opacity(0.55))
                    }
                    Spacer()
                }
                .frame(minHeight: QuackTheme.secondaryButtonHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.quackRow)
            .disabled(appState.connectingRobotId != nil)

            if isCurrent {
                Button {
                    showWifiSetup = true
                } label: {
                    Image(systemName: QuackIcon.wifi)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(QuackTheme.acidCyan)
                        .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                        .background(Circle().fill(QuackTheme.acidCyan.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(.quackTouch)
                .accessibilityLabel("Wi-Fi Setup for \(duck.name)")
            }

            Button {
                QuackHaptics.light()
                settingsTarget = .paired(robotId: duck.robotId)
            } label: {
                Image(systemName: QuackIcon.settings)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        isCurrent || duck.preferences.isCustomSpeedLimit
                            ? QuackTheme.duckOrange
                            : QuackTheme.creamText.opacity(0.75)
                    )
                    .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                    .background(
                        Circle().fill(
                            isCurrent || duck.preferences.isCustomSpeedLimit
                                ? QuackTheme.duckOrange.opacity(0.16)
                                : QuackTheme.creamText.opacity(0.08)
                        )
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.quackTouch)
            .accessibilityLabel("Settings for \(duck.name)")

            Button {
                duckPendingForget = duck
            } label: {
                Image(systemName: QuackIcon.delete)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                    .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                    .background(Circle().fill(QuackTheme.creamText.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.quackTouch)
            .accessibilityLabel("Forget \(duck.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var nearbyBleSection: some View {
        let nearbyUnpaired = appState.unpairedDiscoveredDucks
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("NEARBY BLUETOOTH")
                Spacer()
                Text(appState.bluetoothStateText)
                    .font(QuackTheme.monoValue(size: 11, weight: .medium))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.55))
            }

            if nearbyUnpaired.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(QuackTheme.duckOrange)
                        .scaleEffect(0.85)
                    Text(appState.pairedDucks.isEmpty ? "Scanning for Microducks nearby..." : "Scanning for new Microducks nearby...")
                        .font(.caption)
                        .foregroundStyle(QuackTheme.creamText.opacity(0.6))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .quackInsetCard(cornerRadius: 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(nearbyUnpaired.enumerated()), id: \.element.id) { idx, duck in
                        discoveredDuckRow(duck)
                        if idx < nearbyUnpaired.count - 1 {
                            Divider().overlay(QuackTheme.subtleBorder)
                        }
                    }
                }
                .quackInsetCard(cornerRadius: 18)
            }
        }
    }

    private func discoveredDuckRow(_ duck: DiscoveredDuck) -> some View {
        Button {
            setupTarget = SetupTarget(peripheralId: duck.id, name: duck.name)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(duck.isConnectable ? (duck.hasNoWifi ? QuackTheme.warnYellow : QuackTheme.okGreen) : QuackTheme.creamText.opacity(0.3))
                    .frame(width: 9, height: 9)

                VStack(alignment: .leading, spacing: 2) {
                    Text(duck.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(duck.isConnectable ? QuackTheme.creamText : QuackTheme.creamText.opacity(0.45))

                    HStack(spacing: 6) {
                        if let ip = duck.advInfo.ipv4 {
                            Text(ip)
                                .font(QuackTheme.monoValue(size: 11, weight: .medium))
                                .foregroundStyle(QuackTheme.okGreen)
                        } else if duck.hasNoWifi {
                            Text("No Wi-Fi")
                                .font(QuackTheme.monoValue(size: 11, weight: .semibold))
                                .foregroundStyle(QuackTheme.warnYellow)
                        } else {
                            Text("Bluetooth")
                                .font(QuackTheme.monoValue(size: 11, weight: .medium))
                                .foregroundStyle(QuackTheme.creamText.opacity(0.5))
                        }

                        Text("· \(duck.rssi) dBm")
                            .font(QuackTheme.monoValue(size: 11, weight: .regular))
                            .foregroundStyle(QuackTheme.creamText.opacity(0.5))
                    }
                }

                Spacer()

                if duck.advInfo.isBusy {
                    Text("Busy")
                        .font(QuackTheme.monoValue(size: 11, weight: .bold))
                        .foregroundStyle(QuackTheme.warnYellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(QuackTheme.warnYellow.opacity(0.14)))
                } else {
                    HStack(spacing: 5) {
                        Text("Pair")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: QuackIcon.chevronRight)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(QuackTheme.duckOrange)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.quackRow)
        .disabled(!duck.isConnectable)
    }

    private var licensesLinkRow: some View {
        Button {
            showLicenses = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: QuackIcon.licenses)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                Text("Licenses & Notices")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.85))
                Spacer()
                Image(systemName: QuackIcon.chevronRight)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: QuackTheme.secondaryButtonHeight)
            .quackInsetCard(cornerRadius: 16)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.quackRow)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(QuackTheme.condensedDisplay(size: 13))
            .foregroundStyle(QuackTheme.creamText.opacity(0.65))
            .tracking(0.6)
    }
}
