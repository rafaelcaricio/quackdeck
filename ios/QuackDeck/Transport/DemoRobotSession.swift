import Foundation
import Observation

@MainActor
@Observable
final class DemoRobotSession: RobotSessionTransport {
    private enum DemoSimMode: Equatable {
        case limp
        case homing(startedAt: Date, targetSeated: Bool)
        case held(sitting: Bool)
        case walking
        case kicking(side: KickSide, startedAt: Date)
        case sitting(startedAt: Date)
        case rising(startedAt: Date)
        case autoRisingFromSeat(startedAt: Date)
        case resting(startedAt: Date, torqueCut: Bool)
        case shuttingDown(startedAt: Date, torqueCut: Bool)
        case shuttingDownImmediate(startedAt: Date)
        case limpFall(startedAt: Date, attempt: Int)
        case limpPose(startedAt: Date, attempt: Int)
        case fallRetry(startedAt: Date, attempt: Int)
    }

    private struct ActiveDemoEmotion: Equatable {
        let name: String
        let startedAt: Date
        let duration: TimeInterval
    }

    private struct EmotionOffsets {
        let bodyPitchRad: Double
        let bodyRollRad: Double
        let neckPitch: Double
        let headPitch: Double
        let headYaw: Double
        let headRoll: Double
        let mouthAngle: Double
    }

    private struct WirePhaseKey: Equatable {
        let policy: String
        let homed: Bool
        let sitting: Bool
        let limp: Bool
        let fallen: Bool
        let pickedUp: Bool
        let activeEmotionName: String?
    }

    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var telemetry = TelemetrySnapshot()
    private(set) var videoSource: VideoFrameSource = .demo
    let isDemoMode: Bool = true
    private(set) var currentDuckName: String = "Microduck (Demo)"
    private(set) var currentRobotId: String? = "demo-duck"
    private(set) var currentIpAddress: String? = "192.0.2.10"

    @ObservationIgnored var onStateUpdated: (@MainActor () -> Void)?

    // Exposes live virtual camera/head orientation for DemoVideoView
    private(set) var virtualPitchDeg: Double = 0
    private(set) var virtualRollDeg: Double = 0
    private(set) var virtualYawDeg: Double = 0
    private(set) var virtualGazeNormalized: (x: Double, y: Double) = (0, 0)
    private(set) var lastQuackAt: Date?
    private(set) var activeDemoEmotionName: String?
    private(set) var activeDemoKickSide: KickSide?
    private(set) var lastDroppedEmotionName: String?

    private let startWalkingOnConnect: Bool
    private var simMode: DemoSimMode = .limp
    private var simHardBlocked: Bool = false
    private var simBlockReason: String?
    private var simImuReady: Bool = true
    private var simImuFrozen: Bool = false
    private var simFallen: Bool = false
    private var simPickedUp: Bool = false
    private var simHasSitstand: Bool = true
    private var simHasWalkPolicy: Bool = true
    private var simKickSides: Set<KickSide> = [.left, .right]
    private var simEmotions: [String] = MicroduckEmotions.defaultShippedNames
    private var activeEmotion: ActiveDemoEmotion?
    private var pendingEnableWhenImuReady: Bool = false

    private var sensorsVisible: Bool = false
    private var simTask: Task<Void, Never>?
    private var tickCount: UInt64 = 0
    private var startTime: Date = Date()
    private var lastWirePhaseKey: WirePhaseKey?

    private var commandMove: (vx: Double, vy: Double, vyaw: Double) = (0, 0, 0)
    private var commandLook: (y: Double, z: Double) = (0, LiveRobotSession.lookCenterPoint.z)
    private var odomPosition: [Double] = [0, 0, 0.24]
    private var odomYaw: Double = 0
    private var batteryVolts: Double = 11.92
    private var batteryPercent: Double = 78.0
    private var motorMaxTempC: Double = 44.2
    private var simWifiSsid: String? = "HomeWiFi"
    private var simJoining: Joining?
    private var simVolume: UInt8 = 75
    private var simVolumeApplies: Bool = true
    private var simVolumeSupported: Bool = true

    init(startWalking: Bool = false) {
        self.startWalkingOnConnect = startWalking
    }

    func connect() {
        startTime = Date()
        tickCount = 0
        simHardBlocked = false
        simBlockReason = nil
        simImuReady = true
        simImuFrozen = false
        simFallen = false
        simPickedUp = false
        simHasSitstand = true
        simHasWalkPolicy = true
        simKickSides = [.left, .right]
        simEmotions = MicroduckEmotions.defaultShippedNames
        clearActiveEmotionState(clearDropped: true)
        activeDemoKickSide = nil
        pendingEnableWhenImuReady = false
        commandMove = (0, 0, 0)
        commandLook = (0, LiveRobotSession.lookCenterPoint.z)
        virtualGazeNormalized = (0, 0)
        simMode = startWalkingOnConnect ? .walking : .limp

        videoSource = .demo
        phase = .connected(transportLabel: "Demo")
        telemetry.lastError = nil
        telemetry.statusBanner = nil
        telemetry.reconnectAttempt = 0
        telemetry.nextRetrySeconds = nil
        telemetry.isAutoReconnecting = false
        telemetry.isPoweredOff = false
        telemetry.volumeStatus = simVolumeSupported
            ? .loaded(VolumeResult(volume: simVolume, applies: simVolumeApplies))
            : .unsupported

        telemetry.systemInfo = SystemInfoResult(
            name: "Microduck (Demo)",
            serial: "demo-duck-01",
            uptime_seconds: 142,
            simulated: true
        )
        telemetry.model = ModelResult(
            asset: "microduck_demo",
            trunk_height_m: 0.24,
            joint_names: MicroduckJoints.defaultNames,
            head_joints: ["neck_pitch", "head_pitch", "head_yaw", "head_roll"],
            tof_beams: [],
            tof_fov_deg: 45.0
        )
        telemetry.mediaVideo = MediaVideoInfo(width: 1280, height: 720, rotate: 0)
        telemetry.videoFps = 30.0
        telemetry.tofHz = 15.0
        telemetry.netStatus = NetStatusResult(
            state: .connected,
            ssid: simWifiSsid,
            signal: 84,
            ip4: "192.0.2.10",
            ip6: nil,
            mac: "02:00:00:00:00:01",
            iface: "wlan0",
            joining: nil
        )

        publishPolicyAndSubscribeMetadata()
        publishHealthSnapshot(elapsed: 0)
        stepSimulation(dt: 0.05, forcePublishState: true)
        lastWirePhaseKey = currentWirePhaseKey(now: Date())
        onStateUpdated?()
        startSimulationLoop()
    }

    func setSensorsVisible(_ visible: Bool) {
        sensorsVisible = visible
        telemetry.tofHz = visible ? 15.0 : 10.0
    }

    func setMove(vx: Double, vy: Double, vyaw: Double) {
        let clampedVx = max(-LiveRobotSession.maxLinearSpeed, min(LiveRobotSession.maxLinearSpeed, vx))
        let clampedVy = max(-LiveRobotSession.maxLinearSpeed, min(LiveRobotSession.maxLinearSpeed, vy))
        let clampedVyaw = max(-LiveRobotSession.maxAngularSpeed, min(LiveRobotSession.maxAngularSpeed, vyaw))
        commandMove = (clampedVx, clampedVy, clampedVyaw)
    }

