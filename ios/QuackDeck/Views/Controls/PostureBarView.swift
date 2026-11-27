import SwiftUI

enum PostureBarStyle {
    case portraitBar
    case landscapePill
}

struct PostureBarView: View {
    let appState: AppState
    var style: PostureBarStyle = .portraitBar
    var onOpenSensors: (() -> Void)? = nil

    private enum SlotRole {
        case relax(strong: Bool)
        case secondary
        case primary
    }

    private struct ActionSlot: Identifiable {
        let id: String
        let title: String
        let role: SlotRole
        let action: CockpitAction?
        var systemImage: String? = nil
        var isLoading: Bool = false
        let tapOverride: (() -> Void)?
    }

    private enum RelaxDialogKind: Equatable {
        case withSafeRest(isSeated: Bool)
        case relaxOrShutdown
    }

    var body: some View {
        let state = appState.cockpitState

        Group {
            switch style {
            case .portraitBar:
                slotRow(for: state, isCapsule: false)
                    .padding(5)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(QuackTheme.inkCard)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(QuackTheme.cardBorder, lineWidth: 1)
                            )
                    }

            case .landscapePill:
                slotRow(for: state, isCapsule: true)
                    .padding(4)
                    .quackGlassPill()
            }
        }
        .alert(
            alertTitle(for: activeAlertConfirmation),
            isPresented: alertBinding,
            presenting: activeAlertConfirmation
        ) { confirmation in
            alertActions(for: confirmation)
        } message: { confirmation in
            Text(alertMessage(for: confirmation))
        }
        .confirmationDialog(
            "Release Motor Torque",
            isPresented: dialogBinding,
            titleVisibility: .visible,
            presenting: activeDialogKind
        ) { kind in
            if case .withSafeRest(let isSeated) = kind {
                Button(isSeated ? "Rest & Relax (~5 s)" : "Sit & Relax (~5 s)") {
                    Task {
                        await appState.confirmRestAndRelax()
                    }
                }
            }
            Button("Relax Now (Hold Robot)", role: .destructive) {
                Task {
                    await appState.confirmRelaxNow()
                }
            }
            Button("Shut Down Robot", role: .destructive) {
                presentShutdownConfirmationAfterDialogDismiss()
            }
            Button("Cancel", role: .cancel) {
                appState.cancelPendingConfirmation()
            }
        } message: { kind in
            Text(dialogMessage(for: kind))
        }
    }

    @ViewBuilder
    private func slotRow(for state: CockpitState, isCapsule: Bool) -> some View {
        let slots = slots(for: state, isCapsule: isCapsule)
        let spinnerTitle = transitionalSpinnerTitle(for: state)

        HStack(spacing: isCapsule ? 4 : QuackTheme.controlSpacing) {
            ForEach(slots) { slot in
                slotButton(slot, isCapsule: isCapsule)
            }

            if let spinnerTitle {
                transitionalPill(title: spinnerTitle, isCapsule: isCapsule)
            }
        }
    }

    private func slots(for state: CockpitState, isCapsule: Bool) -> [ActionSlot] {
        switch state {
        case .offline:
            if appState.canForceRetry {
                let retrying = appState.isRetryingConnection
                let retryTitle: String
                if appState.telemetry.isPoweredOff {
                    retryTitle = retrying ? "Reconnecting..." : "Reconnect"
                } else {
                    retryTitle = retrying ? "Retrying..." : (isCapsule ? "Retry" : "Retry Now")
                }
                return [
                    ActionSlot(
                        id: "ducks",
                        title: "Ducks",
                        role: .secondary,
                        action: nil,
                        tapOverride: {
                            QuackHaptics.light()
                            appState.isDucksSheetPresented = true
                        }
                    ),
                    ActionSlot(
                        id: "retry-now",
                        title: retryTitle,
                        role: .primary,
                        action: nil,
                        isLoading: retrying,
                        tapOverride: {
                            QuackHaptics.medium()
                            Task {
                                await appState.forceReconnect()
                            }
                        }
                    )
                ]
            }
            return [
                ActionSlot(
                    id: "open-ducks",
                    title: "Open Ducks",
                    role: .primary,
                    action: nil,
                    tapOverride: {
                        QuackHaptics.light()
                        appState.isDucksSheetPresented = true
                    }
                )
            ]

        case .syncing:
            return []

        case .hardwareBlocked(_, let homed):
            return [
                homed ? relaxSlot(strong: false) : shutdownSlot(),
                sensorsSlot()
            ]

        case .limp:
            return [
                shutdownSlot(),
                ActionSlot(
                    id: "init",
                    title: "Init",
                    role: .primary,
                    action: .initMotors,
                    tapOverride: nil
                )
            ]

        case .initializing:
            return [relaxSlot(strong: true)]

        case .calibratingImu(let frozen):
            var result = [relaxSlot(strong: false)]
            if frozen {
                result.append(sensorsSlot())
            }
            return result

        case .readyHome(let hasPolicy):
            var result = [relaxSlot(strong: false)]
            if hasPolicy {
                result.append(
                    ActionSlot(
                        id: "walk",
                        title: "Walk",
                        role: .primary,
                        action: .walk,
                        tapOverride: nil
                    )
                )
            }
            return result

        case .readySeated(let hasPolicy):
            var result = [relaxSlot(strong: false)]
            if hasPolicy {
                result.append(
                    ActionSlot(
                        id: "stand-from-seat",
                        title: "Stand",
                        role: .primary,
                        action: .standFromSeat,
                        tapOverride: nil
                    )
                )
            }
            return result

        case .walking(let hasSitstand):
            var result = [
                relaxSlot(strong: false),
                ActionSlot(
                    id: "hold",
                    title: "Hold",
                    role: .secondary,
                    action: .hold,
                    tapOverride: nil
                )
            ]
            if hasSitstand {
                result.append(
                    ActionSlot(
                        id: "sit",
                        title: "Sit",
                        role: .primary,
                        action: .sit,
                        tapOverride: nil
                    )
                )
            }
            return result

        case .sittingDown:
            return [relaxSlot(strong: false)]

        case .seated:
            return [
                relaxSlot(strong: false),
                ActionSlot(
                    id: "stand-up",
                    title: "Stand",
                    role: .primary,
                    action: .standUp,
                    tapOverride: nil
                )
            ]

        case .rising:
            return [relaxSlot(strong: true)]

        case .runningSkill:
            return [
                relaxSlot(strong: false),
                ActionSlot(
                    id: "stop-skill",
                    title: "Stop Skill",
                    role: .secondary,
                    action: .stopSkill,
                    tapOverride: nil
                )
            ]

        case .pickedUp:
            return [
                relaxSlot(strong: false),
                ActionSlot(
                    id: "hold",
                    title: "Hold",
                    role: .secondary,
                    action: .hold,
                    tapOverride: nil
                )
            ]

        case .fallenRecovering:
            return [
                relaxSlot(strong: true),
                ActionSlot(
                    id: "cancel",
                    title: "Cancel",
                    role: .secondary,
                    action: .cancelRecovery,
                    tapOverride: nil
                )
            ]

        case .fallenParked(let disarmed):
            var result = [relaxSlot(strong: true)]
            if !disarmed {
                result.append(
                    ActionSlot(
                        id: "hold",
                        title: "Hold",
                        role: .secondary,
                        action: .hold,
                        tapOverride: nil
                    )
                )
            }
            return result

        case .resting(let homed):
            return homed ? [relaxSlot(strong: true)] : []

        case .shuttingDown(let homed):
            return homed ? [relaxSlot(strong: true)] : []
        }
    }

    private func transitionalSpinnerTitle(for state: CockpitState) -> String? {
        switch state {
        case .syncing:
            return "Syncing..."
        case .initializing:
            return "Initializing..."
        case .calibratingImu(let frozen):
            return frozen ? nil : "Calibrating..."
        case .sittingDown:
            return "Sitting..."
        case .rising:
            return "Standing..."
        case .resting(let homed):
            return homed ? "Resting..." : "Finishing..."
        case .shuttingDown(let homed):
            return homed ? "Shutting down..." : "Powering off..."
        default:
            return nil
        }
    }

    private func relaxSlot(strong: Bool) -> ActionSlot {
        ActionSlot(
            id: "relax",
            title: "Relax",
            role: .relax(strong: strong),
            action: .relax,
            tapOverride: nil
        )
    }

    private func shutdownSlot() -> ActionSlot {
        ActionSlot(
            id: "shutdown",
            title: "Shut Down",
            role: .relax(strong: false),
            action: .shutdown,
            systemImage: QuackIcon.power,
            tapOverride: nil
        )
    }

    private func sensorsSlot() -> ActionSlot {
        ActionSlot(
            id: "sensors",
            title: "Sensors",
            role: .primary,
            action: nil,
            tapOverride: {
                QuackHaptics.light()
                onOpenSensors?()
            }
        )
    }

    @ViewBuilder
    private func slotButton(_ slot: ActionSlot, isCapsule: Bool) -> some View {
        let isInFlight = slot.isLoading || (slot.action != nil && appState.inFlightAction == slot.action)
        let isSlotGuarded = slot.action.map { appState.isActionBlockedBySlotGuard($0) } ?? false
        let foreground = foregroundColor(for: slot.role)
        let fontWeight: Font.Weight = {
            if case .primary = slot.role { return .bold }
            return .semibold
        }()

        Button {
            if let action = slot.action {
                guard !appState.isActionBlockedBySlotGuard(action) else { return }
                Task {
                    await appState.requestAction(action)
                }
            } else {
                slot.tapOverride?()
            }
        } label: {
            HStack(spacing: 5) {
                if isInFlight {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(foreground)
                } else if let systemImage = slot.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: isCapsule ? 12 : 13, weight: .semibold))
                        .foregroundStyle(foreground)
                }
                Text(slot.title)
                    .font(.system(size: isCapsule ? 13 : 14, weight: fontWeight))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .modifier(
                SlotDimensionsModifier(
                    fixedPortraitWidth: portraitWidth(for: slot.id),
                    isCapsule: isCapsule
                )
            )
            .background {
                slotBackground(for: slot.role, isCapsule: isCapsule)
            }
            .contentShape(
                isCapsule
                    ? AnyShape(Capsule())
                    : AnyShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            )
        }
        .buttonStyle(.quackTouch)
        .disabled(isInFlight)
        .opacity(isSlotGuarded ? 0.65 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isSlotGuarded)
    }

    private func portraitWidth(for slotId: String) -> CGFloat? {
        switch slotId {
        case "shutdown":
            return 124
        case "relax", "ducks":
            return 96
        default:
            return nil
        }
    }

    private func transitionalPill(title: String, isCapsule: Bool) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .tint(QuackTheme.duckOrange)

            Text(title)
                .font(.system(size: isCapsule ? 13 : 14, weight: .semibold))
                .foregroundStyle(QuackTheme.creamText.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .modifier(SlotDimensionsModifier(fixedPortraitWidth: nil, isCapsule: isCapsule))
        .background {
            pillBackground(
                fill: QuackTheme.duckOrange.opacity(0.16),
                stroke: QuackTheme.duckOrange.opacity(0.45),
                isCapsule: isCapsule
            )
        }
        .allowsHitTesting(false)
    }

    private func foregroundColor(for role: SlotRole) -> Color {
        switch role {
        case .relax:
            return QuackTheme.dangerRed
        case .secondary:
            return QuackTheme.creamText
        case .primary:
            return QuackTheme.inkSurface
        }
    }

    @ViewBuilder
    private func slotBackground(for role: SlotRole, isCapsule: Bool) -> some View {
        switch role {
        case .relax(let strong):
            let fillOpacity = strong ? 0.22 : 0.12
            let strokeOpacity = strong ? 0.60 : 0.38
            pillBackground(
                fill: QuackTheme.dangerRed.opacity(fillOpacity),
                stroke: QuackTheme.dangerRed.opacity(strokeOpacity),
                isCapsule: isCapsule
            )

        case .secondary:
            let fill = isCapsule
                ? Color(hex: 0x1c1c28).opacity(0.88)
                : Color(hex: 0x1c1c28)
            pillBackground(
                fill: fill,
                stroke: QuackTheme.subtleBorder,
                isCapsule: isCapsule
            )

        case .primary:
            pillBackground(
                fill: QuackTheme.duckOrange,
                stroke: nil,
                isCapsule: isCapsule
            )
        }
    }

    @ViewBuilder
    private func pillBackground(fill: Color, stroke: Color?, isCapsule: Bool) -> some View {
        if isCapsule {
            Capsule()
                .fill(fill)
                .overlay {
                    if let stroke {
                        Capsule().strokeBorder(stroke, lineWidth: 1)
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(fill)
                .overlay {
                    if let stroke {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(stroke, lineWidth: 1)
                    }
                }
        }
    }

    // MARK: - Confirmation Modal Bindings & Copy

    private var activeAlertConfirmation: CockpitConfirmation? {
        guard let pending = appState.pendingConfirmation else { return nil }
        switch pending {
        case .relaxOrRest, .relaxOrShutdown:
            return nil
        default:
            return pending
        }
    }

    private var activeDialogKind: RelaxDialogKind? {
        switch appState.pendingConfirmation {
        case .relaxOrRest(let isSeated):
            return .withSafeRest(isSeated: isSeated)
        case .relaxOrShutdown:
            return .relaxOrShutdown
        default:
            return nil
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { activeAlertConfirmation != nil },
            set: { isPresented in
                if !isPresented, activeAlertConfirmation != nil {
                    appState.cancelPendingConfirmation()
                }
            }
        )
    }

    private var dialogBinding: Binding<Bool> {
        Binding(
            get: { activeDialogKind != nil },
            set: { isPresented in
                if !isPresented, activeDialogKind != nil {
                    appState.cancelPendingConfirmation()
                }
            }
        )
    }

    private func presentShutdownConfirmationAfterDialogDismiss() {
        appState.cancelPendingConfirmation()
        Task { @MainActor in
            // Wait for the confirmationDialog sheet dismissal animation before presenting the alert.
            try? await Task.sleep(nanoseconds: 250_000_000)
            await appState.requestAction(.shutdown)
        }
    }

    private func dialogMessage(for kind: RelaxDialogKind) -> String {
        switch kind {
        case .withSafeRest(let isSeated):
            return isSeated
                ? "Rest & Relax eases servos down before cutting torque — keep hands nearby to steady the robot. Hold the robot before tapping Relax Now."
                : "Sit & Relax sits down first before cutting torque — keep hands nearby to steady the robot. Hold the robot before tapping Relax Now."
        case .relaxOrShutdown:
            return "Hold the robot before releasing torque or powering off — servos will go limp immediately."
        }
    }

    private func alertTitle(for confirmation: CockpitConfirmation?) -> String {
        switch confirmation {
        case .initMotors:
            return "Initialize Motors?"
        case .startWalk:
            return "Start Walking?"
        case .standFromHeldSeat:
            return "Stand Up & Walk?"
        case .sitExperimental:
            return "Sit Down?"
        case .relaxDirect:
            return "Release Motor Torque?"
        case .shutdown:
            return "Shut Down Robot?"
        case .relaxOrRest, .relaxOrShutdown, nil:
            return ""
        }
    }

    private func alertMessage(for confirmation: CockpitConfirmation) -> String {
        switch confirmation {
        case .initMotors:
            return "Hold the robot upright with feet clear — joints power on and move to home pose (~2 s)."
        case .startWalk(let hotTempC):
            if let hotTempC {
                return "Hold or steady the robot before starting. Servo temperature is \(Int(hotTempC.rounded())) °C (hot >= 58 °C) — keep runs short and cool below 40 °C."
            }
            return "Hold or steady the robot before starting the walk policy."
        case .standFromHeldSeat(let hotTempC):
            if let hotTempC {
                return "Hold or steady the robot while it stands up from seated (~3 s). Servo temperature is \(Int(hotTempC.rounded())) °C (hot >= 58 °C) — keep runs short."
            }
            return "Hold or steady the robot while it stands up from seated and starts walking (~3 s)."
        case .sitExperimental:
            return "Keep hands nearby while the robot sits down to steady it if needed."
        case .relaxDirect:
            return "Hold the robot immediately — servos will go limp."
        case .shutdown(let mode):
            let name = appState.currentDuckName
            switch mode {
            case .immediateMotorsOff:
                return "Motors are already off. \(name) will power off immediately."
            case .sitAndPowerOff:
                return "\(name) will sit down (~5 s), release torque, and power off. Keep hands nearby to steady the robot."
            case .restAndPowerOff:
                return "\(name) will ease to rest (~5 s), release torque, and power off. Keep hands nearby to steady the robot."
            case .immediateCutTorque:
                return "Hold the robot first — servos will lose torque immediately and \(name) will power off."
            }
        case .relaxOrRest, .relaxOrShutdown:
            return ""
        }
    }

    @ViewBuilder
    private func alertActions(for confirmation: CockpitConfirmation) -> some View {
        if let spec = alertConfirmSpec(for: confirmation) {
            Button(spec.title, role: spec.role) {
                Task {
                    await appState.confirm(confirmation)
                }
            }
            Button("Cancel", role: .cancel) {
                appState.cancelPendingConfirmation()
            }
        }
    }

    private func alertConfirmSpec(for confirmation: CockpitConfirmation) -> (title: String, role: ButtonRole?)? {
        switch confirmation {
        case .initMotors:
            return ("Initialize", nil)
        case .startWalk:
            return ("Start Walk", nil)
        case .standFromHeldSeat:
            return ("Stand Up", nil)
        case .sitExperimental:
            return ("Sit Down", nil)
        case .relaxDirect:
            return ("Relax Now", .destructive)
        case .shutdown:
            return ("Shut Down", .destructive)
        case .relaxOrRest, .relaxOrShutdown:
            return nil
        }
    }
}

private struct SlotDimensionsModifier: ViewModifier {
    let fixedPortraitWidth: CGFloat?
    let isCapsule: Bool

    func body(content: Content) -> some View {
        if isCapsule {
            content
                .padding(.horizontal, 12)
                .frame(minWidth: 56, minHeight: QuackTheme.minTouchTarget)
        } else if let width = fixedPortraitWidth {
            content
                .frame(width: width, height: QuackTheme.minTouchTarget)
        } else {
            content
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: QuackTheme.minTouchTarget)
        }
    }
}
