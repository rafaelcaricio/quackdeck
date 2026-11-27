import SwiftUI

struct PortraitLiveView: View {
    let appState: AppState
    var onOpenSensorsTab: () -> Void

    @State private var showTofControls: Bool = false

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let isCompact = totalHeight < 700

            VStack(spacing: 0) {
                cameraStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                bottomControlStage(isCompact: isCompact)
            }
            .background(QuackTheme.inkBg)
            .animation(.easeOut(duration: 0.2), value: appState.cockpitState)
            .onChange(of: appState.isConnected) { _, connected in
                if !connected {
                    showTofControls = false
                }
            }
        }
    }

    private var cameraStage: some View {
        ZStack {
            VideoStageView(appState: appState)

            // Top and bottom legibility gradients
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [QuackTheme.inkBg.opacity(0.85), QuackTheme.inkBg.opacity(0.32), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 124)

                Spacer()

                LinearGradient(
                    colors: [.clear, QuackTheme.inkBg.opacity(0.55), QuackTheme.inkBg],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 92)
            }
            .allowsHitTesting(false)

            // Floating HUD chrome over video
            VStack(spacing: 10) {
                HStack(spacing: QuackTheme.controlSpacing) {
                    TopStatusPillView(appState: appState)
                    Spacer()
                    if appState.canShowStop {
                        StopPillButton(appState: appState)
                    }
                }

                if appState.motorThermalLevel != .normal, let banner = appState.thermalBannerText {
                    ThermalCautionBanner(level: appState.motorThermalLevel, message: banner)
                }

                Spacer()

                // Floating live HUD chips
                if appState.isConnected {
                    VStack(spacing: 8) {
                        if showTofControls {
                            TofOverlayControlsBar(appState: appState) {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                    showTofControls = false
                                }
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        HStack(spacing: QuackTheme.controlSpacing) {
                            tofChip
                            tempChip
                            Spacer()
                            fpsChip
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    private var tofChip: some View {
        let label: String
        if let dist = appState.telemetry.nearestTofMeters {
            label = String(format: "TOF %.2fm", dist)
        } else {
            label = "TOF --"
        }
        let isOverlayOn = appState.isTofOverlayEnabled

        return Button {
            QuackHaptics.light()
            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                showTofControls.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(QuackTheme.acidCyan)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(QuackTheme.monoValue(size: 13))
                    .foregroundStyle(QuackTheme.acidCyan)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: QuackTheme.minTouchTarget, minHeight: QuackTheme.minTouchTarget)
            .quackGlassPill(
                borderColor: QuackTheme.acidCyan.opacity(showTofControls ? 0.85 : (isOverlayOn ? 0.55 : 0.22))
            )
            .opacity(isOverlayOn || showTofControls ? 1.0 : 0.58)
            .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
        .accessibilityLabel("ToF overlay controls, \(label), \(isOverlayOn ? "\(Int((appState.tofOverlayOpacity * 100).rounded())) percent" : "off")")
    }

    private var tempChip: some View {
        let tempC = appState.telemetry.hottestServoTempC
        let label = tempC.map { String(format: "%.0f°C", $0) } ?? "--°C"
        let color: Color = {
            switch appState.motorThermalLevel {
            case .hot: return QuackTheme.dangerRed
            case .warm: return QuackTheme.warnYellow
            case .normal: return QuackTheme.okGreen
            }
        }()

        return Button {
            QuackHaptics.light()
            onOpenSensorsTab()
        } label: {
            Text(label)
                .font(QuackTheme.monoValue(size: 13))
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .frame(minWidth: QuackTheme.minTouchTarget, minHeight: QuackTheme.minTouchTarget)
                .quackGlassPill()
                .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
        .accessibilityLabel("Open sensors, hottest servo \(label)")
    }

    private var fpsChip: some View {
        let fps = appState.telemetry.videoFps
        let label = fps > 0.5 ? String(format: "%.0f FPS", fps) : "-- FPS"
        return Text(label)
            .font(QuackTheme.monoValue(size: 13, weight: .medium))
            .foregroundStyle(QuackTheme.creamText.opacity(0.82))
            .padding(.horizontal, 12)
            .frame(minHeight: QuackTheme.minTouchTarget)
            .quackGlassPill()
    }

    private func bottomControlStage(isCompact: Bool) -> some View {
        VStack(spacing: 10) {
            if appState.canDrive {
                driveStage(isCompact: isCompact)
                    .padding(.bottom, 6)
            } else if appState.isCompactUtilityRowVisible {
                quackAndCenterRow(height: 48)
            }

            if let guidance = appState.guidanceText {
                GuidanceStripView(
                    text: guidance,
                    tone: appState.guidanceTone,
                    isCompactPill: false
                )
            }

            PostureBarView(
                appState: appState,
                style: .portraitBar,
                onOpenSensors: onOpenSensorsTab
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(QuackTheme.inkBg)
    }

    private func driveStage(isCompact: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VirtualStickView(
                appState: appState,
                size: isCompact ? 132 : 136,
                isGlass: false
            )

            VStack(spacing: QuackTheme.controlSpacing) {
                TurnRockerView(appState: appState, style: .portraitSplit)

                quackAndCenterRow(height: 56)

                Text(velocitySummaryText)
                    .font(QuackTheme.monoValue(size: 11, weight: .regular))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func quackAndCenterRow(height: CGFloat) -> some View {
        let cornerRadius: CGFloat = height >= 56 ? 16 : 14

        return HStack(spacing: QuackTheme.controlSpacing) {
            Button {
                Task {
                    await appState.playQuack()
                }
            } label: {
                Text("QUACK")
                    .font(QuackTheme.condensedDisplay(size: height >= 56 ? 19 : 17))
                    .foregroundStyle(QuackTheme.inkSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(QuackTheme.duckOrange)
                            .shadow(color: QuackTheme.acidMagenta, radius: 0, y: height >= 56 ? 3 : 2)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .buttonStyle(.quackTouch)

            Button {
                appState.lookCenter()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: QuackIcon.lookCenter)
                        .font(.system(size: 15, weight: .semibold))
                    Text("Center")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(QuackTheme.acidCyan)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(hex: 0x161622))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(QuackTheme.acidCyan.opacity(0.4), lineWidth: 1)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .buttonStyle(.quackTouch)
            .accessibilityLabel("Look Center")
        }
    }

    private var velocitySummaryText: String {
        let vx = appState.stickForward * LiveRobotSession.maxLinearSpeed
        let vy = appState.stickStrafeLeft * LiveRobotSession.maxLinearSpeed
        let speed = hypot(vx, vy)
        return String(format: "%.2f m/s · Drag video to look", speed)
    }
}
