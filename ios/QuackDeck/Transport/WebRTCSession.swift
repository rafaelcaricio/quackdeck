import Foundation
import WebRTC

/// Wraps Apple's default decoder factory and adds H.264 High profile (`64001f`)
/// alongside `640c1f` and `42e01f` so hardware encoders such as `omxh264videoenc`
/// decode in VideoToolbox without software fallback or server-side transcode.
final class H264HighProfileVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let baseFactory = RTCDefaultVideoDecoderFactory()

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        var codecs = baseFactory.supportedCodecs()
        let requiredProfiles = ["64001f", "640c1f", "42e01f"]

        var h264Entries: [RTCVideoCodecInfo] = []
        var otherEntries: [RTCVideoCodecInfo] = []

        for codec in codecs {
            if codec.name.caseInsensitiveCompare(kRTCVideoCodecH264Name) == .orderedSame {
                h264Entries.append(codec)
            } else {
                otherEntries.append(codec)
            }
        }

        for profile in requiredProfiles.reversed() {
            let exists = h264Entries.contains { codec in
                codec.parameters["profile-level-id"]?.lowercased() == profile
            }
            if !exists {
                let info = RTCVideoCodecInfo(
                    name: kRTCVideoCodecH264Name,
                    parameters: [
                        "profile-level-id": profile,
                        "level-asymmetry-allowed": "1",
                        "packetization-mode": "1"
                    ]
                )
                h264Entries.insert(info, at: 0)
            }
        }

        // Keep High profile 64001f prioritized first among H.264 profiles.
        h264Entries.sort { lhs, rhs in
            let lProfile = lhs.parameters["profile-level-id"]?.lowercased() ?? ""
            let rProfile = rhs.parameters["profile-level-id"]?.lowercased() ?? ""
            let lRank = requiredProfiles.firstIndex(of: lProfile) ?? Int.max
            let rRank = requiredProfiles.firstIndex(of: rProfile) ?? Int.max
            return lRank < rRank
        }

        codecs = h264Entries + otherEntries
        return codecs
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        if info.name.caseInsensitiveCompare(kRTCVideoCodecH264Name) == .orderedSame {
            if let profile = info.parameters["profile-level-id"]?.lowercased(),
               profile == "64001f" {
                let constrainedEquivalent = RTCVideoCodecInfo(
                    name: kRTCVideoCodecH264Name,
                    parameters: [
                        "profile-level-id": "640c1f",
                        "level-asymmetry-allowed": "1",
                        "packetization-mode": info.parameters["packetization-mode"] ?? "1"
                    ]
                )
                return baseFactory.createDecoder(constrainedEquivalent) ?? RTCVideoDecoderH264()
            }
            return baseFactory.createDecoder(info) ?? RTCVideoDecoderH264()
        }
        return baseFactory.createDecoder(info)
    }
}

enum WebRTCSessionError: LocalizedError {
    case controlChannelClosed
    case controlCallTimeout(String)
    case controlRpcError(code: Int?, message: String)
    case peerConnectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .controlChannelClosed:
            return "Robot control channel is closed."
        case .controlCallTimeout(let method):
            return "\(method) did not answer."
        case .controlRpcError(_, let message):
            return message
        case .peerConnectionFailed(let detail):
            return detail
        }
    }
}

