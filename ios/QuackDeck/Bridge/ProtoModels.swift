import Foundation

enum MicroduckJoints {
    static let defaultNames: [String] = [
        "left_hip_yaw",
        "left_hip_roll",
        "left_hip_pitch",
        "left_knee",
        "left_ankle",
        "neck_pitch",
        "head_pitch",
        "head_yaw",
        "head_roll",
        "mouth",
        "right_hip_yaw",
        "right_hip_roll",
        "right_hip_pitch",
        "right_knee",
        "right_ankle"
    ]

    static let defaultIds: [UInt8] = [
        20, 21, 22, 23, 24,
        30, 31, 32, 33, 34,
        10, 11, 12, 13, 14
    ]
}

// MARK: - system.* & robot.health

struct SystemInfoResult: Codable, Sendable, Equatable {
    let name: String
    let serial: String?
    let uptime_seconds: UInt64
    let simulated: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case serial
        case uptime_seconds
        case simulated
    }

    init(name: String, serial: String? = nil, uptime_seconds: UInt64 = 0, simulated: Bool = false) {
        self.name = name
        self.serial = serial
        self.uptime_seconds = uptime_seconds
        self.simulated = simulated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        serial = try container.decodeIfPresent(String.self, forKey: .serial)
        uptime_seconds = try container.decodeIfPresent(UInt64.self, forKey: .uptime_seconds) ?? 0
        simulated = try container.decodeIfPresent(Bool.self, forKey: .simulated) ?? false
    }
}

struct Battery: Codable, Sendable, Equatable {
    static let lowPct: Double = 30.0
    static let criticalPct: Double = 15.0

    let volts: Double
    let percent: Double

    var isLow: Bool { percent <= Self.lowPct }
    var isCritical: Bool { percent <= Self.criticalPct }
}

struct MotorThermal: Codable, Sendable, Equatable {
    static let warnTempC: Double = 52.0
    static let hotTempC: Double = 58.0

    let hottest: String
    let max_c: Double
    let mean_c: Double

    var isWarning: Bool { max_c >= Self.warnTempC }
    var isHot: Bool { max_c >= Self.hotTempC }
}

struct CpuThrottle: Codable, Sendable, Equatable {
    let level: UInt32
    let max_level: UInt32
    let khz: UInt32
    let max_khz: UInt32

    enum CodingKeys: String, CodingKey {
        case level
        case max_level
        case khz
        case max_khz
    }

    init(level: UInt32 = 0, max_level: UInt32 = 0, khz: UInt32 = 0, max_khz: UInt32 = 0) {
        self.level = level
        self.max_level = max_level
        self.khz = khz
        self.max_khz = max_khz
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decodeIfPresent(UInt32.self, forKey: .level) ?? 0
        max_level = try container.decodeIfPresent(UInt32.self, forKey: .max_level) ?? 0
        khz = try container.decodeIfPresent(UInt32.self, forKey: .khz) ?? 0
        max_khz = try container.decodeIfPresent(UInt32.self, forKey: .max_khz) ?? 0
    }

    var isThrottled: Bool {
        level > 0 || (max_khz > 0 && khz < max_khz)
    }
}

struct LoopHealth: Codable, Sendable, Equatable {
    let target_hz: Double
    let achieved_hz: Double?
    let ticks: UInt64
    let missed: UInt64
    let last_tick_age_ms: UInt64
}

struct BusHealth: Codable, Sendable, Equatable {
    let consecutive_errors: UInt32
    let startup_failures: UInt32
    let missing: [UInt8]

    enum CodingKeys: String, CodingKey {
        case consecutive_errors
        case startup_failures
        case missing
    }

    init(consecutive_errors: UInt32 = 0, startup_failures: UInt32 = 0, missing: [UInt8] = []) {
        self.consecutive_errors = consecutive_errors
        self.startup_failures = startup_failures
        self.missing = missing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        consecutive_errors = try container.decodeIfPresent(UInt32.self, forKey: .consecutive_errors) ?? 0
        startup_failures = try container.decodeIfPresent(UInt32.self, forKey: .startup_failures) ?? 0
        missing = try container.decodeIfPresent([UInt8].self, forKey: .missing) ?? []
    }
}

struct ImuHealth: Codable, Sendable, Equatable {
    static let frozenRun: UInt64 = 25

    let ready: Bool
    let stale_blocks: UInt64
    let consecutive_stale_blocks: UInt64
    let missing: Bool

    enum CodingKeys: String, CodingKey {
        case ready
        case stale_blocks
        case consecutive_stale_blocks
        case missing
    }

