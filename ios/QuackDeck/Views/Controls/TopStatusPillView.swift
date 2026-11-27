import SwiftUI

struct TopStatusPillView: View {
    let appState: AppState

    var body: some View {
        Button {
            QuackHaptics.light()
            appState.isDucksSheetPresented = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: statusDotColor.opacity(appState.isConnected ? 0.75 : 0.25), radius: 5)

                Text(appState.currentDuckName.uppercased())
                    .font(QuackTheme.condensedDisplay(size: 15))
                    .foregroundStyle(QuackTheme.creamText)
                    .lineLimit(1)

                if let percent = appState.telemetry.batteryPercent {
                    let clamped = Int(max(0, min(100, percent)).rounded())
                    Text("\(clamped)%")
                        .font(QuackTheme.monoValue(size: 13))
                        .foregroundStyle(batteryColor)
                } else {
                    Text(appState.phase.shortLabel)
                        .font(QuackTheme.monoValue(size: 12, weight: .medium))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.68))
                }

                Image(systemName: QuackIcon.chevronDown)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.65))
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(minWidth: QuackTheme.minTouchTarget, minHeight: QuackTheme.minTouchTarget)
            .quackGlassPill()
            .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
        .accessibilityLabel(statusAccessibilityLabel)
    }

    private var statusAccessibilityLabel: String {
        if let percent = appState.telemetry.batteryPercent {
            let clamped = Int(max(0, min(100, percent)).rounded())
            return "Duck selector, \(appState.currentDuckName), \(clamped) percent battery"
        }
        return "Duck selector, \(appState.currentDuckName), \(appState.phase.shortLabel)"
    }

    private var statusDotColor: Color {
        switch appState.phase {
        case .connected:
            return QuackTheme.okGreen
        case .disconnected:
            return QuackTheme.creamText.opacity(0.4)
        case .error:
            return QuackTheme.dangerRed
        default:
            return QuackTheme.warnYellow
        }
    }

    private var batteryColor: Color {
        guard let battery = appState.telemetry.health?.battery else {
            return QuackTheme.okGreen
        }
        if battery.isCritical {
            return QuackTheme.dangerRed
        }
        if battery.isLow {
            return QuackTheme.warnYellow
        }
        return QuackTheme.okGreen
    }
}

struct StopPillButton: View {
    let appState: AppState

    var body: some View {
        Button {
            Task {
                await appState.emergencyStop()
            }
        } label: {
            Text("STOP")
                .font(.system(size: 14, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(QuackTheme.creamText)
                .padding(.horizontal, 18)
                .frame(minWidth: 80, minHeight: QuackTheme.minTouchTarget)
                .background(
                    Capsule()
                        .fill(QuackTheme.dangerRed)
                        .shadow(color: QuackTheme.dangerRed.opacity(0.45), radius: 8, y: 3)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
        .accessibilityLabel("Stop Moving")
    }
}

struct GuidanceStripView: View {
    let text: String
    let tone: GuidanceTone
    var isCompactPill: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            toneIndicator

            Text(text)
                .font(.system(size: isCompactPill ? 11 : 12, weight: .semibold))
                .foregroundStyle(QuackTheme.creamText.opacity(tone == .neutral ? 0.86 : 0.96))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if !isCompactPill {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompactPill ? 6 : 7)
        .background {
            if isCompactPill {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(compactFillColor))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(cardFillColor)
            }
        }
        .overlay {
            if isCompactPill {
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var toneIndicator: some View {
        switch tone {
        case .neutral:
            Circle()
                .fill(QuackTheme.creamText.opacity(0.55))
                .frame(width: 6, height: 6)

        case .caution:
            Circle()
                .fill(QuackTheme.warnYellow)
                .frame(width: 7, height: 7)

        case .danger:
            Image(systemName: QuackIcon.statusError)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(QuackTheme.dangerRed)
        }
    }

    private var compactFillColor: Color {
        switch tone {
        case .neutral:
            return QuackTheme.glassFill
        case .caution:
            return QuackTheme.inkSurface.opacity(0.82)
        case .danger:
            return QuackTheme.dangerRed.opacity(0.22)
        }
    }

    private var cardFillColor: Color {
        switch tone {
        case .neutral:
            return QuackTheme.inkCard.opacity(0.92)
        case .caution:
            return QuackTheme.warnYellow.opacity(0.13)
        case .danger:
            return QuackTheme.dangerRed.opacity(0.15)
        }
    }

    private var borderColor: Color {
        switch tone {
        case .neutral:
            return QuackTheme.subtleBorder
        case .caution:
            return QuackTheme.warnYellow.opacity(0.52)
        case .danger:
            return QuackTheme.dangerRed.opacity(0.58)
        }
    }
}

struct ThermalCautionBanner: View {
    enum Style {
        case overlay
        case inline
    }

    let level: ThermalAlertLevel
    let message: String
    var style: Style = .overlay

    var body: some View {
        let accent = level == .hot ? QuackTheme.dangerRed : QuackTheme.warnYellow
        let cornerRadius: CGFloat = style == .overlay ? 14 : 12
        let fillColor: Color = style == .overlay
            ? QuackTheme.inkSurface.opacity(0.88)
            : accent.opacity(0.16)
        let borderColor: Color = style == .overlay
            ? accent.opacity(0.75)
            : accent.opacity(0.45)

        HStack(spacing: 8) {
            Image(systemName: QuackIcon.thermal(for: level))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)

            Text(message)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(QuackTheme.creamText)
                .lineLimit(style == .overlay ? 2 : nil)
                .fixedSize(horizontal: false, vertical: style == .inline)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, style == .overlay ? 7 : 8)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
        }
    }
}
