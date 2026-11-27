import SwiftUI

struct PortraitLiveView: View {
    private enum ActiveHudPanel: Equatable {
        case tof
        case emotions
    }

    let appState: AppState
    var onOpenSensorsTab: () -> Void

    @AppStorage("portraitVideoFraming") private var storedFramingRaw: String = PortraitVideoFraming.fill.rawValue
    @State private var activePanel: ActiveHudPanel?
    @State private var framingToastText: String?
    @State private var framingToastTask: Task<Void, Never>?
    @AccessibilityFocusState private var emoteAccessibilityFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var portraitFraming: PortraitVideoFraming {
        PortraitVideoFraming(rawValue: storedFramingRaw) ?? .fill
    }

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let isCompact = totalHeight < 700

            VStack(spacing: 0) {
                cameraStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        if activePanel == .emotions && appState.canTriggerEmotions {
                            EmotionsPickerPanel(
                                emotions: appState.availableEmotions,
                                activeEmotionName: appState.activeEmotionName,
                                columns: 3,
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
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                if appState.isConnected && (appState.canTriggerEmotions || appState.canShowKicks) {
                    portraitActionStrip
                }

                bottomControlStage(isCompact: isCompact)
            }
            .background(QuackTheme.inkBg)
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
            .onDisappear {
                framingToastTask?.cancel()
                appState.stopAllMotion()
            }
        }
    }

    private func togglePortraitFraming() {
        let next = portraitFraming.toggled
        storedFramingRaw = next.rawValue
        QuackHaptics.light()
        showFramingToast(next.title)
    }

    private func showFramingToast(_ text: String) {
        framingToastTask?.cancel()
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.16)) {
            framingToastText = text
        }
        framingToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.18)) {
                framingToastText = nil
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

    private var cameraStage: some View {
        ZStack {
            VideoStageView(
                appState: appState,
                framing: portraitFraming,
                onDoubleTapFramingToggle: {
                    togglePortraitFraming()
                }
            )

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

                if let framingToastText {
                    Text(framingToastText)
                        .font(QuackTheme.monoValue(size: 12, weight: .bold))
                        .foregroundStyle(QuackTheme.acidCyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .quackGlassPill(borderColor: QuackTheme.acidCyan.opacity(0.55))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                if appState.motorThermalLevel != .normal, let banner = appState.thermalBannerText {
                    ThermalCautionBanner(level: appState.motorThermalLevel, message: banner)
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

                Spacer()

                // Floating live HUD chips
                if appState.isConnected {
                    VStack(spacing: 8) {
                        if activePanel == .tof {
                            TofOverlayControlsBar(appState: appState) {
                                closePanels(restoreEmoteFocus: false)
                            }
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        }

                        HStack(spacing: QuackTheme.controlSpacing) {
                            unifiedTelemetryPill
                            Spacer(minLength: 6)
                            if appState.videoSource != .none {
                                framingToggleButton
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    private var framingToggleButton: some View {
        let isFit = portraitFraming == .fit
        let icon = isFit
            ? "arrow.up.backward.and.arrow.down.forward"
            : "arrow.down.forward.and.arrow.up.backward"

        return Button {
            togglePortraitFraming()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(QuackTheme.acidCyan)
                .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                .background(
                    Circle()
                        .fill(isFit ? QuackTheme.acidCyan.opacity(0.18) : Color.clear)
                )
                .quackGlassPill(borderColor: QuackTheme.acidCyan.opacity(isFit ? 0.95 : 0.45))
                .contentShape(Circle())
        }
        .buttonStyle(.quackTouch)
        .accessibilityLabel("Video framing")
        .accessibilityValue(portraitFraming.title)
        .accessibilityHint("Switches between full frame and fill screen, or double-tap the video")
    }

    private var portraitActionStrip: some View {
        HStack(spacing: QuackTheme.controlSpacing) {
            if appState.canTriggerEmotions {
                emoteChip
            }

            Spacer(minLength: 8)

            if appState.canShowKicks {
                KickPairButtons(appState: appState, style: .portraitStrip)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(QuackTheme.inkBg)
    }

    private var unifiedTelemetryPill: some View {
        let tofText = appState.telemetry.nearestTofMeters.map { String(format: "TOF %.2fm", $0) } ?? "TOF --"
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
                tempText: tempText,
                tempColor: tempColor,
                fpsText: fpsText,
                showFps: true
            )

            telemetryPillContent(
                tofText: tofText,
                tempText: tempText,
                tempColor: tempColor,
                fpsText: fpsText,
                showFps: false
            )
        }
    }

    private func telemetryPillContent(
        tofText: String,
        tempText: String,
        tempColor: Color,
        fpsText: String,
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
                .opacity(isOverlayOn || activePanel == .tof ? 1.0 : 0.58)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(minWidth: QuackTheme.minTouchTarget, minHeight: QuackTheme.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.quackTouch)
            .accessibilityLabel("ToF overlay controls, \(tofText), \(isOverlayOn ? "\(Int((appState.tofOverlayOpacity * 100).rounded())) percent" : "off")")

            dividerBar

            Button {
                QuackHaptics.light()
                onOpenSensorsTab()
            } label: {
                Text(tempText)
                    .foregroundStyle(tempColor)
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .padding(.trailing, showFps ? 8 : 12)
                    .frame(minWidth: QuackTheme.minTouchTarget, minHeight: QuackTheme.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.quackTouch)
            .accessibilityLabel("Open sensors, hottest servo \(tempText)")

            if showFps {
                dividerBar

                Text(fpsText)
                    .foregroundStyle(QuackTheme.creamText.opacity(0.75))
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
            }
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

    private var emoteChip: some View {
        let isHighlighted = activePanel == .emotions || appState.activeEmotionName != nil
        return Button {
            QuackHaptics.light()
            withAnimation(reduceMotion ? .none : .spring(response: 0.24, dampingFraction: 0.85)) {
                activePanel = (activePanel == .emotions) ? nil : .emotions
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: QuackIcon.emotions)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(QuackTheme.duckOrange)
                Text("Emote")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: QuackTheme.minTouchTarget, minHeight: 48)
            .quackGlassPill(borderColor: QuackTheme.duckOrange.opacity(isHighlighted ? 0.9 : 0.45))
            .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
        .accessibilityFocused($emoteAccessibilityFocused)
        .accessibilityLabel("Emotions")
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
