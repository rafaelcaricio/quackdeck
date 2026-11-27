import SwiftUI
import UIKit
import WebRTC

struct VideoStageView: View {
    let appState: AppState
    var framing: PortraitVideoFraming = .fill
    var onDoubleTapFramingToggle: (() -> Void)? = nil

    @State private var normalizedAim: CGPoint = .zero // [-1, 1] in upright source space
    @State private var isDraggingLook: Bool = false
    @State private var gestureStartedOutsideImage: Bool = false
    @State private var lastTapTimestamp: Date?
    @State private var showQuackPop: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var demoGazeSyncKey: String {
        guard let gaze = appState.demoSessionInstance?.virtualGazeNormalized else {
            return "none"
        }
        return String(format: "%.3f:%.3f", gaze.x, gaze.y)
    }

    var body: some View {
        GeometryReader { geo in
            let geometry = VideoStageGeometry.compute(
                stageSize: geo.size,
                mediaVideo: appState.telemetry.mediaVideo,
                framing: framing
            )

            ZStack {
                videoContent(geometry: geometry)

                // Configurable 8×8 ToF depth overlay aligned with the active image frame
                if appState.videoSource != .none,
                   appState.isTofOverlayEnabled,
                   let tofFrame = appState.telemetry.tofFrame {
                    TofVideoOverlayView(
                        frame: tofFrame,
                        opacity: appState.tofOverlayOpacity,
                        gridRect: geometry.tofGridRect(),
                        clipRect: geometry.visibleRect
                    )
                }

                // Upright drag-to-look & double-tap framing surface (rejects letterbox bars)
                if appState.videoSource != .none && (appState.canLook || onDoubleTapFramingToggle != nil) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("quackVideoStage"))
                                .onChanged { value in
                                    if !isDraggingLook && !gestureStartedOutsideImage {
                                        if !geometry.visibleRect.contains(value.startLocation) {
                                            gestureStartedOutsideImage = true
                                            lastTapTimestamp = nil
                                            return
                                        }
                                    }
                                    guard !gestureStartedOutsideImage else { return }

                                    let moveDist = hypot(value.translation.width, value.translation.height)
                                    if moveDist >= 4 {
                                        lastTapTimestamp = nil
                                        guard appState.canLook, !appState.isDrivingInputInhibited else { return }
                                        isDraggingLook = true
                                    }
                                    guard isDraggingLook, appState.canLook, !appState.isDrivingInputInhibited else {
                                        return
                                    }

                                    let clampedPoint = CGPoint(
                                        x: min(max(value.location.x, geometry.visibleRect.minX), geometry.visibleRect.maxX),
                                        y: min(max(value.location.y, geometry.visibleRect.minY), geometry.visibleRect.maxY)
                                    )
                                    guard let aim = geometry.normalizedAim(forStagePoint: clampedPoint) else { return }
                                    normalizedAim = aim

                                    // Robot trunk frame: +y looks left, +z looks up
                                    let y = -Double(aim.x) * LiveRobotSession.lookRange.y
                                    let z = LiveRobotSession.lookRange.z - Double(aim.y) * LiveRobotSession.lookRange.dz
                                    appState.setLook(y: y, z: z)
                                }
                                .onEnded { value in
                                    let wasOutside = gestureStartedOutsideImage
                                    gestureStartedOutsideImage = false
                                    if isDraggingLook {
                                        isDraggingLook = false
                                        appState.stopLook()
                                        return
                                    }
                                    guard !wasOutside,
                                          onDoubleTapFramingToggle != nil,
                                          geometry.visibleRect.contains(value.location) else {
                                        lastTapTimestamp = nil
                                        return
                                    }
                                    let moveDist = hypot(value.translation.width, value.translation.height)
                                    guard moveDist < 4 else {
                                        lastTapTimestamp = nil
                                        return
                                    }
                                    let now = Date()
                                    if let previous = lastTapTimestamp, now.timeIntervalSince(previous) < 0.35 {
                                        lastTapTimestamp = nil
                                        onDoubleTapFramingToggle?()
                                    } else {
                                        lastTapTimestamp = now
                                    }
                                }
                        )
                }

                // Subtle acid-cyan gaze reticle mapped inside visible video
                if appState.videoSource != .none && appState.canLook {
                    reticleOverlay(geometry: geometry)
                        .allowsHitTesting(false)
                }

