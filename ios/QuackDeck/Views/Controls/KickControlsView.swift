import SwiftUI

enum KickPairStyle {
    case portraitStrip
    case landscapeCompact
}

/// Physical left/right foot kick pair (`kick_left`, `kick_right`).
/// Keeps robot-left on the physical left side regardless of interface layout direction,
/// and leaves an inert blank slot when only one foot is loaded on the robot.
struct KickPairButtons: View {
    let appState: AppState
    var style: KickPairStyle = .portraitStrip

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let sides = appState.availableKickSides
        let spacing: CGFloat = 8

        HStack(spacing: spacing) {
            footSlot(for: .left, loaded: sides.contains(.left))
            footSlot(for: .right, loaded: sides.contains(.right))
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private func footSlot(for side: KickSide, loaded: Bool) -> some View {
        let width: CGFloat = style == .portraitStrip ? 80 : 48
        let height: CGFloat = 48

        if loaded {
            let isActive = appState.displayedActiveKickSide == side
            let isBusyOther = appState.isDrivingInputInhibited && !isActive
            let isEnabled = appState.canTriggerKick(side)

            Button {
                Task {
                    await appState.triggerKick(side)
                }
            } label: {
                slotLabel(for: side, isActive: isActive)
                    .frame(width: width, height: height)
                    .background {
                        if style == .portraitStrip {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(isActive ? QuackTheme.duckOrange.opacity(0.28) : QuackTheme.inkCard)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .strokeBorder(
                                            isActive ? QuackTheme.duckOrange : QuackTheme.duckOrange.opacity(0.42),
                                            lineWidth: isActive ? 1.5 : 1
                                        )
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isActive ? QuackTheme.duckOrange.opacity(0.32) : QuackTheme.inkSurface.opacity(0.76))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(
                                            isActive ? QuackTheme.duckOrange : QuackTheme.duckOrange.opacity(0.45),
                                            lineWidth: isActive ? 1.5 : 1
                                        )
                                )
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: style == .portraitStrip ? 15 : 14, style: .continuous))
                    .opacity(isBusyOther ? 0.5 : 1.0)
                    .scaleEffect(!reduceMotion && isActive ? 0.96 : 1.0)
                    .animation(reduceMotion ? .none : .easeOut(duration: 0.14), value: isActive)
            }
            .buttonStyle(.quackTouch)
            .disabled(!isEnabled && !isActive)
            .accessibilityLabel(side.fullLabel)
            .accessibilityHint("Triggers a brief stationary kick")
            .accessibilityAddTraits(isActive ? .isSelected : [])
        } else {
            Color.clear
                .frame(width: width, height: height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func slotLabel(for side: KickSide, isActive: Bool) -> some View {
        switch style {
        case .portraitStrip:
            HStack(spacing: 5) {
                Image(systemName: QuackIcon.kick)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuackTheme.duckOrange)

                Text(side.shortLabel)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isActive ? QuackTheme.duckOrange : QuackTheme.creamText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 6)

        case .landscapeCompact:
            VStack(spacing: 2) {
                Image(systemName: QuackIcon.kick)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuackTheme.duckOrange)

                Text(side.badgeText)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(isActive ? QuackTheme.duckOrange : QuackTheme.creamText)
                    .lineLimit(1)
            }
        }
    }
}
