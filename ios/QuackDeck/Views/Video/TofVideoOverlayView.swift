import SwiftUI
import UIKit

enum TofDepthPalette {
    static func nearestValidZone(in frame: TofFrame?) -> (index: Int, distanceMm: Int)? {
        guard let frame else { return nil }
        let count = min(frame.distance_mm.count, frame.status.count)
        var best: (index: Int, distanceMm: Int)?
        for idx in 0..<count where frame.isValidZone(at: idx) {
            let mm = Int(frame.distance_mm[idx])
            if best == nil || mm < best!.distanceMm {
                best = (idx, mm)
            }
        }
        return best
    }

    static func cardColor(forMillimeters mm: Int) -> Color {
        let cm = Double(mm) / 10.0
        if cm < 20 {
            let t = max(0, min(1, cm / 20.0))
            return interpolateColor(from: QuackTheme.dangerRed, to: QuackTheme.duckOrange, t: t)
        } else if cm < 60 {
            let t = (cm - 20.0) / 40.0
            return interpolateColor(from: QuackTheme.duckOrange, to: QuackTheme.warnYellow, t: t)
        } else if cm <= 150 {
            let t = (cm - 60.0) / 90.0
            return interpolateColor(from: QuackTheme.acidCyan, to: QuackTheme.acidCyan.opacity(0.35), t: t)
        } else {
            return QuackTheme.inkBg.opacity(0.95)
        }
    }

    /// Video-friendly depth color that stays bright for nearby obstacles and
    /// translucent for far (>150 cm) zones so the live camera feed stays legible.
    static func overlayColor(forMillimeters mm: Int) -> Color {
        let cm = Double(mm) / 10.0
        if cm < 20 {
            let t = max(0, min(1, cm / 20.0))
            return interpolateColor(from: QuackTheme.dangerRed, to: QuackTheme.duckOrange, t: t)
        } else if cm < 60 {
            let t = (cm - 20.0) / 40.0
            return interpolateColor(from: QuackTheme.duckOrange, to: QuackTheme.warnYellow, t: t)
        } else if cm <= 150 {
            let t = (cm - 60.0) / 90.0
            return interpolateColor(from: QuackTheme.acidCyan, to: QuackTheme.acidCyan.opacity(0.45), t: t)
        } else {
            return QuackTheme.acidCyan.opacity(0.18)
        }
    }

    private static func interpolateColor(from: Color, to: Color, t: Double) -> Color {
        let clamped = max(0, min(1, t))
        let uiFrom = UIColor(from)
        let uiTo = UIColor(to)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        uiFrom.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        uiTo.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            .sRGB,
            red: r1 + (r2 - r1) * clamped,
            green: g1 + (g2 - g1) * clamped,
            blue: b1 + (b2 - b1) * clamped,
            opacity: a1 + (a2 - a1) * clamped
        )
    }
}

/// Renders the VL53L5CX 8×8 ToF depth grid centered over the upright video feed
/// with configurable opacity, preserving the sensor's 1:1 45°×45° field of view.
struct TofVideoOverlayView: View {
    let frame: TofFrame
    let opacity: Double
    var gridRect: CGRect? = nil
    var clipRect: CGRect? = nil

    var body: some View {
        let clampedOpacity = AppState.clampTofOverlayOpacity(opacity)
        let nearest = TofDepthPalette.nearestValidZone(in: frame)

        Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }

