import CoreBluetooth
import Foundation
import Observation

enum BleManagerError: LocalizedError {
    case bluetoothUnavailable(String)
    case peripheralNotFound
    case peripheralBusy
    case serviceNotFound
    case rpcCharacteristicNotFound
    case invalidApiVersion
    case disconnected(String)
    case timeout(String)
    case rpcError(code: Int?, message: String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let detail):
            return detail
        case .peripheralNotFound:
            return "Duck peripheral is no longer nearby. Try scanning again."
        case .peripheralBusy:
            return "This duck is currently busy with another Bluetooth client."
        case .serviceNotFound:
            return "Microduck BLE service was not found on this device."
        case .rpcCharacteristicNotFound:
            return "Microduck RPC characteristic was not found on this device."
        case .invalidApiVersion:
            return "Robot returned an empty API version over Bluetooth."
        case .disconnected(let detail):
            return detail
        case .timeout(let step):
            return "Bluetooth timed out while \(step)."
        case .rpcError(_, let message):
            return message
        }
    }
}

@MainActor
private final class BleResumableBox<T> {
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

    func startTimeout(seconds: TimeInterval, step: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            let ns = UInt64(max(0.1, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            self.resolve(with: .failure(BleManagerError.timeout(step)))
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
@Observable
final class BleManager: NSObject {
    private static let staleBusyWindowSeconds: TimeInterval = 6.0
    private static let staleDiscoveryWindowSeconds: TimeInterval = 30.0
    private static let disconnectWaitTimeoutSeconds: TimeInterval = 2.0
    private static let unsubscribeWaitTimeoutSeconds: TimeInterval = 0.5

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var isScanning: Bool = false
    private(set) var discoveredDucks: [DiscoveredDuck] = []
    private(set) var connectedPeripheralId: UUID?
    private(set) var isAuthenticated: Bool = false
    private(set) var apiVersion: Int?

    @ObservationIgnored var onUnexpectedDisconnect: ((UUID, String) -> Void)?

    var stateDescription: String {
        switch bluetoothState {
        case .poweredOn: return isScanning ? "Scanning" : "Ready"
        case .poweredOff: return "Bluetooth Off"
        case .unauthorized: return "Bluetooth Denied"
        case .unsupported: return "Bluetooth Unsupported"
        case .resetting: return "Bluetooth Resetting"
        case .unknown: return "Starting Bluetooth"
        @unknown default: return "Bluetooth Unavailable"
        }
    }

    private let uuids: GattUuids
    private let serviceCBUUID: CBUUID
    private let rpcCBUUID: CBUUID

    private var central: CBCentralManager!
    private var wantScan: Bool = false
    private var knownPeripheralIds: Set<UUID> = []

    private var peripheralsById: [UUID: CBPeripheral] = [:]
    private var discoveredById: [UUID: DiscoveredDuck] = [:]
    private var lastMfgDataAt: [UUID: Date] = [:]

    private var activePeripheral: CBPeripheral?
    private var rpcCharacteristic: CBCharacteristic?
    private var noiseSession: BleNoiseSession?
    private var writeMtu: Int = 20

    private var connectionGeneration: UInt64 = 0
    private var didEstablishLinkForGeneration: Bool = false

    private var nextRpcId: Int = 1
    private var pendingRpc: [Int: (Result<String, Error>) -> Void] = [:]
    private var lastActivityAt: Date = .distantPast
    private var keepaliveTask: Task<Void, Never>?
    private var scanPruneTask: Task<Void, Never>?

    private var connectCallback: ((Result<Void, Error>) -> Void)?
    private var discoverServicesCallback: ((Result<Void, Error>) -> Void)?
    private var discoverCharsCallback: ((Result<CBCharacteristic, Error>) -> Void)?
    private var readVersionCallback: ((Result<Int, Error>) -> Void)?
    private var notifyCallback: ((Result<Void, Error>) -> Void)?
    private var writeCallback: ((Result<Void, Error>) -> Void)?

    private var handshakeCompleted: Bool = false
    private var handshakeError: Error?
    private var handshakeCallback: ((Result<Void, Error>) -> Void)?

    // Serialized write lock so concurrent inbound challenges and keepalives never overwrite writeCallback.
    private var activeWriteLockToken: UUID?
    private var writeLockWaiters: [(token: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    private var disconnectWaiters: [UUID: [(token: UUID, continuation: CheckedContinuation<Void, Never>)]] = [:]
    private var unsubscribeWaiters: [UUID: [(token: UUID, continuation: CheckedContinuation<Void, Never>)]] = [:]

    override init() {
        let resolved = (try? QuackDeckCore.gattUuids()) ?? GattUuids(
            serviceUuid: "6F5D2A10-3B47-4C8E-9A1F-2D7E8C4B6019",
            rpcUuid: "6F5D2A11-3B47-4C8E-9A1F-2D7E8C4B6019",
            companyId: 0xFFFF
        )
        self.uuids = resolved
        self.serviceCBUUID = CBUUID(string: resolved.serviceUuid)
        self.rpcCBUUID = CBUUID(string: resolved.rpcUuid)
        super.init()
        self.central = CBCentralManager(delegate: self, queue: .main)
    }

    func setKnownPeripheralIds(_ ids: [UUID]) {
        knownPeripheralIds = Set(ids)
    }

    func startScan() {
        wantScan = true
        publishDiscoveredList()
        guard central.state == .poweredOn else { return }
        beginCoreBluetoothScan()
    }

    func stopScan() {
        wantScan = false
        scanPruneTask?.cancel()
        scanPruneTask = nil
        if isScanning {
            central.stopScan()
            isScanning = false
        }
    }

    func peripheral(for id: UUID) -> CBPeripheral? {
        peripheralsById[id]
    }

    func connectAndAuthenticate(
        peripheralId: UUID,
        robotId: String,
        pskHex: String
    ) async throws -> Int {
        guard central.state == .poweredOn else {
            throw BleManagerError.bluetoothUnavailable(
                bluetoothState == .poweredOff
                    ? "Turn on Bluetooth to connect to your duck."
                    : "Bluetooth is not ready (\(stateDescription))."
            )
        }

        publishDiscoveredList()
        if let existing = discoveredById[peripheralId],
           !existing.isConnectable,
           Date().timeIntervalSince(existing.lastSeen) < Self.staleBusyWindowSeconds {
            throw BleManagerError.peripheralBusy
        }

        let target: CBPeripheral
        if let cached = peripheralsById[peripheralId] {
            target = cached
        } else if let retrieved = central.retrievePeripherals(withIdentifiers: [peripheralId]).first {
            peripheralsById[peripheralId] = retrieved
            target = retrieved
        } else {
            throw BleManagerError.peripheralNotFound
        }

        await disconnect()
        try Task.checkCancellation()

        connectionGeneration &+= 1
        let generation = connectionGeneration
        didEstablishLinkForGeneration = false
        activePeripheral = target
        target.delegate = self

        do {
            try await runStepWithTimeout(
                seconds: 12,
                step: "connecting to duck",
                register: { [weak self] callback in
                    self?.connectCallback = callback
                    return { [weak self] in
                        self?.connectCallback = nil
                    }
                },
                trigger: { [weak self] in
                    guard let self, self.connectionGeneration == generation else { return }
                    self.central.connect(target, options: nil)
                }
            )
            guard connectionGeneration == generation else {
                throw BleManagerError.disconnected("Bluetooth connection superseded.")
            }

            try await runStepWithTimeout(
                seconds: 10,
                step: "discovering services",
                register: { [weak self] callback in
                    self?.discoverServicesCallback = callback
                    return { [weak self] in
                        self?.discoverServicesCallback = nil
                    }
                },
                trigger: { [weak self] in
                    guard let self, self.connectionGeneration == generation else { return }
                    target.discoverServices([self.serviceCBUUID])
                }
            )
            guard connectionGeneration == generation else {
                throw BleManagerError.disconnected("Bluetooth connection superseded.")
            }

            guard let service = target.services?.first(where: { $0.uuid == serviceCBUUID }) else {
                throw BleManagerError.serviceNotFound
            }

            let rpcChar = try await runStepWithTimeout(
                seconds: 10,
                step: "discovering RPC characteristic",
                register: { [weak self] callback in
                    self?.discoverCharsCallback = callback
                    return { [weak self] in
                        self?.discoverCharsCallback = nil
                    }
                },
                trigger: { [weak self] in
                    guard let self, self.connectionGeneration == generation else { return }
                    target.discoverCharacteristics([self.rpcCBUUID], for: service)
                }
            )
            guard connectionGeneration == generation else {
                throw BleManagerError.disconnected("Bluetooth connection superseded.")
            }
            self.rpcCharacteristic = rpcChar

            // Read RPC_UUID first: triggers iOS BLE bond and reads the 1-byte API version.
            let version = try await withTransientAuthRetry(target: target, generation: generation) {
                try await self.readApiVersionOnce(target: target, characteristic: rpcChar, generation: generation)
            }
            guard connectionGeneration == generation else {
                throw BleManagerError.disconnected("Bluetooth connection superseded.")
            }
            self.apiVersion = version

            try await withTransientAuthRetry(target: target, generation: generation) {
                try await self.enableNotificationsOnce(target: target, characteristic: rpcChar, generation: generation)
            }
            guard connectionGeneration == generation else {
                throw BleManagerError.disconnected("Bluetooth connection superseded.")
            }

            let clampedMtu = max(20, min(target.maximumWriteValueLength(for: .withResponse), 512))
            self.writeMtu = clampedMtu

            let (session, initialChunks) = try BleNoiseSession.begin(
                pskHex: pskHex,
                robotId: robotId,
                mtu: clampedMtu
            )
            self.noiseSession = session

            // Arm handshake completion state BEFORE sending Frame::Start so fast responses cannot race.
            let handshakeBox = BleResumableBox<Void>()
            self.handshakeCompleted = false
            self.handshakeError = nil
            self.handshakeCallback = { [weak handshakeBox] result in
                handshakeBox?.resolve(with: result)
            }

            try await withTransientAuthRetry(target: target, generation: generation) {
                try await self.writeChunks(
                    initialChunks,
                    to: target,
                    characteristic: rpcChar,
                    generation: generation
                )
            }

            try await awaitHandshake(box: handshakeBox, generation: generation)
            guard connectionGeneration == generation else {
                throw BleManagerError.disconnected("Bluetooth connection superseded.")
            }

            self.isAuthenticated = true
            self.connectedPeripheralId = peripheralId
            self.lastActivityAt = Date()
            startKeepaliveLoop(generation: generation)
            return version
        } catch {
            let mapped = mapBluetoothError(error)
            if connectionGeneration == generation {
                await disconnect()
            }
            throw mapped
        }
    }

    func call(
        method: String,
        params: [String: Any] = [:],
        timeoutSeconds: TimeInterval = 15
    ) async throws -> String {
        guard let peripheral = activePeripheral,
              let rpcChar = rpcCharacteristic,
              let noiseSession,
              isAuthenticated else {
            throw BleManagerError.disconnected("Not authenticated over Bluetooth.")
        }

        let generation = connectionGeneration
        let id = nextRpcId
        nextRpcId += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let jsonLine = String(data: jsonData, encoding: .utf8) else {
            throw BleManagerError.disconnected("Failed to encode JSON-RPC line.")
        }

        let mtu = max(20, min(peripheral.maximumWriteValueLength(for: .withResponse), 512))
        let chunks = try noiseSession.seal(jsonLine: jsonLine, mtu: mtu)

        lastActivityAt = Date()

        let box = BleResumableBox<String>()
        box.startTimeout(seconds: timeoutSeconds, step: "waiting for \(method)")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingRpc[id] = { [weak box] result in
                    box?.resolve(with: result)
                }
                box.arm(continuation: continuation) { [weak self] in
                    self?.pendingRpc.removeValue(forKey: id)
                }

                if !box.isResolved {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        do {
                            try await self.writeChunks(
                                chunks,
                                to: peripheral,
                                characteristic: rpcChar,
                                generation: generation
                            )
                        } catch {
                            let mapped = self.mapBluetoothError(error)
                            if let cb = self.pendingRpc.removeValue(forKey: id) {
                                cb(.failure(mapped))
                            }
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                box.resolve(with: .failure(CancellationError()))
            }
        }
    }

    func disconnect() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil

        connectionGeneration &+= 1
        didEstablishLinkForGeneration = false
        activeWriteLockToken = nil

        let err = BleManagerError.disconnected("Bluetooth link closed.")
        failPendingContinuations(with: err)

        let peripheral = activePeripheral
        let rpcChar = rpcCharacteristic

        activePeripheral = nil
        rpcCharacteristic = nil
        noiseSession = nil
        connectedPeripheralId = nil
        isAuthenticated = false
        apiVersion = nil
        handshakeCompleted = false
        handshakeError = nil
        handshakeCallback = nil

        guard let peripheral else { return }

        // Clear any stale busy state for the peripheral we just released.
        if let existing = discoveredById[peripheral.identifier], existing.advInfo.isBusy {
            discoveredById[peripheral.identifier] = DiscoveredDuck(
                id: existing.id,
                name: existing.name,
                advInfo: AdvInfo(
                    hasAddressField: existing.advInfo.hasAddressField,
                    ipv4: existing.advInfo.ipv4,
                    isExtended: existing.advInfo.isExtended,
                    isBusy: false
                ),
                rssi: existing.rssi,
                lastSeen: existing.lastSeen
            )
            publishDiscoveredList()
        }

        if peripheral.state == .connected, let rpcChar {
            peripheral.setNotifyValue(false, for: rpcChar)
            await waitForUnsubscribe(peripheralId: peripheral.identifier)
        }

        let currentState = peripheral.state
        if currentState == .connected || currentState == .connecting || currentState == .disconnecting {
            if currentState == .connected || currentState == .connecting {
                central.cancelPeripheralConnection(peripheral)
            }
            await waitForDisconnect(peripheral: peripheral)
        }
    }

    // MARK: - Private helpers

    private func beginCoreBluetoothScan() {
        guard !isScanning else { return }
        publishDiscoveredList()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
        startScanPruneLoop()
    }

    private func startScanPruneLoop() {
        scanPruneTask?.cancel()
        scanPruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.isScanning else { break }
                self.publishDiscoveredList()
            }
        }
    }

    private func startKeepaliveLoop(generation: UInt64) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !Task.isCancelled else { break }
                guard self.connectionGeneration == generation, self.isAuthenticated else { break }
                if Date().timeIntervalSince(self.lastActivityAt) >= 18 {
                    _ = try? await self.call(method: "net.status", params: [:], timeoutSeconds: 8)
                }
            }
        }
    }