    init(
        ready: Bool = false,
        stale_blocks: UInt64 = 0,
        consecutive_stale_blocks: UInt64 = 0,
        missing: Bool = false
    ) {
        self.ready = ready
        self.stale_blocks = stale_blocks
        self.consecutive_stale_blocks = consecutive_stale_blocks
        self.missing = missing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ready = try container.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        stale_blocks = try container.decodeIfPresent(UInt64.self, forKey: .stale_blocks) ?? 0
        consecutive_stale_blocks = try container.decodeIfPresent(UInt64.self, forKey: .consecutive_stale_blocks) ?? 0
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
    }

    var isFrozen: Bool {
        consecutive_stale_blocks >= Self.frozenRun
    }
}

struct HealthResult: Codable, Sendable, Equatable {
    let healthy: Bool
    let degraded: Bool
    let reason: String?
    let battery: Battery?
    let goal_pwm: UInt16?
    let motors: MotorThermal?
    let cpu_temp_c: Double?
    let cpu_throttle: CpuThrottle?
    let control_loop: LoopHealth?
    let bus: BusHealth
    let imu: ImuHealth?

    enum CodingKeys: String, CodingKey {
        case healthy
        case degraded
        case reason
        case battery
        case goal_pwm
        case motors
        case cpu_temp_c
        case cpu_throttle
        case control_loop
        case bus
        case imu
    }

    init(
        healthy: Bool = false,
        degraded: Bool = false,
        reason: String? = nil,
        battery: Battery? = nil,
        goal_pwm: UInt16? = nil,
        motors: MotorThermal? = nil,
        cpu_temp_c: Double? = nil,
        cpu_throttle: CpuThrottle? = nil,
        control_loop: LoopHealth? = nil,
        bus: BusHealth = BusHealth(),
        imu: ImuHealth? = nil
    ) {
        self.healthy = healthy
        self.degraded = degraded
        self.reason = reason
        self.battery = battery
        self.goal_pwm = goal_pwm
        self.motors = motors
        self.cpu_temp_c = cpu_temp_c
        self.cpu_throttle = cpu_throttle
        self.control_loop = control_loop
        self.bus = bus
        self.imu = imu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        healthy = try container.decodeIfPresent(Bool.self, forKey: .healthy) ?? false
        degraded = try container.decodeIfPresent(Bool.self, forKey: .degraded) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        battery = try container.decodeIfPresent(Battery.self, forKey: .battery)
        goal_pwm = try container.decodeIfPresent(UInt16.self, forKey: .goal_pwm)
        motors = try container.decodeIfPresent(MotorThermal.self, forKey: .motors)
        cpu_temp_c = try container.decodeIfPresent(Double.self, forKey: .cpu_temp_c)
        cpu_throttle = try container.decodeIfPresent(CpuThrottle.self, forKey: .cpu_throttle)
        control_loop = try container.decodeIfPresent(LoopHealth.self, forKey: .control_loop)
        bus = try container.decodeIfPresent(BusHealth.self, forKey: .bus) ?? BusHealth()
        imu = try container.decodeIfPresent(ImuHealth.self, forKey: .imu)
    }
}

// MARK: - robot.state & robot.model

struct MoveState: Codable, Sendable, Equatable {
    let requested: [Double]
    let applied: [Double]
    let source: String?
    let limited_by: [String]

    enum CodingKeys: String, CodingKey {
        case requested
        case applied
        case source
        case limited_by
    }

    init(
        requested: [Double] = [0, 0, 0],
        applied: [Double] = [0, 0, 0],
        source: String? = nil,
        limited_by: [String] = []
    ) {
        self.requested = requested
        self.applied = applied
        self.source = source
        self.limited_by = limited_by
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requested = try container.decodeIfPresent([Double].self, forKey: .requested) ?? [0, 0, 0]
        applied = try container.decodeIfPresent([Double].self, forKey: .applied) ?? [0, 0, 0]
        source = try container.decodeIfPresent(String.self, forKey: .source)
        limited_by = try container.decodeIfPresent([String].self, forKey: .limited_by) ?? []
    }
}

struct SafetyState: Codable, Sendable, Equatable {
    let fallen: Bool
    let limp: Bool
    let gravity: [Double]
    let gain: UInt16?
    let picked_up: Bool

    enum CodingKeys: String, CodingKey {
        case fallen
        case limp
        case gravity
        case gain
        case picked_up
    }

    init(
        fallen: Bool = false,
        limp: Bool = false,
        gravity: [Double] = [0, 0, -1],
        gain: UInt16? = nil,
        picked_up: Bool = false
    ) {
        self.fallen = fallen
        self.limp = limp
        self.gravity = gravity
        self.gain = gain
        self.picked_up = picked_up
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fallen = try container.decodeIfPresent(Bool.self, forKey: .fallen) ?? false
        limp = try container.decodeIfPresent(Bool.self, forKey: .limp) ?? false
        gravity = try container.decodeIfPresent([Double].self, forKey: .gravity) ?? [0, 0, -1]
        gain = try container.decodeIfPresent(UInt16.self, forKey: .gain)
        picked_up = try container.decodeIfPresent(Bool.self, forKey: .picked_up) ?? false
    }
}

