import Foundation
import WebRTC

enum ShutdownOutcome: Equatable, Sendable {
    case none
    case requested
    case unconfirmedLostConnection
    case confirmedPoweredOff
}

enum VideoFrameSource: Equatable {
    case none
    case demo
    case webrtc(track: RTCVideoTrack)

    static func == (lhs: VideoFrameSource, rhs: VideoFrameSource) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.demo, .demo):
            return true
        case (.webrtc(let a), .webrtc(let b)):
            return a === b
        default:
            return false
        }
    }
}

struct TelemetrySnapshot: Equatable, Sendable {
    var systemInfo: SystemInfoResult?
    var health: HealthResult?
    var policies: PoliciesResult?
    var subscribeAck: SubscribeResult?
    var robotState: RobotState?
    var model: ModelResult?
    var tofFrame: TofFrame?
    var tofHz: Double = 0
    var headImu: HeadImuFrame?
    var netStatus: NetStatusResult?
    var mediaVideo: MediaVideoInfo?
    var videoFps: Double = 0
    var lookClamped: Bool = false
    var lastError: String?
    var statusBanner: String?
    var reconnectAttempt: Int = 0
    var nextRetrySeconds: Int? = nil
    var isAutoReconnecting: Bool = false
    var isPoweredOff: Bool = false
    var shutdownOutcome: ShutdownOutcome = .none
    var lastRobotStateUptime: TimeInterval?
    var lastHealthUptime: TimeInterval?
    var isRobotStateStale: Bool = false
    var isHealthStale: Bool = false
    var isVideoFirstFrameTimedOut: Bool = false

    var hasSitstand: Bool {
        CockpitStateResolver.hasSitstand(policies: policies, subscribeAck: subscribeAck)
    }

    var hasWalkPolicy: Bool {
        CockpitStateResolver.hasWalkPolicy(policies: policies, subscribeAck: subscribeAck)
    }

    var availableEmotions: [String] {
        MicroduckEmotions.discover(subscribeAck: subscribeAck, policies: policies)
    }

    var availableKickSides: Set<KickSide> {
        MicroduckKicks.discover(policies: policies, subscribeAck: subscribeAck)
    }

    var hasAnyKick: Bool {
        !availableKickSides.isEmpty
    }

    var nearestTofMeters: Double? {
        tofFrame?.nearestValidDistanceMeters
    }

    var hottestServoTempC: Double? {
        health?.motors?.max_c
    }

    var batteryVolts: Double? {
        health?.battery?.volts
    }

    var batteryPercent: Double? {
        health?.battery?.percent
    }

    var bodyPitchRollDegrees: (pitch: Double, roll: Double)? {
        if let quat = robotState?.imu?.quat, quat.count >= 4 {
            return QuackMath.pitchRollDegrees(fromWXYZ: quat)
        }
        if let gravity = robotState?.safety.gravity, gravity.count >= 3 {
            return QuackMath.pitchRollDegrees(fromGravity: gravity)
        }
        return nil
    }
}

@MainActor
protocol RobotSessionTransport: AnyObject {
    var phase: ConnectionPhase { get }
    var telemetry: TelemetrySnapshot { get }
    var videoSource: VideoFrameSource { get }
    var isDemoMode: Bool { get }
    var currentDuckName: String { get }
    var currentRobotId: String? { get }
    var currentIpAddress: String? { get }

    func setSensorsVisible(_ visible: Bool)
    func setMove(vx: Double, vy: Double, vyaw: Double)
    func setLook(y: Double, z: Double)
    func lookCenter()
    func sendInit() async -> IntentResult
    func setPolicyEnabled(_ on: Bool) async -> IntentResult
    func sendSitToggle() async -> IntentResult
    func triggerEmotion(_ name: String) async -> IntentResult
    func triggerKick(_ side: KickSide) async -> IntentResult
    func sendRelax() async -> IntentResult
    func sendRest() async -> IntentResult
    func sendShutdown() async -> IntentResult
    func refreshPolicies() async
    func emergencyStop() async
    func playQuack() async
    func scanWifiNetworks() async throws -> [WifiNetwork]
    func connectWifi(ssid: String, psk: String?) async throws -> ConnectResult
    func forgetWifi(ssid: String) async throws -> Bool
    func refreshNetStatus() async
    func forceReconnect() async
    func disconnect() async
}
