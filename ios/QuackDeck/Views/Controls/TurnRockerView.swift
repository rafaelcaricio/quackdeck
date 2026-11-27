import SwiftUI
import UIKit

enum TurnRockerStyle {
    case portraitSplit
    case landscapePill
    case landscapeCompact
}

struct TurnRockerView: View {
    let appState: AppState
    var style: TurnRockerStyle = .portraitSplit

    @State private var activeDirection: Int = 0 // 1 = left (+vyaw), -1 = right (-vyaw)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isInhibited: Bool {
        appState.isDrivingInputInhibited
    }

    var body: some View {
        Group {
            switch style {
            case .portraitSplit:
                HStack(spacing: QuackTheme.controlSpacing) {
                    turnButton(title: "Left", direction: 1, pillMode: .none)
                        .overlay {
                            TurnHoldTouchOverlay(mode: .fixed(1), isEnabled: !isInhibited) { direction in
                                if direction == 0 {
                                    releaseDirection(1)
                                } else {
                                    applyDirection(direction)
                                }
                            }
                            .accessibilityHidden(true)
                        }
                    turnButton(title: "Right", direction: -1, pillMode: .none)
                        .overlay {
                            TurnHoldTouchOverlay(mode: .fixed(-1), isEnabled: !isInhibited) { direction in
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
                    turnButton(title: "Turn", direction: 1, pillMode: .standard)
                    turnButton(title: "Turn", direction: -1, pillMode: .standard)
                }
                .padding(4)
                .quackGlassPill()
                .overlay {
                    TurnHoldTouchOverlay(mode: .splitHorizontal, isEnabled: !isInhibited) { direction in
                        applyDirection(direction)
                    }
                    .accessibilityHidden(true)
                }

            case .landscapeCompact:
                HStack(spacing: 6) {
                    turnButton(title: "L", direction: 1, pillMode: .compact)
                    turnButton(title: "R", direction: -1, pillMode: .compact)
                }
                .padding(4)
                .quackGlassPill()
                .overlay {
                    TurnHoldTouchOverlay(mode: .splitHorizontal, isEnabled: !isInhibited) { direction in
                        applyDirection(direction)
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .opacity(isInhibited ? 0.45 : 1.0)
        .onChange(of: appState.turnYawLeft) { _, newValue in
            if newValue == 0 && activeDirection != 0 {
                activeDirection = 0
            }
        }
        .onChange(of: isInhibited) { _, inhibited in
            if inhibited && activeDirection != 0 {
                activeDirection = 0
            }
        }
        .onChange(of: appState.inputResetGeneration) { _, _ in
            activeDirection = 0
        }
        .onDisappear {
            if activeDirection != 0 || appState.turnYawLeft != 0 {
                activeDirection = 0
                appState.updateTurnRocker(yawLeft: 0)
            }
        }
    }

    private enum PillMode {
        case none
        case standard
        case compact
    }

    private func applyDirection(_ newDirection: Int) {
        if newDirection == 0 || isInhibited {
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

    private func pulseAccessibleTurn(_ direction: Int) {
        guard !isInhibited else { return }
        applyDirection(direction)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            releaseDirection(direction)
        }
    }

    private func turnButton(title: String, direction: Int, pillMode: PillMode) -> some View {
        let isActive = activeDirection == direction
        let isLeft = direction > 0
        let symbolName = isLeft ? QuackIcon.turnLeft : QuackIcon.turnRight
        let isPill = pillMode != .none

        return HStack(spacing: pillMode == .compact ? 3 : (isPill ? 5 : 6)) {
            if isLeft {
                Image(systemName: symbolName)
                    .font(.system(size: pillMode == .compact ? 12 : (isPill ? 13 : 14), weight: .semibold))
            }
            Text(title)
                .font(.system(size: pillMode == .compact ? 12 : (isPill ? 14 : 15), weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if !isLeft {
                Image(systemName: symbolName)
                    .font(.system(size: pillMode == .compact ? 12 : (isPill ? 13 : 14), weight: .semibold))
            }
        }
        .foregroundStyle(isActive ? QuackTheme.inkSurface : QuackTheme.creamText)
        .padding(.horizontal, pillMode == .compact ? 6 : (isPill ? 14 : 8))
        .frame(
            minWidth: pillMode == .compact ? 45 : (isPill ? 84 : nil),
            maxWidth: isPill ? nil : .infinity
        )
        .frame(height: pillMode == .compact ? 40 : (isPill ? QuackTheme.minTouchTarget : 52))
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
        .scaleEffect(!reduceMotion && isActive ? 0.96 : 1.0)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.1), value: isActive)
        .contentShape(
            isPill
                ? AnyShape(Capsule())
                : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLeft ? "Turn left" : "Turn right")
        .accessibilityHint("Hold to turn continuously, or activate for a short turn pulse")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            pulseAccessibleTurn(direction)
        }
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
    var isEnabled: Bool = true
    let onDirectionChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, isEnabled: isEnabled, onDirectionChanged: onDirectionChanged)
    }

    func makeUIView(context: Context) -> TurnTouchUIView {
        let view = TurnTouchUIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isAccessibilityElement = false
        view.isUserInteractionEnabled = isEnabled
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
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onDirectionChanged = onDirectionChanged
        uiView.isUserInteractionEnabled = isEnabled
        if !isEnabled {
            context.coordinator.resetIfNeeded(async: true)
        }
    }

    static func dismantleUIView(_ uiView: TurnTouchUIView, coordinator: Coordinator) {
        uiView.onDetach = nil
        coordinator.resetIfNeeded(async: true)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var mode: TurnTouchMode
        var isEnabled: Bool
        var onDirectionChanged: (Int) -> Void
        weak var attachedView: UIView?
        private var lastDirection: Int = 0

        init(mode: TurnTouchMode, isEnabled: Bool, onDirectionChanged: @escaping (Int) -> Void) {
            self.mode = mode
            self.isEnabled = isEnabled
            self.onDirectionChanged = onDirectionChanged
        }

        @objc func handlePress(_ recognizer: UILongPressGestureRecognizer) {
            guard isEnabled else {
                resetIfNeeded(async: false)
                return
            }
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