struct LoopState: Codable, Sendable, Equatable {
    let hz: Double
    let missed: UInt64
}

struct ImuState: Codable, Sendable, Equatable {
    let gyro: [Double]
    let quat: [Double]

    enum CodingKeys: String, CodingKey {
        case gyro
        case quat
    }

    init(gyro: [Double] = [0, 0, 0], quat: [Double] = [1, 0, 0, 0]) {
        self.gyro = gyro
        self.quat = quat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gyro = try container.decodeIfPresent([Double].self, forKey: .gyro) ?? [0, 0, 0]
        quat = try container.decodeIfPresent([Double].self, forKey: .quat) ?? [1, 0, 0, 0]
    }
}

struct OdomState: Codable, Sendable, Equatable {
    let position: [Double]
    let yaw: Double

    enum CodingKeys: String, CodingKey {
        case position
        case yaw
    }

    init(position: [Double] = [0, 0, 0], yaw: Double = 0) {
        self.position = position
        self.yaw = yaw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decodeIfPresent([Double].self, forKey: .position) ?? [0, 0, 0]
        yaw = try container.decodeIfPresent(Double.self, forKey: .yaw) ?? 0
    }
}

struct RobotState: Codable, Sendable, Equatable {
    let t: Double
    let movement: MoveState
    let head: [Double]
    let policy: String
    let safety: SafetyState
    let control_loop: LoopState
    let joints: [Double]
    let targets: [Double]
    let velocities: [Double]
    let currents_ma: [Double]
    let odom: OdomState
    let t_ns: UInt64
    let imu: ImuState?

    enum CodingKeys: String, CodingKey {
        case t
        case movement = "move"
        case head
        case policy
        case safety
        case control_loop = "loop"
        case joints
        case targets
        case velocities
        case currents_ma
        case odom
        case t_ns
        case imu
    }

    init(
        t: Double = 0,
        movement: MoveState = MoveState(),
        head: [Double] = [0, 0, 0, 0],
        policy: String = "held",
        safety: SafetyState = SafetyState(),
        control_loop: LoopState = LoopState(hz: 50, missed: 0),
        joints: [Double] = Array(repeating: 0, count: 15),
        targets: [Double] = Array(repeating: 0, count: 15),
        velocities: [Double] = [],
        currents_ma: [Double] = [],
        odom: OdomState = OdomState(),
        t_ns: UInt64 = 0,
        imu: ImuState? = nil
    ) {
        self.t = t
        self.movement = movement
        self.head = head
        self.policy = policy
        self.safety = safety
        self.control_loop = control_loop
        self.joints = joints
        self.targets = targets
        self.velocities = velocities
        self.currents_ma = currents_ma
        self.odom = odom
        self.t_ns = t_ns
        self.imu = imu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        t = try container.decodeIfPresent(Double.self, forKey: .t) ?? 0
        movement = try container.decodeIfPresent(MoveState.self, forKey: .movement) ?? MoveState()
        head = try container.decodeIfPresent([Double].self, forKey: .head) ?? [0, 0, 0, 0]
        policy = try container.decodeIfPresent(String.self, forKey: .policy) ?? "held"
        safety = try container.decodeIfPresent(SafetyState.self, forKey: .safety) ?? SafetyState()
        control_loop = try container.decodeIfPresent(LoopState.self, forKey: .control_loop) ?? LoopState(hz: 0, missed: 0)
        joints = try container.decodeIfPresent([Double].self, forKey: .joints) ?? []
        targets = try container.decodeIfPresent([Double].self, forKey: .targets) ?? []
        velocities = try container.decodeIfPresent([Double].self, forKey: .velocities) ?? []
        currents_ma = try container.decodeIfPresent([Double].self, forKey: .currents_ma) ?? []
        odom = try container.decodeIfPresent(OdomState.self, forKey: .odom) ?? OdomState()
        t_ns = try container.decodeIfPresent(UInt64.self, forKey: .t_ns) ?? 0
        imu = try container.decodeIfPresent(ImuState.self, forKey: .imu)
    }
}

struct ModelResult: Codable, Sendable, Equatable {
    let asset: String
    let trunk_height_m: Double
    let joint_names: [String]
    let head_joints: [String]
    let tof_beams: [[Double]]
    let tof_fov_deg: Double

    enum CodingKeys: String, CodingKey {
        case asset
        case trunk_height_m
        case joint_names
        case head_joints
        case tof_beams
        case tof_fov_deg
    }