    func setLook(y: Double, z: Double) {
        let rawY = max(-LiveRobotSession.lookRange.y, min(LiveRobotSession.lookRange.y, y))
        let minZ = LiveRobotSession.lookRange.z - LiveRobotSession.lookRange.dz
        let maxZ = LiveRobotSession.lookRange.z + LiveRobotSession.lookRange.dz
        let rawZ = max(minZ, min(maxZ, z))

        commandLook = (rawY, rawZ)
        telemetry.lookClamped = abs(y) > 0.65 || z > (maxZ - 0.03) || z < (minZ + 0.03)
        virtualGazeNormalized = (
            x: max(-1, min(1, -rawY / LiveRobotSession.lookRange.y)),
            y: max(-1, min(1, -(rawZ - LiveRobotSession.lookRange.z) / LiveRobotSession.lookRange.dz))
        )
    }

    func stopLook() {
        // Head stays where aimed until Look Center is pressed.
    }

    func lookCenter() {
        commandLook = (0, LiveRobotSession.lookCenterPoint.z)
        telemetry.lookClamped = false
        virtualGazeNormalized = (0, 0)
    }

    func sendInit() async -> IntentResult {
        guard !simHardBlocked else {
            return IntentResult(accepted: false, reason: simBlockReason ?? "Hardware fault prevents torque on.")
        }
        switch simMode {
        case .held(sitting: true), .sitting:
            // Intentional no-op on seated robot to prevent backward tip-over.
            await refreshPolicies()
            return IntentResult(accepted: true, reason: "Already seated.")
        case .homing:
            return IntentResult(accepted: true)
        case .shuttingDown, .shuttingDownImmediate:
            return IntentResult(accepted: false, reason: "Robot is shutting down.")
        default:
            pendingEnableWhenImuReady = false
            simMode = .homing(startedAt: Date(), targetSeated: false)
            publishImmediateWireSnapshot()
            return IntentResult(accepted: true)
        }
    }

    func setPolicyEnabled(_ on: Bool) async -> IntentResult {
        if on {
            guard !simHardBlocked else {
                return IntentResult(accepted: false, reason: simBlockReason ?? "Hardware fault prevents policy start.")
            }
            guard simHasWalkPolicy else {
                return IntentResult(accepted: false, reason: "No walk policy loaded.")
            }
            switch simMode {
            case .limp:
                // Match conservative `policy_on_arrival = false` bring-up behavior.
                simMode = .homing(startedAt: Date(), targetSeated: false)
            case .homing:
                return IntentResult(accepted: false, reason: "Robot is still homing.")
            case .held(let sitting):
                if !simImuReady {
                    pendingEnableWhenImuReady = true
                } else if sitting && simHasSitstand {
                    simMode = .autoRisingFromSeat(startedAt: Date())
                } else {
                    simMode = .walking
                }
            case .walking, .kicking, .sitting, .rising, .autoRisingFromSeat, .limpFall, .limpPose, .fallRetry:
                break
            case .resting:
                return IntentResult(accepted: false, reason: "Robot is resting.")
            case .shuttingDown, .shuttingDownImmediate:
                return IntentResult(accepted: false, reason: "Robot is shutting down.")
            }
            publishImmediateWireSnapshot()
            return IntentResult(accepted: true, reason: "enabled — driving")
        } else {
            pendingEnableWhenImuReady = false
            simPickedUp = false
            commandMove = (0, 0, 0)
            clearActiveEmotionState(clearDropped: true)
            activeDemoKickSide = nil
            let now = Date()
            switch simMode {
            case .limp, .homing, .resting, .shuttingDown, .shuttingDownImmediate:
                break
            case .sitting:
                simMode = .held(sitting: true)
            case .autoRisingFromSeat(let startedAt):
                simMode = .held(sitting: now.timeIntervalSince(startedAt) < 2.0)
            case .held(let sitting):
                simMode = .held(sitting: sitting)
            case .walking, .kicking, .rising, .limpFall, .limpPose, .fallRetry:
                simMode = .held(sitting: false)
            }
            publishImmediateWireSnapshot()
            return IntentResult(accepted: true, reason: "disabled — returning to the home pose")
        }
    }

    func sendSitToggle() async -> IntentResult {
        guard simHasSitstand else {
            return IntentResult(accepted: false, reason: "No sitstand policy configured.")
        }
        switch simMode {
        case .walking:
            commandMove = (0, 0, 0)
            simMode = .sitting(startedAt: Date())
            publishImmediateWireSnapshot()
            return IntentResult(accepted: true)
        case .sitting(let startedAt):
            if Date().timeIntervalSince(startedAt) >= 2.2 {
                simMode = .rising(startedAt: Date())
                publishImmediateWireSnapshot()
            }
            return IntentResult(accepted: true)
        case .rising, .autoRisingFromSeat:
            return IntentResult(accepted: true)
        case .kicking:
            return IntentResult(accepted: false, reason: "robot is busy kicking")
        default:
            return IntentResult(accepted: false, reason: "the policy is not driving")
        }
    }

    func triggerKick(_ side: KickSide) async -> IntentResult {
        guard phase.isConnected else {
            return IntentResult(accepted: false, reason: "Connect to the robot first.")
        }
        guard simKickSides.contains(side) else {
            return IntentResult(accepted: false, reason: "no skill named \"\(side.skillName)\"")
        }
        guard simMode == .walking, !simFallen, !simPickedUp else {
            return IntentResult(accepted: false, reason: "the policy is not driving")
        }
        guard activeEmotion == nil else {
            return IntentResult(accepted: false, reason: "another skill is already playing")
        }
        commandMove = (0, 0, 0)
        activeDemoKickSide = side
        simMode = .kicking(side: side, startedAt: Date())
        publishImmediateWireSnapshot()
        return IntentResult(accepted: true)
    }

    func triggerEmotion(_ name: String) async -> IntentResult {
        guard phase.isConnected else {
            return IntentResult(accepted: false, reason: "Connect to the robot first.")
        }
        guard simEmotions.contains(name) else {
            return IntentResult(accepted: false, reason: "no skill named \"\(name)\"")
        }
        let isDrivingWalkingOrSitting: Bool
        switch simMode {
        case .walking, .sitting:
            isDrivingWalkingOrSitting = true
        default:
            isDrivingWalkingOrSitting = false
        }
        guard isDrivingWalkingOrSitting else {
            return IntentResult(accepted: false, reason: "the policy is not driving")
        }
        if activeEmotion != nil || simFallen || simPickedUp {
            if activeEmotion != nil {
                lastDroppedEmotionName = name
            }
            return IntentResult(accepted: true)
        }

        let now = Date()
        let duration = MicroduckEmotions.knownDurationSeconds(for: name) ?? 2.5
        activeEmotion = ActiveDemoEmotion(name: name, startedAt: now, duration: duration)
        activeDemoEmotionName = name
        commandMove = (0, 0, 0)
        if MicroduckEmotions.maySitRobot(name) && simMode == .walking && simHasSitstand {
            simMode = .sitting(startedAt: now)
        }
        publishImmediateWireSnapshot()
        return IntentResult(accepted: true)
    }