    private func readApiVersionOnce(
        target: CBPeripheral,
        characteristic: CBCharacteristic,
        generation: UInt64
    ) async throws -> Int {
        try await runStepWithTimeout(
            seconds: 25,
            step: "reading API version and bonding",
            register: { [weak self] callback in
                self?.readVersionCallback = callback
                return { [weak self] in
                    self?.readVersionCallback = nil
                }
            },
            trigger: { [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                target.readValue(for: characteristic)
            }
        )
    }

    private func enableNotificationsOnce(
        target: CBPeripheral,
        characteristic: CBCharacteristic,
        generation: UInt64
    ) async throws {
        try await runStepWithTimeout(
            seconds: 10,
            step: "subscribing to notifications",
            register: { [weak self] callback in
                self?.notifyCallback = callback
                return { [weak self] in
                    self?.notifyCallback = nil
                }
            },
            trigger: { [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                target.setNotifyValue(true, for: characteristic)
            }
        )
    }

    private func withTransientAuthRetry<T>(
        target: CBPeripheral,
        generation: UInt64,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isTransientAuthError(error),
                  !Task.isCancelled,
                  connectionGeneration == generation,
                  activePeripheral === target,
                  target.state == .connected else {
                throw mapBluetoothError(error)
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled,
                  connectionGeneration == generation,
                  activePeripheral === target,
                  target.state == .connected else {
                throw BleManagerError.disconnected("Bluetooth link closed during pairing setup.")
            }
            return try await operation()
        }
    }

    private func awaitHandshake(
        box: BleResumableBox<Void>,
        generation: UInt64
    ) async throws {
        if handshakeCompleted {
            return
        }
        if let err = handshakeError {
            throw err
        }

        box.startTimeout(seconds: 12, step: "completing secure Noise handshake")

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.arm(continuation: continuation) { [weak self] in
                    self?.handshakeCallback = nil
                }
                if self.connectionGeneration != generation {
                    box.resolve(with: .failure(BleManagerError.disconnected("Bluetooth connection superseded.")))
                } else if self.handshakeCompleted {
                    box.resolve(with: .success(()))
                } else if let err = self.handshakeError {
                    box.resolve(with: .failure(err))
                }
            }
        } onCancel: {
            Task { @MainActor in
                box.resolve(with: .failure(CancellationError()))
            }
        }
    }

