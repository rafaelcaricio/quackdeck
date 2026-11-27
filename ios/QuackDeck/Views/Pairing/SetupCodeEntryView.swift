import AVFoundation
import SwiftUI
import UIKit

struct SetupCodeEntryView: View {
    let appState: AppState
    let targetPeripheralId: UUID?
    let targetName: String?
    var onOpenWifiSetup: (() -> Void)?
    var onConnected: (() -> Void)?

    @State private var codeText: String = ""
    @State private var isPairing: Bool = false
    @State private var hasSubmittedHere: Bool = false
    @State private var errorMessage: String?
    @State private var cameraStatusMessage: String?

    private var validationResult: Result<ParsedSetupCode, Error>? {
        let trimmed = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Result { try QuackDeckCore.parseSetupCode(trimmed) }
    }

    private var parsedCode: ParsedSetupCode? {
        try? validationResult?.get()
    }

    private var phaseErrorMessage: String? {
        if case .error(let detail) = appState.phase {
            return detail
        }
        return nil
    }

    private var displayedError: String? {
        errorMessage ?? (hasSubmittedHere ? (phaseErrorMessage ?? appState.telemetry.lastError) : nil)
    }

    private var isActivelyConnecting: Bool {
        isPairing || (hasSubmittedHere && !appState.telemetry.isAutoReconnecting && appState.phase == .connectingVideo)
    }

    var body: some View {
        ZStack {
            QuackTheme.inkBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let targetName {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(QuackTheme.duckOrange)
                                .frame(width: 8, height: 8)
                            Text("Pairing with \(targetName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(QuackTheme.creamText)
                        }
                    }

                    scannerBox

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SETUP CODE")
                                .font(QuackTheme.condensedDisplay(size: 13))
                                .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                            Spacer()
                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    codeText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Text("Paste")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(QuackTheme.duckOrange)
                                    .padding(.horizontal, 16)
                                    .frame(minWidth: QuackTheme.minTouchTarget, minHeight: QuackTheme.minTouchTarget)
                                    .background(Capsule().fill(QuackTheme.duckOrange.opacity(0.14)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.quackTouch)
                        }

                        TextField("md1:<robot_id>:<64-hex>", text: $codeText, axis: .vertical)
                            .font(QuackTheme.monoValue(size: 13, weight: .medium))
                            .foregroundStyle(QuackTheme.acidCyan)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...3)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(QuackTheme.inkSurface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(borderColor, lineWidth: 1)
                                    )
                            )