    func sendRelax() async -> IntentResult {
        pendingEnableWhenImuReady = false
        simPickedUp = false
        commandMove = (0, 0, 0)
        clearActiveEmotionState(clearDropped: true)
        activeDemoKickSide = nil
        if case .resting(let startedAt, _) = simMode {
            simMode = .resting(startedAt: startedAt, torqueCut: true)
        } else if case .shuttingDown(let startedAt, _) = simMode {
            simMode = .shuttingDown(startedAt: startedAt, torqueCut: true)
        } else if case .shuttingDownImmediate = simMode {
            // Already torque off and powering down.
        } else {
            simMode = .limp
        }
        publishImmediateWireSnapshot()
        return IntentResult(accepted: true)
    }

    func sendRest() async -> IntentResult {
        pendingEnableWhenImuReady = false
        simPickedUp = false
        commandMove = (0, 0, 0)
        clearActiveEmotionState(clearDropped: true)
        activeDemoKickSide = nil
        if case .shuttingDown = simMode {
            return IntentResult(accepted: true)
        }
        if case .shuttingDownImmediate = simMode {
            return IntentResult(accepted: true)
        }
        let isDrivingState: Bool = {
            switch simMode {
            case .walking, .kicking, .sitting, .rising, .autoRisingFromSeat:
                return true
            default:
                return false
            }
        }()
        if isDrivingState && !simFallen && simHasSitstand {
            simMode = .resting(startedAt: Date(), torqueCut: false)
        } else {
            simMode = .limp
        }
        publishImmediateWireSnapshot()
        return IntentResult(accepted: true)
    }

    func sendShutdown() async -> IntentResult {
        guard phase.isConnected else {
            return IntentResult(accepted: false, reason: "Connect to the robot first.")
        }
        pendingEnableWhenImuReady = false
        simPickedUp = false
        commandMove = (0, 0, 0)
        clearActiveEmotionState(clearDropped: true)

        if case .resting(let startedAt, let torqueCut) = simMode {
            simMode = .shuttingDown(startedAt: startedAt, torqueCut: torqueCut)
            publishImmediateWireSnapshot()
            return IntentResult(accepted: true)
        }

        let isDrivingState: Bool = {
            switch simMode {
            case .walking, .sitting, .rising, .autoRisingFromSeat:
                return true
            default:
                return false
            }
        }()
        if isDrivingState && !simFallen && simHasSitstand && !simHardBlocked {
            simMode = .shuttingDown(startedAt: Date(), torqueCut: false)
        } else {
            simMode = .shuttingDownImmediate(startedAt: Date())
        }
        publishImmediateWireSnapshot()
        return IntentResult(accepted: true)
    }

    func refreshPolicies() async {
        publishPolicyAndSubscribeMetadata()
        onStateUpdated?()
    }

    func emergencyStop() async {
        commandMove = (0, 0, 0)
        publishImmediateWireSnapshot()
    }

    // MARK: - Unit Test Simulation Helpers

    func simulateHardwareBlocked(
        _ blocked: Bool = true,
        reason: String = "battery: 8.4 V too low; torque stays off"
    ) {
        simHardBlocked = blocked
        simBlockReason = blocked ? reason : nil
        publishHealthSnapshot(elapsed: Date().timeIntervalSince(startTime))
        onStateUpdated?()
    }

    func simulateImuCalibrating(_ calibrating: Bool = true, frozen: Bool = false) {
        simImuReady = !calibrating
        simImuFrozen = calibrating && frozen
        if !calibrating, pendingEnableWhenImuReady, case .held(let sitting) = simMode {
            pendingEnableWhenImuReady = false
            simMode = (sitting && simHasSitstand) ? .autoRisingFromSeat(startedAt: Date()) : .walking
        }
        publishHealthSnapshot(elapsed: Date().timeIntervalSince(startTime))
        publishImmediateWireSnapshot()
    }

    func simulateFallen(_ fallen: Bool = true, recovering: Bool = true) {
        simFallen = fallen
        if fallen {
            commandMove = (0, 0, 0)
            clearActiveEmotionState(clearDropped: false)
            activeDemoKickSide = nil
            switch simMode {
            case .walking, .kicking, .sitting, .rising, .autoRisingFromSeat:
                simMode = recovering ? .limpFall(startedAt: Date(), attempt: 1) : .held(sitting: false)
            default:
                break
            }
        } else {
            switch simMode {
            case .limpFall, .limpPose, .fallRetry:
                simMode = .walking
            default:
                break
            }
        }
        publishImmediateWireSnapshot()
    }

    func simulatePickedUp(_ pickedUp: Bool = true) {
        simPickedUp = pickedUp
        if pickedUp {
            commandMove = (0, 0, 0)
            clearActiveEmotionState(clearDropped: false)
            activeDemoKickSide = nil
            if case .kicking = simMode {
                simMode = .walking
            }
        }
        publishImmediateWireSnapshot()
    }

    func simulateNoSitstand(_ disabled: Bool = true) {
        simHasSitstand = !disabled
        publishImmediateWireSnapshot()
    }

    func simulateKickSides(_ sides: Set<KickSide>) {
        simKickSides = sides
        if let active = activeDemoKickSide, !sides.contains(active) {
            activeDemoKickSide = nil
            if case .kicking = simMode {
                simMode = .walking
            }
        }
        publishImmediateWireSnapshot()
    }

    func simulateEmotions(_ names: [String]) {
        simEmotions = names
        publishImmediateWireSnapshot()
    }

    func simulateVolumeSupport(supported: Bool, applies: Bool = true, volume: UInt8? = nil) {
        simVolumeSupported = supported
        simVolumeApplies = applies
        if let volume {
            simVolume = min(100, volume)
        }
        telemetry.volumeStatus = supported
            ? .loaded(VolumeResult(volume: simVolume, applies: simVolumeApplies))
            : .unsupported
        onStateUpdated?()
    }

