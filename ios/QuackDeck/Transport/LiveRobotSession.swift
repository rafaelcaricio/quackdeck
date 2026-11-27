import Foundation
import Network
import Observation
import WebRTC

enum LiveSessionError: LocalizedError {
    case localNetworkBlocked
    case noTargetDuck

    var errorDescription: String? {
        switch self {
        case .localNetworkBlocked:
            return "Local Network access appears blocked. Allow QuackDeck in iOS Settings > Privacy > Local Network, then tap Retry."
        case .noTargetDuck:
            return "No paired duck selected to connect."
        }
    }
}

@MainActor
@Observable
final class LiveRobotSession: RobotSessionTransport {
    static let maxLinearSpeed: Double = 0.3
    static let maxAngularSpeed: Double = 1.5
    static let lookCenterPoint = (x: 1.0, y: 0.0, z: 0.2)
    static let lookRange = (y: 0.7, z: 0.2, dz: 0.45)

    private static let supervisorBackoffSeconds: [Int] = [2, 3, 5, 8, 10]
    private static let localNetworkConfirmedKey = "com.caricio.quackdeck.localNetworkConfirmed"
    private static let localNetworkWaitSeconds: TimeInterval = 20.0
    private static let localNetworkQuickProbeSeconds: TimeInterval = 3.0
    private static let localNetworkRetryIntervalSeconds: TimeInterval = 1.5

    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var telemetry = TelemetrySnapshot()
    private(set) var videoSource: VideoFrameSource = .none
    let isDemoMode: Bool = false
    private(set) var currentDuckName: String = "Microduck"
    private(set) var currentRobotId: String?
    private(set) var currentIpAddress: String?

    @ObservationIgnored var onStateUpdated: (@MainActor () -> Void)?

    private let bleManager: BleManager
    private let vault: RobotVault
    private let webRTC = WebRTCSession()

    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(label: "com.caricio.quackdeck.pathmonitor")
    private var lastNetworkSatisfied: Bool = true

    private var targetDuck: PairedDuck?
    private var pskHex: String?
    private var peripheralId: UUID?
    private var lanRpcClient: LanRpcClient?
    private var isConnectingLanRpcClient: Bool = false
    private var nextLanRpcId: Int = 1

    private enum ShutdownPhase {
        case idle
        case pendingAck
        case acceptedAwaitingDisconnect
    }

    private var connectGeneration: UInt64 = 0
    private var userDisconnected: Bool = false
    private var shutdownPhase: ShutdownPhase = .idle
    private var isAttemptingConnection: Bool = false
    private var consecutiveLanFailures: Int = 0
    private var didNudgeWakeSleep: Bool = false

    private var reconnectSupervisorTask: Task<Void, Never>?
    private var sleepWaitTask: Task<Void, Never>?
    private var sleepWaitToken: UUID?
    private var retryCountdownTask: Task<Void, Never>?
    private var bleIpRefreshTask: Task<Void, Never>?
    private var shutdownFinalizeTask: Task<Void, Never>?

    private var sensorsVisible: Bool = false
    private var headImuSubscribedOnSession: Bool = false
    private var hasStartedStreamsForCurrentChannel: Bool = false
    private var streamInitTask: Task<Void, Never>?
    private var healthPollTask: Task<Void, Never>?
    private var freshnessWatchdogTask: Task<Void, Never>?
    private var tofTimestampWindow: [Date] = []
    private var lastObservedPolicy: String?
    private var policiesFetchSeq: UInt64 = 0
    private var appliedPoliciesSeq: UInt64 = 0

    // 10 Hz continuous motion & look loops
    private var moveVector: (vx: Double, vy: Double, vyaw: Double) = (0, 0, 0)
    private var isSendingMove: Bool = false
    private var moveTimerTask: Task<Void, Never>?

    private var lookTarget: (y: Double, z: Double)?
    private var lookSenderTask: Task<Void, Never>?
    private var lookGestureGeneration: UInt64 = 0

    init(bleManager: BleManager, vault: RobotVault = .shared) {
        self.bleManager = bleManager
        self.vault = vault
        wireWebRTCCallbacks()
        wireBleCallbacks()
        startNetworkPathMonitor()
    }

    deinit {
        pathMonitor?.cancel()
    }

    // MARK: - Connection Entry Points

    func connectToPairedDuck(_ duck: PairedDuck, pskHex: String) async {
        prepareNewConnectionAttempt(
            duck: duck,
            robotId: duck.robotId,
            name: duck.name,
            pskHex: pskHex,
            peripheralId: duck.peripheralId
        )
        let generation = connectGeneration
        await runInitialConnectionAndStartSupervisorIfNeeded(
            duck: duck,
            pskHex: pskHex,
            preferLanFirst: true,
            generation: generation
        )
    }

    func connectViaBle(
        peripheralId: UUID,
        robotId: String,
        pskHex: String,
        fallbackName: String? = nil
    ) async {
        let existing = vault.pairedDuck(for: robotId)
        let resolvedName = (fallbackName?.isEmpty == false ? fallbackName : nil) ?? existing?.name ?? currentDuckName
        let duck = PairedDuck(
            robotId: robotId,
            name: resolvedName,
            lastIp: existing?.lastIp,
            peripheralId: peripheralId,
            pairedAt: existing?.pairedAt ?? Date(),
            lastConnectedAt: existing?.lastConnectedAt
        )
        prepareNewConnectionAttempt(
            duck: duck,
            robotId: robotId,
            name: resolvedName,
            pskHex: pskHex,
            peripheralId: peripheralId
        )
        let generation = connectGeneration
        await runInitialConnectionAndStartSupervisorIfNeeded(
            duck: duck,
            pskHex: pskHex,
            preferLanFirst: false,
            generation: generation
        )
    }

    func forceReconnect() async {
        guard let duck = resolvedTargetDuck(), let pskHex else {
            phase = .error(LiveSessionError.noTargetDuck.localizedDescription)
            telemetry.lastError = LiveSessionError.noTargetDuck.localizedDescription
            onStateUpdated?()
            return
        }

        userDisconnected = false
        shutdownPhase = .idle
        telemetry.shutdownOutcome = .none
        shutdownFinalizeTask?.cancel()
        shutdownFinalizeTask = nil
        connectGeneration &+= 1
        let generation = connectGeneration

        cancelBackgroundReconnectTasks()
        stopLocalMotionAndStreamLoops()
        webRTC.stop()
        lanRpcClient = nil
        await bleManager.disconnect()

        guard connectGeneration == generation, !userDisconnected else { return }

        consecutiveLanFailures = 0
        telemetry.reconnectAttempt = 0
        telemetry.nextRetrySeconds = nil
        telemetry.isAutoReconnecting = false
        telemetry.isPoweredOff = false
        telemetry.lastError = nil
        telemetry.statusBanner = "Retrying connection..."
        onStateUpdated?()

        await runInitialConnectionAndStartSupervisorIfNeeded(
            duck: duck,
            pskHex: pskHex,
            preferLanFirst: true,
            generation: generation
        )
    }

    func nudgeReconnectOnForeground() async {
        guard !userDisconnected,
              !phase.isConnected,
              phase != .configuringWifi,
              resolvedTargetDuck() != nil,
              pskHex != nil else {
            return
        }

        if phase == .connectingVideo && !webRTC.isControlOpen && bleIpRefreshTask == nil {
            telemetry.nextRetrySeconds = nil
            telemetry.statusBanner = "Reconnecting to \(currentDuckName)..."
            onStateUpdated?()
            webRTC.forceReconnectNow()
            return
        }

        if sleepWaitTask != nil {
            didNudgeWakeSleep = true
            sleepWaitTask?.cancel()
            return
        }

        if !isAttemptingConnection && reconnectSupervisorTask == nil {
            let generation = connectGeneration
            startReconnectSupervisor(generation: generation)
        }
    }

    func promoteToLan(
        ipAddress: String,
        robotId: String,
        pskHex: String,
        requireExtendedLocalNetworkWait: Bool = true
    ) async throws {
        let generation = connectGeneration
        try await promoteToLan(
            ipAddress: ipAddress,
            robotId: robotId,
            pskHex: pskHex,
            requireExtendedLocalNetworkWait: requireExtendedLocalNetworkWait,
            generation: generation
        )
    }