    init(
        asset: String = "microduck",
        trunk_height_m: Double = 0.24,
        joint_names: [String] = MicroduckJoints.defaultNames,
        head_joints: [String] = ["neck_pitch", "head_pitch", "head_yaw", "head_roll"],
        tof_beams: [[Double]] = [],
        tof_fov_deg: Double = 45.0
    ) {
        self.asset = asset
        self.trunk_height_m = trunk_height_m
        self.joint_names = joint_names
        self.head_joints = head_joints
        self.tof_beams = tof_beams
        self.tof_fov_deg = tof_fov_deg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asset = try container.decodeIfPresent(String.self, forKey: .asset) ?? ""
        trunk_height_m = try container.decodeIfPresent(Double.self, forKey: .trunk_height_m) ?? 0
        joint_names = try container.decodeIfPresent([String].self, forKey: .joint_names) ?? MicroduckJoints.defaultNames
        head_joints = try container.decodeIfPresent([String].self, forKey: .head_joints) ?? []
        tof_beams = try container.decodeIfPresent([[Double]].self, forKey: .tof_beams) ?? []
        tof_fov_deg = try container.decodeIfPresent(Double.self, forKey: .tof_fov_deg) ?? 45.0
    }
}

// MARK: - tof.frame & head_imu.frame

struct TofFrame: Codable, Sendable, Equatable {
    let seq: UInt64
    let at_us: UInt64
    let t_ns: UInt64
    let rows: UInt8
    let cols: UInt8
    let distance_mm: [Int16]
    let status: [UInt8]

    enum CodingKeys: String, CodingKey {
        case seq
        case at_us
        case t_ns
        case rows
        case cols
        case distance_mm
        case status
    }

    init(
        seq: UInt64 = 0,
        at_us: UInt64 = 0,
        t_ns: UInt64 = 0,
        rows: UInt8 = 8,
        cols: UInt8 = 8,
        distance_mm: [Int16] = [],
        status: [UInt8] = []
    ) {
        self.seq = seq
        self.at_us = at_us
        self.t_ns = t_ns
        self.rows = rows
        self.cols = cols
        self.distance_mm = distance_mm
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        at_us = try container.decodeIfPresent(UInt64.self, forKey: .at_us) ?? 0
        t_ns = try container.decodeIfPresent(UInt64.self, forKey: .t_ns) ?? 0
        rows = try container.decodeIfPresent(UInt8.self, forKey: .rows) ?? 8
        cols = try container.decodeIfPresent(UInt8.self, forKey: .cols) ?? 8
        distance_mm = try container.decodeIfPresent([Int16].self, forKey: .distance_mm) ?? []
        status = try container.decodeIfPresent([UInt8].self, forKey: .status) ?? []
    }

    func isValidZone(at index: Int) -> Bool {
        guard index >= 0, index < distance_mm.count, index < status.count else {
            return false
        }
        let s = status[index]
        return (s == 5 || s == 9) && distance_mm[index] > 0
    }

    var nearestValidDistanceMeters: Double? {
        var bestMm: Int16?
        let count = min(distance_mm.count, status.count)
        for index in 0..<count where isValidZone(at: index) {
            let dist = distance_mm[index]
            if bestMm == nil || dist < bestMm! {
                bestMm = dist
            }
        }
        return bestMm.map { Double($0) / 1000.0 }
    }
}

struct HeadImuFrame: Codable, Sendable, Equatable {
    let seq: UInt64
    let at_us: UInt64
    let t_ns: UInt64
    let gyro: [Float]
    let accel: [Float]
    let quat: [Float]
    let temp_c: Float

    enum CodingKeys: String, CodingKey {
        case seq
        case at_us
        case t_ns
        case gyro
        case accel
        case quat
        case temp_c
    }

    init(
        seq: UInt64 = 0,
        at_us: UInt64 = 0,
        t_ns: UInt64 = 0,
        gyro: [Float] = [0, 0, 0],
        accel: [Float] = [0, 0, -9.81],
        quat: [Float] = [1, 0, 0, 0],
        temp_c: Float = 0
    ) {
        self.seq = seq
        self.at_us = at_us
        self.t_ns = t_ns
        self.gyro = gyro
        self.accel = accel
        self.quat = quat
        self.temp_c = temp_c
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        at_us = try container.decodeIfPresent(UInt64.self, forKey: .at_us) ?? 0
        t_ns = try container.decodeIfPresent(UInt64.self, forKey: .t_ns) ?? 0
        gyro = try container.decodeIfPresent([Float].self, forKey: .gyro) ?? [0, 0, 0]
        accel = try container.decodeIfPresent([Float].self, forKey: .accel) ?? [0, 0, 0]
        quat = try container.decodeIfPresent([Float].self, forKey: .quat) ?? [1, 0, 0, 0]
        temp_c = try container.decodeIfPresent(Float.self, forKey: .temp_c) ?? 0
    }