@MainActor
private final class WebRTCResumableBox<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var onCleanup: (() -> Void)?

    var isResolved: Bool {
        result != nil
    }

    func arm(
        continuation: CheckedContinuation<T, Error>,
        onCleanup: @escaping () -> Void
    ) {
        self.onCleanup = onCleanup
        if let result {
            self.continuation = nil
            self.onCleanup = nil
            onCleanup()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
    }

    func startTimeout(seconds: TimeInterval, method: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            let ns = UInt64(max(0.5, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            self.resolve(with: .failure(WebRTCSessionError.controlCallTimeout(method)))
        }
    }

    func resolve(with result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeoutTask?.cancel()
        timeoutTask = nil
        let cleanup = onCleanup
        onCleanup = nil
        cleanup?()
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}

@MainActor
final class WebRTCSession: NSObject {
    private struct EndpointConfig: Equatable {
        let host: String
        let port: UInt16
        let robotId: String
        let pskHex: String
    }

    private static let reconnectBackoffSeconds: [Int] = [1, 2, 3, 5, 8, 10]
    private static let connectWatchdogSeconds: TimeInterval = 12.0
    private static let firstFrameWatchdogSeconds: TimeInterval = 12.0

    private static let sharedFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: H264HighProfileVideoDecoderFactory()
        )
    }()

    var onVideoTrackChanged: ((RTCVideoTrack?) -> Void)?
    var onControlChannelOpen: (() -> Void)?
    var onControlChannelClosed: (() -> Void)?
    var onNotification: ((_ method: String, _ params: [String: Any]) -> Void)?
    var onVideoStats: ((_ fps: Double) -> Void)?
    var onFirstFrameTimeoutChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onReconnecting: ((_ attempt: Int, _ delaySeconds: Int, _ reason: String) -> Void)?

    private var endpoint: EndpointConfig?
    private var signallingClient: SignallingClient?
    private var signallingTask: Task<Void, Never>?
    private var signallingSendQueue: [String] = []
    private var signallingSendTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectWatchdogTask: Task<Void, Never>?
    private var firstFrameWatchdogTask: Task<Void, Never>?
    private var iceDisconnectGraceTask: Task<Void, Never>?
    private var stabilityResetTask: Task<Void, Never>?

    private var peerConnection: RTCPeerConnection?
    private var controlChannel: RTCDataChannel?
    private var currentVideoTrack: RTCVideoTrack?

    private var sessionId: String?
    private var startingSession = false
    private var shouldStayConnected = false
    private var expectingPeerShutdown = false
    private var isTearingDown = false
    private var sessionGeneration: UInt64 = 0
    private var didNotifyControlOpenForGeneration = false
    private var isFirstFrameTimedOut = false

    private var nextRpcId: Int = 1
    private var pendingRpc: [Int: (Result<Data, Error>) -> Void] = [:]

    // Frozen-frame watchdog (matches upstream mediad console: 1000 ms after first decoded frame)
    private var lastDecodedFrames: Int64 = 0
    private var lastFrameProgressAt: Date = Date()
    private var freezeArmed: Bool = false
    private var lastStatsTimestampUs: Double = 0
    private var lastStatsFramesDecoded: Int64 = 0
    private var reconnectAttempts: Int = 0

    func start(host: String, port: UInt16 = 9443, robotId: String, pskHex: String) {
        let config = EndpointConfig(host: host, port: port, robotId: robotId, pskHex: pskHex)
        endpoint = config
        reconnectAttempts = 0
        expectingPeerShutdown = false
        shouldStayConnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        beginSession(config)
    }

    func forceReconnectNow() {
        guard let endpoint else { return }
        expectingPeerShutdown = false
        shouldStayConnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        beginSession(endpoint)
    }

    /// Disables automatic reconnect while keeping the active WebRTC session open
    /// so a graceful robot shutdown can stream until the peer powers off.
    func prepareForExpectedShutdown() {
        expectingPeerShutdown = true
        shouldStayConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        iceDisconnectGraceTask?.cancel()
        iceDisconnectGraceTask = nil
    }

    func resumeAutoReconnect() {
        guard endpoint != nil else { return }
        expectingPeerShutdown = false
        shouldStayConnected = true
    }

    func stop() {
        expectingPeerShutdown = false
        shouldStayConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownTransport()
        endpoint = nil
        reconnectAttempts = 0
    }

    var isControlOpen: Bool {
        controlChannel?.readyState == .open
    }

    func call(method: String, params: [String: Any] = [:], timeoutSeconds: TimeInterval = 10) async throws -> Data {
        guard let channel = controlChannel, channel.readyState == .open else {
            throw WebRTCSessionError.controlChannelClosed
        }

        let id = nextRpcId
        nextRpcId += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let wireData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let buffer = RTCDataBuffer(data: wireData, isBinary: false)

        let box = WebRTCResumableBox<Data>()
        box.startTimeout(seconds: timeoutSeconds, method: method)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingRpc[id] = { [weak box] result in
                    box?.resolve(with: result)
                }
                box.arm(continuation: continuation) { [weak self] in
                    self?.pendingRpc.removeValue(forKey: id)
                }

                if !box.isResolved, !channel.sendData(buffer) {
                    if let cb = self.pendingRpc.removeValue(forKey: id) {
                        cb(.failure(WebRTCSessionError.controlChannelClosed))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                box.resolve(with: .failure(CancellationError()))
            }
        }
    }

    func tell(method: String, params: [String: Any] = [:]) {
        guard let channel = controlChannel, channel.readyState == .open else { return }
        let id = nextRpcId
        nextRpcId += 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        guard let wireData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        let buffer = RTCDataBuffer(data: wireData, isBinary: false)
        _ = channel.sendData(buffer)
    }

    // MARK: - Signalling & PeerConnection lifecycle

    private func beginSession(_ config: EndpointConfig) {
        teardownTransport()
        let generation = sessionGeneration
        isTearingDown = false
        sessionId = nil
        startingSession = false
        freezeArmed = false
        lastDecodedFrames = 0
        lastFrameProgressAt = Date()
        lastStatsTimestampUs = 0
        lastStatsFramesDecoded = 0

        startConnectWatchdog(generation: generation)

        signallingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await Task.detached(priority: .userInitiated) {
                    try SignallingClient(
                        host: config.host,
                        port: config.port,
                        robotId: config.robotId,
                        pskHex: config.pskHex,
                        timeoutMs: 5000
                    )
                }.value

                guard !Task.isCancelled,
                      self.shouldStayConnected,
                      !self.isTearingDown,
                      generation == self.sessionGeneration else {
                    return
                }
                self.signallingClient = client

                while !Task.isCancelled && (self.shouldStayConnected || self.expectingPeerShutdown) && generation == self.sessionGeneration {
                    let event = try await Task.detached(priority: .userInitiated) {
                        try client.nextEvent(timeoutMs: 250)
                    }.value

                    guard !Task.isCancelled,
                          (self.shouldStayConnected || self.expectingPeerShutdown),
                          !self.isTearingDown,
                          generation == self.sessionGeneration else {
                        break
                    }
                    switch event {
                    case .message(let text):
                        await self.handleSignallingMessage(text, generation: generation)
                    case .closed(let reason):
                        if self.expectingPeerShutdown && !self.isTearingDown && generation == self.sessionGeneration {
                            self.finishExpectedPeerShutdown()
                            return
                        }
                        if self.shouldStayConnected && !self.isTearingDown && generation == self.sessionGeneration {
                            self.onError?(reason)
                            self.scheduleReconnect(reason: reason)
                        }
                        return
                    case .timeout:
                        continue
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      !self.isTearingDown,
                      generation == self.sessionGeneration else {
                    return
                }
                if self.expectingPeerShutdown {
                    self.finishExpectedPeerShutdown()
                    return
                }
                guard self.shouldStayConnected else {
                    return
                }
                let reason = error.localizedDescription
                self.onError?(reason)
                self.scheduleReconnect(reason: reason)
            }
        }
    }

    private func startConnectWatchdog(generation: UInt64) {
        connectWatchdogTask?.cancel()
        connectWatchdogTask = Task { [weak self] in
            let ns = UInt64(Self.connectWatchdogSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard let self,
                  !Task.isCancelled,
                  self.shouldStayConnected,
                  !self.isTearingDown,
                  self.sessionGeneration == generation,
                  !self.isControlOpen else {
                return
            }
            self.onError?("Video connection timed out.")
            self.scheduleReconnect(reason: "Video connection timed out.")
        }
    }

    private func teardownTransport() {
        isTearingDown = true
        sessionGeneration &+= 1
        didNotifyControlOpenForGeneration = false

        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil

        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        if isFirstFrameTimedOut {
            isFirstFrameTimedOut = false
            onFirstFrameTimeoutChanged?(false)
        }

        iceDisconnectGraceTask?.cancel()
        iceDisconnectGraceTask = nil

        stabilityResetTask?.cancel()
        stabilityResetTask = nil

        statsTask?.cancel()
        statsTask = nil

        signallingSendTask?.cancel()
        signallingSendTask = nil
        signallingSendQueue.removeAll()

        signallingTask?.cancel()
        signallingTask = nil
        signallingClient = nil

        let pending = pendingRpc
        pendingRpc.removeAll()
        for (_, cb) in pending {
            cb(.failure(WebRTCSessionError.controlChannelClosed))
        }

        if let controlChannel {
            controlChannel.delegate = nil
            controlChannel.close()
        }
        controlChannel = nil

        if let peerConnection {
            peerConnection.delegate = nil
            peerConnection.close()
        }
        peerConnection = nil

        if currentVideoTrack != nil {
            currentVideoTrack = nil
            onVideoTrackChanged?(nil)
        }
        sessionId = nil
        startingSession = false
    }

    private func sendSignalling(_ dict: [String: Any]) {
        guard signallingClient != nil,
              let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        signallingSendQueue.append(text)
        drainSignallingQueue()
    }

    private func drainSignallingQueue() {
        guard signallingSendTask == nil else { return }
        let generation = sessionGeneration
        signallingSendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.signallingSendTask = nil }

            while !Task.isCancelled,
                  generation == self.sessionGeneration,
                  !self.isTearingDown,
                  !self.signallingSendQueue.isEmpty,
                  let client = self.signallingClient {
                let nextText = self.signallingSendQueue.removeFirst()
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try client.send(text: nextText)
                    }.value
                } catch {
                    guard !Task.isCancelled,
                          generation == self.sessionGeneration,
                          !self.isTearingDown else {
                        return
                    }
                    if self.expectingPeerShutdown {
                        self.finishExpectedPeerShutdown()
                        return
                    }
                    let reason = error.localizedDescription
                    self.onError?(reason)
                    self.scheduleReconnect(reason: reason)
                    return
                }
            }
        }
    }

    private func handleSignallingMessage(_ raw: String, generation: UInt64) async {
        guard generation == sessionGeneration,
              (shouldStayConnected || expectingPeerShutdown),
              !isTearingDown else {
            return
        }
        guard let data = raw.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else {
            return
        }

        switch type {
        case "welcome":
            sendSignalling(["type": "list"])

        case "list":
            guard shouldStayConnected, sessionId == nil, !startingSession else { return }
            let producers = (msg["producers"] as? [[String: Any]]) ?? []
            guard let first = producers.first, let peerId = first["id"] as? String else {
                let reason = "Robot camera stream is not ready yet."
                onError?(reason)
                scheduleReconnect(reason: reason)
                return
            }
            startingSession = true
            sendSignalling(["type": "startSession", "peerId": peerId])

        case "sessionStarted":
            startingSession = false
            guard let sid = msg["sessionId"] as? String else { return }
            sessionId = sid
            createPeerConnection(generation: generation)

        case "peer":
            guard let pc = peerConnection else { return }
            if let sdpDict = msg["sdp"] as? [String: Any],
               let sdpTypeString = sdpDict["type"] as? String,
               let sdpString = sdpDict["sdp"] as? String {
                let sdpType = RTCSessionDescription.type(for: sdpTypeString)
                let remoteDesc = RTCSessionDescription(type: sdpType, sdp: sdpString)
                do {
                    try await setRemoteDescription(pc, description: remoteDesc)
                    guard generation == self.sessionGeneration,
                          self.peerConnection === pc,
                          !self.isTearingDown else { return }
                    if sdpType == .offer {
                        let answer = try await createAnswer(pc)
                        guard generation == self.sessionGeneration,
                              self.peerConnection === pc,
                              !self.isTearingDown else { return }
                        try await setLocalDescription(pc, description: answer)
                        guard generation == self.sessionGeneration,
                              self.peerConnection === pc,
                              !self.isTearingDown else { return }
                        if let sid = sessionId {
                            sendSignalling([
                                "type": "peer",
                                "sessionId": sid,
                                "sdp": [
                                    "type": "answer",
                                    "sdp": answer.sdp
                                ]
                            ])
                        }
                    }
                } catch {
                    guard generation == self.sessionGeneration, !self.isTearingDown else { return }
                    onError?(error.localizedDescription)
                    scheduleReconnect(reason: error.localizedDescription)
                }
            } else if let iceDict = msg["ice"] as? [String: Any],
                      let candidateStr = iceDict["candidate"] as? String {
                let mLineIndex = (iceDict["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
                let sdpMid = iceDict["sdpMid"] as? String
                let candidate = RTCIceCandidate(sdp: candidateStr, sdpMLineIndex: mLineIndex, sdpMid: sdpMid)
                try? await addIceCandidate(pc, candidate: candidate)
            }

        case "endSession":
            sessionId = nil
            startingSession = false
            if expectingPeerShutdown {
                finishExpectedPeerShutdown()
                return
            }
            let wasOpen = isControlOpen
            teardownTransport()
            if wasOpen {
                onControlChannelClosed?()
            }
            scheduleReconnect(reason: "Video session ended by robot.")

        case "error":
            let details = (msg["details"] as? String) ?? "Signalling error from robot."
            onError?(details)
            if !isControlOpen {
                scheduleReconnect(reason: details)
            }

        default:
            break
        }
    }

    private func createPeerConnection(generation: UInt64) {
        let config = RTCConfiguration()
        // LAN connection: empty iceServers avoids external STUN round trips.
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.sharedFactory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        ) else {
            let reason = "Could not initialize WebRTC peer connection."
            onError?(reason)
            scheduleReconnect(reason: reason)
            return
        }

        self.peerConnection = pc
        startStatsPolling(generation: generation, peerConnection: pc)
    }

    private func startStatsPolling(generation: UInt64, peerConnection pc: RTCPeerConnection) {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self,
                      !Task.isCancelled,
                      generation == self.sessionGeneration,
                      self.peerConnection === pc else {
                    break
                }
                let report = await self.gatherStatistics(pc)
                guard !Task.isCancelled,
                      generation == self.sessionGeneration,
                      self.peerConnection === pc,
                      !self.isTearingDown else {
                    break
                }
                self.processStatisticsReport(report, connectionState: pc.connectionState)
            }
        }
    }

    private func processStatisticsReport(
        _ report: RTCStatisticsReport,
        connectionState: RTCPeerConnectionState
    ) {
        var inboundVideo: RTCStatistics?
        for (_, stat) in report.statistics {
            if stat.type == "inbound-rtp" {
                let kind = (stat.values["kind"] as? String) ?? (stat.values["mediaType"] as? String)
                if kind == "video" {
                    inboundVideo = stat
                    break
                }
            }
        }

        guard let inboundVideo else { return }

        let framesDecoded = (inboundVideo.values["framesDecoded"] as? NSNumber)?.int64Value ?? 0
        let reportedFps = (inboundVideo.values["framesPerSecond"] as? NSNumber)?.doubleValue

        if let reportedFps {
            onVideoStats?(reportedFps)
        } else if lastStatsTimestampUs > 0 && inboundVideo.timestamp_us > lastStatsTimestampUs {
            let dt = (inboundVideo.timestamp_us - lastStatsTimestampUs) / 1_000_000.0
            let df = Double(framesDecoded - lastStatsFramesDecoded)
            if dt > 0 && df >= 0 {
                onVideoStats?(df / dt)
            }
        }
        lastStatsTimestampUs = inboundVideo.timestamp_us
        lastStatsFramesDecoded = framesDecoded

        guard connectionState == .connected else { return }
        let now = Date()
        if framesDecoded != lastDecodedFrames {
            lastDecodedFrames = framesDecoded
            lastFrameProgressAt = now
            if framesDecoded > 0 {
                freezeArmed = true
                firstFrameWatchdogTask?.cancel()
                firstFrameWatchdogTask = nil
                if isFirstFrameTimedOut {
                    isFirstFrameTimedOut = false
                    onFirstFrameTimeoutChanged?(false)
                }
                if isControlOpen {
                    reconnectAttempts = 0
                }
            }
            return
        }

        let stallThreshold: TimeInterval = expectingPeerShutdown ? 2.0 : 1.0
        if freezeArmed && now.timeIntervalSince(lastFrameProgressAt) >= stallThreshold {
            freezeArmed = false
            if expectingPeerShutdown {
                finishExpectedPeerShutdown()
            } else {
                scheduleReconnect(reason: "Video stream stalled")
            }
        }
    }

    private func finishExpectedPeerShutdown() {
        guard expectingPeerShutdown else { return }
        expectingPeerShutdown = false
        shouldStayConnected = false
        teardownTransport()
        onControlChannelClosed?()
    }

    private func scheduleReconnect(reason: String) {
        guard shouldStayConnected, let endpoint else { return }
        guard reconnectTask == nil else { return }

        teardownTransport()
        reconnectAttempts += 1
        let index = min(reconnectAttempts - 1, Self.reconnectBackoffSeconds.count - 1)
        let delaySeconds = Self.reconnectBackoffSeconds[max(0, index)]

        onReconnecting?(reconnectAttempts, delaySeconds, reason)

        reconnectTask = Task { [weak self] in
            let ns = UInt64(delaySeconds) * 1_000_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard let self else { return }
            self.reconnectTask = nil
            guard !Task.isCancelled, self.shouldStayConnected, self.endpoint == endpoint else { return }
            self.beginSession(endpoint)
        }
    }

    private func handleControlChannelDidOpen(generation: UInt64) {
        guard !didNotifyControlOpenForGeneration,
              generation == sessionGeneration,
              !isTearingDown else {
            return
        }
        didNotifyControlOpenForGeneration = true
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil

        if lastDecodedFrames == 0 && !expectingPeerShutdown {
            startFirstFrameWatchdog(generation: generation)
        }

        stabilityResetTask?.cancel()
        stabilityResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.sessionGeneration == generation,
                  self.isControlOpen else {
                return
            }
            self.reconnectAttempts = 0
        }

        onControlChannelOpen?()
    }

    private func startFirstFrameWatchdog(generation: UInt64) {
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = Task { [weak self] in
            let ns = UInt64(Self.firstFrameWatchdogSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard let self,
                  !Task.isCancelled,
                  !self.isTearingDown,
                  self.sessionGeneration == generation,
                  self.isControlOpen,
                  self.lastDecodedFrames == 0,
                  !self.expectingPeerShutdown else {
                return
            }
            self.isFirstFrameTimedOut = true
            self.onFirstFrameTimeoutChanged?(true)
            self.onError?("Camera stream did not start (control still active).")
        }
    }

    // MARK: - Async wrappers for RTCPeerConnection callbacks

    private func setRemoteDescription(_ pc: RTCPeerConnection, description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func createAnswer(_ pc: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: WebRTCSessionError.peerConnectionFailed("Missing SDP answer."))
                }
            }
        }
    }

    private func setLocalDescription(_ pc: RTCPeerConnection, description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func addIceCandidate(_ pc: RTCPeerConnection, candidate: RTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func gatherStatistics(_ pc: RTCPeerConnection) async -> RTCStatisticsReport {
        await withCheckedContinuation { continuation in
            pc.statistics { report in
                continuation.resume(returning: report)
            }
        }
    }

    private func handleControlMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Notification (no id)
        if object["id"] == nil || object["id"] is NSNull {
            if let method = object["method"] as? String {
                let params = (object["params"] as? [String: Any]) ?? [:]
                onNotification?(method, params)
            }
            return
        }

        guard let id = object["id"] as? Int,
              let cb = pendingRpc.removeValue(forKey: id) else {
            return
        }

        if let errObj = object["error"] as? [String: Any] {
            let code = errObj["code"] as? Int
            let message = (errObj["message"] as? String) ?? "Control channel error"
            cb(.failure(WebRTCSessionError.controlRpcError(code: code, message: message)))
            return
        }

        if let result = object["result"],
           let resultData = try? JSONSerialization.data(withJSONObject: result, options: []) {
            cb(.success(resultData))
        } else {
            cb(.success(Data("{}".utf8)))
        }
    }
}

