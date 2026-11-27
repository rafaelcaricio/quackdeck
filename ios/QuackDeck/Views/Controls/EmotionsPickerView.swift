import SwiftUI

struct EmotionsPickerPanel: View {
    let emotions: [String]
    let activeEmotionName: String?
    var columns: Int = 3
    var onSelect: (String) -> Void
    var onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var effectiveColumns: Int {
        if dynamicTypeSize.isAccessibilitySize {
            return max(1, columns - 2)
        }
        return max(1, columns)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: effectiveColumns)
    }

    private var maxGridHeight: CGFloat {
        columns <= 3 ? 192 : 146
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("EMOTIONS")
                    .font(QuackTheme.condensedDisplay(size: 14))
                    .foregroundStyle(QuackTheme.duckOrange)

                Text("(\(emotions.count))")
                    .font(QuackTheme.monoValue(size: 12, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.62))

                Spacer(minLength: 8)

                Button {
                    QuackHaptics.light()
                    onClose()
                } label: {
                    Image(systemName: QuackIcon.close)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(QuackTheme.creamText.opacity(0.1)))
                        .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                        .contentShape(Circle())
                }
                .buttonStyle(.quackTouch)
                .accessibilityLabel("Close Emotions")
            }

            ViewThatFits(in: .vertical) {
                gridContent
                ScrollView(.vertical, showsIndicators: true) {
                    gridContent
                }
            }
            .frame(maxHeight: maxGridHeight)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .quackGlassPill(cornerRadius: 22, borderColor: QuackTheme.duckOrange.opacity(0.45))
        .shadow(color: .black.opacity(0.42), radius: 14, y: 6)
    }

    private var gridContent: some View {
        LazyVGrid(columns: gridColumns, spacing: 8) {
            ForEach(emotions, id: \.self) { name in
                emotionButton(for: name)
            }
        }
        .padding(.trailing, 6)
    }

    private func emotionButton(for name: String) -> some View {
        let label = MicroduckEmotions.displayLabel(for: name)
        let maySit = MicroduckEmotions.maySitRobot(name)
        let isActive = activeEmotionName == name

        return Button {
            onSelect(name)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isActive ? QuackTheme.creamText : QuackTheme.creamText.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if maySit {
                        maySitBadge
                    }
                }

                VStack(spacing: 3) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isActive ? QuackTheme.creamText : QuackTheme.creamText.opacity(0.92))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    if maySit {
                        maySitBadge
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: QuackTheme.minTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? QuackTheme.duckOrange.opacity(0.28) : QuackTheme.creamText.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isActive ? QuackTheme.duckOrange : QuackTheme.subtleBorder,
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.quackTouch)
        .accessibilityLabel(maySit ? "\(label), may sit robot" : label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var maySitBadge: some View {
        Text("May sit")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(QuackTheme.inkSurface)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(QuackTheme.warnYellow)
            )
    }
}

struct ActiveEmotionBadgePill: View {
    var activeKickSide: KickSide? = nil
    let emotionName: String?
    let endsAt: Date?
    var showCountdown: Bool = true
    let statusNote: String?

    var body: some View {
        if let statusNote, !statusNote.isEmpty {
            pillContainer {
                Circle()
                    .fill(QuackTheme.duckOrange)
                    .frame(width: 7, height: 7)

                Text(statusNote)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        } else if let activeKickSide {
            pillContainer {
                Circle()
                    .fill(QuackTheme.duckOrange)
                    .frame(width: 7, height: 7)

                Image(systemName: QuackIcon.kick)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QuackTheme.duckOrange)

                Text(activeKickSide.activeBannerText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        } else if let emotionName {
            pillContainer {
                Circle()
                    .fill(QuackTheme.duckOrange)
                    .frame(width: 7, height: 7)

                Text("Emotion: \(MicroduckEmotions.displayLabel(for: emotionName))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if showCountdown, let endsAt, endsAt.timeIntervalSinceNow > 0 {
                    TimelineView(.periodic(from: .now, by: 0.2)) { context in
                        let remaining = endsAt.timeIntervalSince(context.date)
                        if remaining > 0.05 {
                            Text(String(format: "%.1fs", remaining))
                                .font(QuackTheme.monoValue(size: 12, weight: .semibold))
                                .foregroundStyle(QuackTheme.duckOrange)
                        }
                    }
                }
            }
        }
    }

    private func pillContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .quackGlassPill(borderColor: QuackTheme.duckOrange.opacity(0.65))
        .allowsHitTesting(false)
    }
}