    private func succeedHandshake() {
        handshakeCompleted = true
        if let cb = handshakeCallback {
            handshakeCallback = nil
            cb(.success(()))
        }
    }

    private func failHandshake(with error: Error) {
        let mapped = mapBluetoothError(error)
        if handshakeError == nil {
            handshakeError = mapped
        }
        if let cb = handshakeCallback {
            handshakeCallback = nil
            cb(.failure(mapped))
        }
    }

    private func acquireWriteLock(generation: UInt64) async throws -> UUID {
        let token = UUID()
        if activeWriteLockToken == nil {
            guard connectionGeneration == generation else {
                throw BleManagerError.disconnected("Bluetooth link closed.")
            }
            activeWriteLockToken = token
            return token
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard self.connectionGeneration == generation else {
                    continuation.resume(throwing: BleManagerError.disconnected("Bluetooth link closed."))
                    return
                }
                if self.activeWriteLockToken == nil {
                    self.activeWriteLockToken = token
                    continuation.resume(returning: ())
                } else {
                    self.writeLockWaiters.append((token: token, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let idx = self.writeLockWaiters.firstIndex(where: { $0.token == token }) {
                    let removed = self.writeLockWaiters.remove(at: idx)
                    removed.continuation.resume(throwing: CancellationError())
                }
            }
        }
        return token
    }

    private func releaseWriteLock(token: UUID) {
        guard activeWriteLockToken == token else { return }
        if !writeLockWaiters.isEmpty {
            let next = writeLockWaiters.removeFirst()
            activeWriteLockToken = next.token
            next.continuation.resume(returning: ())
        } else {
            activeWriteLockToken = nil
        }
    }

    private func writeChunks(
        _ chunks: [Data],
        to peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        generation: UInt64
    ) async throws {
        let lockToken = try await acquireWriteLock(generation: generation)
        defer { releaseWriteLock(token: lockToken) }

        for chunk in chunks {
            guard connectionGeneration == generation,
                  activePeripheral === peripheral,
                  peripheral.state == .connected else {
                throw BleManagerError.disconnected("Bluetooth link closed.")
            }

            try await runStepWithTimeout(
                seconds: 6,
                step: "writing Bluetooth packet",
                register: { [weak self] callback in
                    self?.writeCallback = callback
                    return { [weak self] in
                        self?.writeCallback = nil
                    }
                },
                trigger: { [weak self] in
                    guard let self,
                          self.connectionGeneration == generation,
                          self.activePeripheral === peripheral else {
                        return
                    }
                    peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                }
            )
            lastActivityAt = Date()
        }
    }

    private func handleInboundNotification(_ data: Data) {
        guard let noiseSession,
              let peripheral = activePeripheral,
              let rpcChar = rpcCharacteristic else {
            return
        }
        let generation = connectionGeneration
        let mtu = max(20, min(peripheral.maximumWriteValueLength(for: .withResponse), 512))
        do {
            let step = try noiseSession.feed(data, mtu: mtu)
            if !step.outboundChunks.isEmpty {
                Task { @MainActor [weak self] in
                    guard let self, self.connectionGeneration == generation else { return }
                    do {
                        try await self.writeChunks(
                            step.outboundChunks,
                            to: peripheral,
                            characteristic: rpcChar,
                            generation: generation
                        )
                    } catch {
                        if !self.handshakeCompleted {
                            self.failHandshake(with: error)
                        }
                    }
                }
            }
            if step.ready {
                succeedHandshake()
            }
            for message in step.inboundMessages {
                dispatchInboundMessage(message)
            }
        } catch {
            failHandshake(with: error)
            failPendingContinuations(with: mapBluetoothError(error))
        }
    }

    private func dispatchInboundMessage(_ jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else {
            return
        }
        guard let callback = pendingRpc.removeValue(forKey: id) else {
            return
        }
        if let errObj = object["error"] as? [String: Any] {
            let code = errObj["code"] as? Int
            let message = (errObj["message"] as? String) ?? "Bluetooth RPC error"
            callback(.failure(BleManagerError.rpcError(code: code, message: message)))
            return
        }
        if let resultObj = object["result"],
           let resultData = try? JSONSerialization.data(withJSONObject: resultObj, options: []),
           let resultString = String(data: resultData, encoding: .utf8) {
            callback(.success(resultString))
            return
        }
        callback(.success("{}"))
    }

    private func failPendingContinuations(with error: Error) {
        let mapped = mapBluetoothError(error)

        if let cb = connectCallback {
            connectCallback = nil
            cb(.failure(mapped))
        }
        if let cb = discoverServicesCallback {
            discoverServicesCallback = nil
            cb(.failure(mapped))
        }
        if let cb = discoverCharsCallback {
            discoverCharsCallback = nil
            cb(.failure(mapped))
        }
        if let cb = readVersionCallback {
            readVersionCallback = nil
            cb(.failure(mapped))
        }
        if let cb = notifyCallback {
            notifyCallback = nil
            cb(.failure(mapped))
        }
        if let cb = writeCallback {
            writeCallback = nil
            cb(.failure(mapped))
        }
        failHandshake(with: mapped)

        let lockWaiters = writeLockWaiters
        writeLockWaiters.removeAll()
        for waiter in lockWaiters {
            waiter.continuation.resume(throwing: mapped)
        }

        let rpcMap = pendingRpc
        pendingRpc.removeAll()
        for (_, cb) in rpcMap {
            cb(.failure(mapped))
        }
    }

    private func runStepWithTimeout<T>(
        seconds: TimeInterval,
        step: String,
        register: @MainActor (@escaping (Result<T, Error>) -> Void) -> (() -> Void),
        trigger: @MainActor () -> Void
    ) async throws -> T {
        try Task.checkCancellation()
        let box = BleResumableBox<T>()
        box.startTimeout(seconds: seconds, step: step)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cleanup = register { [weak box] result in
                    box?.resolve(with: result)
                }
                box.arm(continuation: continuation, onCleanup: cleanup)
                if !box.isResolved {
                    trigger()
                }
            }
        } onCancel: {
            Task { @MainActor in
                box.resolve(with: .failure(CancellationError()))
            }
        }
    }

