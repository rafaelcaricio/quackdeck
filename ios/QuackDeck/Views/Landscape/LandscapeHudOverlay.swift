import SwiftUI

struct LandscapeHudOverlay: View {
    let appState: AppState
    @Binding var isSensorsDrawerOpen: Bool
    var drawerWidth: CGFloat = 0

    @State private var showTofControls: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            // Top floating pill bar
            HStack(spacing: 10) {
                TopStatusPillView(appState: appState)
                    .layoutPriority(2)

                Spacer(minLength: 4)

                if appState.isConnected {
                    centerTelemetryPill
                }

                Spacer(minLength: 4)

                HStack(spacing: QuackTheme.controlSpacing) {
                    sensorsToggleButton
                    if appState.canShowStop {
                        StopPillButton(appState: appState)
                    }
                }
                .layoutPriority(2)
            }

            if showTofControls && appState.isConnected {
                TofOverlayControlsBar(appState: appState) {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                        showTofControls = false
                    }
                }
                .frame(maxWidth: 300)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if appState.motorThermalLevel != .normal, let banner = appState.thermalBannerText {
                ThermalCautionBanner(level: appState.motorThermalLevel, message: banner)
                    .frame(maxWidth: 420)
            }

            Spacer(minLength: 0)

            // Bottom cockpit controls
            HStack(alignment: .bottom, spacing: 8) {
                if appState.canDrive {
                    // Left thumb: translucent virtual stick
                    VStack(spacing: 4) {
                        VirtualStickView(appState: appState, size: 128, isGlass: true)

                        Text(stickSpeedText)
                            .font(QuackTheme.monoValue(size: 12, weight: .medium))
                            .foregroundStyle(QuackTheme.creamText.opacity(0.75))
                            .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    }
                }

                Spacer(minLength: 4)

                // Bottom center: guidance pill (when active) + compact posture segmented pill
                VStack(spacing: 6) {
                    if let guidance = appState.guidanceText {
                        GuidanceStripView(
                            text: guidance,
                            tone: appState.guidanceTone,
                            isCompactPill: true
                        )
                    }

                    PostureBarView(
                        appState: appState,
                        style: .landscapePill,
                        onOpenSensors: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                isSensorsDrawerOpen = true
                            }
                        }
                    )
                    .padding(.bottom, 4)
                }

                Spacer(minLength: 4)

                // Right thumb: Look Center + QUACK + Turn rocker (hidden behind drawer if open)
                if isSensorsDrawerOpen {
                    Color.clear
                        .frame(width: drawerWidth + 4, height: 1)
                } else if appState.canLook || appState.canDrive {
                    VStack(alignment: .trailing, spacing: 12) {
                        if appState.canLook {
                            HStack(spacing: 12) {
                                lookCenterButton
                                quackButton
                            }
                        }

                        if appState.canDrive {
                            TurnRockerView(appState: appState, style: .landscapePill)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.2), value: appState.cockpitState)
        .onChange(of: appState.isConnected) { _, connected in
            if !connected {
                showTofControls = false
            }
        }
    }

    private var lookCenterButton: some View {
        Button {
            appState.lookCenter()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: QuackIcon.lookCenter)
                    .font(.system(size: 17, weight: .semibold))
                Text("Center")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(QuackTheme.acidCyan)
            .frame(width: 64, height: 64)
            .quackGlassPill(borderColor: QuackTheme.acidCyan.opacity(0.45))
            .contentShape(Circle())
        }
        .buttonStyle(.quackTouch)
        .accessibilityLabel("Look Center")
    }

    private var quackButton: some View {
        Button {
            Task {
                await appState.playQuack()
            }
        } label: {
            Text("QUACK")
                .font(QuackTheme.condensedDisplay(size: 18))
                .foregroundStyle(QuackTheme.inkSurface)
                .frame(width: 72, height: 72)
                .background(
                    Circle()
                        .fill(QuackTheme.warnYellow)
                        .overlay(
                            Circle()
                                .strokeBorder(QuackTheme.inkSurface, lineWidth: 2)
                        )
                        .shadow(color: QuackTheme.acidCyan, radius: 0, y: 3)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.quackTouch)
    }

    private var centerTelemetryPill: some View {
        let tofText = appState.telemetry.nearestTofMeters.map { String(format: "TOF %.2fm", $0) } ?? "TOF --"
        let pitchText: String = {
            if let pr = appState.telemetry.bodyPitchRollDegrees {
                return String(format: "%+.1f°", pr.pitch)
            }
            return "+0.0°"
        }()
        let tempText = appState.telemetry.hottestServoTempC.map { String(format: "%.0f°C", $0) } ?? "--°C"
        let tempColor: Color = {
            switch appState.motorThermalLevel {
            case .hot: return QuackTheme.dangerRed
            case .warm: return QuackTheme.warnYellow
            case .normal: return QuackTheme.okGreen
            }
        }()
        let fpsText = appState.telemetry.videoFps > 0.5
            ? String(format: "%.0f FPS", appState.telemetry.videoFps)
            : "-- FPS"

        return ViewThatFits(in: .horizontal) {
            telemetryPillContent(
                tofText: tofText,
                pitchText: pitchText,
                tempText: tempText,
                tempColor: tempColor,
                fpsText: fpsText,
                showPitch: true,
                showFps: true
            )

            telemetryPillContent(
                tofText: tofText,
                pitchText: pitchText,
                tempText: tempText,
                tempColor: tempColor,
                fpsText: fpsText,
                showPitch: false,
                showFps: true
            )

            telemetryPillContent(
                tofText: tofText,
                pitchText: pitchText,
                tempText: tempText,
                tempColor: tempColor,
                fpsText: fpsText,
                showPitch: false,
                showFps: false
            )
        }
    }

    private func telemetryPillContent(
        tofText: String,
        pitchText: String,
        tempText: String,
        tempColor: Color,
        fpsText: String,
        showPitch: Bool,
        showFps: Bool
    ) -> some View {
        let isOverlayOn = appState.isTofOverlayEnabled
        return HStack(spacing: 0) {
            Button {
                QuackHaptics.light()
                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                    showTofControls.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(QuackTheme.acidCyan)
                        .frame(width: 6, height: 6)
                    Text(tofText)
                        .foregroundStyle(QuackTheme.acidCyan)
                        .lineLimit(1)
                }
                .opacity(isOverlayOn || showTofControls ? 1.0 : 0.55)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(minWidth: QuackTheme.minTouchTarget, minHeight: QuackTheme.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.quackTouch)
            .accessibilityLabel("ToF overlay controls, \(tofText), \(isOverlayOn ? "\(Int((appState.tofOverlayOpacity * 100).rounded())) percent" : "off")")

            HStack(spacing: 7) {
                dividerBar

                if showPitch {
                    Text(pitchText)
                        .foregroundStyle(QuackTheme.creamText.opacity(0.9))
                        .lineLimit(1)

                    dividerBar
                }

                Text(tempText)
                    .foregroundStyle(tempColor)
                    .lineLimit(1)

                if showFps {
                    dividerBar

                    Text(fpsText)
                        .foregroundStyle(QuackTheme.creamText.opacity(0.68))
                        .lineLimit(1)
                }
            }
            .padding(.trailing, 12)
        }
        .font(QuackTheme.monoValue(size: 12.5))
        .fixedSize(horizontal: true, vertical: false)
        .quackGlassPill()
    }

    private var dividerBar: some View {
        Rectangle()
            .fill(QuackTheme.creamText.opacity(0.24))
            .frame(width: 1, height: 14)
    }

    private var sensorsToggleButton: some View {
        Button {
            QuackHaptics.light()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                isSensorsDrawerOpen.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: QuackIcon.sensors)
                    .font(.system(size: 15, weight: .semibold))
                Text("Sensors")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSensorsDrawerOpen ? QuackTheme.inkSurface : QuackTheme.creamText)
            .padding(.horizontal, 14)
            .frame(minWidth: QuackTheme.minTouchTarget, minHeight: QuackTheme.minTouchTarget)
            .background {
                if isSensorsDrawerOpen {
                    Capsule().fill(QuackTheme.duckOrange)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(QuackTheme.glassFill))
                        .overlay(Capsule().strokeBorder(QuackTheme.subtleBorder, lineWidth: 1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
    }

    private var stickSpeedText: String {
        let vx = appState.stickForward * LiveRobotSession.maxLinearSpeed
        let vy = appState.stickStrafeLeft * LiveRobotSession.maxLinearSpeed
        return String(format: "%.2f M/S", hypot(vx, vy))
    }
}