                        validationView
                    }

                    if let displayedError, !displayedError.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: QuackIcon.statusError)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(QuackTheme.dangerRed)
                            Text(displayedError)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(QuackTheme.dangerRed)
                        }
                    }

                    if isActivelyConnecting || (hasSubmittedHere && appState.phase != .disconnected) {
                        phaseBanner
                    }

                    Button {
                        startPairing()
                    } label: {
                        HStack(spacing: 8) {
                            if isActivelyConnecting {
                                ProgressView()
                                    .tint(QuackTheme.inkSurface)
                            }
                            Text(
                                isActivelyConnecting
                                    ? "Connecting..."
                                    : (displayedError != nil ? "Retry Pairing" : "Pair & Connect")
                            )
                            .font(.body.weight(.bold))
                        }
                        .foregroundStyle(QuackTheme.inkSurface)
                        .frame(maxWidth: .infinity)
                        .frame(height: QuackTheme.primaryButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(parsedCode != nil && !isActivelyConnecting ? QuackTheme.duckOrange : QuackTheme.duckOrange.opacity(0.35))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.quackTouch)
                    .disabled(parsedCode == nil || isActivelyConnecting)

                    if appState.phase == .configuringWifi {
                        Button {
                            onOpenWifiSetup?()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: QuackIcon.wifi)
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Configure Robot Wi-Fi")
                                    .font(.body.weight(.bold))
                            }
                            .foregroundStyle(QuackTheme.inkSurface)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(QuackTheme.acidCyan)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.quackTouch)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Setup Code")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: codeText) { _, _ in
            hasSubmittedHere = false
        }
        .onChange(of: appState.phase) { _, newPhase in
            if newPhase == .configuringWifi {
                onOpenWifiSetup?()
            } else if newPhase.isConnected {
                onConnected?()
            }
        }
    }

    private var borderColor: Color {
        switch validationResult {
        case .success: return QuackTheme.okGreen.opacity(0.65)
        case .failure: return QuackTheme.dangerRed.opacity(0.65)
        case nil: return QuackTheme.subtleBorder
        }
    }

    @ViewBuilder
    private var validationView: some View {
        switch validationResult {
        case .success(let parsed):
            HStack(spacing: 6) {
                Image(systemName: QuackIcon.statusSuccess)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuackTheme.okGreen)
                Text("Valid code for \(parsed.robotId)")
                    .font(QuackTheme.monoValue(size: 12, weight: .semibold))
                    .foregroundStyle(QuackTheme.okGreen)
            }
        case .failure(let error):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: QuackIcon.statusError)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuackTheme.dangerRed)
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(QuackTheme.dangerRed)
            }
        case nil:
            Text("Scan the robot QR code or paste its md1: setup code.")
                .font(.caption)
                .foregroundStyle(QuackTheme.creamText.opacity(0.55))
        }
    }

    private var scannerBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(QuackTheme.inkSurface)

            QrScannerView(
                onScannedCode: { scanned in
                    let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
                    if codeText != trimmed {
                        codeText = trimmed
                        QuackHaptics.success()
                    }
                },
                onUnavailable: { reason in
                    cameraStatusMessage = reason
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if let cameraStatusMessage {
                VStack(spacing: 8) {
                    Image(systemName: QuackIcon.qrScanner)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(QuackTheme.duckOrange)
                    Text(cameraStatusMessage)
                        .font(.caption)
                        .foregroundStyle(QuackTheme.creamText.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(QuackTheme.acidCyan.opacity(0.8), lineWidth: 2)
                    .frame(width: 150, height: 150)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 220)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(QuackTheme.subtleBorder, lineWidth: 1)
        )
    }

    private var phaseBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        appState.phase.isConnected
                            ? QuackTheme.okGreen
                            : (phaseErrorMessage != nil ? QuackTheme.dangerRed : QuackTheme.acidCyan)
                    )
                    .frame(width: 8, height: 8)
                Text("Status: \(appState.phase.shortLabel)")
                    .font(QuackTheme.monoValue(size: 12, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText)
                Spacer()
            }

            if let banner = appState.telemetry.statusBanner,
               !banner.isEmpty,
               !appState.phase.isConnected,
               phaseErrorMessage == nil {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(QuackTheme.creamText.opacity(0.7))
            }
        }
        .padding(10)
        .quackInsetCard(cornerRadius: 12)
    }

    private func startPairing() {
        let trimmed = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parsedCode != nil, !isActivelyConnecting else { return }
        errorMessage = nil
        hasSubmittedHere = true
        isPairing = true
        Task {
            defer { isPairing = false }
            do {
                if let targetPeripheralId {
                    try await appState.connectViaBle(peripheralId: targetPeripheralId, setupCodeRaw: trimmed)
                } else {
                    try await appState.pairAndConnect(setupCodeRaw: trimmed, peripheralId: nil)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct QrScannerView: UIViewRepresentable {
    let onScannedCode: (String) -> Void
    let onUnavailable: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScannedCode: onScannedCode, onUnavailable: onUnavailable)
    }

    func makeUIView(context: Context) -> ScannerContainerView {
        let view = ScannerContainerView()
        context.coordinator.configure(in: view)
        return view
    }

    func updateUIView(_ uiView: ScannerContainerView, context: Context) {}

    static func dismantleUIView(_ uiView: ScannerContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class ScannerContainerView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onScannedCode: (String) -> Void
        private let onUnavailable: (String) -> Void
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.caricio.quackdeck.qr")
        private var configured = false

        init(onScannedCode: @escaping (String) -> Void, onUnavailable: @escaping (String) -> Void) {
            self.onScannedCode = onScannedCode
            self.onUnavailable = onUnavailable
        }

        func configure(in view: ScannerContainerView) {
            guard !configured else { return }
            configured = true

            guard let device = AVCaptureDevice.default(for: .video) else {
                DispatchQueue.main.async {
                    self.onUnavailable("Camera unavailable here. Paste the md1: code below.")
                }
                return
            }

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                startCapture(device: device, in: view)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        self.startCapture(device: device, in: view)
                    } else {
                        DispatchQueue.main.async {
                            self.onUnavailable("Camera permission denied. Paste the md1: code below.")
                        }
                    }
                }
            default:
                DispatchQueue.main.async {
                    self.onUnavailable("Camera access blocked. Allow it in Settings or paste the code below.")
                }
            }
        }

        private func startCapture(device: AVCaptureDevice, in view: ScannerContainerView) {
            sessionQueue.async {
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else {
                        DispatchQueue.main.async {
                            self.onUnavailable("Could not start camera input.")
                        }
                        return
                    }
                    self.session.addInput(input)

                    let output = AVCaptureMetadataOutput()
                    guard self.session.canAddOutput(output) else {
                        DispatchQueue.main.async {
                            self.onUnavailable("QR reader unavailable on this device.")
                        }
                        return
                    }
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = [.qr]

                    let preview = AVCaptureVideoPreviewLayer(session: self.session)
                    preview.videoGravity = .resizeAspectFill
                    DispatchQueue.main.async {
                        view.previewLayer = preview
                        preview.frame = view.bounds
                        view.layer.insertSublayer(preview, at: 0)
                    }
                    self.session.startRunning()
                } catch {
                    DispatchQueue.main.async {
                        self.onUnavailable("Camera error: \(error.localizedDescription)")
                    }
                }
            }
        }

        func stop() {
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let text = readable.stringValue,
                  !text.isEmpty else { return }
            onScannedCode(text)
        }
    }
}
