import Foundation
import Security

enum RobotVaultError: LocalizedError {
    case encodingFailed
    case corruptIndex
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode robot pairing key"
        case .corruptIndex:
            return "Saved ducks metadata could not be decoded; original backup preserved"
        case .keychainStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message) (\(status))"
            }
            return "Keychain error (\(status))"
        }
    }
}

final class RobotVault: @unchecked Sendable {
    static let shared = RobotVault()

    private let keychainService: String
    private let defaultsKey: String
    private let corruptBackupKey: String
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(
        keychainService: String = "com.caricio.quackdeck.psk",
        defaultsKey: String = "com.caricio.quackdeck.pairedDucks",
        defaults: UserDefaults = .standard
    ) {
        self.keychainService = keychainService
        self.defaultsKey = defaultsKey
        self.corruptBackupKey = "\(defaultsKey).corruptBackup"
        self.defaults = defaults
    }

    var hasCorruptIndexBackup: Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.data(forKey: corruptBackupKey) != nil
    }

    func loadPairedDucks() -> [PairedDuck] {
        lock.lock()
        defer { lock.unlock() }
        return readIndexLocked().ducks
    }

    func pairedDuck(for robotId: String) -> PairedDuck? {
        loadPairedDucks().first { $0.robotId == robotId }
    }

    func save(duck: PairedDuck, pskHex: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let read = readIndexLocked()
        if read.decodeFailed && read.ducks.isEmpty {
            throw RobotVaultError.corruptIndex
        }

        try storeKeychainSecret(pskHex, account: duck.robotId)

        var list = read.ducks
        if let idx = list.firstIndex(where: { $0.robotId == duck.robotId }) {
            list[idx] = duck
        } else {
            list.insert(duck, at: 0)
        }
        writeIndexLocked(list)
    }

    func updateConnectionMetadata(
        robotId: String,
        name: String? = nil,
        lastIp: String? = nil,
        peripheralId: UUID? = nil,
        connectedAt: Date? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        let read = readIndexLocked()
        if read.decodeFailed && read.ducks.isEmpty {
            return
        }
        var list = read.ducks
        guard let idx = list.firstIndex(where: { $0.robotId == robotId }) else { return }
        if let name, !name.isEmpty {
            list[idx].name = name
        }
        if let lastIp, !lastIp.isEmpty {
            list[idx].lastIp = lastIp
        }
        if let peripheralId {
            list[idx].peripheralId = peripheralId
        }
        if let connectedAt {
            list[idx].lastConnectedAt = connectedAt
        }
        writeIndexLocked(list)
    }

    func pskHex(for robotId: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: robotId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw RobotVaultError.keychainStatus(status)
        }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    func remove(robotId: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let read = readIndexLocked()
        if read.decodeFailed && read.ducks.isEmpty {
            throw RobotVaultError.corruptIndex
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: robotId
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw RobotVaultError.keychainStatus(status)
        }

        var list = read.ducks
        list.removeAll { $0.robotId == robotId }
        writeIndexLocked(list)
    }

    // MARK: - Helpers

    private func storeKeychainSecret(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw RobotVaultError.encodingFailed
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw RobotVaultError.keychainStatus(updateStatus)
        }

        var insertQuery = baseQuery
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RobotVaultError.keychainStatus(addStatus)
        }
    }

    private func readIndexLocked() -> (ducks: [PairedDuck], decodeFailed: Bool) {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return ([], false)
        }
        if let decoded = try? JSONDecoder().decode([PairedDuck].self, from: data) {
            return (decoded, false)
        }

        if defaults.data(forKey: corruptBackupKey) == nil {
            defaults.set(data, forKey: corruptBackupKey)
        }

        var recovered: [PairedDuck] = []
        if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let decoder = JSONDecoder()
            for element in array {
                guard JSONSerialization.isValidJSONObject(element),
                      let itemData = try? JSONSerialization.data(withJSONObject: element, options: []),
                      let duck = try? decoder.decode(PairedDuck.self, from: itemData) else {
                    continue
                }
                recovered.append(duck)
            }
        }
        return (recovered, true)
    }

    private func writeIndexLocked(_ ducks: [PairedDuck]) {
        guard let data = try? JSONEncoder().encode(ducks) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