    // MARK: - RobotSessionTransport

    func setSensorsVisible(_ visible: Bool) {
        sensorsVisible = visible
        guard webRTC.isControlOpen else { return }
        let hz = visible ? 10 : 2
        Task {
            await self.subscribeRobotState(hz: hz)
            if visible && !self.headImuSubscribedOnSession {
                self.headImuSubscribedOnSession = true
                _ = try? await self.webRTC.call(method: "head_imu.stream")
            }
        }
    }

    func setMove(vx: Double, vy: Double, vyaw: Double) {
        let clampedVx = max(-Self.maxLinearSpeed, min(Self.maxLinearSpeed, vx))
        let clampedVy = max(-Self.maxLinearSpeed, min(Self.maxLinearSpeed, vy))
        let clampedVyaw = max(-Self.maxAngularSpeed, min(Self.maxAngularSpeed, vyaw))
        let previousVyaw = moveVector.vyaw
        moveVector = (clampedVx, clampedVy, clampedVyaw)

        let moving = abs(clampedVx) > 0.001 || abs(clampedVy) > 0.001 || abs(clampedVyaw) > 0.001
        if moving {
            if !isSendingMove {
                isSendingMove = true
                sendCurrentMove()
                startMoveLoop()
            } else if abs(clampedVyaw - previousVyaw) > 0.001 {
                sendCurrentMove()
            }
        } else if isSendingMove {
            isSendingMove = false
            moveTimerTask?.cancel()
            moveTimerTask = nil
            webRTC.tell(method: "robot.move", params: ["vx": 0.0, "vy": 0.0, "vyaw": 0.0])
        }
    }

    func setLook(y: Double, z: Double) {
        let clampedY = max(-Self.lookRange.y, min(Self.lookRange.y, y))
        let minZ = Self.lookRange.z - Self.lookRange.dz
        let maxZ = Self.lookRange.z + Self.lookRange.dz
        let clampedZ = max(minZ, min(maxZ, z))

        lookTarget = (clampedY, clampedZ)
        if lookSenderTask == nil {
            startLookLoop()
        }
    }

    func stopLook() {
        lookGestureGeneration &+= 1
        lookTarget = nil
        lookSenderTask?.cancel()
        lookSenderTask = nil
    }