    var pitchRollDegrees: (pitch: Double, roll: Double) {
        QuackMath.pitchRollDegrees(fromWXYZ: quat.map(Double.init))
    }
}

// MARK: - net.*

enum NetState: String, Codable, Sendable, Equatable {
    case connected
    case connecting
    case disconnected
    case unavailable
}

enum JoinStep: String, Codable, Sendable, Equatable {
    case scanning
    case associating
    case authenticating
    case keyRejected = "key_rejected"
    case addressing

    var displayLabel: String {
        switch self {
        case .scanning: return "Scanning"
        case .associating: return "Associating"
        case .authenticating: return "Authenticating"
        case .keyRejected: return "Key rejected"
        case .addressing: return "Getting IP address"
        }
    }

    var stepIndex: Int {
        switch self {
        case .scanning: return 0
        case .associating: return 1
        case .authenticating, .keyRejected: return 2
        case .addressing: return 3
        }
    }
}

struct Joining: Codable, Sendable, Equatable {
    let ssid: String
    let step: JoinStep
    let elapsed_seconds: UInt32
    let timeout_seconds: UInt32
}

struct NetStatusResult: Codable, Sendable, Equatable {
    let state: NetState
    let ssid: String?
    let signal: UInt8?
    let ip4: String?
    let ip6: String?
    let mac: String?
    let iface: String?
    let joining: Joining?

    init(
        state: NetState = .disconnected,
        ssid: String? = nil,
        signal: UInt8? = nil,
        ip4: String? = nil,
        ip6: String? = nil,
        mac: String? = nil,
        iface: String? = nil,
        joining: Joining? = nil
    ) {
        self.state = state
        self.ssid = ssid
        self.signal = signal
        self.ip4 = ip4
        self.ip6 = ip6
        self.mac = mac
        self.iface = iface
        self.joining = joining
    }
}

enum WifiSecurity: String, Codable, Sendable, Equatable {
    case open
    case wep
    case wpaPsk = "wpa_psk"
    case wpa3Sae = "wpa3_sae"
    case enterprise

    var displayBadge: String {
        switch self {
        case .open: return "Open"
        case .wep: return "WEP"
        case .wpaPsk: return "WPA2"
        case .wpa3Sae: return "WPA3"
        case .enterprise: return "Enterprise"
        }
    }

    var isSupported: Bool {
        switch self {
        case .open, .wpaPsk, .wpa3Sae:
            return true
        case .wep, .enterprise:
            return false
        }
    }

    var requiresPassword: Bool {
        self == .wpaPsk || self == .wpa3Sae
    }
}

struct WifiNetwork: Codable, Sendable, Equatable, Identifiable {
    let ssid: String
    let signal: UInt8
    let security: WifiSecurity
    let saved: Bool

    var id: String { "\(ssid)-\(security.rawValue)" }
}

struct NetScanResult: Codable, Sendable, Equatable {
    let networks: [WifiNetwork]
}

enum ConnectFailure: String, Codable, Sendable, Equatable {
    case badKey = "bad_key"
    case notFound = "not_found"
    case timeout
    case unsupported
    case other

    var userMessage: String {
        switch self {
        case .badKey:
            return "Incorrect Wi-Fi password. Check the password and try again."
        case .notFound:
            return "Network not found. Move the robot closer and rescan."
        case .timeout:
            return "Timed out waiting for an IP address. Try joining again."
        case .unsupported:
            return "This Wi-Fi security type is not supported."
        case .other:
            return "Could not connect to this Wi-Fi network."
        }
    }
}

enum ConnectResult: Codable, Sendable, Equatable {
    case connected(ssid: String, ip4: String?)
    case failed(reason: ConnectFailure, detail: String?)

    private enum CodingKeys: String, CodingKey {
        case outcome
        case ssid
        case ip4
        case reason
        case detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        switch outcome {
        case "connected":
            let ssid = try container.decode(String.self, forKey: .ssid)
            let ip4 = try container.decodeIfPresent(String.self, forKey: .ip4)
            self = .connected(ssid: ssid, ip4: ip4)
        case "failed":
            let reason = try container.decode(ConnectFailure.self, forKey: .reason)
            let detail = try container.decodeIfPresent(String.self, forKey: .detail)
            self = .failed(reason: reason, detail: detail)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Unknown ConnectResult outcome: \(outcome)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connected(let ssid, let ip4):
            try container.encode("connected", forKey: .outcome)
            try container.encode(ssid, forKey: .ssid)
            try container.encodeIfPresent(ip4, forKey: .ip4)
        case .failed(let reason, let detail):
            try container.encode("failed", forKey: .outcome)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(detail, forKey: .detail)
        }
    }
}

struct ForgetResult: Codable, Sendable, Equatable {
    let removed: Bool
}

// MARK: - Robot intents, policies & media