                if appState.isConnected && appState.telemetry.isVideoFirstFrameTimedOut {
                    Text("Camera stream did not start · control active")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(QuackTheme.warnYellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .quackGlassPill(borderColor: QuackTheme.warnYellow.opacity(0.5))
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
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "quackVideoStage")
        }
        .onChange(of: framing) { _, _ in
            endLookInteraction()
        }
        .onChange(of: appState.telemetry.mediaVideo?.rotate) { _, _ in
            endLookInteraction()
        }
        .onChange(of: appState.inputResetGeneration) { _, _ in
            endLookInteraction()
        }
        .onChange(of: appState.isDrivingInputInhibited) { _, inhibited in
            if inhibited && isDraggingLook {
                isDraggingLook = false
                gestureStartedOutsideImage = false
            }
        }
        .onChange(of: appState.canLook) { _, canLook in
            if !canLook {
                endLookInteraction()
            }
        }
        .onChange(of: appState.telemetry.statusBanner) { _, banner in
            if banner == "Quack!" {
                triggerQuackPop()
            }
        }
        .onChange(of: demoGazeSyncKey) { _, _ in
            if let gaze = appState.demoSessionInstance?.virtualGazeNormalized, !isDraggingLook {
                normalizedAim = CGPoint(x: gaze.x, y: gaze.y)
            }
        }
        .onChange(of: appState.telemetry.robotState?.head) { _, head in
            if let head, head.count >= 3, !isDraggingLook, !appState.isDemoMode {
                if abs(head[1]) < 0.03 && abs(head[2]) < 0.03 {
                    normalizedAim = .zero
                }
            }
        }
    }

    private func endLookInteraction() {
        gestureStartedOutsideImage = false
        lastTapTimestamp = nil
        if isDraggingLook {
            isDraggingLook = false
            appState.stopLook()
        }
    }

    @ViewBuilder
    private func videoContent(geometry: VideoStageGeometry) -> some View {
        switch appState.videoSource {
        case .demo:
            DemoVideoView(
                appState: appState,
                demoSession: appState.demoSessionInstance,
                geometry: geometry
            )

        case .webrtc(let track):
            WebRTCVideoRepresentable(
                track: track,
                rotationDegrees: appState.telemetry.mediaVideo?.rotate ?? 0,
                contentMode: framing == .fit ? .scaleAspectFit : .scaleAspectFill
            )
            .background(QuackTheme.inkBg)

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

    @ViewBuilder
    private func reticleOverlay(geometry: VideoStageGeometry) -> some View {
        if let point = geometry.stagePoint(forNormalizedAim: normalizedAim) {
            let showLimit = appState.telemetry.lookClamped
            let vr = geometry.visibleRect

            ZStack {
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
                    .position(x: point.x, y: point.y)

                if showLimit && vr.width > 72 && vr.height > 44 {
                    let lx = min(max(point.x, vr.minX + 36), vr.maxX - 36)
                    let ly = max(vr.minY + 18, point.y - 26)
                    Text("LIMIT")
                        .font(QuackTheme.monoValue(size: 10, weight: .bold))
                        .foregroundStyle(QuackTheme.inkSurface)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(QuackTheme.warnYellow))
                        .position(x: lx, y: ly)
                }
            }
            .frame(width: geometry.stageSize.width, height: geometry.stageSize.height)
            .mask(
                Rectangle()
                    .frame(width: max(0, vr.width), height: max(0, vr.height))
                    .position(x: vr.midX, y: vr.midY)
            )
        }
    }

    private func triggerQuackPop() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.65)) {
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
    let contentMode: UIView.ContentMode

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RotatableVideoContainerView {
        let container = RotatableVideoContainerView()
        container.backgroundColor = UIColor(red: 0.031, green: 0.031, blue: 0.047, alpha: 1.0)
        container.applyContentMode(contentMode)
        context.coordinator.attach(track: track, to: container.videoView)
        container.applyRotation(degrees: rotationDegrees)
        return container
    }

    func updateUIView(_ uiView: RotatableVideoContainerView, context: Context) {
        context.coordinator.attach(track: track, to: uiView.videoView)
        uiView.applyContentMode(contentMode)
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

    func applyContentMode(_ mode: UIView.ContentMode) {
        if videoView.videoContentMode != mode {
            videoView.videoContentMode = mode
            setNeedsLayout()
        }
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