    func lookCenter() {
        stopLook()
        let generation = lookGestureGeneration
        telemetry.lookClamped = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let params: [String: Any] = [
                "x": Self.lookCenterPoint.x,
                "y": Self.lookCenterPoint.y,
                "z": Self.lookCenterPoint.z,
                "neck_pitch": 0.0
            ]
            if let data = try? await webRTC.call(method: "robot.look", params: params),
               let result = try? JSONDecoder().decode(LookResult.self, from: data),
               self.lookGestureGeneration == generation {
                self.telemetry.lookClamped = result.clamped
            }
        }
    }

    func sendInit() async -> IntentResult {
        await callPostureRpc(method: "robot.init")
    }

    func setPolicyEnabled(_ on: Bool) async -> IntentResult {
        await callPostureRpc(method: "robot.enable", params: ["on": on, "toggle": false])
    }

    func sendSitToggle() async -> IntentResult {
        await callPostureRpc(method: "robot.do", params: ["skill": "sit_toggle"])
    }

    func triggerEmotion(_ name: String) async -> IntentResult {
        await callSkillRpc(skill: name)
    }

    func triggerKick(_ side: KickSide) async -> IntentResult {
        await callSkillRpc(skill: side.skillName)
    }

    func sendRelax() async -> IntentResult {
        await callPostureRpc(method: "robot.relax")
    }

    func sendRest() async -> IntentResult {
        await callPostureRpc(method: "robot.rest")
    }

    func sendShutdown() async -> IntentResult {
        guard webRTC.isControlOpen else {
            return IntentResult(accepted: false, reason: "Connect to the robot first.")
        }

        moveVector = (0, 0, 0)
        isSendingMove = false
        moveTimerTask?.cancel()
        moveTimerTask = nil
        stopLook()
        cancelBackgroundReconnectTasks()

        let generation = connectGeneration
        shutdownPhase = .pendingAck
        telemetry.shutdownOutcome = .none
        telemetry.statusBanner = "Requesting shutdown..."
        webRTC.prepareForExpectedShutdown()

        do {
            let data = try await webRTC.call(method: "robot.shutdown", params: [:], timeoutSeconds: 8)
            guard let result = try? JSONDecoder().decode(IntentResult.self, from: data) else {
                shutdownPhase = .idle
                webRTC.resumeAutoReconnect()
                let message = "Invalid shutdown response from robot."
                telemetry.shutdownOutcome = .none
                telemetry.statusBanner = message
                onStateUpdated?()
                return IntentResult(accepted: false, reason: message)
            }
            if result.accepted {
                shutdownPhase = .acceptedAwaitingDisconnect
                telemetry.shutdownOutcome = .requested
                telemetry.statusBanner = "Shutdown requested..."
                onStateUpdated?()
                if !webRTC.isControlOpen {
                    finalizeConfirmedShutdown()
                } else {
                    startShutdownFinalizeFallback(generation: generation)
                }
                return result
            } else {
                shutdownPhase = .idle
                telemetry.shutdownOutcome = .none
                webRTC.resumeAutoReconnect()
                if let reason = result.reason {
                    telemetry.statusBanner = reason
                }
                onStateUpdated?()
                return result
            }
        } catch WebRTCSessionError.controlChannelClosed {
            if shutdownPhase == .acceptedAwaitingDisconnect {
                finalizeConfirmedShutdown()
                return IntentResult(accepted: true)
            }
            if shutdownPhase == .pendingAck {
                finalizeUnconfirmedShutdown()
                return IntentResult(accepted: false, reason: "Connection lost · shutdown unconfirmed.")
            }
            return IntentResult(accepted: false, reason: WebRTCSessionError.controlChannelClosed.localizedDescription)
        } catch {
            if shutdownPhase == .pendingAck {
                shutdownPhase = .idle
                telemetry.shutdownOutcome = .none
                webRTC.resumeAutoReconnect()
                telemetry.lastError = error.localizedDescription
                onStateUpdated?()
            }
            return IntentResult(accepted: false, reason: error.localizedDescription)
        }
    }

    func refreshPolicies() async {
        guard webRTC.isControlOpen else { return }
        policiesFetchSeq &+= 1
        let seq = policiesFetchSeq
        if let data = try? await webRTC.call(method: "robot.policies", timeoutSeconds: 5),
           let policies = try? JSONDecoder().decode(PoliciesResult.self, from: data) {
            if seq >= appliedPoliciesSeq {
                appliedPoliciesSeq = seq
                telemetry.policies = policies
                onStateUpdated?()
            }
        }
    }

    func emergencyStop() async {
        moveVector = (0, 0, 0)
        isSendingMove = false
        moveTimerTask?.cancel()
        moveTimerTask = nil
        stopLook()

        if webRTC.isControlOpen {
            webRTC.tell(method: "robot.move", params: ["vx": 0.0, "vy": 0.0, "vyaw": 0.0])
            _ = try? await webRTC.call(method: "robot.stop")
        }
    }

    private func callPostureRpc(method: String, params: [String: Any] = [:]) async -> IntentResult {
        guard webRTC.isControlOpen else {
            return IntentResult(accepted: false, reason: "Connect to the robot first.")
        }
        do {
            let data = try await webRTC.call(method: method, params: params)
            guard let result = try? JSONDecoder().decode(IntentResult.self, from: data) else {
                let message = "Invalid response from robot."
                telemetry.statusBanner = message
                await refreshPolicies()
                return IntentResult(accepted: false, reason: message)
            }
            if !result.accepted, let reason = result.reason {
                telemetry.statusBanner = reason
            }
            await refreshPolicies()
            return result
        } catch {
            telemetry.lastError = error.localizedDescription
            await refreshPolicies()
            return IntentResult(accepted: false, reason: error.localizedDescription)
        }
    }

    private func callSkillRpc(skill: String) async -> IntentResult {
        guard webRTC.isControlOpen else {
            return IntentResult(accepted: false, reason: "Connect to the robot first.")
        }
        do {
            let data = try await webRTC.call(method: "robot.do", params: ["skill": skill])
            guard let result = try? JSONDecoder().decode(IntentResult.self, from: data) else {
                let message = "Invalid response from robot."
                telemetry.statusBanner = message
                Task { [weak self] in
                    await self?.refreshPolicies()
                }
                return IntentResult(accepted: false, reason: message)
            }
            if !result.accepted, let reason = result.reason {
                telemetry.statusBanner = reason
            }
            Task { [weak self] in
                await self?.refreshPolicies()
            }
            return result
        } catch {
            telemetry.lastError = error.localizedDescription
            Task { [weak self] in
                await self?.refreshPolicies()
            }
            return IntentResult(accepted: false, reason: error.localizedDescription)
        }
    }

    func playQuack() async {
        guard webRTC.isControlOpen else { return }
        _ = try? await webRTC.call(method: "robot.sound", params: ["tag": "chirp"])
    }

    func scanWifiNetworks() async throws -> [WifiNetwork] {
        let raw = try await callProvisioningRpc(method: "net.scan", timeoutSeconds: 20)
        let result = try decodeJSON(NetScanResult.self, from: raw)
        return result.networks
    }

    func connectWifi(ssid: String, psk: String?) async throws -> ConnectResult {
        var params: [String: Any] = ["ssid": ssid]
        if let psk, !psk.isEmpty {
            params["psk"] = psk
        }

        // Poll net.status every 1 s while net.connect runs so UI sees live Joining progress.
        let pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { break }
                await self.refreshNetStatus()
            }
        }
        defer { pollTask.cancel() }

        let raw = try await callProvisioningRpc(method: "net.connect", params: params, timeoutSeconds: 55)
        let result = try decodeJSON(ConnectResult.self, from: raw)
        await refreshNetStatus()

        if case .connected(_, let ip4) = result,
           let ipAddress = ip4 ?? telemetry.netStatus?.ip4,
           !ipAddress.isEmpty,
           let robotId = currentRobotId,
           let pskHex {
            let generation = connectGeneration
            do {
                try await promoteToLan(
                    ipAddress: ipAddress,
                    robotId: robotId,
                    pskHex: pskHex,
                    requireExtendedLocalNetworkWait: true,
                    generation: generation
                )
            } catch {
                handleBleFallbackFailure(error, generation: generation)
            }
        }
        return result
    }

    func forgetWifi(ssid: String) async throws -> Bool {
        let raw = try await callProvisioningRpc(method: "net.forget", params: ["ssid": ssid], timeoutSeconds: 15)
        let result = try decodeJSON(ForgetResult.self, from: raw)
        await refreshNetStatus()
        return result.removed
    }

    func refreshNetStatus() async {
        do {
            let raw = try await callProvisioningRpc(method: "net.status", timeoutSeconds: 10)
            let status = try decodeJSON(NetStatusResult.self, from: raw)
            telemetry.netStatus = status
            if let ip4 = status.ip4, !ip4.isEmpty, currentIpAddress != ip4 {
                currentIpAddress = ip4
                targetDuck?.lastIp = ip4
                if let robotId = currentRobotId {
                    vault.updateConnectionMetadata(robotId: robotId, lastIp: ip4)
                }
            }
        } catch {
            // Keep existing status if a single poll hiccups during join.
        }
    }

    func disconnect() async {
        userDisconnected = true
        shutdownPhase = .idle
        telemetry.shutdownOutcome = .none
        shutdownFinalizeTask?.cancel()
        shutdownFinalizeTask = nil
        connectGeneration &+= 1
        cancelBackgroundReconnectTasks()
        stopLocalMotionAndStreamLoops()

        webRTC.stop()
        lanRpcClient = nil
        await bleManager.disconnect()

        targetDuck = nil
        currentRobotId = nil
        currentIpAddress = nil
        pskHex = nil
        peripheralId = nil
        consecutiveLanFailures = 0

        telemetry = TelemetrySnapshot()
        videoSource = .none
        phase = .disconnected
        onStateUpdated?()
    }

    // MARK: - Connection Orchestration & Reconnect Supervisor

    private func prepareNewConnectionAttempt(
        duck: PairedDuck,
        robotId: String,
        name: String,
        pskHex: String,
        peripheralId: UUID?
    ) {
        userDisconnected = false
        shutdownPhase = .idle
        telemetry.shutdownOutcome = .none
        shutdownFinalizeTask?.cancel()
        shutdownFinalizeTask = nil
        connectGeneration &+= 1
        cancelBackgroundReconnectTasks()
        stopLocalMotionAndStreamLoops()
        webRTC.stop()
        lanRpcClient = nil

        self.targetDuck = duck
        self.currentRobotId = robotId
        self.currentDuckName = name
        self.pskHex = pskHex
        self.peripheralId = peripheralId
        self.consecutiveLanFailures = 0

        self.telemetry.lastError = nil
        self.telemetry.statusBanner = nil
        self.telemetry.reconnectAttempt = 0
        self.telemetry.nextRetrySeconds = nil
        self.telemetry.isAutoReconnecting = false
        self.telemetry.isPoweredOff = false
    }

    private func runInitialConnectionAndStartSupervisorIfNeeded(
        duck: PairedDuck,
        pskHex: String,
        preferLanFirst: Bool,
        generation: UInt64
    ) async {
        do {
            try await performConnectionAttempt(
                duck: duck,
                pskHex: pskHex,
                preferLanFirst: preferLanFirst,
                generation: generation
            )
        } catch {
            guard connectGeneration == generation, !userDisconnected else { return }
            if phase != .configuringWifi {
                let message = error.localizedDescription
                phase = .error(message)
                telemetry.lastError = message
                onStateUpdated?()
                startReconnectSupervisor(generation: generation)
            }
        }
    }

    private func performConnectionAttempt(
        duck: PairedDuck,
        pskHex: String,
        preferLanFirst: Bool,
        generation: UInt64
    ) async throws {
        guard connectGeneration == generation, !userDisconnected else {
            throw CancellationError()
        }
        isAttemptingConnection = true
        defer { isAttemptingConnection = false }

        if preferLanFirst, let lanIp = currentIpAddress ?? duck.lastIp, !lanIp.isEmpty {
            do {
                try await promoteToLan(
                    ipAddress: lanIp,
                    robotId: duck.robotId,
                    pskHex: pskHex,
                    requireExtendedLocalNetworkWait: false,
                    generation: generation
                )
                return
            } catch let lanErr as LiveSessionError where lanErr == .localNetworkBlocked {
                throw lanErr
            } catch {
                guard connectGeneration == generation, !userDisconnected else {
                    throw CancellationError()
                }
                consecutiveLanFailures += 1
                telemetry.statusBanner = "Direct LAN at \(lanIp) unreachable; trying Bluetooth..."
            }
        }

        // Fall back to BLE if peripheral is known or already discovered
        var resolvedPid = peripheralId ?? duck.peripheralId ?? matchingDiscoveredPeripheralId()
        if resolvedPid == nil {
            guard bleManager.bluetoothState == .poweredOn else {
                if preferLanFirst, let lanIp = currentIpAddress ?? duck.lastIp, !lanIp.isEmpty {
                    throw BleManagerError.disconnected("Duck is offline on LAN (\(lanIp)) and Bluetooth is unavailable.")
                }
                throw BleManagerError.bluetoothUnavailable(
                    bleManager.bluetoothState == .poweredOff
                        ? "Turn on Bluetooth to connect to your duck."
                        : "Bluetooth is not ready (\(bleManager.stateDescription))."
                )
            }
            bleManager.startScan()
            phase = .scanning
            onStateUpdated?()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard connectGeneration == generation, !userDisconnected else {
                throw CancellationError()
            }
            resolvedPid = peripheralId ?? duck.peripheralId ?? matchingDiscoveredPeripheralId()
        }

        guard let pid = resolvedPid else {
            throw BleManagerError.disconnected("Duck is offline on LAN and not seen over Bluetooth.")
        }

        try await connectViaBleInternal(
            peripheralId: pid,
            robotId: duck.robotId,
            pskHex: pskHex,
            fallbackName: duck.name,
            generation: generation
        )
    }

    private func connectViaBleInternal(
        peripheralId: UUID,
        robotId: String,
        pskHex: String,
        fallbackName: String?,
        generation: UInt64
    ) async throws {
        guard connectGeneration == generation, !userDisconnected else {
            throw CancellationError()
        }

        self.peripheralId = peripheralId
        self.currentRobotId = robotId
        self.pskHex = pskHex
        if let fallbackName, !fallbackName.isEmpty {
            self.currentDuckName = fallbackName
        }

        phase = .connectingBle
        onStateUpdated?()

        phase = .authenticatingBle
        onStateUpdated?()
        _ = try await bleManager.connectAndAuthenticate(
            peripheralId: peripheralId,
            robotId: robotId,
            pskHex: pskHex
        )
        guard connectGeneration == generation, !userDisconnected else {
            throw CancellationError()
        }

        // Never gate on `hello` (`updaterd` may be absent on forks); verify via system.info + robot.health.
        let sysInfoJSON = try await bleManager.call(method: "system.info", timeoutSeconds: 10)
        let sysInfo = try decodeJSON(SystemInfoResult.self, from: sysInfoJSON)
        telemetry.systemInfo = sysInfo
        currentDuckName = sysInfo.name

        if let healthJSON = try? await bleManager.call(method: "robot.health", timeoutSeconds: 10),
           let health = try? decodeJSON(HealthResult.self, from: healthJSON) {
            telemetry.health = health
        }

        let netJSON = try await bleManager.call(method: "net.status", timeoutSeconds: 10)
        let netStatus = try decodeJSON(NetStatusResult.self, from: netJSON)
        telemetry.netStatus = netStatus

        let advIp = bleManager.discoveredDucks.first(where: { $0.id == peripheralId })?.advInfo.ipv4
        let ipAddress = netStatus.ip4 ?? advIp

        let savedDuck = PairedDuck(
            robotId: robotId,
            name: sysInfo.name,
            lastIp: ipAddress ?? targetDuck?.lastIp,
            peripheralId: peripheralId,
            pairedAt: vault.pairedDuck(for: robotId)?.pairedAt ?? targetDuck?.pairedAt ?? Date(),
            lastConnectedAt: Date()
        )
        targetDuck = savedDuck
        try? vault.save(duck: savedDuck, pskHex: pskHex)

        guard connectGeneration == generation, !userDisconnected else {
            throw CancellationError()
        }

        if let ipAddress, !ipAddress.isEmpty {
            try await promoteToLan(
                ipAddress: ipAddress,
                robotId: robotId,
                pskHex: pskHex,
                requireExtendedLocalNetworkWait: true,
                generation: generation
            )
        } else {
            phase = .configuringWifi
            telemetry.reconnectAttempt = 0
            telemetry.nextRetrySeconds = nil
            telemetry.isAutoReconnecting = false
            telemetry.statusBanner = "Connected over Bluetooth. Configure Wi-Fi for live video and control."
            onStateUpdated?()
        }
    }

    private func promoteToLan(
        ipAddress: String,
        robotId: String,
        pskHex: String,
        requireExtendedLocalNetworkWait: Bool,
        generation: UInt64
    ) async throws {
        guard connectGeneration == generation, !userDisconnected else {
            throw CancellationError()
        }

        currentIpAddress = ipAddress
        currentRobotId = robotId
        self.pskHex = pskHex
        phase = .connectingLan
        telemetry.lastError = nil
        onStateUpdated?()

        let client = try await connectLanRpcWithLocalNetworkWait(
            ipAddress: ipAddress,
            robotId: robotId,
            pskHex: pskHex,
            requireExtendedWait: requireExtendedLocalNetworkWait,
            generation: generation
        )
        guard connectGeneration == generation, !userDisconnected else {
            throw CancellationError()
        }
        self.lanRpcClient = client

        // Verify via system.info + robot.health (never `hello`)
        let sysRaw = try await callLanRpc(client: client, method: "system.info", timeoutMs: 4000)
        let sysInfo = try decodeJSON(SystemInfoResult.self, from: sysRaw)
        telemetry.systemInfo = sysInfo
        currentDuckName = sysInfo.name

        if let healthRaw = try? await callLanRpc(client: client, method: "robot.health", timeoutMs: 4000),
           let health = try? decodeJSON(HealthResult.self, from: healthRaw) {
            telemetry.health = health
        }
        if let netRaw = try? await callLanRpc(client: client, method: "net.status", timeoutMs: 4000),
           let netStatus = try? decodeJSON(NetStatusResult.self, from: netRaw) {
            telemetry.netStatus = netStatus
        }

        vault.updateConnectionMetadata(
            robotId: robotId,
            name: sysInfo.name,
            lastIp: ipAddress,
            peripheralId: peripheralId,
            connectedAt: Date()
        )
        if var duck = targetDuck, duck.robotId == robotId {
            duck.name = sysInfo.name
            duck.lastIp = ipAddress
            duck.peripheralId = peripheralId ?? duck.peripheralId
            duck.lastConnectedAt = Date()
            targetDuck = duck
        }

        guard connectGeneration == generation, !userDisconnected else {
            throw CancellationError()
        }

        consecutiveLanFailures = 0
        phase = .connectingVideo
        telemetry.statusBanner = nil
        onStateUpdated?()
        webRTC.start(host: ipAddress, port: 9443, robotId: robotId, pskHex: pskHex)
    }

    private func connectLanRpcWithLocalNetworkWait(
        ipAddress: String,
        robotId: String,
        pskHex: String,
        requireExtendedWait: Bool,
        generation: UInt64
    ) async throws -> LanRpcClient {
        do {
            let client = try await Task.detached(priority: .userInitiated) {
                try LanRpcClient(host: ipAddress, port: 9444, robotId: robotId, pskHex: pskHex, timeoutMs: 4000)
            }.value
            Self.markLocalNetworkConfirmed()
            return client
        } catch {
            guard connectGeneration == generation, !userDisconnected, !Task.isCancelled else {
                throw CancellationError()
            }
            guard isLikelyLocalNetworkError(error) else {
                throw error
            }

            telemetry.statusBanner = "Allow Local Network access if prompted..."
            onStateUpdated?()

            var sawLocalNetworkDenied = false
            var lastError: Error = error
            let initialBudget = (requireExtendedWait || !Self.hasConfirmedLocalNetwork)
                ? Self.localNetworkWaitSeconds
                : Self.localNetworkQuickProbeSeconds
            let start = Date()
            var deadline = start.addingTimeInterval(initialBudget)

            while Date() < deadline {
                guard connectGeneration == generation, !userDisconnected, !Task.isCancelled else {
                    throw CancellationError()
                }

                let remaining = deadline.timeIntervalSinceNow
                let sliceTimeout = min(Self.localNetworkRetryIntervalSeconds, max(0.25, remaining))
                let probe = await probeTcpWithNetworkFramework(
                    host: ipAddress,
                    port: 9444,
                    timeoutSeconds: sliceTimeout
                )

                guard connectGeneration == generation, !userDisconnected, !Task.isCancelled else {
                    throw CancellationError()
                }

                if probe.sawLocalNetworkDenied {
                    sawLocalNetworkDenied = true
                    let extendedDeadline = start.addingTimeInterval(Self.localNetworkWaitSeconds)
                    if extendedDeadline > deadline {
                        deadline = extendedDeadline
                    }
                }

                do {
                    let client = try await Task.detached(priority: .userInitiated) {
                        try LanRpcClient(host: ipAddress, port: 9444, robotId: robotId, pskHex: pskHex, timeoutMs: 3000)
                    }.value
                    Self.markLocalNetworkConfirmed()
                    telemetry.statusBanner = nil
                    return client
                } catch {
                    lastError = error
                    if !isLikelyLocalNetworkError(error) {
                        throw error
                    }
                }

                if Date() < deadline && !probe.reachedReady {
                    let sleepNs = UInt64(min(0.4, max(0.05, deadline.timeIntervalSinceNow)) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: sleepNs)
                }
            }

            if sawLocalNetworkDenied || requireExtendedWait || isExplicitLocalNetworkPermissionError(lastError) {
                throw LiveSessionError.localNetworkBlocked
            }
            throw lastError
        }
    }

    private struct ProbeResult: Sendable {
        let reachedReady: Bool
        let sawLocalNetworkDenied: Bool
    }

    private func probeTcpWithNetworkFramework(
        host: String,
        port: UInt16,
        timeoutSeconds: TimeInterval
    ) async -> ProbeResult {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return ProbeResult(reachedReady: false, sawLocalNetworkDenied: false)
        }

        final class ProbeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            private var sawDenied = false
            private var connection: NWConnection?
            private var continuation: CheckedContinuation<ProbeResult, Never>?
            private var timer: DispatchSourceTimer?

            func start(host: String, port: NWEndpoint.Port, timeoutSeconds: TimeInterval, continuation: CheckedContinuation<ProbeResult, Never>) {
                lock.lock()
                self.continuation = continuation
                let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
                self.connection = conn
                lock.unlock()

                conn.pathUpdateHandler = { [weak self] path in
                    if path.unsatisfiedReason == .localNetworkDenied {
                        self?.markDenied()
                    }
                }

                conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if conn.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        self.markDenied()
                    }
                    switch state {
                    case .ready:
                        self.finish(ready: true)
                    case .waiting(let err):
                        if case .posix(let code) = err, code == .EPERM {
                            self.markDenied()
                        }
                    case .failed(let err):
                        if case .posix(let code) = err, code == .EPERM {
                            self.markDenied()
                        }
                        self.finish(ready: false)
                    case .cancelled:
                        self.finish(ready: false)
                    default:
                        break
                    }
                }

                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + max(0.2, timeoutSeconds))
                timer.setEventHandler { [weak self] in
                    self?.finish(ready: false)
                }
                lock.lock()
                self.timer = timer
                lock.unlock()
                timer.resume()

                conn.start(queue: DispatchQueue.global(qos: .userInitiated))
            }

            func markDenied() {
                lock.lock()
                sawDenied = true
                lock.unlock()
            }

            func finish(ready: Bool) {
                lock.lock()
                guard !resumed else {
                    lock.unlock()
                    return
                }
                resumed = true
                let cont = continuation
                continuation = nil
                let denied = sawDenied
                let conn = connection
                connection = nil
                let t = timer
                timer = nil
                lock.unlock()

                t?.cancel()
                conn?.pathUpdateHandler = nil
                conn?.stateUpdateHandler = nil
                conn?.cancel()
                cont?.resume(returning: ProbeResult(reachedReady: ready, sawLocalNetworkDenied: denied))
            }
        }

        let box = ProbeBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.start(
                    host: host,
                    port: nwPort,
                    timeoutSeconds: timeoutSeconds,
                    continuation: continuation
                )
            }
        } onCancel: {
            box.finish(ready: false)
        }
    }

    private func startReconnectSupervisor(generation: UInt64) {
        reconnectSupervisorTask?.cancel()
        reconnectSupervisorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempt = max(1, self.telemetry.reconnectAttempt)

            while !Task.isCancelled,
                  self.connectGeneration == generation,
                  !self.userDisconnected,
                  !self.phase.isConnected,
                  self.phase != .configuringWifi {
                guard let duck = self.resolvedTargetDuck(), let pskHex = self.pskHex else {
                    break
                }

                let delayIdx = min(attempt - 1, Self.supervisorBackoffSeconds.count - 1)
                let delaySeconds = Self.supervisorBackoffSeconds[max(0, delayIdx)]

                self.telemetry.reconnectAttempt = attempt
                self.telemetry.isAutoReconnecting = true
                self.onStateUpdated?()

                let shouldProceed = await self.waitForSupervisorBackoff(
                    seconds: delaySeconds,
                    generation: generation
                )
                guard shouldProceed,
                      !Task.isCancelled,
                      self.connectGeneration == generation,
                      !self.userDisconnected else {
                    break
                }

                self.telemetry.nextRetrySeconds = nil
                self.telemetry.statusBanner = "Reconnecting to \(self.currentDuckName)..."
                self.onStateUpdated?()

                do {
                    try await self.performConnectionAttempt(
                        duck: duck,
                        pskHex: pskHex,
                        preferLanFirst: true,
                        generation: generation
                    )
                    // Connected or promoted to .connectingVideo / .configuringWifi.
                    break
                } catch {
                    guard !Task.isCancelled,
                          self.connectGeneration == generation,
                          !self.userDisconnected,
                          self.phase != .configuringWifi else {
                        break
                    }
                    let message = error.localizedDescription
                    self.phase = .error(message)
                    self.telemetry.lastError = message
                    self.onStateUpdated?()
                    attempt += 1
                }
            }

            if self.connectGeneration == generation {
                self.reconnectSupervisorTask = nil
            }
        }
    }

    private func waitForSupervisorBackoff(seconds: Int, generation: UInt64) async -> Bool {
        sleepWaitTask?.cancel()
        didNudgeWakeSleep = false
        let token = UUID()
        sleepWaitToken = token

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(1, seconds)
            while remaining > 0,
                  !Task.isCancelled,
                  self.connectGeneration == generation,
                  !self.userDisconnected {
                self.telemetry.nextRetrySeconds = remaining
                self.onStateUpdated?()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining -= 1
            }
            if !Task.isCancelled, self.connectGeneration == generation {
                self.telemetry.nextRetrySeconds = nil
                self.onStateUpdated?()
            }
        }
        sleepWaitTask = task
        await task.value
        if sleepWaitToken == token {
            sleepWaitTask = nil
            sleepWaitToken = nil
        }

        if didNudgeWakeSleep {
            didNudgeWakeSleep = false
            return connectGeneration == generation && !userDisconnected
        }
        return !Task.isCancelled && connectGeneration == generation && !userDisconnected
    }

    private func startWebRtcRetryCountdown(seconds: Int, generation: UInt64) {
        retryCountdownTask?.cancel()
        retryCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(1, seconds)
            while remaining > 0,
                  !Task.isCancelled,
                  self.connectGeneration == generation,
                  !self.userDisconnected,
                  !self.phase.isConnected {
                self.telemetry.nextRetrySeconds = remaining
                self.telemetry.statusBanner = "Reconnecting (\(self.telemetry.reconnectAttempt)) in \(remaining)s..."
                self.onStateUpdated?()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining -= 1
            }
            if !Task.isCancelled, self.connectGeneration == generation, !self.phase.isConnected {
                self.telemetry.nextRetrySeconds = nil
                self.telemetry.statusBanner = "Reconnecting to \(self.currentDuckName)..."
                self.onStateUpdated?()
            }
        }
    }

    private func triggerBleIpRefreshFallback(generation: UInt64) {
        guard bleIpRefreshTask == nil,
              connectGeneration == generation,
              !userDisconnected,
              let duck = resolvedTargetDuck(),
              let pskHex else {
            return
        }

        bleIpRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.bleIpRefreshTask = nil }

            // Check if already authenticated over BLE first.
            if self.bleManager.isAuthenticated {
                if let netRaw = try? await self.bleManager.call(method: "net.status", timeoutSeconds: 8),
                   let netStatus = try? self.decodeJSON(NetStatusResult.self, from: netRaw) {
                    self.telemetry.netStatus = netStatus
                    if let ip4 = netStatus.ip4, !ip4.isEmpty, ip4 != self.currentIpAddress {
                        self.webRTC.stop()
                        do {
                            try await self.promoteToLan(
                                ipAddress: ip4,
                                robotId: duck.robotId,
                                pskHex: pskHex,
                                requireExtendedLocalNetworkWait: true,
                                generation: generation
                            )
                        } catch {
                            self.handleBleFallbackFailure(error, generation: generation)
                        }
                    } else if netStatus.ip4 == nil {
                        self.webRTC.stop()
                        self.phase = .configuringWifi
                        self.telemetry.isAutoReconnecting = false
                        self.telemetry.nextRetrySeconds = nil
                        self.telemetry.statusBanner = "Connected over Bluetooth. Configure Wi-Fi for live video and control."
                        self.onStateUpdated?()
                    }
                }
                return
            }

            guard self.bleManager.bluetoothState == .poweredOn else { return }

            let wasAlreadyScanning = self.bleManager.isScanning
            if !wasAlreadyScanning {
                self.bleManager.startScan()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !wasAlreadyScanning {
                self.bleManager.stopScan()
            }

            guard self.connectGeneration == generation,
                  !self.userDisconnected,
                  !self.phase.isConnected else {
                return
            }

            let pid = self.peripheralId ?? duck.peripheralId ?? self.matchingDiscoveredPeripheralId()
            if let pid,
               let discovered = self.bleManager.discoveredDucks.first(where: { $0.id == pid }),
               let advIp = discovered.advInfo.ipv4,
               !advIp.isEmpty,
               advIp != self.currentIpAddress {
                self.webRTC.stop()
                do {
                    try await self.promoteToLan(
                        ipAddress: advIp,
                        robotId: duck.robotId,
                        pskHex: pskHex,
                        requireExtendedLocalNetworkWait: false,
                        generation: generation
                    )
                } catch {
                    self.handleBleFallbackFailure(error, generation: generation)
                }
                return
            }

            // If peripheral is connectable nearby, query net.status over BLE in case DHCP changed without adv update.
            if let pid,
               let discovered = self.bleManager.discoveredDucks.first(where: { $0.id == pid }),
               discovered.isConnectable {
                self.webRTC.stop()
                do {
                    try await self.connectViaBleInternal(
                        peripheralId: pid,
                        robotId: duck.robotId,
                        pskHex: pskHex,
                        fallbackName: duck.name,
                        generation: generation
                    )
                } catch {
                    self.handleBleFallbackFailure(error, generation: generation)
                }
            }
        }
    }

    private func handleBleFallbackFailure(_ error: Error, generation: UInt64) {
        guard connectGeneration == generation, !userDisconnected, phase != .configuringWifi else {
            return
        }
        let message = error.localizedDescription
        phase = .error(message)
        telemetry.lastError = message
        onStateUpdated?()
        startReconnectSupervisor(generation: generation)
    }

    private func startNetworkPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(satisfied: satisfied)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: pathMonitorQueue)
    }

    private func handleNetworkPathUpdate(satisfied: Bool) {
        let becameSatisfied = !lastNetworkSatisfied && satisfied
        lastNetworkSatisfied = satisfied
        guard becameSatisfied else { return }

        guard !userDisconnected,
              !phase.isConnected,
              phase != .configuringWifi,
              resolvedTargetDuck() != nil,
              pskHex != nil else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.nudgeReconnectOnForeground()
        }
    }

    private func wireBleCallbacks() {
        bleManager.onUnexpectedDisconnect = { [weak self] _, detail in
            guard let self,
                  !self.userDisconnected,
                  self.phase == .configuringWifi else {
                return
            }
            let generation = self.connectGeneration
            self.phase = .error(detail)
            self.telemetry.lastError = detail
            self.telemetry.statusBanner = nil
            self.onStateUpdated?()
            self.startReconnectSupervisor(generation: generation)
        }
    }

    private func cancelBackgroundReconnectTasks() {
        reconnectSupervisorTask?.cancel()
        reconnectSupervisorTask = nil
        sleepWaitTask?.cancel()
        sleepWaitTask = nil
        sleepWaitToken = nil
        retryCountdownTask?.cancel()
        retryCountdownTask = nil
        bleIpRefreshTask?.cancel()
        bleIpRefreshTask = nil
        didNudgeWakeSleep = false
    }

    private func stopLocalMotionAndStreamLoops() {
        moveVector = (0, 0, 0)
        isSendingMove = false
        moveTimerTask?.cancel()
        moveTimerTask = nil
        stopLook()
        streamInitTask?.cancel()
        streamInitTask = nil
        healthPollTask?.cancel()
        healthPollTask = nil
        freshnessWatchdogTask?.cancel()
        freshnessWatchdogTask = nil
        headImuSubscribedOnSession = false
        hasStartedStreamsForCurrentChannel = false
        lastObservedPolicy = nil
    }

    private func resolvedTargetDuck() -> PairedDuck? {
        if let targetDuck {
            return targetDuck
        }
        guard let robotId = currentRobotId else { return nil }
        return vault.pairedDuck(for: robotId) ?? PairedDuck(
            robotId: robotId,
            name: currentDuckName,
            lastIp: currentIpAddress,
            peripheralId: peripheralId
        )
    }

    private func matchingDiscoveredPeripheralId() -> UUID? {
        if let pid = peripheralId,
           bleManager.discoveredDucks.contains(where: { $0.id == pid && $0.isConnectable }) {
            return pid
        }
        if let ip = currentIpAddress,
           let matchedByIp = bleManager.discoveredDucks.first(where: { $0.isConnectable && $0.advInfo.ipv4 == ip }) {
            return matchedByIp.id
        }
        return bleManager.discoveredDucks.first(where: { $0.isConnectable })?.id
    }

    private func isLikelyLocalNetworkError(_ error: Error) -> Bool {
        if isExplicitLocalNetworkPermissionError(error) {
            return true
        }
        let msg = error.localizedDescription.lowercased()
        return msg.contains("os error 65")
            || msg.contains("no route to host")
            || msg.contains("network is unreachable")
            || msg.contains("timed out connecting")
            || msg.contains("host is down")
    }

    private func isExplicitLocalNetworkPermissionError(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("eperm")
            || msg.contains("os error 1")
            || msg.contains("operation not permitted")
    }

    private static var hasConfirmedLocalNetwork: Bool {
        UserDefaults.standard.bool(forKey: localNetworkConfirmedKey)
    }

    private static func markLocalNetworkConfirmed() {
        UserDefaults.standard.set(true, forKey: localNetworkConfirmedKey)
    }

    // MARK: - Internal loops & WebRTC wiring

    private func wireWebRTCCallbacks() {
        webRTC.onVideoTrackChanged = { [weak self] track in
            guard let self else { return }
            self.videoSource = track.map { .webrtc(track: $0) } ?? .none
        }

        webRTC.onFirstFrameTimeoutChanged = { [weak self] timedOut in
            guard let self else { return }
            self.telemetry.isVideoFirstFrameTimedOut = timedOut
            self.onStateUpdated?()
        }

        webRTC.onControlChannelOpen = { [weak self] in
            guard let self, !self.hasStartedStreamsForCurrentChannel else { return }
            let generation = self.connectGeneration
            self.hasStartedStreamsForCurrentChannel = true
            self.headImuSubscribedOnSession = false
            self.lastObservedPolicy = nil
            self.consecutiveLanFailures = 0

            self.retryCountdownTask?.cancel()
            self.retryCountdownTask = nil
            self.reconnectSupervisorTask?.cancel()
            self.reconnectSupervisorTask = nil

            self.telemetry.health = nil
            self.telemetry.policies = nil
            self.telemetry.subscribeAck = nil
            self.telemetry.robotState = nil
            self.telemetry.lastError = nil
            self.telemetry.statusBanner = nil
            self.telemetry.reconnectAttempt = 0
            self.telemetry.nextRetrySeconds = nil
            self.telemetry.isAutoReconnecting = false
            self.telemetry.isRobotStateStale = false
            self.telemetry.isHealthStale = false
            self.telemetry.lastRobotStateUptime = nil
            self.telemetry.lastHealthUptime = nil
            self.telemetry.isVideoFirstFrameTimedOut = false
            self.telemetry.shutdownOutcome = .none

            self.phase = .connected(transportLabel: "LAN")
            self.onStateUpdated?()
            self.startSessionStreams()

            // Release BLE cleanly once LAN video + control channel are open so the robot stops advertising Busy.
            Task { @MainActor [weak self] in
                guard let self, self.connectGeneration == generation else { return }
                if self.bleManager.connectedPeripheralId != nil || self.bleManager.isAuthenticated {
                    await self.bleManager.disconnect()
                }
            }
        }

        webRTC.onControlChannelClosed = { [weak self] in
            guard let self else { return }
            if self.shutdownPhase == .acceptedAwaitingDisconnect {
                self.finalizeConfirmedShutdown()
                return
            }
            if self.shutdownPhase == .pendingAck {
                self.finalizeUnconfirmedShutdown()
                return
            }
            self.hasStartedStreamsForCurrentChannel = false
            self.stopLocalMotionAndStreamLoops()
            self.telemetry.policies = nil
            self.telemetry.subscribeAck = nil
            self.telemetry.robotState = nil
            self.telemetry.isRobotStateStale = false
            self.telemetry.isHealthStale = false
            self.telemetry.lastRobotStateUptime = nil
            self.telemetry.lastHealthUptime = nil
            if self.phase.isConnected {
                self.phase = .connectingVideo
            }
            self.onStateUpdated?()
        }

        webRTC.onVideoStats = { [weak self] fps in
            self?.telemetry.videoFps = fps
        }

        webRTC.onReconnecting = { [weak self] attempt, delaySeconds, reason in
            guard let self, !self.userDisconnected, self.shutdownPhase == .idle else { return }
            let generation = self.connectGeneration
            self.hasStartedStreamsForCurrentChannel = false
            self.consecutiveLanFailures += 1
            self.telemetry.reconnectAttempt = attempt
            self.telemetry.nextRetrySeconds = delaySeconds
            self.telemetry.isAutoReconnecting = true
            self.telemetry.lastError = reason
            self.telemetry.statusBanner = "Reconnecting (\(attempt)) in \(delaySeconds)s..."
            self.phase = .connectingVideo
            self.onStateUpdated?()

            self.startWebRtcRetryCountdown(seconds: delaySeconds, generation: generation)

            if self.consecutiveLanFailures >= 3 && self.consecutiveLanFailures % 3 == 0 {
                self.triggerBleIpRefreshFallback(generation: generation)
            }
        }

        webRTC.onError = { [weak self] message in
            self?.telemetry.lastError = message
        }

        webRTC.onNotification = { [weak self] method, params in
            self?.handleControlNotification(method: method, params: params)
        }
    }

    private func startShutdownFinalizeFallback(generation: UInt64) {
        shutdownFinalizeTask?.cancel()
        shutdownFinalizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.connectGeneration == generation,
                  self.shutdownPhase == .acceptedAwaitingDisconnect else {
                return
            }
            // Do not mark confirmed power-off while the connection is still open.
            self.telemetry.statusBanner = "Shutdown requested, but robot is still responding."
            self.onStateUpdated?()
        }
    }

    private func finalizeConfirmedShutdown() {
        shutdownFinalizeTask?.cancel()
        shutdownFinalizeTask = nil
        shutdownPhase = .idle
        userDisconnected = true
        connectGeneration &+= 1
        cancelBackgroundReconnectTasks()
        stopLocalMotionAndStreamLoops()
        webRTC.stop()
        lanRpcClient = nil

        var poweredOffSnapshot = TelemetrySnapshot()
        poweredOffSnapshot.isPoweredOff = true
        poweredOffSnapshot.shutdownOutcome = .confirmedPoweredOff
        telemetry = poweredOffSnapshot
        videoSource = .none
        phase = .disconnected
        onStateUpdated?()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.bleManager.connectedPeripheralId != nil || self.bleManager.isAuthenticated {
                await self.bleManager.disconnect()
            }
        }
    }

    private func finalizeUnconfirmedShutdown() {
        shutdownFinalizeTask?.cancel()
        shutdownFinalizeTask = nil
        shutdownPhase = .idle
        userDisconnected = true
        connectGeneration &+= 1
        cancelBackgroundReconnectTasks()
        stopLocalMotionAndStreamLoops()
        webRTC.stop()
        lanRpcClient = nil

        var lostSnapshot = TelemetrySnapshot()
        lostSnapshot.isPoweredOff = false
        lostSnapshot.shutdownOutcome = .unconfirmedLostConnection
        lostSnapshot.statusBanner = "Connection lost · shutdown unconfirmed"
        telemetry = lostSnapshot
        videoSource = .none
        phase = .disconnected
        onStateUpdated?()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.bleManager.connectedPeripheralId != nil || self.bleManager.isAuthenticated {
                await self.bleManager.disconnect()
            }
        }
    }

    private func startSessionStreams() {
        streamInitTask?.cancel()
        streamInitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let hz = self.sensorsVisible ? 10 : 2
            async let healthCall: Void = self.pollHealthOnce()
            async let policiesCall: Void = self.refreshPolicies()
            async let subscribeCall: Void = self.subscribeRobotState(hz: hz)
            async let videoCall: Void = self.fetchMediaVideo()
            async let sysCall: Void = self.fetchSystemInfo()
            async let modelCall: Void = self.fetchRobotModel()
            async let tofCall: Void = self.startTofStream()
            async let headImuCall: Void = self.startHeadImuIfNeeded()

            _ = await (
                healthCall,
                policiesCall,
                subscribeCall,
                videoCall,
                sysCall,
                modelCall,
                tofCall,
                headImuCall
            )
            guard !Task.isCancelled, self.webRTC.isControlOpen else { return }
            self.startHealthLoop()
            self.startFreshnessWatchdog()
        }
    }

    private func subscribeRobotState(hz: Int) async {
        guard webRTC.isControlOpen else { return }
        if let data = try? await webRTC.call(method: "robot.subscribe", params: ["hz": hz]),
           let ack = try? JSONDecoder().decode(SubscribeResult.self, from: data) {
            telemetry.subscribeAck = ack
            onStateUpdated?()
        }
    }

    private func fetchMediaVideo() async {
        if let videoData = try? await webRTC.call(method: "media.video"),
           let videoInfo = try? JSONDecoder().decode(MediaVideoInfo.self, from: videoData) {
            telemetry.mediaVideo = videoInfo
        }
    }

    private func fetchSystemInfo() async {
        if let sysData = try? await webRTC.call(method: "system.info"),
           let sysInfo = try? JSONDecoder().decode(SystemInfoResult.self, from: sysData) {
            telemetry.systemInfo = sysInfo
            currentDuckName = sysInfo.name
        }
    }

    private func fetchRobotModel() async {
        if let modelData = try? await webRTC.call(method: "robot.model"),
           let model = try? JSONDecoder().decode(ModelResult.self, from: modelData) {
            telemetry.model = model
        }
    }

    private func startTofStream() async {
        _ = try? await webRTC.call(method: "tof.stream")
    }

    private func startHeadImuIfNeeded() async {
        guard sensorsVisible else { return }
        headImuSubscribedOnSession = true
        _ = try? await webRTC.call(method: "head_imu.stream")
    }

    private func startHealthLoop() {
        healthPollTask?.cancel()
        healthPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { break }
                async let healthTask: Void = self.pollHealthOnce()
                async let policiesTask: Void = self.refreshPolicies()
                _ = await (healthTask, policiesTask)
            }
        }
    }

    private func pollHealthOnce() async {
        guard webRTC.isControlOpen else { return }
        if let data = try? await webRTC.call(method: "robot.health", timeoutSeconds: 5),
           let health = try? JSONDecoder().decode(HealthResult.self, from: data) {
            telemetry.health = health
            telemetry.lastHealthUptime = ProcessInfo.processInfo.systemUptime
            telemetry.isHealthStale = false
            onStateUpdated?()
        }
    }

    private func startFreshnessWatchdog() {
        freshnessWatchdogTask?.cancel()
        let generation = connectGeneration
        freshnessWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self,
                      !Task.isCancelled,
                      self.connectGeneration == generation,
                      self.webRTC.isControlOpen else {
                    break
                }
                let nowUptime = ProcessInfo.processInfo.systemUptime
                var changed = false

                if let lastState = self.telemetry.lastRobotStateUptime,
                   nowUptime - lastState > 2.5,
                   !self.telemetry.isRobotStateStale {
                    self.telemetry.isRobotStateStale = true
                    self.moveVector = (0, 0, 0)
                    self.isSendingMove = false
                    self.moveTimerTask?.cancel()
                    self.moveTimerTask = nil
                    self.stopLook()
                    changed = true
                }

                if let lastHealth = self.telemetry.lastHealthUptime,
                   nowUptime - lastHealth > 7.0,
                   !self.telemetry.isHealthStale {
                    self.telemetry.isHealthStale = true
                    changed = true
                }

                if changed {
                    self.onStateUpdated?()
                }
            }
        }
    }

    private func handleControlNotification(method: String, params: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: params, options: []) else {
            return
        }
        switch method {
        case "robot.state":
            if let state = try? JSONDecoder().decode(RobotState.self, from: data) {
                let previousPolicy = lastObservedPolicy
                lastObservedPolicy = state.policy
                telemetry.lastRobotStateUptime = ProcessInfo.processInfo.systemUptime
                telemetry.isRobotStateStale = false
                telemetry.robotState = state
                onStateUpdated?()
                if previousPolicy != state.policy {
                    Task { @MainActor [weak self] in
                        await self?.refreshPolicies()
                    }
                }
            }
        case "media.video":
            if let info = try? JSONDecoder().decode(MediaVideoInfo.self, from: data) {
                telemetry.mediaVideo = info
            }
        case "tof.frame":
            if let frame = try? JSONDecoder().decode(TofFrame.self, from: data) {
                telemetry.tofFrame = frame
                recordTofSampleRate()
            }
        case "head_imu.frame":
            if let frame = try? JSONDecoder().decode(HeadImuFrame.self, from: data) {
                telemetry.headImu = frame
            }
        default:
            break
        }
    }

    private func recordTofSampleRate() {
        let now = Date()
        tofTimestampWindow.append(now)
        tofTimestampWindow.removeAll { now.timeIntervalSince($0) > 2.0 }
        if tofTimestampWindow.count >= 2,
           let first = tofTimestampWindow.first,
           let last = tofTimestampWindow.last {
            let span = last.timeIntervalSince(first)
            if span > 0.05 {
                telemetry.tofHz = Double(tofTimestampWindow.count - 1) / span
            }
        }
    }

    private func startMoveLoop() {
        moveTimerTask?.cancel()
        moveTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled, self.isSendingMove else { break }
                self.sendCurrentMove()
            }
        }
    }

    private func sendCurrentMove() {
        webRTC.tell(method: "robot.move", params: [
            "vx": moveVector.vx,
            "vy": moveVector.vy,
            "vyaw": moveVector.vyaw
        ])
    }

    private func startLookLoop() {
        lookSenderTask?.cancel()
        lookSenderTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !Task.isCancelled, let target = self.lookTarget else { break }
                let callGen = self.lookGestureGeneration
                if self.webRTC.isControlOpen {
                    let params: [String: Any] = [
                        "x": Self.lookCenterPoint.x,
                        "y": target.y,
                        "z": target.z,
                        "neck_pitch": 0.0
                    ]
                    if let data = try? await self.webRTC.call(method: "robot.look", params: params),
                       let result = try? JSONDecoder().decode(LookResult.self, from: data),
                       self.lookGestureGeneration == callGen,
                       self.lookTarget != nil {
                        self.telemetry.lookClamped = result.clamped
                    }
                }
                guard !Task.isCancelled, self.lookTarget != nil else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.lookSenderTask = nil
        }
    }

    // MARK: - Provisioning RPC routing (BLE preferred for net.connect/net.forget, reconnectable LAN :9444 fallback)

    private func callProvisioningRpc(
        method: String,
        params: [String: Any] = [:],
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        if bleManager.isAuthenticated {
            return try await bleManager.call(method: method, params: params, timeoutSeconds: timeoutSeconds)
        }
        if let ip = currentIpAddress, let robotId = currentRobotId, let pskHex {
            let client = try await ensureLanRpcClient(host: ip, robotId: robotId, pskHex: pskHex)
            do {
                return try await callLanRpc(
                    client: client,
                    method: method,
                    params: params,
                    timeoutMs: UInt64(timeoutSeconds * 1000)
                )
            } catch {
                // Retire the :9444 lane on any transport/timeout/correlation failure.
                if !isLanRpcRemoteError(error) && self.lanRpcClient === client {
                    self.lanRpcClient = nil
                }

                // Only safe idempotent reads may auto-retry on a fresh :9444 connection.
                if isLanRpcSocketClosedError(error), isIdempotentProvisioningRead(method) {
                    let refreshed = try await ensureLanRpcClient(host: ip, robotId: robotId, pskHex: pskHex)
                    return try await callLanRpc(
                        client: refreshed,
                        method: method,
                        params: params,
                        timeoutMs: UInt64(timeoutSeconds * 1000)
                    )
                }

                // For Wi-Fi mutations that errored ambiguously, reconcile via net.status first.
                if method == "net.connect" || method == "net.forget" {
                    await refreshNetStatus()
                }
                throw error
            }
        }
        if webRTC.isControlOpen && (method == "net.status" || method == "net.scan") {
            let data = try await webRTC.call(method: method, params: params, timeoutSeconds: timeoutSeconds)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        throw BleManagerError.disconnected("Connect via Bluetooth to configure robot Wi-Fi.")
    }

    private func ensureLanRpcClient(host: String, robotId: String, pskHex: String) async throws -> LanRpcClient {
        if let existing = lanRpcClient {
            return existing
        }
        while isConnectingLanRpcClient {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let existing = lanRpcClient {
                return existing
            }
        }
        isConnectingLanRpcClient = true
        defer { isConnectingLanRpcClient = false }

        let fresh = try await Task.detached(priority: .userInitiated) {
            try LanRpcClient(host: host, port: 9444, robotId: robotId, pskHex: pskHex, timeoutMs: 4000)
        }.value
        self.lanRpcClient = fresh
        return fresh
    }

    private func isIdempotentProvisioningRead(_ method: String) -> Bool {
        switch method {
        case "net.status", "net.scan", "system.info", "robot.health":
            return true
        default:
            return false
        }
    }

    private func isLanRpcRemoteError(_ error: Error) -> Bool {
        if case BleManagerError.rpcError = error {
            return true
        }
        return false
    }

    private func isLanRpcSocketClosedError(_ error: Error) -> Bool {
        if isLanRpcRemoteError(error) {
            return false
        }
        let msg = error.localizedDescription.lowercased()
        return msg.contains("closed by robot")
            || msg.contains("write failed")
            || msg.contains("read failed")
            || msg.contains("broken pipe")
            || msg.contains("connection reset")
            || msg.contains("retired")
            || msg.contains("null handle")
    }

    private func callLanRpc(
        client: LanRpcClient,
        method: String,
        params: [String: Any] = [:],
        timeoutMs: UInt64
    ) async throws -> String {
        let id = nextLanRpcId
        nextLanRpcId += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let reqData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let reqText = String(data: reqData, encoding: .utf8) else {
            throw BleManagerError.disconnected("Failed to encode LAN RPC request.")
        }

        let responseLine = try await Task.detached(priority: .userInitiated) {
            try client.call(requestJSON: reqText, timeoutMs: timeoutMs)
        }.value

        guard let respData = responseLine.data(using: .utf8),
              let respObj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw QuackCoreError.invalidResponse("Malformed JSON-RPC reply on LAN lane.")
        }
        guard let respId = respObj["id"] as? Int, respId == id else {
            if self.lanRpcClient === client {
                self.lanRpcClient = nil
            }
            throw QuackCoreError.invalidResponse("Mismatched JSON-RPC reply ID on LAN lane.")
        }
        if let errObj = respObj["error"] as? [String: Any] {
            let code = errObj["code"] as? Int
            let message = (errObj["message"] as? String) ?? "LAN RPC error"
            throw BleManagerError.rpcError(code: code, message: message)
        }
        if let result = respObj["result"],
           let resultData = try? JSONSerialization.data(withJSONObject: result, options: []),
           let resultString = String(data: resultData, encoding: .utf8) {
            return resultString
        }
        return "{}"
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        guard let data = jsonString.data(using: .utf8) else {
            throw QuackCoreError.invalidResponse("Non-UTF8 JSON payload")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