    private func waitForUnsubscribe(peripheralId: UUID) async {
        let token = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            let ns = UInt64(Self.unsubscribeWaitTimeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard let self else { return }
            self.resumeWaiter(in: &self.unsubscribeWaiters, peripheralId: peripheralId, token: token)
        }
        await withCheckedContinuation { continuation in
            unsubscribeWaiters[peripheralId, default: []].append((token: token, continuation: continuation))
        }
        timeoutTask.cancel()
    }

    private func waitForDisconnect(peripheral: CBPeripheral) async {
        if peripheral.state == .disconnected {
            return
        }
        let peripheralId = peripheral.identifier
        let token = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            let ns = UInt64(Self.disconnectWaitTimeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard let self else { return }
            self.resumeWaiter(in: &self.disconnectWaiters, peripheralId: peripheralId, token: token)
        }
        await withCheckedContinuation { continuation in
            if peripheral.state == .disconnected {
                continuation.resume(returning: ())
                return
            }
            disconnectWaiters[peripheralId, default: []].append((token: token, continuation: continuation))
        }
        timeoutTask.cancel()
    }

    private func resumeWaiter(
        in map: inout [UUID: [(token: UUID, continuation: CheckedContinuation<Void, Never>)]],
        peripheralId: UUID,
        token: UUID
    ) {
        guard var list = map[peripheralId],
              let idx = list.firstIndex(where: { $0.token == token }) else {
            return
        }
        let entry = list.remove(at: idx)
        if list.isEmpty {
            map.removeValue(forKey: peripheralId)
        } else {
            map[peripheralId] = list
        }
        entry.continuation.resume(returning: ())
    }

