import SwiftUI
import UIKit
import WebRTC

struct VideoStageView: View {
    let appState: AppState

    @State private var normalizedAim: CGPoint = .zero // [-1, 1] in upright view space
    @State private var isDraggingLook: Bool = false
    @State private var showQuackPop: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                videoContent

                // Configurable 8×8 ToF depth overlay (works over both live WebRTC and Demo video)
                if appState.videoSource != .none,
                   appState.isTofOverlayEnabled,
                   let tofFrame = appState.telemetry.tofFrame {
                    TofVideoOverlayView(
                        frame: tofFrame,
                        opacity: appState.tofOverlayOpacity
                    )
                }

                // Upright drag-to-look gesture surface (active only in U5 Walking and U6b Seated)
                if appState.canLook {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    guard appState.canLook else { return }
                                    isDraggingLook = true
                                    let width = max(geo.size.width, 1)
                                    let height = max(geo.size.height, 1)
                                    let nx = max(-1.0, min(1.0, (value.location.x / width) * 2.0 - 1.0))
                                    let ny = max(-1.0, min(1.0, (value.location.y / height) * 2.0 - 1.0))
                                    normalizedAim = CGPoint(x: nx, y: ny)

                                    // Robot trunk frame: +y looks left, +z looks up
                                    let y = -Double(nx) * LiveRobotSession.lookRange.y
                                    let z = LiveRobotSession.lookRange.z - Double(ny) * LiveRobotSession.lookRange.dz
                                    appState.setLook(y: y, z: z)
                                }
                                .onEnded { _ in
                                    isDraggingLook = false
                                    appState.stopLook()
                                }
                        )
                }

                // Subtle acid-cyan gaze reticle (active only when head look is live)
                if appState.videoSource != .none && appState.canLook {
                    reticleOverlay(in: geo.size)
                        .allowsHitTesting(false)
                }

                // Comic QUACK pop badge
                if showQuackPop {
                    Text("QUACK!")
                        .font(QuackTheme.condensedDisplay(size: 26))
                        .foregroundStyle(QuackTheme.inkSurface)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(QuackTheme.warnYellow)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(QuackTheme.inkSurface, lineWidth: 2)
                                )
                                .shadow(color: QuackTheme.acidMagenta, radius: 0, x: 3, y: 3)
                        )
                        .rotationEffect(.degrees(-5))
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: appState.canLook) { _, canLook in
            if !canLook && isDraggingLook {
                isDraggingLook = false
                appState.stopLook()
            }
        }
        .onChange(of: appState.telemetry.statusBanner) { _, banner in
            if banner == "Quack!" {
                triggerQuackPop()
            }
        }
        .onChange(of: appState.demoSessionInstance?.virtualGazeNormalized.x) { _, newX in
            if let newX, let newY = appState.demoSessionInstance?.virtualGazeNormalized.y, !isDraggingLook {
                normalizedAim = CGPoint(x: newX, y: newY)
            }
        }
        .onChange(of: appState.telemetry.robotState?.head) { _, head in
            if let head, head.count >= 3, !isDraggingLook, !appState.isDemoMode {
                // Keep reticle aligned when Look Center resets head
                if abs(head[1]) < 0.03 && abs(head[2]) < 0.03 {
                    normalizedAim = .zero
                }
            }
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        switch appState.videoSource {
        case .demo:
            DemoVideoView(
                appState: appState,
                demoSession: appState.demoSessionInstance
            )

        case .webrtc(let track):
            WebRTCVideoRepresentable(
                track: track,
                rotationDegrees: appState.telemetry.mediaVideo?.rotate ?? 0
            )
            .background(Color(hex: 0x0d0e15))

        case .none:
            ZStack {
                Color(hex: 0x0d0e15)
                VStack(spacing: 10) {
                    Image(systemName: QuackIcon.liveUnavailable)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.38))

                    Text(appState.isConnected ? "Waiting for camera stream..." : "No Duck Connected")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.75))

                    Text(appState.isConnected ? appState.phase.shortLabel : "Open Ducks to pair or try Offline Demo")
                        .font(.system(size: 12))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.45))
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func reticleOverlay(in size: CGSize) -> some View {
        let rx = (normalizedAim.x * 0.5 + 0.5) * size.width
        let ry = (normalizedAim.y * 0.5 + 0.5) * size.height
        let showLimit = appState.telemetry.lookClamped

        return ZStack {
            Circle()
                .strokeBorder(
                    QuackTheme.acidCyan.opacity(isDraggingLook ? 0.95 : 0.65),
                    lineWidth: isDraggingLook ? 2.0 : 1.5
                )
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .fill(QuackTheme.acidCyan)
                        .frame(width: 4, height: 4)
                )
                .position(x: rx, y: ry)

            if showLimit {
                Text("LIMIT")
                    .font(QuackTheme.monoValue(size: 10, weight: .bold))
                    .foregroundStyle(QuackTheme.inkSurface)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(QuackTheme.warnYellow))
                    .position(x: min(max(rx, 36), size.width - 36), y: max(22, ry - 26))
            }
        }
    }

    private func triggerQuackPop() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.65)) {
            showQuackPop = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            withAnimation(.easeOut(duration: 0.18)) {
                showQuackPop = false
            }
        }
    }
}

private struct WebRTCVideoRepresentable: UIViewRepresentable {
    let track: RTCVideoTrack
    let rotationDegrees: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RotatableVideoContainerView {
        let container = RotatableVideoContainerView()
        container.backgroundColor = UIColor(red: 0.05, green: 0.055, blue: 0.082, alpha: 1.0)
        container.videoView.videoContentMode = .scaleAspectFill
        context.coordinator.attach(track: track, to: container.videoView)
        container.applyRotation(degrees: rotationDegrees)
        return container
    }

    func updateUIView(_ uiView: RotatableVideoContainerView, context: Context) {
        context.coordinator.attach(track: track, to: uiView.videoView)
        uiView.applyRotation(degrees: rotationDegrees)
    }

    static func dismantleUIView(_ uiView: RotatableVideoContainerView, coordinator: Coordinator) {
        coordinator.detach(from: uiView.videoView)
    }

    final class Coordinator {
        private var currentTrack: RTCVideoTrack?

        func attach(track: RTCVideoTrack, to videoView: RTCMTLVideoView) {
            if currentTrack === track { return }
            if let existing = currentTrack {
                existing.remove(videoView)
            }
            track.add(videoView)
            currentTrack = track
        }

        func detach(from videoView: RTCMTLVideoView) {
            currentTrack?.remove(videoView)
            currentTrack = nil
        }
    }
}

private final class RotatableVideoContainerView: UIView {
    let videoView = RTCMTLVideoView(frame: .zero)
    private var rotationDegrees: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(videoView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyRotation(degrees: Int) {
        let normalized = ((degrees % 360) + 360) % 360
        if rotationDegrees != normalized {
            rotationDegrees = normalized
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let quarterTurns = rotationDegrees == 90 || rotationDegrees == 270
        let targetBounds = quarterTurns
            ? CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            : bounds

        videoView.transform = .identity
        videoView.bounds = targetBounds
        videoView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        videoView.transform = CGAffineTransform(
            rotationAngle: CGFloat(rotationDegrees) * .pi / 180.0
        )
    }
}