extension WebRTCSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let track = stream.videoTracks.first
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isTearingDown else { return }
            if let track, self.currentVideoTrack !== track {
                self.currentVideoTrack = track
                self.onVideoTrackChanged?(track)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.peerConnection === peerConnection,
                  (self.shouldStayConnected || self.expectingPeerShutdown),
                  !self.isTearingDown else {
                return
            }
            let generation = self.sessionGeneration

            switch newState {
            case .connected:
                self.iceDisconnectGraceTask?.cancel()
                self.iceDisconnectGraceTask = nil

            case .disconnected:
                self.iceDisconnectGraceTask?.cancel()
                let graceNs: UInt64 = self.expectingPeerShutdown ? 2_000_000_000 : 3_000_000_000
                self.iceDisconnectGraceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: graceNs)
                    guard let self,
                          !Task.isCancelled,
                          self.sessionGeneration == generation,
                          self.peerConnection === peerConnection,
                          (self.shouldStayConnected || self.expectingPeerShutdown),
                          !self.isTearingDown,
                          peerConnection.connectionState == .disconnected else {
                        return
                    }
                    if self.expectingPeerShutdown {
                        self.finishExpectedPeerShutdown()
                        return
                    }
                    let reason = "WebRTC media connection lost."
                    self.onError?(reason)
                    self.scheduleReconnect(reason: reason)
                }

            case .failed, .closed:
                if self.expectingPeerShutdown {
                    self.finishExpectedPeerShutdown()
                    return
                }
                let reason = "WebRTC media connection failed; reconnecting..."
                self.onError?(reason)
                self.scheduleReconnect(reason: reason)

            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let sdp = candidate.sdp
        let mLineIndex = candidate.sdpMLineIndex
        Task { @MainActor [weak self] in
            guard let self,
                  self.peerConnection === peerConnection,
                  !self.isTearingDown,
                  let sid = self.sessionId else {
                return
            }
            self.sendSignalling([
                "type": "peer",
                "sessionId": sid,
                "ice": [
                    "candidate": sdp,
                    "sdpMLineIndex": mLineIndex
                ]
            ])
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        let track = (rtpReceiver.track as? RTCVideoTrack) ?? mediaStreams.first?.videoTracks.first
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isTearingDown else { return }
            if let track, self.currentVideoTrack !== track {
                self.currentVideoTrack = track
                self.onVideoTrackChanged?(track)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.peerConnection === peerConnection,
                  !self.isTearingDown else {
                return
            }
            guard dataChannel.label == "control" || self.controlChannel == nil else { return }
            self.controlChannel = dataChannel
            dataChannel.delegate = self
            if dataChannel.readyState == .open {
                self.handleControlChannelDidOpen(generation: self.sessionGeneration)
            }
        }
    }
}

extension WebRTCSession: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        Task { @MainActor [weak self] in
            guard let self,
                  self.controlChannel === dataChannel,
                  !self.isTearingDown else {
                return
            }
            switch state {
            case .open:
                self.handleControlChannelDidOpen(generation: self.sessionGeneration)
            case .closed:
                if self.expectingPeerShutdown {
                    self.finishExpectedPeerShutdown()
                    return
                }
                let pending = self.pendingRpc
                self.pendingRpc.removeAll()
                for (_, cb) in pending {
                    cb(.failure(WebRTCSessionError.controlChannelClosed))
                }
                self.onControlChannelClosed?()
                if self.shouldStayConnected {
                    self.scheduleReconnect(reason: "Robot control channel closed.")
                }
            default:
                break
            }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor [weak self] in
            guard let self,
                  self.controlChannel === dataChannel,
                  !self.isTearingDown else {
                return
            }
            self.handleControlMessage(data)
        }
    }
}