    private func resumeAllWaiters(
        in map: inout [UUID: [(token: UUID, continuation: CheckedContinuation<Void, Never>)]],
        peripheralId: UUID
    ) {
        guard let list = map.removeValue(forKey: peripheralId) else { return }
        for entry in list {
            entry.continuation.resume(returning: ())
        }
    }

    private func isTransientAuthError(_ error: Error) -> Bool {
        if let attError = error as? CBATTError {
            return attError.code == .insufficientAuthentication || attError.code == .insufficientEncryption
        }
        let ns = error as NSError
        if ns.domain == CBATTErrorDomain {
            return ns.code == CBATTError.Code.insufficientAuthentication.rawValue
                || ns.code == CBATTError.Code.insufficientEncryption.rawValue
        }
        return false
    }

    private func isPeerRemovedPairingError(_ error: Error) -> Bool {
        if let cbError = error as? CBError, cbError.code == .peerRemovedPairingInformation {
            return true
        }
        let ns = error as NSError
        return ns.domain == CBErrorDomain && ns.code == 14
    }

    private func mapBluetoothError(_ error: Error) -> Error {
        if isPeerRemovedPairingError(error) {
            return BleManagerError.disconnected(
                "Bluetooth pairing expired. Forget this duck in iOS Bluetooth Settings and pair again."
            )
        }
        return error
    }