struct IntentResult: Codable, Sendable, Equatable {
    let accepted: Bool
    let reason: String?

    init(accepted: Bool, reason: String? = nil) {
        self.accepted = accepted
        self.reason = reason
    }
}

struct PolicySlot: Codable, Sendable, Equatable {
    let slot: String
    let path: String?
    let origin: String?
    let overridden: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case slot
        case path
        case origin
        case overridden
        case error
    }

    init(
        slot: String = "",
        path: String? = nil,
        origin: String? = nil,
        overridden: Bool = false,
        error: String? = nil
    ) {
        self.slot = slot
        self.path = path
        self.origin = origin
        self.overridden = overridden
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slot = try container.decodeIfPresent(String.self, forKey: .slot) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path)
        origin = try container.decodeIfPresent(String.self, forKey: .origin)
        overridden = try container.decodeIfPresent(Bool.self, forKey: .overridden) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

struct PoliciesResult: Codable, Sendable, Equatable {
    let mode: String
    let enabled: Bool
    let slots: [PolicySlot]
    let skills: [String]
    let homed: Bool?
    let sitting: Bool?
    let change_error: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case enabled
        case slots
        case skills
        case homed
        case sitting
        case change_error
    }

    init(
        mode: String = "walk",
        enabled: Bool = true,
        slots: [PolicySlot] = [],
        skills: [String] = [],
        homed: Bool? = nil,
        sitting: Bool? = nil,
        change_error: String? = nil
    ) {
        self.mode = mode
        self.enabled = enabled
        self.slots = slots
        self.skills = skills
        self.homed = homed
        self.sitting = sitting
        self.change_error = change_error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        slots = try container.decodeIfPresent([PolicySlot].self, forKey: .slots) ?? []
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        homed = try container.decodeIfPresent(Bool.self, forKey: .homed)
        sitting = try container.decodeIfPresent(Bool.self, forKey: .sitting)
        change_error = try container.decodeIfPresent(String.self, forKey: .change_error)
    }

    var hasSitstandSlot: Bool {
        slots.contains { $0.slot == "sitstand" && $0.path != nil } || skills.contains("sit_toggle")
    }
}

struct SubscribeResult: Codable, Sendable, Equatable {
    let accepted: Bool
    let walk: String?
    let stand: String?
    let sitstand: String?
    let ground_pick: String?
    let skills: [String]
    let unavailable: String?

    enum CodingKeys: String, CodingKey {
        case accepted
        case walk
        case stand
        case sitstand
        case ground_pick
        case skills
        case unavailable
    }

    init(
        accepted: Bool = true,
        walk: String? = nil,
        stand: String? = nil,
        sitstand: String? = nil,
        ground_pick: String? = nil,
        skills: [String] = [],
        unavailable: String? = nil
    ) {
        self.accepted = accepted
        self.walk = walk
        self.stand = stand
        self.sitstand = sitstand
        self.ground_pick = ground_pick
        self.skills = skills
        self.unavailable = unavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? true
        walk = try container.decodeIfPresent(String.self, forKey: .walk)
        stand = try container.decodeIfPresent(String.self, forKey: .stand)
        sitstand = try container.decodeIfPresent(String.self, forKey: .sitstand)
        ground_pick = try container.decodeIfPresent(String.self, forKey: .ground_pick)
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        unavailable = try container.decodeIfPresent(String.self, forKey: .unavailable)
    }
}

struct HeadParams: Codable, Sendable, Equatable {
    let neck_pitch: Double
    let head_pitch: Double
    let head_yaw: Double
    let head_roll: Double
}

struct LookResult: Codable, Sendable, Equatable {
    let head: HeadParams
    let clamped: Bool
}

struct MediaVideoInfo: Codable, Sendable, Equatable {
    let width: Int
    let height: Int
    let rotate: Int
    let mono_ns: UInt64?
    let real_ns: UInt64?

    init(width: Int = 1280, height: Int = 720, rotate: Int = 0, mono_ns: UInt64? = nil, real_ns: UInt64? = nil) {
        self.width = width
        self.height = height
        self.rotate = rotate
        self.mono_ns = mono_ns
        self.real_ns = real_ns
    }
}

// MARK: - App & Discovery Models

struct DiscoveredDuck: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let advInfo: AdvInfo
    let rssi: Int
    let lastSeen: Date

    var isConnectable: Bool { !advInfo.isBusy }
    var hasNoWifi: Bool { advInfo.hasAddressField && advInfo.ipv4 == nil }
}

struct PairedDuck: Codable, Identifiable, Sendable, Equatable {
    let robotId: String
    var name: String
    var lastIp: String?
    var peripheralId: UUID?
    let pairedAt: Date
    var lastConnectedAt: Date?

    var id: String { robotId }

