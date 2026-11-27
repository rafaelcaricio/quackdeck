import Foundation
import Observation
import SwiftUI

enum ThermalAlertLevel: Equatable, Sendable {
    case normal
    case warm
    case hot
}

@MainActor
@Observable
final class AppState {
    static let defaultTofOverlayOpacity: Double = 0.45
    static let tofOverlayOpacityRange: ClosedRange<Double> = 0.05...1.0

    private static let tofOverlayEnabledKey = "com.caricio.quackdeck.tofOverlayEnabled"
    private static let tofOverlayOpacityKey = "com.caricio.quackdeck.tofOverlayOpacity"

    let bleManager = BleManager()
    private let vault: RobotVault
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var pairedDucks: [PairedDuck] = []
    private(set) var lastConnectedDuck: PairedDuck?
    private(set) var isRetryingConnection: Bool = false
    private var liveSession: LiveRobotSession?
    private var demoSession: DemoRobotSession?

    var isDucksSheetPresented: Bool = false
    var activeAlertMessage: String?

    var isTofOverlayEnabled: Bool {
        didSet {
            defaults.set(isTofOverlayEnabled, forKey: Self.tofOverlayEnabledKey)
        }
    }

    var tofOverlayOpacity: Double {
        didSet {
            let clamped = Self.clampTofOverlayOpacity(tofOverlayOpacity)
            if clamped != tofOverlayOpacity {
                tofOverlayOpacity = clamped
                return
            }
            defaults.set(clamped, forKey: Self.tofOverlayOpacityKey)
        }
    }

    // Cockpit state machine latches, guards, and active confirmation
    private(set) var awaitingPostHomingPolicies: Bool = false
    private(set) var isSitSettling: Bool = false
    private(set) var isAutoRising: Bool = false
    private(set) var isRestingPending: Bool = false
    private(set) var isShutdownPending: Bool = false
    private(set) var disarmedWhileFallen: Bool = false
    private(set) var inFlightAction: CockpitAction?
    private(set) var slotGuardActive: Bool = false
    private(set) var didConfirmSitThisSession: Bool = false
    var pendingConfirmation: CockpitConfirmation?

    // Continuous drive state kept at app level for instant scenePhase zeroing
    private(set) var stickForward: Double = 0
    private(set) var stickStrafeLeft: Double = 0
    private(set) var turnYawLeft: Double = 0

    // Internal transition & timer tracking
    @ObservationIgnored private var lastObservedPolicy: String?
    @ObservationIgnored private var lastResolvedCockpitState: CockpitState = .offline
    @ObservationIgnored private var inFlightStartState: CockpitState?
    @ObservationIgnored private var autoRiseSawDrivingPolicy: Bool = false
    @ObservationIgnored private var suppressNextPostHomingLatch: Bool = false
    @ObservationIgnored private var postHomingTask: Task<Void, Never>?
    @ObservationIgnored private var sitSettleTask: Task<Void, Never>?
    @ObservationIgnored private var autoRiseTask: Task<Void, Never>?
    @ObservationIgnored private var restPendingTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownPendingTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightTask: Task<Void, Never>?
    @ObservationIgnored private var slotGuardTask: Task<Void, Never>?
    @ObservationIgnored private var observationGeneration: UInt64 = 0
    @ObservationIgnored private var retryAttemptGeneration: UInt64 = 0

    init(vault: RobotVault = .shared, defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
        if defaults.object(forKey: Self.tofOverlayEnabledKey) != nil {
            self.isTofOverlayEnabled = defaults.bool(forKey: Self.tofOverlayEnabledKey)
        } else {
            self.isTofOverlayEnabled = true
        }
        if defaults.object(forKey: Self.tofOverlayOpacityKey) != nil {
            self.tofOverlayOpacity = Self.clampTofOverlayOpacity(
                defaults.double(forKey: Self.tofOverlayOpacityKey)
            )
        } else {
            self.tofOverlayOpacity = Self.defaultTofOverlayOpacity
        }
        reloadPairedDucks()
    }

