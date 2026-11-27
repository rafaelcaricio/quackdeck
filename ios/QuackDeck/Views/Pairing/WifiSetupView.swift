import SwiftUI

struct WifiSetupView: View {
    let appState: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var networks: [WifiNetwork] = []
    @State private var isScanning: Bool = false
    @State private var isConnecting: Bool = false
    @State private var scanError: String?
    @State private var connectMessage: (text: String, isError: Bool)?
    @State private var unsupportedNotice: String?

    @State private var networkForPassword: WifiNetwork?
    @State private var passphrase: String = ""
    @State private var showPassphrase: Bool = false

    private var netStatus: NetStatusResult? {
        appState.telemetry.netStatus
    }

    var body: some View {
        ZStack {
            QuackTheme.inkBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    currentStatusCard

                    if isConnecting || netStatus?.joining != nil {
                        joiningProgressCard
                    }

                    if let connectMessage {
                        let color = connectMessage.isError ? QuackTheme.dangerRed : QuackTheme.okGreen
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: connectMessage.isError ? QuackIcon.statusError : QuackIcon.statusSuccess)
                                .font(.system(size: 13, weight: .semibold))
                            Text(connectMessage.text)
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(color)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(color.opacity(0.14))
                        )
                    }

                    if let unsupportedNotice {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: QuackIcon.statusError)
                                .font(.system(size: 13, weight: .semibold))
                            Text(unsupportedNotice)
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(QuackTheme.warnYellow)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(QuackTheme.warnYellow.opacity(0.14))
                        )
                    }

                    networksSection
                }
                .padding(16)
            }
        }
        .navigationTitle("Robot Wi-Fi")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await runScan() }
                } label: {
                    Image(systemName: QuackIcon.refresh)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(QuackTheme.duckOrange)
                }
                .disabled(isScanning || isConnecting)
                .accessibilityLabel("Refresh Wi-Fi networks")
            }
        }
        .sheet(item: $networkForPassword) { network in
            passphrasePromptSheet(for: network)
                .presentationDetents([.medium])
        }
        .task {
            await appState.refreshNetStatus()
            await runScan()
        }
    }

    private var currentStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CURRENT LINK")
                    .font(QuackTheme.condensedDisplay(size: 13))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                Spacer()
                Text(statusStateLabel)
                    .font(QuackTheme.monoValue(size: 11, weight: .bold))
                    .foregroundStyle(statusColor)
            }

            if let netStatus {
                HStack {
                    Text(netStatus.ssid ?? "Not connected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(QuackTheme.creamText)
                    Spacer()
                    if let signal = netStatus.signal {
                        Text("\(signal)%")
                            .font(QuackTheme.monoValue(size: 12, weight: .semibold))
                            .foregroundStyle(QuackTheme.acidCyan)
                    }
                }

                if let ip4 = netStatus.ip4 {
                    HStack {
                        Text("IPv4: \(ip4)")
                            .font(QuackTheme.monoValue(size: 12, weight: .medium))
                            .foregroundStyle(QuackTheme.okGreen)
                        Spacer()
                        Text("LAN: \(appState.phase.shortLabel)")
                            .font(QuackTheme.monoValue(size: 11, weight: .semibold))
                            .foregroundStyle(appState.isConnected ? QuackTheme.okGreen : QuackTheme.acidCyan)
                    }
                }

                if let ssid = netStatus.ssid {
                    Button {
                        Task { await forgetNetwork(ssid: ssid) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: QuackIcon.delete)
                                .font(.system(size: 14, weight: .semibold))
                            Text("Forget \(ssid)")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(QuackTheme.dangerRed)
                        .frame(maxWidth: .infinity, minHeight: QuackTheme.minTouchTarget)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(QuackTheme.dangerRed.opacity(0.14))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.quackTouch)
                    .padding(.top, 4)
                    .disabled(isConnecting)
                }
            } else {
                Text("Reading robot Wi-Fi status...")
                    .font(.caption)
                    .foregroundStyle(QuackTheme.creamText.opacity(0.55))
            }
        }
        .padding(14)
        .quackInsetCard(cornerRadius: 18)
    }

    private var joiningProgressCard: some View {
        let joining = netStatus?.joining
        let currentIndex = joining?.step.stepIndex ?? 0
        let steps = ["Scanning", "Associating", "Authenticating", "Addressing"]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("JOINING \(joining?.ssid.uppercased() ?? "WI-FI")")
                    .font(QuackTheme.condensedDisplay(size: 13))
                    .foregroundStyle(QuackTheme.acidCyan)
                Spacer()
                if let joining {
                    Text("\(joining.elapsed_seconds)s / \(joining.timeout_seconds)s")
                        .font(QuackTheme.monoValue(size: 11, weight: .medium))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                }
            }

            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { idx, title in
                    let isDone = idx < currentIndex
                    let isCurrent = idx == currentIndex
                    let isRejected = joining?.step == .keyRejected && idx == 2
                    let pillColor: Color = isRejected
                        ? QuackTheme.dangerRed
                        : (isDone ? QuackTheme.okGreen : (isCurrent ? QuackTheme.duckOrange : QuackTheme.creamText.opacity(0.35)))

                    VStack(spacing: 4) {
                        Capsule()
                            .fill(pillColor)
                            .frame(height: 4)
                        Text(title)
                            .font(.system(size: 9, weight: isCurrent ? .bold : .medium))
                            .foregroundStyle(pillColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
            }

            if let step = joining?.step {
                Text(step == .keyRejected ? "Key rejected — verifying password error..." : step.displayLabel)
                    .font(.caption)
                    .foregroundStyle(step == .keyRejected ? QuackTheme.dangerRed : QuackTheme.creamText.opacity(0.7))
            }
        }
        .padding(14)
        .quackInsetCard(cornerRadius: 18)
    }

    private var networksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AVAILABLE NETWORKS")
                    .font(QuackTheme.condensedDisplay(size: 13))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                Spacer()
                if isScanning {
                    ProgressView()
                        .tint(QuackTheme.duckOrange)
                        .scaleEffect(0.8)
                }
            }

            if let scanError {
                Text(scanError)
                    .font(.caption)
                    .foregroundStyle(QuackTheme.dangerRed)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quackInsetCard(cornerRadius: 16)
            } else if networks.isEmpty && !isScanning {
                Text("No Wi-Fi networks found. Tap refresh to scan again.")
                    .font(.caption)
                    .foregroundStyle(QuackTheme.creamText.opacity(0.55))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quackInsetCard(cornerRadius: 16)
            } else if !networks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(networks.enumerated()), id: \.element.id) { idx, network in
                        networkRow(network)
                        if idx < networks.count - 1 {
                            Divider().overlay(QuackTheme.subtleBorder)
                        }
                    }
                }
                .quackInsetCard(cornerRadius: 18)
            }
        }
    }

    private func networkRow(_ network: WifiNetwork) -> some View {
        HStack(spacing: QuackTheme.controlSpacing) {
            Button {
                handleTap(network)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: QuackIcon.wifi, variableValue: wifiSignalFraction(for: network.signal))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(network.security.isSupported ? QuackTheme.acidCyan : QuackTheme.creamText.opacity(0.35))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(network.ssid)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(network.security.isSupported ? QuackTheme.creamText : QuackTheme.creamText.opacity(0.45))

                            if network.saved {
                                badge("Saved", color: QuackTheme.okGreen)
                            }
                        }

                        HStack(spacing: 6) {
                            badge(
                                network.security.displayBadge,
                                color: network.security.isSupported ? QuackTheme.creamText.opacity(0.75) : QuackTheme.warnYellow
                            )
                            Text("\(network.signal)%")
                                .font(QuackTheme.monoValue(size: 11, weight: .medium))
                                .foregroundStyle(QuackTheme.creamText.opacity(0.55))
                        }
                    }

                    Spacer()

                    if !network.security.isSupported {
                        Text("Unsupported")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(QuackTheme.warnYellow)
                    } else {
                        Image(systemName: QuackIcon.chevronRight)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(QuackTheme.creamText.opacity(0.45))
                    }
                }
                .frame(minHeight: QuackTheme.secondaryButtonHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.quackRow)
            .disabled(isConnecting)

            if network.saved {
                Button {
                    Task { await forgetNetwork(ssid: network.ssid) }
                } label: {
                    Image(systemName: QuackIcon.delete)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                        .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                        .background(Circle().fill(QuackTheme.creamText.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.quackTouch)
                .disabled(isConnecting)
                .accessibilityLabel("Forget \(network.ssid)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func passphrasePromptSheet(for network: WifiNetwork) -> some View {
        NavigationStack {
            ZStack {
                QuackTheme.inkBg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Enter Wi-Fi password for \(network.ssid) (\(network.security.displayBadge)).")
                        .font(.subheadline)
                        .foregroundStyle(QuackTheme.creamText.opacity(0.8))

                    if let connectMessage, connectMessage.isError {
                        Text(connectMessage.text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(QuackTheme.dangerRed)
                    }

                    HStack(spacing: 8) {
                        Group {
                            if showPassphrase {
                                TextField("Password", text: $passphrase)
                            } else {
                                SecureField("Password", text: $passphrase)
                            }
                        }
                        .font(QuackTheme.monoValue(size: 15, weight: .medium))
                        .foregroundStyle(QuackTheme.creamText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            showPassphrase.toggle()
                        } label: {
                            Image(systemName: showPassphrase ? QuackIcon.eyeSlash : QuackIcon.eye)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(QuackTheme.creamText.opacity(0.75))
                                .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.quackTouch)
                        .accessibilityLabel(showPassphrase ? "Hide password" : "Show password")
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(QuackTheme.inkSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(QuackTheme.subtleBorder, lineWidth: 1)
                            )
                    )

                    Button {
                        let chosen = network
                        let psk = passphrase
                        networkForPassword = nil
                        Task { await connect(network: chosen, psk: psk) }
                    } label: {
                        Text("Join \(network.ssid)")
                            .font(.body.weight(.bold))
                            .foregroundStyle(QuackTheme.inkSurface)
                            .frame(maxWidth: .infinity)
                            .frame(height: QuackTheme.primaryButtonHeight)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(passphrase.isEmpty ? QuackTheme.duckOrange.opacity(0.35) : QuackTheme.duckOrange)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.quackTouch)
                    .disabled(passphrase.isEmpty)

                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("Wi-Fi Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        networkForPassword = nil
                    }
                    .foregroundStyle(QuackTheme.creamText.opacity(0.7))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(QuackTheme.monoValue(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var statusStateLabel: String {
        switch netStatus?.state {
        case .connected: return "CONNECTED"
        case .connecting: return "CONNECTING"
        case .disconnected: return "DISCONNECTED"
        case .unavailable: return "UNAVAILABLE"
        case nil: return "--"
        }
    }

    private var statusColor: Color {
        switch netStatus?.state {
        case .connected: return QuackTheme.okGreen
        case .connecting: return QuackTheme.warnYellow
        case .disconnected: return QuackTheme.creamText.opacity(0.55)
        case .unavailable: return QuackTheme.dangerRed
        case nil: return QuackTheme.creamText.opacity(0.4)
        }
    }

    private func wifiSignalFraction(for signal: UInt8) -> Double {
        if signal >= 70 { return 1.0 }
        if signal >= 40 { return 0.6 }
        return 0.25
    }

    private func handleTap(_ network: WifiNetwork) {
        unsupportedNotice = nil
        connectMessage = nil

        guard network.security.isSupported else {
            unsupportedNotice = "\(network.ssid) uses \(network.security.displayBadge), which is not supported. Choose Open, WPA2, or WPA3."
            return
        }

        if network.saved || !network.security.requiresPassword {
            Task { await connect(network: network, psk: nil) }
        } else {
            passphrase = ""
            networkForPassword = network
        }
    }

    private func runScan() async {
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        do {
            networks = try await appState.scanWifiNetworks()
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func connect(network: WifiNetwork, psk: String?) async {
        isConnecting = true
        connectMessage = nil
        unsupportedNotice = nil
        defer { isConnecting = false }

        do {
            let result = try await appState.connectWifi(ssid: network.ssid, psk: psk)
            switch result {
            case .connected(let ssid, let ip4):
                if let ip4, !ip4.isEmpty {
                    connectMessage = ("Connected to \(ssid) (\(ip4)). Switching to LAN video...", false)
                    QuackHaptics.success()
                } else {
                    connectMessage = ("Associated with \(ssid). Waiting for IP address...", false)
                }
                await runScan()
            case .failed(let reason, _):
                QuackHaptics.error()
                connectMessage = (reason.userMessage, true)
                if reason == .badKey && network.security.requiresPassword {
                    passphrase = ""
                    networkForPassword = network
                }
            }
        } catch {
            QuackHaptics.error()
            connectMessage = (error.localizedDescription, true)
        }
    }

    private func forgetNetwork(ssid: String) async {
        do {
            let removed = try await appState.forgetWifi(ssid: ssid)
            await runScan()
            if removed {
                connectMessage = ("Removed saved network \(ssid).", false)
            } else {
                let stillSaved = networks.first(where: { $0.ssid == ssid })?.saved ?? false
                connectMessage = stillSaved
                    ? ("Could not remove saved network \(ssid).", true)
                    : ("Network \(ssid) was already absent.", false)
            }
        } catch {
            connectMessage = (error.localizedDescription, true)
        }
    }
}
