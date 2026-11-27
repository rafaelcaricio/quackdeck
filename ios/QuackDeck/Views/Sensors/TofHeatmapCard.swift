import SwiftUI

struct TofHeatmapCard: View {
    let frame: TofFrame?
    let tofHz: Double
    var isCompact: Bool = false
    var isOverlayEnabled: Binding<Bool>? = nil
    var overlayOpacity: Binding<Double>? = nil

    private var gridColumns: Int {
        max(1, Int(frame?.cols ?? 8))
    }

    private var gridRows: Int {
        max(1, Int(frame?.rows ?? 8))
    }

    private var nearestReading: (index: Int, distanceMm: Int)? {
        TofDepthPalette.nearestValidZone(in: frame)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            HStack(alignment: .center, spacing: 8) {
                Text("TOF DEPTH · VL53L5CX")
                    .font(QuackTheme.condensedDisplay(size: isCompact ? 13 : 14))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.85))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(tofHz > 0 ? String(format: "%.0f HZ", tofHz) : "-- HZ")
                    .font(QuackTheme.monoValue(size: 11, weight: .bold))
                    .foregroundStyle(tofHz > 0 ? QuackTheme.acidCyan : QuackTheme.creamText.opacity(0.45))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(QuackTheme.acidCyan.opacity(tofHz > 0 ? 0.14 : 0.06))
                    )
            }

            HStack(alignment: .center, spacing: isCompact ? 10 : 14) {
                heatmapGrid
                    .frame(width: isCompact ? 88 : 116, height: isCompact ? 88 : 116)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(QuackTheme.inkBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(QuackTheme.subtleBorder, lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                    Text("NEAREST")
                        .font(QuackTheme.condensedDisplay(size: 11))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.55))

                    if let nearest = nearestReading {
                        let cm = Int((Double(nearest.distanceMm) / 10.0).rounded())
                        Text("\(cm) cm")
                            .font(QuackTheme.monoValue(size: isCompact ? 22 : 28, weight: .bold))
                            .foregroundStyle(TofDepthPalette.cardColor(forMillimeters: nearest.distanceMm))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text("-- cm")
                            .font(QuackTheme.monoValue(size: isCompact ? 22 : 28, weight: .bold))
                            .foregroundStyle(QuackTheme.creamText.opacity(0.4))
                    }

                    Text(frame == nil ? "Waiting for 8×8 frames" : "8×8 valid range zones")
                        .font(.caption2)
                        .foregroundStyle(QuackTheme.creamText.opacity(0.6))
                        .lineLimit(2)

                    if !isCompact {
                        colorLegend
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let isOverlayEnabled, let overlayOpacity {
                Divider()
                    .overlay(QuackTheme.subtleBorder)

                overlayControls(
                    isEnabled: isOverlayEnabled,
                    opacity: overlayOpacity
                )
            }
        }
        .padding(isCompact ? 10 : 14)
        .quackInsetCard(cornerRadius: isCompact ? 16 : 20)
    }

    private func overlayControls(
        isEnabled: Binding<Bool>,
        opacity: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
            HStack(spacing: 8) {
                Text("DEPTH OVERLAY")
                    .font(QuackTheme.condensedDisplay(size: 11))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                    .tracking(0.5)

                Spacer(minLength: 4)

                Text(isEnabled.wrappedValue ? "\(Int((opacity.wrappedValue * 100).rounded()))%" : "OFF")
                    .font(QuackTheme.monoValue(size: 11, weight: .bold))
                    .foregroundStyle(
                        isEnabled.wrappedValue
                            ? QuackTheme.acidCyan
                            : QuackTheme.creamText.opacity(0.45)
                    )

                Toggle("Depth overlay", isOn: isEnabled)
                    .labelsHidden()
                    .tint(QuackTheme.acidCyan)
                    .scaleEffect(isCompact ? 0.85 : 0.92)
                    .accessibilityLabel("Depth overlay")
                    .accessibilityValue(isEnabled.wrappedValue ? "On, \(Int((opacity.wrappedValue * 100).rounded())) percent" : "Off")
            }
            .frame(minHeight: QuackTheme.minTouchTarget)

            Slider(
                value: Binding(
                    get: { opacity.wrappedValue },
                    set: { newValue in
                        if !isEnabled.wrappedValue {
                            isEnabled.wrappedValue = true
                        }
                        opacity.wrappedValue = newValue
                    }
                ),
                in: AppState.tofOverlayOpacityRange,
                step: 0.05
            )
            .tint(QuackTheme.acidCyan)
            .opacity(isEnabled.wrappedValue ? 1.0 : 0.45)
            .accessibilityLabel("ToF video overlay opacity")
        }
    }

    private var heatmapGrid: some View {
        let nearestIdx = nearestReading?.index
        return Canvas { context, size in
            let cols = gridColumns
            let rows = gridRows
            let gap: CGFloat = 2
            let cellW = (size.width - gap * CGFloat(max(0, cols - 1))) / CGFloat(cols)
            let cellH = (size.height - gap * CGFloat(max(0, rows - 1))) / CGFloat(rows)

            for r in 0..<rows {
                for c in 0..<cols {
                    let idx = r * cols + c
                    let rect = CGRect(
                        x: CGFloat(c) * (cellW + gap),
                        y: CGFloat(r) * (cellH + gap),
                        width: max(1, cellW),
                        height: max(1, cellH)
                    )
                    let path = Path(roundedRect: rect, cornerRadius: 2)

                    if let frame, frame.isValidZone(at: idx) {
                        let mm = Int(frame.distance_mm[idx])
                        context.fill(path, with: .color(TofDepthPalette.cardColor(forMillimeters: mm)))
                        if nearestIdx == idx {
                            context.stroke(
                                path,
                                with: .color(QuackTheme.creamText.opacity(0.95)),
                                lineWidth: 1.4
                            )
                        }
                    } else {
                        context.fill(path, with: .color(Color.white.opacity(0.05)))
                    }
                }
            }
        }
    }

    private var colorLegend: some View {
        HStack(spacing: 8) {
            legendItem(color: QuackTheme.dangerRed, label: "<20")
            legendItem(color: QuackTheme.warnYellow, label: "20-60")
            legendItem(color: QuackTheme.acidCyan, label: "60-150")
            legendItem(color: Color(hex: 0x161b29), label: ">150")
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(QuackTheme.monoValue(size: 9, weight: .medium))
                .foregroundStyle(QuackTheme.creamText.opacity(0.55))
        }
    }
}
