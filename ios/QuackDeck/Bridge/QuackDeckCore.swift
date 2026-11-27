import Foundation
import QuackDeckCoreFFI

enum QuackCoreError: LocalizedError, Equatable {
    case rustError(String)
    case invalidResponse(String)
    case invalidBase64
    case nullHandle

    var errorDescription: String? {
        switch self {
        case .rustError(let message):
            return message
        case .invalidResponse(let detail):
            return "Unexpected core response: \(detail)"
        case .invalidBase64:
            return "Invalid base64 chunk returned by core"
        case .nullHandle:
            return "Core handle is closed"
        }
    }
}

struct GattUuids: Codable, Sendable, Equatable {
    let serviceUuid: String
    let rpcUuid: String
    let companyId: UInt16

    enum CodingKeys: String, CodingKey {
        case serviceUuid = "service_uuid"
        case rpcUuid = "rpc_uuid"
        case companyId = "company_id"
    }
}

struct AdvInfo: Codable, Sendable, Equatable {
    let hasAddressField: Bool
    let ipv4: String?
    let isExtended: Bool
    let isBusy: Bool

    enum CodingKeys: String, CodingKey {
        case hasAddressField = "has_address_field"
        case ipv4
        case isExtended = "is_extended"
        case isBusy = "is_busy"
    }

    init(
        hasAddressField: Bool = false,
        ipv4: String? = nil,
        isExtended: Bool = false,
        isBusy: Bool = false
    ) {
        self.hasAddressField = hasAddressField
        self.ipv4 = ipv4
        self.isExtended = isExtended
        self.isBusy = isBusy
    }
}

struct ParsedSetupCode: Codable, Sendable, Equatable {
    let robotId: String
    let pskHex: String

    enum CodingKeys: String, CodingKey {
        case robotId = "robot_id"
        case pskHex = "psk_hex"
    }
}

struct BleStepOutput: Sendable, Equatable {
    let ready: Bool
    let outboundChunks: [Data]
    let inboundMessages: [String]
}

enum SignallingEvent: Decodable, Sendable, Equatable {
    case message(String)
    case closed(String)
    case timeout

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "message":
            self = .message(try container.decode(String.self, forKey: .text))
        case "closed":
            self = .closed(try container.decode(String.self, forKey: .reason))
        case "timeout":
            self = .timeout
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown signalling event kind: \(kind)"
            )
        }
    }
}

private struct CoreEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let value: T?
    let error: String?
}

private struct BleChunksPayload: Decodable {
    let outboundChunksB64: [String]

    enum CodingKeys: String, CodingKey {
        case outboundChunksB64 = "outbound_chunks_b64"
    }
}

private struct BleStepPayload: Decodable {
    let ready: Bool
    let outboundChunksB64: [String]
    let inboundMessages: [String]

    enum CodingKeys: String, CodingKey {
        case ready
        case outboundChunksB64 = "outbound_chunks_b64"
        case inboundMessages = "inbound_messages"
    }
}

private func decodeCoreResult<T: Decodable>(_ ptr: UnsafeMutablePointer<CChar>?) throws -> T {
    guard let ptr else {
        throw QuackCoreError.invalidResponse("null pointer")
    }
    defer { qd_string_free(ptr) }
    let jsonString = String(cString: ptr)
    guard let data = jsonString.data(using: .utf8) else {
        throw QuackCoreError.invalidResponse("non-UTF8 output")
    }
    let envelope = try JSONDecoder().decode(CoreEnvelope<T>.self, from: data)
    if !envelope.ok {
        throw QuackCoreError.rustError(envelope.error ?? "Unknown error")
    }
    guard let value = envelope.value else {
        throw QuackCoreError.invalidResponse("missing value")
    }
    return value
}

private func decodeBase64Chunks(_ encoded: [String]) throws -> [Data] {
    try encoded.map { item in
        guard let data = Data(base64Encoded: item) else {
            throw QuackCoreError.invalidBase64
        }
        return data
    }
}

enum QuackDeckCore {
    static func gattUuids() throws -> GattUuids {
        try decodeCoreResult(qd_gatt_uuids())
    }

    static func parseManufacturerData(_ data: Data) throws -> AdvInfo {
        try data.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return try decodeCoreResult(qd_parse_cb_manufacturer_data(base, rawBuffer.count))
        }
    }

    static func parseSetupCode(_ raw: String) throws -> ParsedSetupCode {
        try raw.withCString { cStr in
            try decodeCoreResult(qd_parse_setup_code(cStr))
        }
    }
}

