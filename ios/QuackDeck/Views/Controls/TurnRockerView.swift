import SwiftUI
import UIKit

enum TurnRockerStyle {
    case portraitSplit
    case landscapePill
}

struct TurnRockerView: View {
    let appState: AppState
    var style: TurnRockerStyle = .portraitSplit

    @State private var activeDirection: Int = 0 // 1 = left (+vyaw), -1 = right (-vyaw)

    var body: some View {
        Group {
            switch style {
            case .portraitSplit:
                HStack(spacing: QuackTheme.controlSpacing) {
                    turnButton(title: "Left", direction: 1, isPill: false)
                        .overlay {
                            TurnHoldTouchOverlay(mode: .fixed(1)) { direction in
                                if direction == 0 {
                                    releaseDirection(1)
                                } else {
                                    applyDirection(direction)
                                }
                            }
                            .accessibilityHidden(true)
                        }
                    turnButton(title: "Right", direction: -1, isPill: false)
                        .overlay {
                            TurnHoldTouchOverlay(mode: .fixed(-1)) { direction in
                                if direction == 0 {
                                    releaseDirection(-1)
                                } else {
                                    applyDirection(direction)
                                }
                            }
                            .accessibilityHidden(true)
                        }
                }

            case .landscapePill:
                HStack(spacing: 6) {
                    turnButton(title: "Turn", direction: 1, isPill: true)
                    turnButton(title: "Turn", direction: -1, isPill: true)
                }
                .padding(4)
                .quackGlassPill()
                .overlay {
                    TurnHoldTouchOverlay(mode: .splitHorizontal) { direction in
                        applyDirection(direction)
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: appState.turnYawLeft) { _, newValue in
            if newValue == 0 && activeDirection != 0 {
                activeDirection = 0
            }
        }
    }

    private func applyDirection(_ newDirection: Int) {
        if newDirection == 0 {
            if activeDirection != 0 {
                activeDirection = 0
            }
            if appState.turnYawLeft != 0 {
                appState.updateTurnRocker(yawLeft: 0)
            }
            return
        }
        guard activeDirection != newDirection else { return }
        activeDirection = newDirection
        QuackHaptics.light()
        appState.updateTurnRocker(yawLeft: Double(newDirection))
    }

    private func releaseDirection(_ direction: Int) {
        guard activeDirection == direction else { return }
        activeDirection = 0
        if appState.turnYawLeft != 0 {
            appState.updateTurnRocker(yawLeft: 0)
        }
    }

    private func turnButton(title: String, direction: Int, isPill: Bool) -> some View {
        let isActive = activeDirection == direction
        let isLeft = direction > 0
        let symbolName = isLeft ? QuackIcon.turnLeft : QuackIcon.turnRight

        return HStack(spacing: isPill ? 5 : 6) {
            if isLeft {
                Image(systemName: symbolName)
                    .font(.system(size: isPill ? 13 : 14, weight: .semibold))
            }
            Text(title)
                .font(.system(size: isPill ? 14 : 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if !isLeft {
                Image(systemName: symbolName)
                    .font(.system(size: isPill ? 13 : 14, weight: .semibold))
            }
        }
        .foregroundStyle(isActive ? QuackTheme.inkSurface : QuackTheme.creamText)
        .padding(.horizontal, isPill ? 14 : 8)
        .frame(minWidth: isPill ? 84 : nil, maxWidth: isPill ? nil : .infinity)
        .frame(height: isPill ? QuackTheme.minTouchTarget : 52)
        .background {
            if isPill {
                Capsule()
                    .fill(isActive ? QuackTheme.duckOrange : Color.clear)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isActive ? QuackTheme.duckOrange : Color(hex: 0x161622))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isActive ? QuackTheme.duckOrange : QuackTheme.creamText.opacity(0.12),
                                lineWidth: 1
                            )
                    )
            }
        }
        .scaleEffect(isActive ? 0.96 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isActive)
        .contentShape(
            isPill
                ? AnyShape(Capsule())
                : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLeft ? "Turn left" : "Turn right")
        .accessibilityAddTraits(.isButton)
    }
}

private enum TurnTouchMode: Equatable {
    case fixed(Int)
    case splitHorizontal
}

private final class TurnTouchUIView: UIView {
    var onDetach: (() -> Void)?

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            onDetach?()
        }
    }
}

private struct TurnHoldTouchOverlay: UIViewRepresentable {
    let mode: TurnTouchMode
    let onDirectionChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, onDirectionChanged: onDirectionChanged)
    }

    func makeUIView(context: Context) -> TurnTouchUIView {
        let view = TurnTouchUIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isAccessibilityElement = false
        view.onDetach = { [weak coordinator = context.coordinator] in
            coordinator?.resetIfNeeded(async: true)
        }

        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePress(_:))
        )
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = 10_000
        recognizer.delaysTouchesBegan = false
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        context.coordinator.attachedView = view
        return view
    }

    func updateUIView(_ uiView: TurnTouchUIView, context: Context) {
        context.coordinator.mode = mode
        context.coordinator.onDirectionChanged = onDirectionChanged
    }

    static func dismantleUIView(_ uiView: TurnTouchUIView, coordinator: Coordinator) {
        uiView.onDetach = nil
        coordinator.resetIfNeeded(async: true)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var mode: TurnTouchMode
        var onDirectionChanged: (Int) -> Void
        weak var attachedView: UIView?
        private var lastDirection: Int = 0

        init(mode: TurnTouchMode, onDirectionChanged: @escaping (Int) -> Void) {
            self.mode = mode
            self.onDirectionChanged = onDirectionChanged
        }

        @objc func handlePress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let direction: Int
                switch mode {
                case .fixed(let fixedDirection):
                    direction = fixedDirection
                case .splitHorizontal:
                    guard let view = attachedView ?? recognizer.view, view.bounds.width > 0 else {
                        return
                    }
                    let location = recognizer.location(in: view)
                    direction = location.x < view.bounds.midX ? 1 : -1
                }
                if lastDirection != direction {
                    lastDirection = direction
                    onDirectionChanged(direction)
                }

            case .ended, .cancelled, .failed:
                resetIfNeeded(async: false)

            default:
                break
            }
        }

        func resetIfNeeded(async: Bool) {
            guard lastDirection != 0 else { return }
            lastDirection = 0
            let callback = onDirectionChanged
            if async {
                DispatchQueue.main.async {
                    callback(0)
                }
            } else {
                callback(0)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer.view !== gestureRecognizer.view
        }
    }
}