    func playQuack() async {
        lastQuackAt = Date()
        telemetry.statusBanner = "Quack!"
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self?.telemetry.statusBanner == "Quack!" {
                self?.telemetry.statusBanner = nil
            }
        }
    }

    func refreshVolume() async {
        guard phase.isConnected else { return }
        telemetry.volumeStatus = simVolumeSupported
            ? .loaded(VolumeResult(volume: simVolume, applies: simVolumeApplies))
            : .unsupported
        onStateUpdated?()
    }

    func setSpeakerVolume(_ volume: UInt8) async throws -> VolumeResult {
        guard phase.isConnected else {
            throw BleManagerError.disconnected("Connect to a duck first.")
        }
        guard simVolumeSupported else {
            telemetry.volumeStatus = .unsupported
            onStateUpdated?()
            throw BleManagerError.rpcError(code: -32601, message: "Method not found: robot.setVolume")
        }
        simVolume = min(100, volume)
        let result = VolumeResult(volume: simVolume, applies: simVolumeApplies)
        telemetry.volumeStatus = .loaded(result)
        onStateUpdated?()
        return result
    }

    func playTestQuack() async {
        guard phase.isConnected else { return }
        lastQuackAt = Date()
        let banner = simVolume == 0 ? "Quack! (Muted)" : "Quack! (\(simVolume)%)"
        telemetry.statusBanner = banner
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self?.telemetry.statusBanner == banner {
                self?.telemetry.statusBanner = nil
            }
        }
    }

    func scanWifiNetworks() async throws -> [WifiNetwork] {
        try? await Task.sleep(nanoseconds: 350_000_000)
        return [
            WifiNetwork(ssid: "HomeWiFi", signal: 86, security: .wpaPsk, saved: true),
            WifiNetwork(ssid: "Studio-5G", signal: 72, security: .wpa3Sae, saved: false),
            WifiNetwork(ssid: "DuckNet", signal: 58, security: .open, saved: false),
            WifiNetwork(ssid: "CampusAuth", signal: 44, security: .enterprise, saved: false)
        ]
    }

    func connectWifi(ssid: String, psk: String?) async throws -> ConnectResult {
        let steps: [JoinStep] = [.scanning, .associating, .authenticating, .addressing]
        for (idx, step) in steps.enumerated() {
            simJoining = Joining(ssid: ssid, step: step, elapsed_seconds: UInt32(idx), timeout_seconds: 30)
            await refreshNetStatus()
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        simJoining = nil

        if psk == "wrong" {
            await refreshNetStatus()
            return .failed(reason: .badKey, detail: "Simulated wrong passphrase")
        }

        simWifiSsid = ssid
        await refreshNetStatus()
        return .connected(ssid: ssid, ip4: "192.0.2.10")
    }

    func forgetWifi(ssid: String) async throws -> Bool {
        if simWifiSsid == ssid {
            simWifiSsid = nil
        }
        await refreshNetStatus()
        return true
    }

    func refreshNetStatus() async {
        telemetry.netStatus = NetStatusResult(
            state: simJoining != nil ? .connecting : (simWifiSsid != nil ? .connected : .disconnected),
            ssid: simWifiSsid,
            signal: simWifiSsid != nil ? 84 : nil,
            ip4: simWifiSsid != nil ? "192.0.2.10" : nil,
            ip6: nil,
            mac: "02:00:00:00:00:01",
            iface: "wlan0",
            joining: simJoining
        )
    }

    func forceReconnect() async {
        simTask?.cancel()
        simTask = nil
        connect()
    }

    func disconnect() async {
        simTask?.cancel()
        simTask = nil
        clearActiveEmotionState(clearDropped: true)
        activeDemoKickSide = nil
        videoSource = .none
        phase = .disconnected
        telemetry = TelemetrySnapshot()
        onStateUpdated?()
    }

    // MARK: - Simulation loop

    private struct ResolvedSimWire {
        let policyName: String
        let homed: Bool
        let sitting: Bool
        let isLimp: Bool
        let isFallen: Bool
        let isPickedUp: Bool
        let isTorqueOn: Bool
        let isHeadDriving: Bool
        let isWalkingGait: Bool
        let isCrouched: Bool
        let gain: UInt16
        let activeMove: (Double, Double, Double)
    }

    private func startSimulationLoop() {
        simTask?.cancel()
        simTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000) // 20 Hz base sim tick
                guard let self, !Task.isCancelled else { break }
                self.stepSimulation(dt: 0.05)
            }
        }
    }

    private func publishImmediateWireSnapshot() {
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        publishPolicyAndSubscribeMetadata(now: now)
        let wire = resolveWireSnapshot(now: now)
        publishRobotState(elapsed: elapsed, wire: wire)
        lastWirePhaseKey = currentWirePhaseKey(now: now)
        onStateUpdated?()
    }

    private func currentWirePhaseKey(now: Date) -> WirePhaseKey {
        let wire = resolveWireSnapshot(now: now)
        return WirePhaseKey(
            policy: wire.policyName,
            homed: wire.homed,
            sitting: wire.sitting,
            limp: wire.isLimp,
            fallen: wire.isFallen,
            pickedUp: wire.isPickedUp,
            activeEmotionName: activeDemoEmotionName
        )
    }

    private func advanceSimModeTransitions(now: Date) {
        switch simMode {
        case .homing(let startedAt, let targetSeated):
            if now.timeIntervalSince(startedAt) >= 2.0 {
                simMode = .held(sitting: targetSeated)
            }
        case .autoRisingFromSeat(let startedAt):
            if now.timeIntervalSince(startedAt) >= 3.0 {
                simMode = .walking
            }
        case .walking:
            break
        case .kicking(_, let startedAt):
            if simFallen || simPickedUp || now.timeIntervalSince(startedAt) >= MicroduckKicks.durationSeconds {
                simMode = .walking
                activeDemoKickSide = nil
            }
        case .rising(let startedAt):
            if now.timeIntervalSince(startedAt) >= 1.0 {
                simMode = .walking
            }
        case .resting(let startedAt, _):
            if now.timeIntervalSince(startedAt) >= 5.0 {
                simMode = .limp
            }
        case .shuttingDown(let startedAt, _):
            if now.timeIntervalSince(startedAt) >= 5.0 {
                finishSimulatedShutdown()
            }
        case .shuttingDownImmediate(let startedAt):
            if now.timeIntervalSince(startedAt) >= 0.6 {
                finishSimulatedShutdown()
            }
        case .limpFall(let startedAt, let attempt):
            if now.timeIntervalSince(startedAt) >= 1.0 {
                simMode = .limpPose(startedAt: now, attempt: attempt)
            }
        case .limpPose(let startedAt, let attempt):
            if now.timeIntervalSince(startedAt) >= 0.6 {
                simMode = .fallRetry(startedAt: now, attempt: attempt)
            }
        case .fallRetry(let startedAt, let attempt):
            if !simFallen {
                simMode = .walking
            } else if now.timeIntervalSince(startedAt) >= 3.0 {
                if attempt < 3 {
                    simMode = .limpFall(startedAt: now, attempt: attempt + 1)
                } else {
                    simMode = .held(sitting: false)
                }
            }
        default:
            break
        }

        if let emotion = activeEmotion {
            let isWalkingOrSitting: Bool
            switch simMode {
            case .walking, .sitting:
                isWalkingOrSitting = true
            default:
                isWalkingOrSitting = false
            }
            if simFallen || simPickedUp || !isWalkingOrSitting || now.timeIntervalSince(emotion.startedAt) >= emotion.duration {
                clearActiveEmotionState(clearDropped: false)
            }
        }
    }

    private func finishSimulatedShutdown() {
        simTask?.cancel()
        simTask = nil
        clearActiveEmotionState(clearDropped: true)
        activeDemoKickSide = nil
        simMode = .limp
        videoSource = .none
        var poweredOffSnapshot = TelemetrySnapshot()
        poweredOffSnapshot.isPoweredOff = true
        poweredOffSnapshot.shutdownOutcome = .confirmedPoweredOff
        telemetry = poweredOffSnapshot
        phase = .disconnected
        onStateUpdated?()
    }

    private func resolveWireSnapshot(now: Date) -> ResolvedSimWire {
        switch simMode {
        case .limp:
            return ResolvedSimWire(
                policyName: "held",
                homed: false,
                sitting: false,
                isLimp: false,
                isFallen: simFallen,
                isPickedUp: false,
                isTorqueOn: false,
                isHeadDriving: false,
                isWalkingGait: false,
                isCrouched: false,
                gain: 200,
                activeMove: (0, 0, 0)
            )
        case .homing(_, let targetSeated):
            return ResolvedSimWire(
                policyName: "homing",
                homed: false,
                sitting: targetSeated,
                isLimp: false,
                isFallen: simFallen,
                isPickedUp: false,
                isTorqueOn: true,
                isHeadDriving: false,
                isWalkingGait: false,
                isCrouched: targetSeated,
                gain: 400,
                activeMove: (0, 0, 0)
            )
        case .held(let sitting):
            return ResolvedSimWire(
                policyName: "held",
                homed: true,
                sitting: sitting,
                isLimp: false,
                isFallen: simFallen,
                isPickedUp: false,
                isTorqueOn: true,
                isHeadDriving: false,
                isWalkingGait: false,
                isCrouched: sitting,
                gain: 650,
                activeMove: (0, 0, 0)
            )
        case .walking, .fallRetry:
            if simPickedUp && !simFallen {
                return ResolvedSimWire(
                    policyName: "held",
                    homed: true,
                    sitting: false,
                    isLimp: false,
                    isFallen: false,
                    isPickedUp: true,
                    isTorqueOn: true,
                    isHeadDriving: false,
                    isWalkingGait: false,
                    isCrouched: false,
                    gain: 650,
                    activeMove: (0, 0, 0)
                )
            }
            let move = (simFallen || activeEmotion != nil) ? (0.0, 0.0, 0.0) : commandMove
            return ResolvedSimWire(
                policyName: "walk",
                homed: true,
                sitting: false,
                isLimp: false,
                isFallen: simFallen,
                isPickedUp: false,
                isTorqueOn: true,
                isHeadDriving: !simFallen,
                isWalkingGait: !simFallen,
                isCrouched: false,
                gain: 650,
                activeMove: move
            )
        case .kicking(let side, _):
            if simPickedUp && !simFallen {
                return ResolvedSimWire(
                    policyName: "held",
                    homed: true,
                    sitting: false,
                    isLimp: false,
                    isFallen: false,
                    isPickedUp: true,
                    isTorqueOn: true,
                    isHeadDriving: false,
                    isWalkingGait: false,
                    isCrouched: false,
                    gain: 650,
                    activeMove: (0, 0, 0)
                )
            }
            return ResolvedSimWire(
                policyName: side.skillName,
                homed: true,
                sitting: false,
                isLimp: false,
                isFallen: simFallen,
                isPickedUp: false,
                isTorqueOn: true,
                isHeadDriving: !simFallen,
                isWalkingGait: false,
                isCrouched: false,
                gain: 650,
                activeMove: (0, 0, 0)
            )
        case .sitting:
            if simPickedUp && !simFallen {
                return ResolvedSimWire(
                    policyName: "held",
                    homed: true,
                    sitting: true,
                    isLimp: false,
                    isFallen: false,
                    isPickedUp: true,
                    isTorqueOn: true,
                    isHeadDriving: false,
                    isWalkingGait: false,
                    isCrouched: true,
                    gain: 650,
                    activeMove: (0, 0, 0)
                )
            }
            return ResolvedSimWire(
                policyName: "sit",
                homed: true,
                sitting: true,
                isLimp: false,
                isFallen: simFallen,
                isPickedUp: false,
                isTorqueOn: true,
                isHeadDriving: !simFallen,
                isWalkingGait: false,
                isCrouched: true,
                gain: 650,
                activeMove: (0, 0, 0)
            )
        case .rising:
            return ResolvedSimWire(
                policyName: "rise",
                homed: true,
                sitting: false,
                isLimp: false,
                isFallen: simFallen,
                isPickedUp: simPickedUp,
                isTorqueOn: true,
                isHeadDriving: true,
                isWalkingGait: false,
                isCrouched: false,
                gain: 650,
                activeMove: (0, 0, 0)
            )
        case .autoRisingFromSeat(let startedAt):
            let dt = now.timeIntervalSince(startedAt)
            let stillSitting = dt < 2.0
            return ResolvedSimWire(
                policyName: stillSitting ? "sit" : "rise",
                homed: true,
                sitting: stillSitting,
                isLimp: false,
                isFallen: simFallen,
                isPickedUp: simPickedUp,
                isTorqueOn: true,
                isHeadDriving: true,
                isWalkingGait: false,
                isCrouched: stillSitting,
                gain: 650,
                activeMove: (0, 0, 0)
            )
        case .resting(let startedAt, let torqueCut),
             .shuttingDown(let startedAt, let torqueCut):
            let dt = now.timeIntervalSince(startedAt)
            if dt < 3.0 {
                return ResolvedSimWire(
                    policyName: torqueCut ? "held" : "sit",
                    homed: !torqueCut,
                    sitting: !torqueCut,
                    isLimp: false,
                    isFallen: simFallen,
                    isPickedUp: false,
                    isTorqueOn: !torqueCut,
                    isHeadDriving: false,
                    isWalkingGait: false,
                    isCrouched: true,
                    gain: torqueCut ? 200 : 650,
                    activeMove: (0, 0, 0)
                )
            } else if dt < 4.5 {
                return ResolvedSimWire(
                    policyName: "rest",
                    homed: !torqueCut,
                    sitting: false,
                    isLimp: false,
                    isFallen: simFallen,
                    isPickedUp: false,
                    isTorqueOn: !torqueCut,
                    isHeadDriving: false,
                    isWalkingGait: false,
                    isCrouched: true,
                    gain: torqueCut ? 200 : 400,
                    activeMove: (0, 0, 0)
                )
            } else {
                return ResolvedSimWire(
                    policyName: "rest",
                    homed: false,
                    sitting: false,
                    isLimp: false,
                    isFallen: simFallen,
                    isPickedUp: false,
                    isTorqueOn: false,
                    isHeadDriving: false,
                    isWalkingGait: false,
                    isCrouched: true,
                    gain: 200,
                    activeMove: (0, 0, 0)
                )
            }
        case .shuttingDownImmediate:
            return ResolvedSimWire(
                policyName: "held",
                homed: false,
                sitting: false,
                isLimp: false,
                isFallen: simFallen,
                isPickedUp: false,
                isTorqueOn: false,
                isHeadDriving: false,
                isWalkingGait: false,
                isCrouched: false,
                gain: 200,
                activeMove: (0, 0, 0)
            )
        case .limpFall:
            return ResolvedSimWire(
                policyName: "limp_fall",
                homed: true,
                sitting: false,
                isLimp: true,
                isFallen: true,
                isPickedUp: false,
                isTorqueOn: false,
                isHeadDriving: false,
                isWalkingGait: false,
                isCrouched: false,
                gain: 50,
                activeMove: (0, 0, 0)
            )
        case .limpPose:
            return ResolvedSimWire(
                policyName: "limp_pose",
                homed: true,
                sitting: false,
                isLimp: false,
                isFallen: true,
                isPickedUp: false,
                isTorqueOn: true,
                isHeadDriving: false,
                isWalkingGait: false,
                isCrouched: false,
                gain: 160,
                activeMove: (0, 0, 0)
            )
        }
    }

    private func publishPolicyAndSubscribeMetadata(now: Date = Date()) {
        let wire = resolveWireSnapshot(now: now)
        var slots: [PolicySlot] = [
            PolicySlot(
                slot: "walk",
                path: simHasWalkPolicy ? "velstand.onnx" : nil,
                origin: simHasWalkPolicy ? "official" : nil
            ),
            PolicySlot(
                slot: "sitstand",
                path: simHasSitstand ? "alpha_sitstand.onnx" : nil,
                origin: simHasSitstand ? "official" : nil
            )
        ]
        var policySkills: [String] = []
        for side in KickSide.allCases {
            let loaded = simKickSides.contains(side)
            slots.append(
                PolicySlot(
                    slot: side.skillName,
                    path: loaded ? "ball_\(side.rawValue).onnx" : nil,
                    origin: loaded ? "official" : nil
                )
            )
            if loaded {
                policySkills.append(side.skillName)
            }
        }
        telemetry.policies = PoliciesResult(
            mode: "walk",
            enabled: simHasWalkPolicy,
            slots: slots,
            skills: policySkills,
            homed: wire.homed,
            sitting: wire.sitting,
            change_error: nil
        )
        telemetry.subscribeAck = SubscribeResult(
            accepted: true,
            walk: simHasWalkPolicy ? "velstand.onnx" : nil,
            stand: nil,
            sitstand: simHasSitstand ? "alpha_sitstand.onnx" : nil,
            ground_pick: nil,
            skills: policySkills + simEmotions,
            unavailable: simHasWalkPolicy ? nil : "no policy configured; holding the startup pose"
        )
    }

    private func publishHealthSnapshot(elapsed: TimeInterval) {
        let healthy = !simHardBlocked
        let degraded = simHardBlocked
        let reason: String? = simHardBlocked ? (simBlockReason ?? "battery: 8.4 V too low; torque stays off") : nil
        telemetry.lastHealthUptime = ProcessInfo.processInfo.systemUptime
        telemetry.isHealthStale = false
        telemetry.health = HealthResult(
            healthy: healthy,
            degraded: degraded,
            reason: reason,
            battery: Battery(volts: batteryVolts, percent: batteryPercent),
            goal_pwm: 640,
            motors: MotorThermal(
                hottest: "left_knee",
                max_c: motorMaxTempC,
                mean_c: motorMaxTempC - 5.2
            ),
            cpu_temp_c: 54.0,
            cpu_throttle: CpuThrottle(level: 0, max_level: 4, khz: 1800000, max_khz: 1800000),
            control_loop: LoopHealth(
                target_hz: 50.0,
                achieved_hz: 50.0,
                ticks: max(1, tickCount * 2),
                missed: 0,
                last_tick_age_ms: 2
            ),
            bus: BusHealth(
                consecutive_errors: 0,
                startup_failures: simHardBlocked ? 1 : 0,
                missing: []
            ),
            imu: ImuHealth(
                ready: simImuReady,
                stale_blocks: simImuFrozen ? 30 : 0,
                consecutive_stale_blocks: simImuFrozen ? 30 : 0,
                missing: false
            )
        )
        telemetry.systemInfo = SystemInfoResult(
            name: "Microduck (Demo)",
            serial: "demo-duck-01",
            uptime_seconds: UInt64(142 + elapsed),
            simulated: true
        )
    }

    private func stepSimulation(dt: Double, forcePublishState: Bool = false) {
        tickCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)

        advanceSimModeTransitions(now: now)
        guard phase.isConnected else { return }
        let phaseKey = currentWirePhaseKey(now: now)
        let phaseChanged = (phaseKey != lastWirePhaseKey)
        let wire = resolveWireSnapshot(now: now)

        // Move integration when actively walking
        let activeMove = wire.activeMove
        odomYaw += activeMove.2 * dt
        let cosYaw = cos(odomYaw)
        let sinYaw = sin(odomYaw)
        odomPosition[0] += (activeMove.0 * cosYaw - activeMove.1 * sinYaw) * dt
        odomPosition[1] += (activeMove.0 * sinYaw + activeMove.1 * cosYaw) * dt

        let speed = hypot(activeMove.0, activeMove.1) + abs(activeMove.2) * 0.2
        let walkPhase = elapsed * 6.5
        let isWalking = wire.isWalkingGait && speed > 0.02

        // Body attitude
        let emo = activeEmotion.map { emotionOffsets(for: $0, now: now) }
        let activeKick: (side: KickSide, progress: Double)? = {
            guard case .kicking(let side, let startedAt) = simMode else { return nil }
            let progress = max(0.0, min(1.0, now.timeIntervalSince(startedAt) / MicroduckKicks.durationSeconds))
            return (side, progress)
        }()
        var pitchRad: Double
        var rollRad: Double
        if wire.isFallen {
            pitchRad = 1.05
            rollRad = 0.25
        } else if !wire.isTorqueOn {
            pitchRad = 0.05
            rollRad = 0.03
        } else if let activeKick {
            let swing = sin(activeKick.progress * .pi)
            pitchRad = -0.06 * swing
            // Counter-roll onto stance foot while kicking
            rollRad = (activeKick.side == .left ? -0.14 : 0.14) * swing
        } else if isWalking {
            pitchRad = -activeMove.0 * 0.22 + sin(walkPhase) * 0.025
            rollRad = activeMove.1 * 0.25 + cos(walkPhase) * 0.035
        } else {
            pitchRad = sin(elapsed * 0.8) * 0.014
            rollRad = cos(elapsed * 0.6) * 0.012
        }
        if let emo, wire.isTorqueOn && !wire.isFallen {
            pitchRad += emo.bodyPitchRad
            rollRad += emo.bodyRollRad
        }

        virtualPitchDeg = pitchRad * 180.0 / .pi
        virtualRollDeg = rollRad * 180.0 / .pi
        virtualYawDeg = odomYaw * 180.0 / .pi

        let baseHeadYaw = wire.isHeadDriving ? max(-0.85, min(0.85, commandLook.y / 0.7 * 0.65)) : 0.0
        let baseHeadPitch = wire.isHeadDriving ? max(-0.45, min(0.45, -(commandLook.z - 0.2) / 0.45 * 0.35)) : 0.0
        let headYaw = wire.isHeadDriving ? max(-0.85, min(0.85, baseHeadYaw + (emo?.headYaw ?? 0.0))) : 0.0
        let headPitch = wire.isHeadDriving ? max(-0.45, min(0.45, baseHeadPitch + (emo?.headPitch ?? 0.0))) : 0.0
        let headRoll = wire.isHeadDriving ? (emo?.headRoll ?? 0.0) : 0.0
        let neckPitch = wire.isHeadDriving ? (0.08 + (emo?.neckPitch ?? 0.0)) : 0.08
        let mouthAngle = wire.isHeadDriving ? (emo?.mouthAngle ?? 0.0) : 0.0

        if let emo, wire.isHeadDriving {
            _ = emo
            virtualGazeNormalized = (
                x: max(-1, min(1, -headYaw / 0.65)),
                y: max(-1, min(1, -headPitch / 0.35))
            )
        } else if activeEmotion == nil {
            virtualGazeNormalized = (
                x: max(-1, min(1, -commandLook.y / LiveRobotSession.lookRange.y)),
                y: max(-1, min(1, -(commandLook.z - LiveRobotSession.lookRange.z) / LiveRobotSession.lookRange.dz))
            )
        }

        // Publish RobotState at 10 Hz (Sensors open), 2 Hz (Live), or immediately on mode change
        let stateDivider: UInt64 = sensorsVisible ? 2 : 10
        if forcePublishState || phaseChanged || tickCount % stateDivider == 0 {
            if phaseChanged {
                publishPolicyAndSubscribeMetadata(now: now)
            }
            publishRobotState(
                elapsed: elapsed,
                wire: wire,
                rollRad: rollRad,
                pitchRad: pitchRad,
                walkPhase: walkPhase,
                speed: speed,
                isWalking: isWalking,
                neckPitch: neckPitch,
                headPitch: headPitch,
                headYaw: headYaw,
                headRoll: headRoll,
                mouthAngle: mouthAngle,
                activeKick: activeKick
            )
            if phaseChanged {
                lastWirePhaseKey = phaseKey
                onStateUpdated?()
            }
        }

        // Publish 8x8 ToF depth wave at ~10 Hz
        if forcePublishState || tickCount % 2 == 0 {
            var distances = [Int16](repeating: 1400, count: 64)
            var statuses = [UInt8](repeating: 5, count: 64)
            let waveCol = 3.5 + sin(elapsed * 1.4) * 2.2
            let waveRow = 3.8 + cos(elapsed * 0.9) * 1.6

            for r in 0..<8 {
                for c in 0..<8 {
                    let idx = r * 8 + c
                    if r == 0 && (c == 0 || c == 7) {
                        distances[idx] = 0
                        statuses[idx] = 255
                        continue
                    }
                    let distGrid = hypot(Double(c) - waveCol, Double(r) - waveRow)
                    let baseMm = 340.0 + distGrid * 220.0 + sin(elapsed * 2.0 + Double(idx) * 0.1) * 35.0
                    distances[idx] = Int16(max(120, min(2800, Int(baseMm))))
                    statuses[idx] = distGrid < 2.5 ? 5 : 9
                }
            }

            telemetry.tofFrame = TofFrame(
                seq: tickCount / 2,
                at_us: UInt64(elapsed * 1_000_000),
                t_ns: UInt64(elapsed * 1_000_000_000),
                rows: 8,
                cols: 8,
                distance_mm: distances,
                status: statuses
            )
        }

        // Publish Head IMU at 10 Hz when Sensors visible
        if sensorsVisible && tickCount % 2 == 0 {
            let headQuat = quaternionFromEuler(
                roll: rollRad + headRoll + 0.02,
                pitch: pitchRad + headPitch,
                yaw: odomYaw + headYaw
            ).map(Float.init)
            telemetry.headImu = HeadImuFrame(
                seq: tickCount / 2,
                at_us: UInt64(elapsed * 1_000_000),
                t_ns: UInt64(elapsed * 1_000_000_000),
                gyro: [
                    Float((rollRad + headRoll) * 0.4),
                    Float(headPitch * 0.3),
                    Float(activeMove.2)
                ],
                accel: [0.1, -0.05, -9.81],
                quat: headQuat,
                temp_c: 34.8
            )
        }

        // Health & policies at 1 Hz
        if tickCount % 20 == 0 {
            batteryVolts = max(10.5, batteryVolts - 0.0008)
            batteryPercent = max(5, min(100, (batteryVolts - 10.2) / (12.6 - 10.2) * 100.0))
            if wire.isTorqueOn && isWalking {
                motorMaxTempC = min(55.5, motorMaxTempC + 0.08)
            } else {
                motorMaxTempC = max(41.0, motorMaxTempC - 0.04)
            }
            publishPolicyAndSubscribeMetadata(now: now)
            publishHealthSnapshot(elapsed: elapsed)
            onStateUpdated?()
        }
    }

    private func clearActiveEmotionState(clearDropped: Bool) {
        activeEmotion = nil
        activeDemoEmotionName = nil
        if clearDropped {
            lastDroppedEmotionName = nil
        }
    }

    private func emotionOffsets(for emotion: ActiveDemoEmotion, now: Date) -> EmotionOffsets {
        let t = max(0, now.timeIntervalSince(emotion.startedAt))
        let remaining = max(0, emotion.duration - t)
        let envelope = min(1.0, t / 0.2) * min(1.0, remaining / 0.25)

        switch emotion.name {
        case "yes", "yes_fast":
            let freq = emotion.name == "yes_fast" ? 18.0 : 12.0
            return EmotionOffsets(
                bodyPitchRad: 0.06 * sin(t * freq) * envelope,
                bodyRollRad: 0,
                neckPitch: 0.12 * sin(t * freq) * envelope,
                headPitch: 0.28 * sin(t * freq) * envelope,
                headYaw: 0,
                headRoll: 0,
                mouthAngle: 0.25 * max(0, sin(t * freq)) * envelope
            )
        case "no":
            return EmotionOffsets(
                bodyPitchRad: 0,
                bodyRollRad: 0,
                neckPitch: 0,
                headPitch: 0,
                headYaw: 0.45 * sin(t * 14.0) * envelope,
                headRoll: 0.08 * sin(t * 14.0) * envelope,
                mouthAngle: 0.10 * envelope
            )
        case "angry":
            return EmotionOffsets(
                bodyPitchRad: -0.10 * envelope,
                bodyRollRad: 0,
                neckPitch: -0.08 * envelope,
                headPitch: -0.18 * envelope,
                headYaw: 0.35 * sin(t * 18.0) * envelope,
                headRoll: 0,
                mouthAngle: 0.45 * envelope
            )
        case "mock":
            return EmotionOffsets(
                bodyPitchRad: 0,
                bodyRollRad: 0.05 * cos(t * 5.5) * envelope,
                neckPitch: 0,
                headPitch: 0.08 * sin(t * 11.0) * envelope,
                headYaw: 0.40 * sin(t * 11.0) * envelope,
                headRoll: 0.18 * cos(t * 5.5) * envelope,
                mouthAngle: 0.35 * (0.5 + 0.5 * sin(t * 10.0)) * envelope
            )
        case "curious":
            return EmotionOffsets(
                bodyPitchRad: 0,
                bodyRollRad: 0.08 * envelope,
                neckPitch: -0.04 * envelope,
                headPitch: -0.10 * envelope,
                headYaw: 0.22 * sin(t * 2.5) * envelope,
                headRoll: 0.38 * envelope,
                mouthAngle: 0.15 * envelope
            )
        case "mmh":
            return EmotionOffsets(
                bodyPitchRad: 0.04 * envelope,
                bodyRollRad: -0.06 * envelope,
                neckPitch: 0.06 * envelope,
                headPitch: 0.12 * envelope,
                headYaw: -0.16 * envelope,
                headRoll: -0.32 * envelope,
                mouthAngle: 0.05 * envelope
            )
        case "excited":
            return EmotionOffsets(
                bodyPitchRad: 0.12 * sin(t * 16.0) * envelope,
                bodyRollRad: 0.10 * cos(t * 8.0) * envelope,
                neckPitch: -0.08 * envelope,
                headPitch: -0.22 * abs(sin(t * 8.0)) * envelope,
                headYaw: 0.25 * sin(t * 8.0) * envelope,
                headRoll: 0.12 * sin(t * 8.0) * envelope,
                mouthAngle: 0.48 * (0.5 + 0.5 * sin(t * 14.0)) * envelope
            )
        case "laugh":
            return EmotionOffsets(
                bodyPitchRad: 0.10 * sin(t * 18.0) * envelope,
                bodyRollRad: 0.06 * cos(t * 9.0) * envelope,
                neckPitch: -0.06 * envelope,
                headPitch: -0.26 * (0.5 + 0.5 * sin(t * 15.0)) * envelope,
                headYaw: 0,
                headRoll: 0.14 * sin(t * 7.5) * envelope,
                mouthAngle: 0.55 * (0.5 + 0.5 * sin(t * 15.0)) * envelope
            )
        case "impatient":
            return EmotionOffsets(
                bodyPitchRad: 0.05 * sin(t * 12.0) * envelope,
                bodyRollRad: 0.11 * sin(t * 12.0) * envelope,
                neckPitch: 0,
                headPitch: 0.10 * sin(t * 12.0) * envelope,
                headYaw: 0.28 * sin(t * 6.0) * envelope,
                headRoll: 0,
                mouthAngle: 0.20 * envelope
            )
        case "sad":
            return EmotionOffsets(
                bodyPitchRad: 0.18 * envelope,
                bodyRollRad: 0,
                neckPitch: 0.24 * envelope,
                headPitch: 0.32 * envelope,
                headYaw: 0,
                headRoll: 0.10 * sin(t * 1.5) * envelope,
                mouthAngle: 0.05 * envelope
            )
        case "devastated":
            return EmotionOffsets(
                bodyPitchRad: 0.24 * envelope,
                bodyRollRad: 0,
                neckPitch: 0.30 * envelope,
                headPitch: 0.38 * envelope,
                headYaw: 0.15 * sin(t * 2.0) * envelope,
                headRoll: 0,
                mouthAngle: 0.35 * envelope
            )
        case "defiant":
            return EmotionOffsets(
                bodyPitchRad: -0.14 * envelope,
                bodyRollRad: 0,
                neckPitch: -0.16 * envelope,
                headPitch: -0.28 * envelope,
                headYaw: 0.18 * sin(t * 3.0) * envelope,
                headRoll: -0.12 * envelope,
                mouthAngle: 0.22 * envelope
            )
        default:
            return EmotionOffsets(
                bodyPitchRad: 0.05 * sin(t * 6.0) * envelope,
                bodyRollRad: 0.05 * cos(t * 4.0) * envelope,
                neckPitch: 0,
                headPitch: 0.18 * sin(t * 6.0) * envelope,
                headYaw: 0.16 * sin(t * 3.0) * envelope,
                headRoll: 0.16 * cos(t * 4.0) * envelope,
                mouthAngle: 0.25 * envelope
            )
        }
    }

    private func publishRobotState(
        elapsed: TimeInterval,
        wire: ResolvedSimWire,
        rollRad: Double = 0,
        pitchRad: Double = 0,
        walkPhase: Double = 0,
        speed: Double = 0,
        isWalking: Bool = false,
        neckPitch: Double = 0.08,
        headPitch: Double = 0,
        headYaw: Double = 0,
        headRoll: Double = 0,
        mouthAngle: Double = 0,
        activeKick: (side: KickSide, progress: Double)? = nil
    ) {
        let bodyQuat = quaternionFromEuler(roll: rollRad, pitch: pitchRad, yaw: odomYaw)
        let gravity = [
            -sin(pitchRad),
            sin(rollRad) * cos(pitchRad),
            -cos(rollRad) * cos(pitchRad)
        ]
        let headAngles = [neckPitch, headPitch, headYaw, headRoll]

        var joints = [Double](repeating: 0, count: 15)
        var targets = [Double](repeating: 0, count: 15)
        var currents = [Double](repeating: 0, count: 15)

        for idx in 0..<15 {
            let baseAngle: Double
            let targetAngle: Double
            let baseCurrent: Double

            if idx >= 5 && idx <= 9 {
                let hIdx = idx - 5
                targetAngle = hIdx < 4 ? headAngles[hIdx] : mouthAngle
                baseAngle = targetAngle + sin(elapsed * 2.1 + Double(idx)) * 0.008
                baseCurrent = wire.isTorqueOn ? (110 + Double(hIdx == 1 ? 75 : 25)) : 8
            } else {
                let legSign = idx < 5 ? 1.0 : -1.0
                let stride = isWalking ? sin(walkPhase + (legSign > 0 ? 0 : .pi)) * 0.16 * min(1.0, speed / 0.2) : 0
                let isKnee = idx == 3 || idx == 13
                let isAnkle = idx == 4 || idx == 14
                let kneeOffset = wire.isCrouched ? 1.05 : 0.58
                let ankleOffset = wire.isCrouched ? -0.58 : -0.30
                let hipOffset = wire.isCrouched ? -0.52 : -0.28
                let kickSwing: Double = {
                    guard let activeKick else { return 0.0 }
                    let isLeftLeg = idx < 5
                    let matchesFoot = (activeKick.side == .left && isLeftLeg) || (activeKick.side == .right && !isLeftLeg)
                    guard matchesFoot else { return 0.0 }
                    let env = sin(activeKick.progress * .pi)
                    if idx == 2 || idx == 12 { return -0.55 * env } // hip pitch swing forward
                    if idx == 3 || idx == 13 { return -0.35 * env } // knee extension
                    if idx == 4 || idx == 14 { return 0.25 * env }  // ankle pitch
                    return 0.0
                }()
                let homeOffset = isKnee ? kneeOffset : (isAnkle ? ankleOffset : (idx == 2 || idx == 12 ? hipOffset : 0.0))
                targetAngle = homeOffset + stride + kickSwing
                baseAngle = targetAngle + (!wire.isTorqueOn ? 0.04 : sin(elapsed * 3.0 + Double(idx)) * 0.01)
                let activeLoad = isKnee ? 340.0 : (isAnkle ? 260.0 : 190.0)
                baseCurrent = !wire.isTorqueOn ? 6.0 : activeLoad + (isWalking ? abs(stride) * 1800.0 : 0.0) + abs(kickSwing) * 950.0
            }
            joints[idx] = baseAngle
            targets[idx] = targetAngle
            currents[idx] = baseCurrent
        }

        let applied = [wire.activeMove.0, wire.activeMove.1, wire.activeMove.2]
        var limitedBy: [String] = []
        if wire.isLimp { limitedBy.append("limp") }
        if wire.isFallen { limitedBy.append("fallen") }
        if wire.isPickedUp { limitedBy.append("picked_up") }

        telemetry.lastRobotStateUptime = ProcessInfo.processInfo.systemUptime
        telemetry.isRobotStateStale = false
        telemetry.robotState = RobotState(
            t: elapsed,
            movement: MoveState(
                requested: [commandMove.0, commandMove.1, commandMove.2],
                applied: applied,
                source: "quackdeck-demo",
                limited_by: limitedBy
            ),
            head: headAngles,
            policy: wire.policyName,
            safety: SafetyState(
                fallen: wire.isFallen,
                limp: wire.isLimp,
                gravity: gravity,
                gain: wire.gain,
                picked_up: wire.isPickedUp
            ),
            control_loop: LoopState(hz: 50.0, missed: 0),
            joints: joints,
            targets: targets,
            velocities: [Double](repeating: 0, count: 15),
            currents_ma: currents,
            odom: OdomState(position: odomPosition, yaw: odomYaw),
            t_ns: UInt64(elapsed * 1_000_000_000),
            imu: ImuState(
                gyro: [
                    isWalking ? cos(walkPhase) * 0.12 : 0.01,
                    isWalking ? sin(walkPhase) * 0.09 : -0.01,
                    wire.activeMove.2 * 0.9
                ],
                quat: bodyQuat
            )
        )
    }

    private func quaternionFromEuler(roll: Double, pitch: Double, yaw: Double) -> [Double] {
        let cr = cos(roll * 0.5)
        let sr = sin(roll * 0.5)
        let cp = cos(pitch * 0.5)
        let sp = sin(pitch * 0.5)
        let cy = cos(yaw * 0.5)
        let sy = sin(yaw * 0.5)

        let w = cr * cp * cy + sr * sp * sy
        let x = sr * cp * cy - cr * sp * sy
        let y = cr * sp * cy + sr * cp * sy
        let z = cr * cp * sy - sr * sp * cy
        return [w, x, y, z]
    }
}