final class BleNoiseSession: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        lock.lock()
        let current = handle
        handle = nil
        lock.unlock()
        if let current {
            qd_ble_session_free(current)
        }
    }

    static func begin(
        pskHex: String,
        robotId: String,
        mtu: Int
    ) throws -> (session: BleNoiseSession, initialChunks: [Data]) {
        var rawHandle: OpaquePointer?
        var adopted = false
        defer {
            if !adopted, let leaked = rawHandle {
                qd_ble_session_free(leaked)
            }
        }
        let payload: BleChunksPayload = try pskHex.withCString { pskPtr in
            try robotId.withCString { idPtr in
                try decodeCoreResult(qd_ble_session_new(pskPtr, idPtr, mtu, &rawHandle))
            }
        }
        guard let rawHandle else {
            throw QuackCoreError.nullHandle
        }
        let chunks = try decodeBase64Chunks(payload.outboundChunksB64)
        let session = BleNoiseSession(handle: rawHandle)
        adopted = true
        return (session, chunks)
    }

    func feed(_ chunk: Data, mtu: Int) throws -> BleStepOutput {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else {
            throw QuackCoreError.nullHandle
        }
        let payload: BleStepPayload = try chunk.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return try decodeCoreResult(qd_ble_session_feed(handle, base, rawBuffer.count, mtu))
        }
        return BleStepOutput(
            ready: payload.ready,
            outboundChunks: try decodeBase64Chunks(payload.outboundChunksB64),
            inboundMessages: payload.inboundMessages
        )
    }

    func seal(jsonLine: String, mtu: Int) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else {
            throw QuackCoreError.nullHandle
        }
        let payload: BleChunksPayload = try jsonLine.withCString { linePtr in
            try decodeCoreResult(qd_ble_session_seal(handle, linePtr, mtu))
        }
        return try decodeBase64Chunks(payload.outboundChunksB64)
    }
}

final class LanRpcClient: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    init(
        host: String,
        port: UInt16 = 9444,
        robotId: String,
        pskHex: String,
        timeoutMs: UInt64 = 4000
    ) throws {
        var rawHandle: OpaquePointer?
        var adopted = false
        defer {
            if !adopted, let leaked = rawHandle {
                qd_lan_rpc_free(leaked)
            }
        }
        let _: Bool = try host.withCString { hostPtr in
            try robotId.withCString { idPtr in
                try pskHex.withCString { pskPtr in
                    try decodeCoreResult(
                        qd_lan_rpc_connect(hostPtr, port, idPtr, pskPtr, timeoutMs, &rawHandle)
                    )
                }
            }
        }
        guard let rawHandle else {
            throw QuackCoreError.nullHandle
        }
        self.handle = rawHandle
        adopted = true
    }

    deinit {
        lock.lock()
        let current = handle
        handle = nil
        lock.unlock()
        if let current {
            qd_lan_rpc_free(current)
        }
    }

    func call(requestJSON: String, timeoutMs: UInt64 = 5000) throws -> String {
        lock.lock()
        let current = handle
        lock.unlock()
        guard let current else {
            throw QuackCoreError.nullHandle
        }
        return try requestJSON.withCString { reqPtr in
            try decodeCoreResult(qd_lan_rpc_call(current, reqPtr, timeoutMs))
        }
    }
}

final class SignallingClient: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    init(
        host: String,
        port: UInt16 = 9443,
        robotId: String,
        pskHex: String,
        timeoutMs: UInt64 = 4000
    ) throws {
        var rawHandle: OpaquePointer?
        var adopted = false
        defer {
            if !adopted, let leaked = rawHandle {
                qd_sig_free(leaked)
            }
        }
        let _: Bool = try host.withCString { hostPtr in
            try robotId.withCString { idPtr in
                try pskHex.withCString { pskPtr in
                    try decodeCoreResult(
                        qd_sig_connect(hostPtr, port, idPtr, pskPtr, timeoutMs, &rawHandle)
                    )
                }
            }
        }
        guard let rawHandle else {
            throw QuackCoreError.nullHandle
        }
        self.handle = rawHandle
        adopted = true
    }

    deinit {
        lock.lock()
        let current = handle
        handle = nil
        lock.unlock()
        if let current {
            qd_sig_free(current)
        }
    }

    func send(text: String) throws {
        lock.lock()
        let current = handle
        lock.unlock()
        guard let current else {
            throw QuackCoreError.nullHandle
        }
        let _: Bool = try text.withCString { textPtr in
            try decodeCoreResult(qd_sig_send(current, textPtr))
        }
    }

    func nextEvent(timeoutMs: UInt64 = 250) throws -> SignallingEvent {
        lock.lock()
        let current = handle
        lock.unlock()
        guard let current else {
            throw QuackCoreError.nullHandle
        }
        return try decodeCoreResult(qd_sig_next_event(current, timeoutMs))
    }
}
