import SwiftUI

struct LandscapeHudOverlay: View {
    private enum ActiveHudPanel: Equatable {
        case tof
        case emotions
    }

    let appState: AppState
    @Binding var isSensorsDrawerOpen: Bool
    var drawerWidth: CGFloat = 0
    var stageWidth: CGFloat = 852

    @State private var activePanel: ActiveHudPanel?
    @AccessibilityFocusState private var emoteAccessibilityFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hasKicks = appState.canShowKicks
        let remainingWidth = max(0, stageWidth - 24 - 128 - 220 - 32)
        let fitsCompactL2Row = remainingWidth >= 220

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

            if activePanel == .tof && appState.isConnected {
                TofOverlayControlsBar(appState: appState) {
                    closePanels(restoreEmoteFocus: false)
                }
                .frame(maxWidth: 300)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }

            if appState.motorThermalLevel != .normal, let banner = appState.thermalBannerText {
                ThermalCautionBanner(level: appState.motorThermalLevel, message: banner)
                    .frame(maxWidth: 420)
            }

            if appState.displayedActiveKickSide != nil || appState.activeEmotionName != nil || appState.emotionStatusNote != nil {
                ActiveEmotionBadgePill(
                    activeKickSide: appState.displayedActiveKickSide,
                    emotionName: appState.activeEmotionName,
                    endsAt: appState.activeEmotionEndsAt,
                    showCountdown: appState.activeEmotionDurationKnown,
                    statusNote: appState.emotionStatusNote
                )
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
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
                            withAnimation(reduceMotion ? .none : .spring(response: 0.28, dampingFraction: 0.85)) {
                                isSensorsDrawerOpen = true
                            }
                        }
                    )
                    .padding(.bottom, 4)
                }

                Spacer(minLength: 4)

                // Right thumb: Emote + Center + QUACK + L2 Kick pair beside Turn rocker
                if isSensorsDrawerOpen {
                    Color.clear
                        .frame(width: drawerWidth + 4, height: 1)
                } else if appState.canLook || appState.canDrive {
                    trailingActionCluster(hasKicks: hasKicks, fitsCompactRow: fitsCompactL2Row)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(alignment: .bottomTrailing) {
            if activePanel == .emotions && appState.canTriggerEmotions && !isSensorsDrawerOpen {
                EmotionsPickerPanel(
                    emotions: appState.availableEmotions,
                    activeEmotionName: appState.activeEmotionName,
                    columns: 4,
                    onSelect: { name in
                        closePanels(restoreEmoteFocus: false)
                        Task {
                            await appState.triggerEmotion(name)
                        }
                    },
                    onClose: {
                        closePanels(restoreEmoteFocus: true)
                    }
                )
                .frame(maxWidth: 368)
                .padding(.trailing, 12)
                .padding(.bottom, appState.canDrive ? 118 : 68)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.2), value: appState.layoutCockpitState)
        .onChange(of: appState.isConnected) { _, connected in
            if !connected {
                activePanel = nil
            }
        }
        .onChange(of: appState.canTriggerEmotions) { _, canTrigger in
            if !canTrigger && activePanel == .emotions {
                activePanel = nil
            }
        }
        .onChange(of: isSensorsDrawerOpen) { _, open in
            if open && activePanel == .emotions {
                activePanel = nil
            }
        }
        .onDisappear {
            appState.stopAllMotion()
        }
    }

    @ViewBuilder
    private func trailingActionCluster(hasKicks: Bool, fitsCompactRow: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            if appState.canLook {
                if hasKicks {
                    HStack(spacing: 8) {
                        if appState.canTriggerEmotions {
                            emoteCompactButton
                        }
                        lookCenterCompactButton
                        quackCalmPillButton
                    }
                } else {
                    HStack(spacing: 10) {
                        if appState.canTriggerEmotions {
                            emoteCircleButton
                        }
                        lookCenterButton
                        quackButton
                    }
                }
            }

            if appState.canDrive {
                if hasKicks && fitsCompactRow {
                    HStack(spacing: 12) {
                        KickPairButtons(appState: appState, style: .landscapeCompact)
                        TurnRockerView(appState: appState, style: .landscapeCompact)
                    }
                } else if hasKicks {
                    VStack(alignment: .trailing, spacing: 8) {
                        KickPairButtons(appState: appState, style: .landscapeCompact)
                        TurnRockerView(appState: appState, style: .landscapeCompact)
                    }
                } else {
                    TurnRockerView(appState: appState, style: .landscapePill)
                }
            }
        }
    }

    private func closePanels(restoreEmoteFocus: Bool) {
        withAnimation(reduceMotion ? .none : .spring(response: 0.24, dampingFraction: 0.85)) {
            activePanel = nil
        }
        if restoreEmoteFocus {
            Task { @MainActor in
                emoteAccessibilityFocused = true
            }
        }
    }

    private var emoteCompactButton: some View {
        let isHighlighted = activePanel == .emotions || appState.activeEmotionName != nil
        return Button {
            QuackHaptics.light()
            withAnimation(reduceMotion ? .none : .spring(response: 0.24, dampingFraction: 0.85)) {
                activePanel = (activePanel == .emotions) ? nil : .emotions
            }
        } label: {
            Image(systemName: QuackIcon.emotions)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(QuackTheme.duckOrange)
                .frame(width: 48, height: QuackTheme.minTouchTarget)
                .quackGlassPill(borderColor: QuackTheme.duckOrange.opacity(isHighlighted ? 0.9 : 0.45))
                .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
        .accessibilityFocused($emoteAccessibilityFocused)
        .accessibilityLabel("Emotions")
    }

    private var lookCenterCompactButton: some View {
        Button {
            appState.lookCenter()
        } label: {
            Image(systemName: QuackIcon.lookCenter)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(QuackTheme.acidCyan)
                .frame(width: 48, height: QuackTheme.minTouchTarget)
                .quackGlassPill(borderColor: QuackTheme.acidCyan.opacity(0.45))
                .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
        .accessibilityLabel("Look Center")
    }

    private var quackCalmPillButton: some View {
        Button {
            Task {
                await appState.playQuack()
            }
        } label: {
            Text("QUACK")
                .font(QuackTheme.condensedDisplay(size: 15))
                .foregroundStyle(QuackTheme.creamText)
                .frame(width: 68, height: QuackTheme.minTouchTarget)
                .quackGlassPill(borderColor: QuackTheme.subtleBorder)
                .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
    }

    private var emoteCircleButton: some View {
        let isHighlighted = activePanel == .emotions || appState.activeEmotionName != nil
        return Button {
            QuackHaptics.light()
            withAnimation(reduceMotion ? .none : .spring(response: 0.24, dampingFraction: 0.85)) {
                activePanel = (activePanel == .emotions) ? nil : .emotions
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: QuackIcon.emotions)
                    .font(.system(size: 16, weight: .semibold))
                Text("Emote")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(QuackTheme.duckOrange)
            .frame(width: 56, height: 56)
            .quackGlassPill(borderColor: QuackTheme.duckOrange.opacity(isHighlighted ? 0.9 : 0.45))
            .contentShape(Circle())
        }
        .buttonStyle(.quackTouch)
        .accessibilityFocused($emoteAccessibilityFocused)
        .accessibilityLabel("Emotions")
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
            .frame(width: 60, height: 60)
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
                .font(QuackTheme.condensedDisplay(size: 17))
                .foregroundStyle(QuackTheme.inkSurface)
                .frame(width: 68, height: 68)
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
            return "—°"
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
                withAnimation(reduceMotion ? .none : .spring(response: 0.24, dampingFraction: 0.85)) {
                    activePanel = (activePanel == .tof) ? nil : .tof
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
                .opacity(isOverlayOn || activePanel == .tof ? 1.0 : 0.55)
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
            withAnimation(reduceMotion ? .none : .spring(response: 0.28, dampingFraction: 0.85)) {
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
        let maxLinear = appState.activeMaxLinearSpeed
        let vx = appState.stickForward * maxLinear
        let vy = appState.stickStrafeLeft * maxLinear
        let speed = hypot(vx, vy)
        if appState.activeDuckPreferences.isCustomSpeedLimit {
            return String(format: "%.2f / %.2f M/S", speed, maxLinear)
        }
        return String(format: "%.2f M/S", speed)
    }
}