    private func publishDiscoveredList() {
        let now = Date()
        var refreshed: [UUID: DiscoveredDuck] = [:]
        for (id, duck) in discoveredById {
            let age = now.timeIntervalSince(duck.lastSeen)
            guard age < Self.staleDiscoveryWindowSeconds else {
                lastMfgDataAt.removeValue(forKey: id)
                continue
            }
            if duck.advInfo.isBusy {
                let mfgAge = now.timeIntervalSince(lastMfgDataAt[id] ?? duck.lastSeen)
                if mfgAge > Self.staleBusyWindowSeconds {
                    // Expire stale busy entries so a previously busy duck is never stuck greyed out.
                    continue
                }
            }
            refreshed[id] = duck
        }
        discoveredById = refreshed
        discoveredDucks = discoveredById.values.sorted { lhs, rhs in
            if lhs.isConnectable != rhs.isConnectable {
                return lhs.isConnectable && !rhs.isConnectable
            }
            if lhs.rssi != rhs.rssi {
                return lhs.rssi > rhs.rssi
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private nonisolated func onMainActorSync(_ body: @MainActor @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in
                body()
            }
        }
    }
}

extension BleManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onMainActorSync {
            self.bluetoothState = central.state
            if central.state == .poweredOn {
                if self.wantScan {
                    self.beginCoreBluetoothScan()
                }
            } else {
                self.scanPruneTask?.cancel()
                self.scanPruneTask = nil
                self.isScanning = false
                if self.connectedPeripheralId != nil || self.activePeripheral != nil {
                    Task { @MainActor in
                        await self.disconnect()
                    }
                }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let rssiValue = RSSI.intValue == 127 ? -99 : RSSI.intValue

        onMainActorSync {
            let now = Date()
            let advInfo: AdvInfo
            if let mfgData {
                advInfo = (try? QuackDeckCore.parseManufacturerData(mfgData)) ?? AdvInfo()
            } else {
                advInfo = AdvInfo()
            }

            let hasService = serviceUUIDs.contains(self.serviceCBUUID)
            let isKnown = self.knownPeripheralIds.contains(peripheral.identifier)
            guard hasService || advInfo.hasAddressField || isKnown else {
                return
            }

            if advInfo.hasAddressField {
                self.lastMfgDataAt[peripheral.identifier] = now
            }

            self.peripheralsById[peripheral.identifier] = peripheral
            let previous = self.discoveredById[peripheral.identifier]
            let displayName: String
            if let localName, !localName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = localName
            } else if let previous {
                displayName = previous.name
            } else {
                displayName = "Microduck \(peripheral.identifier.uuidString.prefix(4))"
            }

            // Preserve earlier decoded IPv4 if a subsequent scan packet omitted manufacturer data,
            // while allowing stale busy markers older than 6 s to expire.
            let mergedAdv: AdvInfo
            if advInfo.hasAddressField {
                mergedAdv = advInfo
            } else if let previous, previous.advInfo.hasAddressField {
                let busyFresh = previous.advInfo.isBusy
                    && now.timeIntervalSince(self.lastMfgDataAt[peripheral.identifier] ?? previous.lastSeen) < Self.staleBusyWindowSeconds
                mergedAdv = AdvInfo(
                    hasAddressField: previous.advInfo.hasAddressField,
                    ipv4: previous.advInfo.ipv4,
                    isExtended: previous.advInfo.isExtended,
                    isBusy: busyFresh
                )
            } else {
                mergedAdv = advInfo
            }

            self.discoveredById[peripheral.identifier] = DiscoveredDuck(
                id: peripheral.identifier,
                name: displayName,
                advInfo: mergedAdv,
                rssi: rssiValue,
                lastSeen: now
            )
            self.publishDiscoveredList()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onMainActorSync {
            guard self.activePeripheral?.identifier == peripheral.identifier else { return }
            self.didEstablishLinkForGeneration = true
            if let cb = self.connectCallback {
                self.connectCallback = nil
                cb(.success(()))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        onMainActorSync {
            self.resumeAllWaiters(in: &self.disconnectWaiters, peripheralId: peripheral.identifier)
            guard self.activePeripheral?.identifier == peripheral.identifier else { return }
            let mapped: Error
            if let error {
                mapped = self.mapBluetoothError(error)
            } else {
                mapped = BleManagerError.disconnected("Failed to connect over Bluetooth.")
            }
            if let cb = self.connectCallback {
                self.connectCallback = nil
                cb(.failure(mapped))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        onMainActorSync {
            self.resumeAllWaiters(in: &self.unsubscribeWaiters, peripheralId: peripheral.identifier)
            self.resumeAllWaiters(in: &self.disconnectWaiters, peripheralId: peripheral.identifier)

            guard self.activePeripheral?.identifier == peripheral.identifier,
                  self.didEstablishLinkForGeneration else {
                return
            }

            let detailError: Error
            if let error {
                detailError = self.mapBluetoothError(error)
            } else {
                detailError = BleManagerError.disconnected("Bluetooth connection closed.")
            }

            self.keepaliveTask?.cancel()
            self.keepaliveTask = nil
            self.connectionGeneration &+= 1
            self.didEstablishLinkForGeneration = false
            self.activeWriteLockToken = nil
            self.activePeripheral = nil
            self.rpcCharacteristic = nil
            self.noiseSession = nil
            self.connectedPeripheralId = nil
            self.isAuthenticated = false
            self.apiVersion = nil
            self.failPendingContinuations(with: detailError)
            self.onUnexpectedDisconnect?(peripheral.identifier, detailError.localizedDescription)
        }
    }
}

extension BleManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        onMainActorSync {
            guard self.activePeripheral?.identifier == peripheral.identifier else { return }
            guard let cb = self.discoverServicesCallback else { return }
            self.discoverServicesCallback = nil
            if let error {
                cb(.failure(self.mapBluetoothError(error)))
                return
            }
            if peripheral.services?.contains(where: { $0.uuid == self.serviceCBUUID }) == true {
                cb(.success(()))
            } else {
                cb(.failure(BleManagerError.serviceNotFound))
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        onMainActorSync {
            guard self.activePeripheral?.identifier == peripheral.identifier else { return }
            guard let cb = self.discoverCharsCallback else { return }
            self.discoverCharsCallback = nil
            if let error {
                cb(.failure(self.mapBluetoothError(error)))
                return
            }
            if let rpc = service.characteristics?.first(where: { $0.uuid == self.rpcCBUUID }) {
                cb(.success(rpc))
            } else {
                cb(.failure(BleManagerError.rpcCharacteristicNotFound))
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        onMainActorSync {
            guard characteristic.uuid == self.rpcCBUUID else { return }
            self.resumeAllWaiters(in: &self.unsubscribeWaiters, peripheralId: peripheral.identifier)
            guard self.activePeripheral?.identifier == peripheral.identifier else { return }
            guard let cb = self.notifyCallback else { return }
            self.notifyCallback = nil
            if let error {
                cb(.failure(self.mapBluetoothError(error)))
            } else {
                cb(.success(()))
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        onMainActorSync {
            guard self.activePeripheral?.identifier == peripheral.identifier,
                  characteristic.uuid == self.rpcCBUUID else {
                return
            }
            guard let cb = self.writeCallback else { return }
            self.writeCallback = nil
            if let error {
                cb(.failure(self.mapBluetoothError(error)))
            } else {
                cb(.success(()))
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let value = characteristic.value
        onMainActorSync {
            guard self.activePeripheral?.identifier == peripheral.identifier,
                  characteristic.uuid == self.rpcCBUUID else {
                return
            }
            if let readCb = self.readVersionCallback {
                self.readVersionCallback = nil
                if let error {
                    readCb(.failure(self.mapBluetoothError(error)))
                    return
                }
                guard let byte = value?.first else {
                    readCb(.failure(BleManagerError.invalidApiVersion))
                    return
                }
                readCb(.success(Int(byte)))
                return
            }

            if let error {
                self.failPendingContinuations(with: self.mapBluetoothError(error))
                return
            }
            if let value, !value.isEmpty {
                self.handleInboundNotification(value)
            }
        }
    }
}