            let drawLayerContent: (inout GraphicsContext) -> Void = { ctx in
                let cols = max(1, Int(frame.cols))
                let rows = max(1, Int(frame.rows))
                let resolvedGridRect: CGRect
                if let gridRect, gridRect.width >= 48, gridRect.height >= 48 {
                    resolvedGridRect = gridRect
                } else {
                    let isLandscape = size.width > size.height
                    let fallbackSide = isLandscape
                        ? min(size.width * 0.46, size.height * 0.66)
                        : min(size.width * 0.84, size.height * 0.58)
                    guard fallbackSide >= 48 else { return }
                    resolvedGridRect = CGRect(
                        x: (size.width - fallbackSide) * 0.5,
                        y: (size.height - fallbackSide) * 0.5,
                        width: fallbackSide,
                        height: fallbackSide
                    )
                }

                let gridSide = min(resolvedGridRect.width, resolvedGridRect.height)
                guard gridSide >= 48 else { return }
                let originX = resolvedGridRect.minX
                let originY = resolvedGridRect.minY

                let gap: CGFloat = 2.5
                let cellW = (gridSide - gap * CGFloat(max(0, cols - 1))) / CGFloat(cols)
                let cellH = (gridSide - gap * CGFloat(max(0, rows - 1))) / CGFloat(rows)
                let cornerRadius = max(2.0, min(5.0, min(cellW, cellH) * 0.16))

                // Subtle corner brackets framing the 45°×45° ToF cone
                drawCornerBrackets(in: &ctx, rect: resolvedGridRect.insetBy(dx: -5, dy: -5))

                var nearestCellRect: CGRect?

                for r in 0..<rows {
                    for c in 0..<cols {
                        let idx = r * cols + c
                        let cellRect = CGRect(
                            x: originX + CGFloat(c) * (cellW + gap),
                            y: originY + CGFloat(r) * (cellH + gap),
                            width: max(1, cellW),
                            height: max(1, cellH)
                        )
                        let cellPath = Path(roundedRect: cellRect, cornerRadius: cornerRadius)

                        if frame.isValidZone(at: idx) {
                            let mm = Int(frame.distance_mm[idx])
                            ctx.fill(cellPath, with: .color(TofDepthPalette.overlayColor(forMillimeters: mm)))

                            if nearest?.index == idx {
                                nearestCellRect = cellRect
                                ctx.stroke(
                                    cellPath,
                                    with: .color(QuackTheme.creamText.opacity(0.95)),
                                    lineWidth: 1.8
                                )
                            }
                        } else {
                            ctx.stroke(
                                cellPath,
                                with: .color(Color.white.opacity(0.10)),
                                lineWidth: 0.75
                            )
                        }
                    }
                }

                if let nearest, let cellRect = nearestCellRect, cellW >= 20 {
                    let cm = Int((Double(nearest.distanceMm) / 10.0).rounded())
                    let label = cm >= 100 ? String(format: "%.1fm", Double(cm) / 100.0) : "\(cm)cm"
                    let text = Text(label)
                        .font(QuackTheme.monoValue(size: 10, weight: .bold))
                        .foregroundStyle(QuackTheme.creamText)
                    let resolved = ctx.resolve(text)
                    let textSize = resolved.measure(in: CGSize(width: 80, height: 20))
                    let pillW = textSize.width + 8
                    let pillH = textSize.height + 4
                    let pillX = min(max(cellRect.midX - pillW * 0.5, resolvedGridRect.minX), resolvedGridRect.maxX - pillW)
                    let preferredY = cellRect.minY - pillH - 4
                    let pillY = preferredY >= resolvedGridRect.minY ? preferredY : cellRect.maxY + 4
                    let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
                    ctx.fill(
                        Path(roundedRect: pillRect, cornerRadius: 5),
                        with: .color(QuackTheme.inkBg.opacity(0.82))
                    )
                    ctx.draw(resolved, at: CGPoint(x: pillRect.midX, y: pillRect.midY), anchor: .center)
                }
            }

            if let clipRect, clipRect.width > 0, clipRect.height > 0 {
                context.drawLayer { clipped in
                    clipped.clip(to: Path(clipRect))
                    drawLayerContent(&clipped)
                }
            } else {
                drawLayerContent(&context)
            }
        }
        .opacity(clampedOpacity)
        .allowsHitTesting(false)
    }

    private func drawCornerBrackets(in context: inout GraphicsContext, rect: CGRect) {
        let len: CGFloat = 12
        var path = Path()

        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))

        // Top-right
        path.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))

        // Bottom-left
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + len, y: rect.maxY))

        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - len))

        context.stroke(
            path,
            with: .color(QuackTheme.acidCyan.opacity(0.65)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }
}

/// Compact floating glass control pill for toggling the ToF video overlay and
/// adjusting its opacity live over the camera feed.
struct TofOverlayControlsBar: View {
    let appState: AppState
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                QuackHaptics.light()
                appState.isTofOverlayEnabled.toggle()
            } label: {
                Image(systemName: appState.isTofOverlayEnabled ? QuackIcon.eye : QuackIcon.eyeSlash)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        appState.isTofOverlayEnabled
                            ? QuackTheme.acidCyan
                            : QuackTheme.creamText.opacity(0.55)
                    )
                    .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                    .background(
                        Circle().fill(
                            appState.isTofOverlayEnabled
                                ? QuackTheme.acidCyan.opacity(0.16)
                                : QuackTheme.creamText.opacity(0.08)
                        )
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.quackTouch)
            .accessibilityLabel(appState.isTofOverlayEnabled ? "Hide ToF overlay" : "Show ToF overlay")

            Slider(
                value: Binding(
                    get: { appState.tofOverlayOpacity },
                    set: { newValue in
                        if !appState.isTofOverlayEnabled {
                            appState.isTofOverlayEnabled = true
                        }
                        appState.tofOverlayOpacity = newValue
                    }
                ),
                in: AppState.tofOverlayOpacityRange,
                step: 0.05
            )
            .tint(QuackTheme.acidCyan)
            .accessibilityLabel("ToF overlay opacity")

            Text(appState.isTofOverlayEnabled ? "\(Int((appState.tofOverlayOpacity * 100).rounded()))%" : "OFF")
                .font(QuackTheme.monoValue(size: 12, weight: .bold))
                .foregroundStyle(
                    appState.isTofOverlayEnabled
                        ? QuackTheme.acidCyan
                        : QuackTheme.creamText.opacity(0.5)
                )
                .frame(width: 38, alignment: .trailing)

            Button {
                QuackHaptics.light()
                onClose()
            } label: {
                Image(systemName: QuackIcon.close)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.75))
                    .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(.quackTouch)
            .accessibilityLabel("Close ToF overlay controls")
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .frame(height: 50)
        .quackGlassPill(borderColor: QuackTheme.acidCyan.opacity(0.4))
    }
}