    static func clampTofOverlayOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTofOverlayOpacity }
        return min(tofOverlayOpacityRange.upperBound, max(tofOverlayOpacityRange.lowerBound, value))
    }

    var activeSession: (any RobotSessionTransport)? {
        if let demoSession {
            return demoSession
        }
        return liveSession
    }

    var phase: ConnectionPhase {
        activeSession?.phase ?? .disconnected
    }

    var isConnected: Bool {
        phase.isConnected
    }

    var isDemoMode: Bool {
        activeSession?.isDemoMode ?? false
    }

    var currentDuckName: String {
        activeSession?.currentDuckName ?? lastConnectedDuck?.name ?? "No Duck"
    }

    var canForceRetry: Bool {
        if let live = liveSession {
            switch live.phase {
            case .connected, .configuringWifi:
                return false
            case .disconnected, .scanning, .connectingBle, .authenticatingBle, .connectingLan, .connectingVideo, .error:
                return true
            }
        }
        if let demo = demoSession {
            return !demo.phase.isConnected
        }
        return lastConnectedDuck != nil
    }

    var currentRobotId: String? {
        activeSession?.currentRobotId
    }

    var currentIpAddress: String? {
        activeSession?.currentIpAddress
    }

    var telemetry: TelemetrySnapshot {
        activeSession?.telemetry ?? TelemetrySnapshot()
    }

    var videoSource: VideoFrameSource {
        activeSession?.videoSource ?? .none
    }

    var cockpitState: CockpitState {
        computeCockpitState()
    }

    var canDrive: Bool {
        Self.canDrive(for: cockpitState)
    }

    var canLook: Bool {
        Self.canLook(for: cockpitState)
    }

    var canShowStop: Bool {
        Self.canDrive(for: cockpitState)
    }

    var canShowQuack: Bool {
        Self.canLook(for: cockpitState)
    }

    var isCompactUtilityRowVisible: Bool {
        cockpitState == .seated
    }

    var canSafeRest: Bool {
        let fallen = telemetry.robotState?.safety.fallen ?? false
        let pickedUp = telemetry.robotState?.safety.picked_up ?? false
        guard !fallen, !pickedUp, telemetry.hasSitstand else { return false }
        switch cockpitState {
        case .walking(let hasSitstand):
            return hasSitstand
        case .seated:
            return true
        default:
            return false
        }
    }

    var canShutdownFromRelaxMenu: Bool {
        let pickedUp = telemetry.robotState?.safety.picked_up ?? false
        guard !pickedUp else { return false }
        switch cockpitState {
        case .readyHome, .readySeated, .calibratingImu, .walking, .seated, .fallenParked:
            return true
        case .hardwareBlocked(_, let homed):
            return homed
        default:
            return false
        }
    }

    var shutdownConfirmationMode: ShutdownConfirmationMode? {
        let fallen = telemetry.robotState?.safety.fallen ?? false
        let pickedUp = telemetry.robotState?.safety.picked_up ?? false
        guard !pickedUp else { return nil }
        switch cockpitState {
        case .limp:
            return .immediateMotorsOff
        case .hardwareBlocked(_, let homed):
            return homed ? .immediateCutTorque : .immediateMotorsOff
        case .walking(let hasSitstand):
            return (hasSitstand && !fallen) ? .sitAndPowerOff : .immediateCutTorque
        case .seated:
            return (!fallen && telemetry.hasSitstand) ? .restAndPowerOff : .immediateCutTorque
        case .readyHome, .readySeated, .calibratingImu, .fallenParked:
            return .immediateCutTorque
        default:
            return nil
        }
    }

    var guidanceText: String? {
        switch cockpitState {
        case .offline:
            if !canForceRetry {
                if phase == .configuringWifi {
                    return telemetry.statusBanner ?? "Bluetooth connected · Configure Wi-Fi in Ducks"
                }
                return "Not connected · Open Ducks to pair or demo"
            }
            if isRetryingConnection {
                return telemetry.isPoweredOff
                    ? "Reconnecting to \(currentDuckName)..."
                    : "Retrying connection to \(currentDuckName)..."
            }
            if telemetry.isPoweredOff && phase == .disconnected {
                return "\(currentDuckName) powered off · Turn it on, then tap Reconnect"
            }
            switch phase {
            case .error(let detail):
                if let secs = telemetry.nextRetrySeconds, telemetry.isAutoReconnecting {
                    return secs > 0
                        ? "\(detail) · Retrying in \(secs)s..."
                        : "\(detail) · Retrying now..."
                }
                return detail
            case .connectingVideo, .connectingLan, .connectingBle, .authenticatingBle, .scanning:
                if let secs = telemetry.nextRetrySeconds, telemetry.isAutoReconnecting {
                    return secs > 0
                        ? "Connection lost · Retrying in \(secs)s..."
                        : "Reconnecting to \(currentDuckName)..."
                }
                if let banner = telemetry.statusBanner, !banner.isEmpty {
                    return banner
                }
                return "Reconnecting to \(currentDuckName)..."
            case .disconnected:
                if let secs = telemetry.nextRetrySeconds, telemetry.isAutoReconnecting {
                    return secs > 0
                        ? "Connection lost · Retrying in \(secs)s..."
                        : "Reconnecting to \(currentDuckName)..."
                }
                return "Disconnected from \(currentDuckName) · Tap Retry to reconnect"
            case .configuringWifi, .connected:
                return phase.shortLabel
            }
        case .syncing:
            return "Syncing robot state..."
        case .hardwareBlocked(let reason, _):
            return "Cannot power on · \(reason)"
        case .limp(let fallen):
            return fallen
                ? "Tipped over · Set upright & hold before Init"
                : "Motors off · Hold upright, then tap Init"
        case .initializing:
            return "Initializing motors... Hold steady (~2 s)"
        case .calibratingImu(let frozen):
            return frozen
                ? "Balance sensor stalled · Check Sensors or Relax"
                : "Hold robot still · Calibrating balance sensor..."
        case .readyHome(let hasPolicy):
            return hasPolicy
                ? "Ready · Hold or steady robot, then tap Walk"
                : "No walk policy loaded · Sensors active"
        case .readySeated(let hasPolicy):
            return hasPolicy
                ? "Held in seat · Hold robot, then tap Stand to rise"
                : "Held in seat · No walk policy loaded"
        case .walking:
            return nil
        case .sittingDown:
            return "Sitting down... Stay ready to steady"
        case .seated:
            return "Seated · Keep hands near to Stand, or drag to look"
        case .rising:
            return "Standing up... Stay ready to steady"
        case .runningSkill(let name):
            return "Running \(name)..."
        case .pickedUp:
            return "Picked up · Walking paused. Set down to resume, or Hold"
        case .fallenRecovering:
            return "Fall detected · Recovering... Keep hands clear"
        case .fallenParked(let disarmed):
            return disarmed
                ? "Policy stopped · Set upright to continue"
                : "Tipped over · Tap Hold before lifting, or stand upright"
        case .resting(let homed):
            return homed
                ? "Resting · Easing down before cutting torque..."
                : "Motors off · Finishing motor reset..."
        case .shuttingDown(let homed):
            return homed
                ? "Shutting down · Easing down before power-off..."
                : "Shutting down · Powering off robot..."
        }
    }

    var guidanceTone: GuidanceTone {
        switch cockpitState {
        case .offline:
            guard canForceRetry else {
                return phase == .configuringWifi ? .caution : .neutral
            }
            if telemetry.isPoweredOff && phase == .disconnected && !isRetryingConnection {
                return .neutral
            }
            if case .error = phase {
                return .danger
            }
            return .caution
        case .hardwareBlocked, .fallenRecovering:
            return .danger
        case .fallenParked(let disarmed):
            return disarmed ? .caution : .danger
        case .limp(let fallen):
            return fallen ? .caution : .neutral
        case .calibratingImu(let frozen):
            return frozen ? .caution : .neutral
        case .readyHome(let hasPolicy), .readySeated(let hasPolicy):
            return hasPolicy ? .neutral : .caution
        case .pickedUp, .shuttingDown:
            return .caution
        default:
            return .neutral
        }
    }

    var discoveredDucks: [DiscoveredDuck] {
        bleManager.discoveredDucks
    }

    var unpairedDiscoveredDucks: [DiscoveredDuck] {
        Self.filterUnpairedDiscoveredDucks(bleManager.discoveredDucks, pairedDucks: pairedDucks)
    }

    static func isAlreadyPaired(_ discovered: DiscoveredDuck, in pairedDucks: [PairedDuck]) -> Bool {
        let discoveredNameLower = discovered.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isGenericFallbackName = discoveredNameLower.isEmpty
            || discoveredNameLower == "microduck"
            || discoveredNameLower.hasPrefix("microduck ")

        for paired in pairedDucks {
            if let pid = paired.peripheralId, pid == discovered.id {
                return true
            }
            if let advIp = discovered.advInfo.ipv4, !advIp.isEmpty,
               let lastIp = paired.lastIp, !lastIp.isEmpty,
               advIp == lastIp {
                return true
            }
            if !isGenericFallbackName {
                let pairedNameLower = paired.name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let pairedIdLower = paired.robotId
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if discoveredNameLower == pairedNameLower || discoveredNameLower == pairedIdLower {
                    return true
                }
            }
        }
        return false
    }

    static func filterUnpairedDiscoveredDucks(
        _ discovered: [DiscoveredDuck],
        pairedDucks: [PairedDuck]
    ) -> [DiscoveredDuck] {
        discovered.filter { !isAlreadyPaired($0, in: pairedDucks) }
    }

    var isBluetoothScanning: Bool {
        bleManager.isScanning
    }

    var bluetoothStateText: String {
        bleManager.stateDescription
    }

    var demoSessionInstance: DemoRobotSession? {
        demoSession
    }

    var motorThermalLevel: ThermalAlertLevel {
        guard let motors = telemetry.health?.motors else { return .normal }
        if motors.isHot { return .hot }
        if motors.isWarning { return .warm }
        return .normal
    }

    var thermalBannerText: String? {
        guard let motors = telemetry.health?.motors else { return nil }
        let tempText = String(format: "%.0f °C", motors.max_c)
        if motors.isHot {
            return "Hot servo (\(motors.hottest) \(tempText)) — rest \(currentDuckName) and cool below 40 °C."
        }
        if motors.isWarning {
            return "Warm servo (\(motors.hottest) \(tempText)) — keep runs under 2–3 min."
        }
        return nil
    }

    // MARK: - Pairing & Session Switching

    func reloadPairedDucks() {
        let ducks = vault.loadPairedDucks()
        pairedDucks = ducks
        bleManager.setKnownPeripheralIds(ducks.compactMap(\.peripheralId))
        if let current = lastConnectedDuck {
            if let updated = ducks.first(where: { $0.robotId == current.robotId }) {
                lastConnectedDuck = updated
            } else {
                lastConnectedDuck = mostRecentConnectedDuck(in: ducks)
            }
        } else {
            lastConnectedDuck = mostRecentConnectedDuck(in: ducks)
        }
    }

    func startBleScan() {
        bleManager.startScan()
    }

    func stopBleScan() {
        bleManager.stopScan()
    }

    func startDemoMode(startWalking: Bool = false) {
        if liveSession == nil && demoSession == nil {
            activateDemoSession(startWalking: startWalking)
            return
        }
        Task { @MainActor in
            await stopActiveLiveSessionIfAny()
            await stopDemoModeIfAny()
            activateDemoSession(startWalking: startWalking)
        }
    }

    private func activateDemoSession(startWalking: Bool) {
        resetCockpitLatches()
        let demo = DemoRobotSession(startWalking: startWalking)
        demo.onStateUpdated = { [weak self] in
            self?.reconcileCockpitState()
        }
        demo.connect()
        self.demoSession = demo
        self.isDucksSheetPresented = false
        self.armSessionObservation()
        self.reconcileCockpitState()
        QuackHaptics.success()
    }

    @discardableResult
    func pairAndConnect(setupCodeRaw: String, peripheralId: UUID? = nil) async throws -> PairedDuck {
        let parsed = try QuackDeckCore.parseSetupCode(setupCodeRaw)
        let targetPeripheralId = peripheralId
            ?? vault.pairedDuck(for: parsed.robotId)?.peripheralId
            ?? bleManager.discoveredDucks.first(where: { $0.isConnectable })?.id

        let existing = vault.pairedDuck(for: parsed.robotId)
        let duckName = bleManager.discoveredDucks.first(where: { $0.id == targetPeripheralId })?.name
            ?? existing?.name
            ?? parsed.robotId

        let duck = PairedDuck(
            robotId: parsed.robotId,
            name: duckName,
            lastIp: bleManager.discoveredDucks.first(where: { $0.id == targetPeripheralId })?.advInfo.ipv4 ?? existing?.lastIp,
            peripheralId: targetPeripheralId,
            pairedAt: existing?.pairedAt ?? Date(),
            lastConnectedAt: existing?.lastConnectedAt
        )
        try vault.save(duck: duck, pskHex: parsed.pskHex)
        reloadPairedDucks()

        await connectToPairedDuck(duck)
        if case .error(let detail) = liveSession?.phase {
            throw BleManagerError.disconnected(liveSession?.telemetry.lastError ?? detail)
        }
        return vault.pairedDuck(for: parsed.robotId) ?? duck
    }

    func connectToPairedDuck(_ duck: PairedDuck) async {
        await stopDemoModeIfAny()
        await liveSession?.disconnect()
        resetCockpitLatches()
        lastConnectedDuck = duck

        let session = LiveRobotSession(bleManager: bleManager, vault: vault)
        session.onStateUpdated = { [weak self] in
            self?.reconcileCockpitState()
        }
        liveSession = session
        armSessionObservation()

        do {
            guard let pskHex = try vault.pskHex(for: duck.robotId) else {
                activeAlertMessage = "No setup key found for \(duck.name). Pair again with the setup code."
                return
            }
            await session.connectToPairedDuck(duck, pskHex: pskHex)
            reloadPairedDucks()
            reconcileCockpitState()
        } catch {
            activeAlertMessage = error.localizedDescription
            reconcileCockpitState()
        }
    }

    func connectViaBle(peripheralId: UUID, setupCodeRaw: String) async throws {
        let parsed = try QuackDeckCore.parseSetupCode(setupCodeRaw)
        await stopDemoModeIfAny()
        await liveSession?.disconnect()
        resetCockpitLatches()

        let discoveredName = bleManager.discoveredDucks.first(where: { $0.id == peripheralId })?.name
        let duck = PairedDuck(
            robotId: parsed.robotId,
            name: discoveredName ?? parsed.robotId,
            lastIp: bleManager.discoveredDucks.first(where: { $0.id == peripheralId })?.advInfo.ipv4,
            peripheralId: peripheralId,
            pairedAt: vault.pairedDuck(for: parsed.robotId)?.pairedAt ?? Date(),
            lastConnectedAt: nil
        )
        try vault.save(duck: duck, pskHex: parsed.pskHex)
        lastConnectedDuck = duck
        reloadPairedDucks()

        let session = LiveRobotSession(bleManager: bleManager, vault: vault)
        session.onStateUpdated = { [weak self] in
            self?.reconcileCockpitState()
        }
        liveSession = session
        armSessionObservation()

        await session.connectViaBle(
            peripheralId: peripheralId,
            robotId: parsed.robotId,
            pskHex: parsed.pskHex,
            fallbackName: discoveredName
        )
        reloadPairedDucks()
        reconcileCockpitState()
        if case .error(let detail) = session.phase {
            throw BleManagerError.disconnected(session.telemetry.lastError ?? detail)
        }
    }

    func forceReconnect() async {
        stopAllMotion()
        pendingConfirmation = nil
        resetCockpitLatches()

        retryAttemptGeneration &+= 1
        let retryGen = retryAttemptGeneration

        if let demo = demoSession {
            isRetryingConnection = true
            defer {
                if retryAttemptGeneration == retryGen {
                    isRetryingConnection = false
                }
                reconcileCockpitState()
            }
            await demo.forceReconnect()
            return
        }

        if let live = liveSession {
            isRetryingConnection = true
            defer {
                if retryAttemptGeneration == retryGen {
                    isRetryingConnection = false
                }
                reloadPairedDucks()
                reconcileCockpitState()
            }
            await live.forceReconnect()
            return
        }

        guard let duck = lastConnectedDuck ?? mostRecentConnectedDuck(in: pairedDucks) else {
            activeAlertMessage = "No paired duck available to reconnect."
            return
        }

        isRetryingConnection = true
        defer {
            if retryAttemptGeneration == retryGen {
                isRetryingConnection = false
            }
            reconcileCockpitState()
        }
        await connectToPairedDuck(duck)
    }

    func forgetDuck(_ duck: PairedDuck) throws {
        if currentRobotId == duck.robotId {
            Task { @MainActor in
                await self.disconnect()
            }
        }
        try vault.remove(robotId: duck.robotId)
        reloadPairedDucks()
    }

    func disconnect() async {
        stopAllMotion()
        observationGeneration &+= 1
        if let demo = demoSession {
            demo.onStateUpdated = nil
            await demo.disconnect()
            demoSession = nil
        }
        if let live = liveSession {
            live.onStateUpdated = nil
            await live.disconnect()
            liveSession = nil
        }
        resetCockpitLatches()
        reconcileCockpitState()
    }

    // MARK: - Wi-Fi Provisioning

    func scanWifiNetworks() async throws -> [WifiNetwork] {
        guard let session = activeSession else {
            throw BleManagerError.disconnected("Connect to a duck first.")
        }
        return try await session.scanWifiNetworks()
    }

    func connectWifi(ssid: String, psk: String?) async throws -> ConnectResult {
        guard let session = activeSession else {
            throw BleManagerError.disconnected("Connect to a duck first.")
        }
        let result = try await session.connectWifi(ssid: ssid, psk: psk)
        reloadPairedDucks()
        return result
    }

    func forgetWifi(ssid: String) async throws -> Bool {
        guard let session = activeSession else {
            throw BleManagerError.disconnected("Connect to a duck first.")
        }
        return try await session.forgetWifi(ssid: ssid)
    }

    func refreshNetStatus() async {
        await activeSession?.refreshNetStatus()
    }

    // MARK: - Controls & Safety

    func setSensorsVisible(_ visible: Bool) {
        activeSession?.setSensorsVisible(visible)
    }

    /// Updates virtual drive thumbstick in normalized `[-1, 1]` axes:
    /// `forward > 0` moves forward (`+vx`), `strafeLeft > 0` strafes left (`+vy`).
    func updateDriveStick(forward: Double, strafeLeft: Double) {
        if !canDrive {
            if stickForward != 0 || stickStrafeLeft != 0 {
                stickForward = 0
                stickStrafeLeft = 0
                pushCombinedMove()
            }
            return
        }
        stickForward = max(-1, min(1, forward))
        stickStrafeLeft = max(-1, min(1, strafeLeft))
        pushCombinedMove()
    }

    /// Updates turn rocker in normalized `[-1, 1]` (`yawLeft > 0` turns left `+vyaw`).
    func updateTurnRocker(yawLeft: Double) {
        if !canDrive {
            if turnYawLeft != 0 {
                turnYawLeft = 0
                pushCombinedMove()
            }
            return
        }
        turnYawLeft = max(-1, min(1, yawLeft))
        pushCombinedMove()
    }

    func setLook(y: Double, z: Double) {
        guard canLook else { return }
        activeSession?.setLook(y: y, z: z)
    }

    func stopLook() {
        liveSession?.stopLook()
        demoSession?.stopLook()
    }

    func lookCenter() {
        guard canLook else { return }
        QuackHaptics.light()
        activeSession?.lookCenter()
    }

    func isActionBlockedBySlotGuard(_ action: CockpitAction) -> Bool {
        guard slotGuardActive else { return false }
        switch action {
        case .stopMoving:
            return false
        case .relax:
            // Protect against tapping Relax right after tapping Init in U2 -> U3; never guard safety states.
            return cockpitState == .initializing
        case .shutdown:
            // Protect against tapping Shut Down right after Relax transitions into U2 Limp.
            if case .limp = cockpitState {
                return true
            }
            return false
        case .sit, .hold:
            if case .walking = cockpitState {
                return true
            }
            return false
        default:
            return false
        }
    }

    func requestAction(_ action: CockpitAction) async {
        if action == .stopMoving {
            await emergencyStop()
            return
        }
        guard !isActionBlockedBySlotGuard(action) else { return }

        if let currentInFlight = inFlightAction {
            // Emergency relax and safety-state holds/cancels bypass unrelated in-flight locks.
            let isUrgentOverride = action == .relax || cockpitState.isSafetyOverrideState
            if currentInFlight == action || !isUrgentOverride {
                return
            }
        }

        switch action {
        case .initMotors:
            pendingConfirmation = .initMotors

        case .walk:
            pendingConfirmation = .startWalk(hotTempC: hotServoTempForConfirmation)

        case .standFromSeat:
            pendingConfirmation = .standFromHeldSeat(hotTempC: hotServoTempForConfirmation)

        case .sit:
            if !didConfirmSitThisSession {
                pendingConfirmation = .sitExperimental
            } else {
                await dispatchAction(.sit)
            }

        case .relax:
            QuackHaptics.warning()
            if canSafeRest {
                pendingConfirmation = .relaxOrRest(isSeated: cockpitState == .seated)
            } else if canShutdownFromRelaxMenu {
                pendingConfirmation = .relaxOrShutdown
            } else {
                pendingConfirmation = .relaxDirect
            }

        case .rest:
            guard canSafeRest else {
                QuackHaptics.warning()
                activeAlertMessage = "Safe rest is unavailable in the current robot state."
                return
            }
            await dispatchAction(.rest)

        case .shutdown:
            QuackHaptics.warning()
            guard let mode = shutdownConfirmationMode else {
                activeAlertMessage = cockpitState == .pickedUp
                    ? "Set the robot down or tap Relax first before shutting down."
                    : "Robot shutdown is unavailable in the current state."
                return
            }
            pendingConfirmation = .shutdown(mode: mode)

        case .hold, .standUp, .cancelRecovery, .stopSkill:
            await dispatchAction(action)

        case .stopMoving:
            await emergencyStop()
        }
    }

    func confirmDialogAction() async {
        guard let confirmation = pendingConfirmation else { return }
        await confirm(confirmation)
    }

    func confirm(_ confirmation: CockpitConfirmation) async {
        pendingConfirmation = nil
        guard isConfirmationValidForCurrentState(confirmation) else { return }

        switch confirmation {
        case .initMotors:
            await dispatchAction(.initMotors)
        case .startWalk:
            await dispatchAction(.walk)
        case .standFromHeldSeat:
            await dispatchAction(.standFromSeat)
        case .sitExperimental:
            didConfirmSitThisSession = true
            await dispatchAction(.sit)
        case .relaxDirect, .relaxOrShutdown, .relaxOrRest:
            await dispatchAction(.relax)
        case .shutdown:
            await dispatchAction(.shutdown)
        }
    }

    private func isConfirmationValidForCurrentState(_ confirmation: CockpitConfirmation) -> Bool {
        switch confirmation {
        case .initMotors:
            if case .limp = cockpitState { return true }
            return false
        case .startWalk:
            return cockpitState == .readyHome(hasPolicy: true)
        case .standFromHeldSeat:
            return cockpitState == .readySeated(hasPolicy: true)
        case .sitExperimental:
            return cockpitState == .walking(hasSitstand: true)
        case .relaxDirect, .relaxOrShutdown, .relaxOrRest:
            switch cockpitState {
            case .offline, .syncing, .limp:
                return false
            case .hardwareBlocked(_, let homed):
                return homed
            default:
                return true
            }
        case .shutdown(let mode):
            return shutdownConfirmationMode == mode
        }
    }

    func confirmRelaxNow() async {
        pendingConfirmation = nil
        await dispatchAction(.relax)
    }

    func confirmRestAndRelax() async {
        let isStillSafe = canSafeRest
        pendingConfirmation = nil
        guard isStillSafe else {
            QuackHaptics.warning()
            activeAlertMessage = "Safe rest is no longer available in the current robot state."
            return
        }
        await dispatchAction(.rest)
    }

    func cancelPendingConfirmation() {
        pendingConfirmation = nil
    }

    func emergencyStop() async {
        QuackHaptics.heavy()
        stickForward = 0
        stickStrafeLeft = 0
        turnYawLeft = 0
        await activeSession?.emergencyStop()
    }

    func playQuack() async {
        guard canShowQuack else { return }
        QuackHaptics.light()
        await activeSession?.playQuack()
    }

    func stopAllMotion() {
        stickForward = 0
        stickStrafeLeft = 0
        turnYawLeft = 0
        activeSession?.setMove(vx: 0, vy: 0, vyaw: 0)
        stopLook()
    }

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase != .active {
            stopAllMotion()
            Task { @MainActor in
                await self.activeSession?.emergencyStop()
            }
        } else if let live = liveSession, !isConnected, phase != .configuringWifi {
            Task { @MainActor in
                await live.nudgeReconnectOnForeground()
            }
        }
    }

    // MARK: - State Machine Reconciliation & Timers

    func reconcileCockpitState() {
        let currentPhase = phase
        let health = telemetry.health
        let policies = telemetry.policies
        let robotState = telemetry.robotState

        if !currentPhase.isConnected {
            resetCockpitLatches()
        } else if health == nil || policies == nil || robotState == nil {
            // Reconnecting or initial sync: clear previous policy edge so already-seated ducks skip U6a.
            lastObservedPolicy = nil
        } else if let robotState {
            let newPolicy = robotState.policy
            let prevPolicy = lastObservedPolicy
            let fallen = robotState.safety.fallen
            let pickedUp = robotState.safety.picked_up

            if !fallen {
                disarmedWhileFallen = false
            }

            if newPolicy != "homing" {
                if prevPolicy == "homing" && newPolicy == "held" && !suppressNextPostHomingLatch && policies?.homed != true {
                    startPostHomingLatch()
                }
                suppressNextPostHomingLatch = false
            }

            if policies?.homed == true || (newPolicy != "held" && newPolicy != "homing") {
                clearPostHomingLatch()
            }

            if (policies?.homed == false && newPolicy == "held") || fallen {
                clearRestingPending()
            }

            if isAutoRising {
                if newPolicy == "sit" || newPolicy == "rise" {
                    autoRiseSawDrivingPolicy = true
                }
                if newPolicy == "walk" || newPolicy == "stand" || fallen || (autoRiseSawDrivingPolicy && newPolicy == "held") {
                    clearAutoRising()
                }
            }

            if let prevPolicy,
               prevPolicy != "sit",
               newPolicy == "sit",
               !isRestingPending,
               !isAutoRising,
               !fallen,
               !pickedUp {
                startSitSettleTimer()
            }

            if newPolicy != "sit" || fallen || pickedUp || isRestingPending || isAutoRising {
                clearSitSettling()
            }

            lastObservedPolicy = newPolicy
        }

        let resolved = computeCockpitState()
        if resolved != lastResolvedCockpitState {
            let previous = lastResolvedCockpitState
            lastResolvedCockpitState = resolved

            pendingConfirmation = nil

            if let startState = inFlightStartState, resolved != startState {
                clearInFlightAction()
            }

            if !Self.canDrive(for: resolved) && (stickForward != 0 || stickStrafeLeft != 0 || turnYawLeft != 0) {
                stickForward = 0
                stickStrafeLeft = 0
                turnYawLeft = 0
                activeSession?.setMove(vx: 0, vy: 0, vyaw: 0)
            }
            if !Self.canLook(for: resolved) {
                stopLook()
            }

            if resolved.isSafetyOrFaultState || resolved == .offline || resolved == .syncing {
                clearSlotGuard()
            } else if shouldArmSlotGuard(from: previous, to: resolved) {
                armSlotGuard()
            }

            emitTransitionHaptic(from: previous, to: resolved)
        }
    }

    private func computeCockpitState() -> CockpitState {
        CockpitStateResolver.resolve(
            phase: phase,
            health: telemetry.health,
            policies: telemetry.policies,
            subscribeAck: telemetry.subscribeAck,
            robotState: telemetry.robotState,
            awaitingPostHomingPolicies: awaitingPostHomingPolicies,
            isSitSettling: isSitSettling,
            isAutoRising: isAutoRising,
            isRestingPending: isRestingPending,
            isShutdownPending: isShutdownPending,
            disarmedWhileFallen: disarmedWhileFallen
        )
    }

    private static func canDrive(for state: CockpitState) -> Bool {
        if case .walking = state { return true }
        return false
    }

    private static func canLook(for state: CockpitState) -> Bool {
        switch state {
        case .walking, .seated:
            return true
        default:
            return false
        }
    }

    private var hotServoTempForConfirmation: Double? {
        guard let motors = telemetry.health?.motors, motors.isHot else {
            return nil
        }
        return motors.max_c
    }

    private func dispatchAction(_ action: CockpitAction) async {
        guard let session = activeSession else { return }
        let startState = cockpitState
        startInFlightLock(for: action, startState: startState)
        QuackHaptics.medium()

        let result: IntentResult
        switch action {
        case .initMotors:
            let wasFallen = telemetry.robotState?.safety.fallen ?? false
            if wasFallen {
                disarmedWhileFallen = true
            }
            result = await session.sendInit()
            if !result.accepted && wasFallen {
                disarmedWhileFallen = false
            }

        case .walk:
            result = await session.setPolicyEnabled(true)

        case .standFromSeat:
            startAutoRiseTimer()
            result = await session.setPolicyEnabled(true)
            if !result.accepted {
                clearAutoRising()
            }

        case .hold, .cancelRecovery, .stopSkill:
            let wasFallen = telemetry.robotState?.safety.fallen ?? false
            clearAutoRising()
            clearSitSettling()
            if wasFallen && (action == .hold || action == .cancelRecovery) {
                disarmedWhileFallen = true
            }
            result = await session.setPolicyEnabled(false)
            if !result.accepted && wasFallen && (action == .hold || action == .cancelRecovery) {
                disarmedWhileFallen = false
            }

        case .sit, .standUp:
            result = await session.sendSitToggle()

        case .relax:
            if case .initializing = startState {
                suppressNextPostHomingLatch = true
            }
            clearPostHomingLatch()
            clearAutoRising()
            clearSitSettling()
            result = await session.sendRelax()

        case .rest:
            if case .initializing = startState {
                suppressNextPostHomingLatch = true
            }
            clearPostHomingLatch()
            clearAutoRising()
            clearSitSettling()
            startRestPendingTimer()
            result = await session.sendRest()
            if !result.accepted {
                clearRestingPending()
            }

        case .shutdown:
            stopAllMotion()
            clearPostHomingLatch()
            clearAutoRising()
            clearSitSettling()
            clearRestingPending()
            startShutdownPendingTimer()
            result = await session.sendShutdown()
            if !result.accepted {
                clearShutdownPending()
            }

        case .stopMoving:
            clearInFlightAction()
            await emergencyStop()
            return
        }

        reconcileCockpitState()

        if !result.accepted {
            clearInFlightAction()
            QuackHaptics.error()
            activeAlertMessage = result.reason ?? "The robot refused that action."
        } else if cockpitState != startState {
            clearInFlightAction()
        }
    }

    private func startInFlightLock(for action: CockpitAction, startState: CockpitState) {
        inFlightTask?.cancel()
        inFlightAction = action
        inFlightStartState = startState
        let timeoutNs: UInt64 = (action == .standUp) ? 1_200_000_000 : 1_500_000_000
        inFlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard let self, !Task.isCancelled else { return }
            self.clearInFlightAction()
        }
    }

    private func clearInFlightAction() {
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightAction = nil
        inFlightStartState = nil
    }

    private func shouldArmSlotGuard(from previous: CockpitState, to next: CockpitState) -> Bool {
        switch (previous, next) {
        case (.limp, .initializing):
            return true
        case (.readyHome, .walking),
             (.readySeated, .walking),
             (.rising, .walking),
             (.seated, .walking):
            return true
        case (.initializing, .limp),
             (.calibratingImu, .limp),
             (.readyHome, .limp),
             (.readySeated, .limp),
             (.walking, .limp),
             (.sittingDown, .limp),
             (.seated, .limp),
             (.rising, .limp),
             (.runningSkill, .limp),
             (.pickedUp, .limp),
             (.fallenRecovering, .limp),
             (.fallenParked, .limp),
             (.resting, .limp):
            return true
        default:
            return false
        }
    }

    private func armSlotGuard() {
        slotGuardTask?.cancel()
        slotGuardActive = true
        slotGuardTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.slotGuardActive = false
            self.slotGuardTask = nil
        }
    }

    private func clearSlotGuard() {
        slotGuardTask?.cancel()
        slotGuardTask = nil
        slotGuardActive = false
    }

    private func startPostHomingLatch() {
        postHomingTask?.cancel()
        awaitingPostHomingPolicies = true
        postHomingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.awaitingPostHomingPolicies = false
            self.postHomingTask = nil
            self.reconcileCockpitState()
        }
    }

    private func clearPostHomingLatch() {
        postHomingTask?.cancel()
        postHomingTask = nil
        awaitingPostHomingPolicies = false
    }

    private func startSitSettleTimer() {
        sitSettleTask?.cancel()
        isSitSettling = true
        sitSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isSitSettling = false
            self.sitSettleTask = nil
            self.reconcileCockpitState()
        }
    }

    private func clearSitSettling() {
        sitSettleTask?.cancel()
        sitSettleTask = nil
        isSitSettling = false
    }

    private func startAutoRiseTimer() {
        autoRiseTask?.cancel()
        isAutoRising = true
        autoRiseSawDrivingPolicy = false
        autoRiseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isAutoRising = false
            self.autoRiseSawDrivingPolicy = false
            self.autoRiseTask = nil
            self.reconcileCockpitState()
        }
    }

    private func clearAutoRising() {
        autoRiseTask?.cancel()
        autoRiseTask = nil
        isAutoRising = false
        autoRiseSawDrivingPolicy = false
    }

    private func startRestPendingTimer() {
        restPendingTask?.cancel()
        isRestingPending = true
        restPendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isRestingPending = false
            self.restPendingTask = nil
            self.reconcileCockpitState()
        }
    }

    private func clearRestingPending() {
        restPendingTask?.cancel()
        restPendingTask = nil
        isRestingPending = false
    }

    private func startShutdownPendingTimer() {
        shutdownPendingTask?.cancel()
        isShutdownPending = true
        shutdownPendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isShutdownPending = false
            self.shutdownPendingTask = nil
            self.reconcileCockpitState()
        }
    }

    private func clearShutdownPending() {
        shutdownPendingTask?.cancel()
        shutdownPendingTask = nil
        isShutdownPending = false
    }

    private func resetCockpitLatches() {
        clearPostHomingLatch()
        clearSitSettling()
        clearAutoRising()
        clearRestingPending()
        clearShutdownPending()
        clearInFlightAction()
        clearSlotGuard()
        disarmedWhileFallen = false
        suppressNextPostHomingLatch = false
        lastObservedPolicy = nil
        pendingConfirmation = nil
        if !phase.isConnected {
            didConfirmSitThisSession = false
        }
    }

    private func emitTransitionHaptic(from previous: CockpitState, to next: CockpitState) {
        switch (previous, next) {
        case (.initializing, .readyHome),
             (.initializing, .readySeated),
             (.calibratingImu, .readyHome),
             (.calibratingImu, .readySeated),
             (.sittingDown, .seated),
             (.rising, .walking):
            QuackHaptics.success()

        case (_, .pickedUp):
            QuackHaptics.warning()

        case (_, .hardwareBlocked),
             (_, .fallenRecovering),
             (_, .fallenParked):
            QuackHaptics.error()

        default:
            break
        }
    }

    private func armSessionObservation() {
        observationGeneration &+= 1
        let generation = observationGeneration
        observeActiveSession(generation: generation)
    }

    private func observeActiveSession(generation: UInt64) {
        guard generation == observationGeneration, let session = activeSession else { return }
        withObservationTracking {
            _ = session.phase
            _ = session.telemetry.health
            _ = session.telemetry.policies
            _ = session.telemetry.subscribeAck
            _ = session.telemetry.robotState
            _ = session.telemetry.isPoweredOff
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.observationGeneration else { return }
                self.reconcileCockpitState()
                self.observeActiveSession(generation: generation)
            }
        }
    }

    // MARK: - Private helpers

    private func pushCombinedMove() {
        let vx = stickForward * LiveRobotSession.maxLinearSpeed
        let vy = stickStrafeLeft * LiveRobotSession.maxLinearSpeed
        let vyaw = turnYawLeft * LiveRobotSession.maxAngularSpeed
        activeSession?.setMove(vx: vx, vy: vy, vyaw: vyaw)
    }

    private func mostRecentConnectedDuck(in ducks: [PairedDuck]) -> PairedDuck? {
        ducks
            .filter { $0.lastConnectedAt != nil }
            .max { ($0.lastConnectedAt ?? .distantPast) < ($1.lastConnectedAt ?? .distantPast) }
    }

    private func stopActiveLiveSessionIfAny() async {
        if let live = liveSession {
            live.onStateUpdated = nil
            await live.disconnect()
            liveSession = nil
        }
    }

    private func stopDemoModeIfAny() async {
        if let demo = demoSession {
            demo.onStateUpdated = nil
            await demo.disconnect()
            demoSession = nil
        }
    }
}

private extension CockpitState {
    var isSafetyOverrideState: Bool {
        switch self {
        case .pickedUp, .fallenRecovering, .fallenParked, .resting, .shuttingDown:
            return true
        default:
            return false
        }
    }

    var isSafetyOrFaultState: Bool {
        switch self {
        case .hardwareBlocked, .pickedUp, .fallenRecovering, .fallenParked, .resting, .shuttingDown:
            return true
        default:
            return false
        }
    }
}