    init(
        robotId: String,
        name: String,
        lastIp: String? = nil,
        peripheralId: UUID? = nil,
        pairedAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.robotId = robotId
        self.name = name
        self.lastIp = lastIp
        self.peripheralId = peripheralId
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
    }
}

/// Unified UI cockpit state resolved from wire telemetry and local transition latches.
enum CockpitState: Equatable, Hashable, Sendable {
    case offline
    case syncing
    case hardwareBlocked(reason: String, homed: Bool)
    case limp(fallen: Bool)
    case initializing
    case calibratingImu(frozen: Bool)
    case readyHome(hasPolicy: Bool)
    case readySeated(hasPolicy: Bool)
    case walking(hasSitstand: Bool)
    case sittingDown
    case seated
    case rising
    case runningSkill(name: String)
    case pickedUp
    case fallenRecovering
    case fallenParked(disarmed: Bool)
    case resting(homed: Bool)
    case shuttingDown(homed: Bool)
}

/// Discrete cockpit actions triggered by posture and safety buttons.
enum CockpitAction: Equatable, Hashable, Sendable {
    case initMotors
    case walk
    case standFromSeat
    case hold
    case sit
    case standUp
    case relax
    case rest
    case shutdown
    case stopMoving
    case cancelRecovery
    case stopSkill
}

/// Safety framing for robot power-off confirmation copy and validation.
enum ShutdownConfirmationMode: Equatable, Hashable, Sendable {
    case immediateMotorsOff
    case sitAndPowerOff
    case restAndPowerOff
    case immediateCutTorque
}

/// Confirmation prompt presented before torque or experimental posture changes.
enum CockpitConfirmation: Identifiable, Equatable, Sendable {
    case initMotors
    case startWalk(hotTempC: Double?)
    case standFromHeldSeat(hotTempC: Double?)
    case sitExperimental
    case relaxDirect
    case relaxOrShutdown
    case relaxOrRest(isSeated: Bool)
    case shutdown(mode: ShutdownConfirmationMode)

    var id: String {
        switch self {
        case .initMotors:
            return "initMotors"
        case .startWalk:
            return "startWalk"
        case .standFromHeldSeat:
            return "standFromHeldSeat"
        case .sitExperimental:
            return "sitExperimental"
        case .relaxDirect:
            return "relaxDirect"
        case .relaxOrShutdown:
            return "relaxOrShutdown"
        case .relaxOrRest(let isSeated):
            return "relaxOrRest-\(isSeated)"
        case .shutdown(let mode):
            return "shutdown-\(mode)"
        }
    }
}

/// Visual severity tone for the single-line cockpit guidance strip.
enum GuidanceTone: Equatable, Sendable {
    case neutral
    case caution
    case danger
}

/// Pure, priority-ordered resolver mapping robot wire signals and edge latches to `CockpitState`.
enum CockpitStateResolver {
    static func isHardBlocked(_ health: HealthResult) -> Bool {
        if health.bus.startup_failures > 0 { return true }
        if health.control_loop?.ticks == 0 { return true }
        if !health.bus.missing.isEmpty { return true }
        if health.imu?.missing == true { return true }
        if health.degraded, let reason = health.reason, reason.contains("torque stays off") {
            return true
        }
        return false
    }

    static func hasWalkPolicy(policies: PoliciesResult?, subscribeAck: SubscribeResult?) -> Bool {
        guard let policies, policies.enabled else { return false }
        if subscribeAck?.unavailable != nil {
            return false
        }
        if let walkSlot = policies.slots.first(where: { $0.slot == "walk" }) {
            return walkSlot.path != nil
        }
        if let subscribeAck {
            return subscribeAck.walk != nil
        }
        return true
    }

    static func hasSitstand(policies: PoliciesResult?, subscribeAck: SubscribeResult?) -> Bool {
        if let policies {
            if policies.hasSitstandSlot {
                return true
            }
            if policies.slots.contains(where: { $0.slot == "sitstand" && $0.path == nil }) {
                return false
            }
        }
        return subscribeAck?.sitstand != nil
    }

    static func resolve(
        phase: ConnectionPhase,
        health: HealthResult?,
        policies: PoliciesResult?,
        subscribeAck: SubscribeResult?,
        robotState: RobotState?,
        awaitingPostHomingPolicies: Bool = false,
        isSitSettling: Bool = false,
        isAutoRising: Bool = false,
        isRestingPending: Bool = false,
        isShutdownPending: Bool = false,
        disarmedWhileFallen: Bool = false
    ) -> CockpitState {
        // 1. Offline / Connecting
        guard phase.isConnected else {
            return .offline
        }

        // 2. Shutting Down (takes precedence even from hardware-blocked or limp states until link drops)
        if isShutdownPending {
            return .shuttingDown(homed: policies?.homed == true)
        }

        // 3. Hardware Blocked (evaluated immediately from health without waiting for robot.state)
        if let health, isHardBlocked(health) {
            let trimmed = health.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = (trimmed?.isEmpty == false ? trimmed : nil) ?? "check battery/motors"
            return .hardwareBlocked(reason: reason, homed: policies?.homed == true)
        }

        // 3. Initial Sync Gate
        guard let health, let policies, let robotState else {
            return .syncing
        }

        let policy = robotState.policy
        let fallen = robotState.safety.fallen
        let pickedUp = robotState.safety.picked_up
        let sitstandAvailable = hasSitstand(policies: policies, subscribeAck: subscribeAck)
        let walkPolicyAvailable = hasWalkPolicy(policies: policies, subscribeAck: subscribeAck)

        // 4. Resting / Shutting Down
        if policy == "rest" || (isRestingPending && policy == "sit") {
            return .resting(homed: policies.homed == true)
        }

        // 5. Initializing (Homing ramp + brief post-homing policy refresh latch)
        if policy == "homing" || awaitingPostHomingPolicies {
            return .initializing
        }

        // 6. Limp — Motors Off (gated on policy == "held" to avoid stale homed == false flicker)
        if policy == "held" && policies.homed == false {
            return .limp(fallen: fallen)
        }

        // 7. Fallen — Recovering (covers limp_fall, limp_pose, self-righting retries, seated tip-over)
        if policy == "limp_fall" || policy == "limp_pose" || (policy != "held" && policy != "homing" && policy != "rest" && fallen) {
            return .fallenRecovering
        }

        // 8. Fallen — Parked
        if policy == "held" && fallen {
            return .fallenParked(disarmed: disarmedWhileFallen)
        }

        // 9. Picked Up — Paused
        if pickedUp {
            return .pickedUp
        }

        // 10. Rising (direct rise or settle_then_rise from U4c)
        if policy == "rise" || (isAutoRising && policy == "sit") {
            return .rising
        }

        // 11. Sitting Down (observed non-sit -> sit edge within 2.2 s settle window)
        if policy == "sit" && isSitSettling {
            return .sittingDown
        }

        // 12. Seated
        if policy == "sit" {
            return .seated
        }

        // 13. Walking — Active
        if policy == "walk" || policy == "stand" {
            return .walking(hasSitstand: sitstandAvailable)
        }

        // 14. Running Skill
        if policy != "held" {
            return .runningSkill(name: policy)
        }

        // 15. Calibrating IMU
        if health.imu?.ready == false {
            return .calibratingImu(frozen: health.imu?.isFrozen == true)
        }

        // 16. Ready — Held in Seat
        if policies.sitting == true {
            return .readySeated(hasPolicy: walkPolicyAvailable)
        }

        // 17. Ready — Holding Pose
        return .readyHome(hasPolicy: walkPolicyAvailable)
    }
}

enum ConnectionPhase: Equatable, Sendable {
    case disconnected
    case scanning
    case connectingBle
    case authenticatingBle
    case configuringWifi
    case connectingLan
    case connectingVideo
    case connected(transportLabel: String)
    case error(String)

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    var shortLabel: String {
        switch self {
        case .disconnected: return "Offline"
        case .scanning: return "Scanning"
        case .connectingBle: return "BLE..."
        case .authenticatingBle: return "Auth..."
        case .configuringWifi: return "Wi-Fi"
        case .connectingLan: return "LAN..."
        case .connectingVideo: return "Video..."
        case .connected(let label): return label
        case .error: return "Error"
        }
    }
}

// MARK: - Math helpers

enum QuackMath {
    static func pitchRollDegrees(fromWXYZ q: [Double]) -> (pitch: Double, roll: Double) {
        guard q.count >= 4 else { return (0, 0) }
        let w = q[0]
        let x = q[1]
        let y = q[2]
        let z = q[3]

        let sinrCosp = 2.0 * (w * x + y * z)
        let cosrCosp = 1.0 - 2.0 * (x * x + y * y)
        let rollRad = atan2(sinrCosp, cosrCosp)

        let sinp = 2.0 * (w * y - z * x)
        let pitchRad: Double
        if abs(sinp) >= 1.0 {
            pitchRad = copysign(.pi / 2.0, sinp)
        } else {
            pitchRad = asin(sinp)
        }
        let radToDeg = 180.0 / .pi
        return (pitchRad * radToDeg, rollRad * radToDeg)
    }

    static func pitchRollDegrees(fromGravity g: [Double]) -> (pitch: Double, roll: Double) {
        guard g.count >= 3 else { return (0, 0) }
        let gx = g[0]
        let gy = g[1]
        let gz = g[2]
        let radToDeg = 180.0 / .pi
        let pitch = atan2(gx, -gz) * radToDeg
        let roll = atan2(gy, hypot(gx, gz)) * radToDeg
        return (pitch, roll)
    }
}
