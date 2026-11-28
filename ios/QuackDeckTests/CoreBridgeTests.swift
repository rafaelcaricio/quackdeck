import XCTest
@testable import QuackDeck

final class CoreBridgeTests: XCTestCase {
    func testGattUuidsMatchUpstreamConstants() throws {
        let uuids = try QuackDeckCore.gattUuids()
        XCTAssertEqual(uuids.serviceUuid, "6F5D2A10-3B47-4C8E-9A1F-2D7E8C4B6019")
        XCTAssertEqual(uuids.rpcUuid, "6F5D2A11-3B47-4C8E-9A1F-2D7E8C4B6019")
        XCTAssertEqual(uuids.companyId, 0xFFFF)
    }

    func testManufacturerDataDecodingVariants() throws {
        // CoreBluetooth prepends little-endian 0xFFFF company ID.
        let prefix = Data([0xFF, 0xFF])

        // 4-byte legacy IPv4: 192.0.2.10
        let legacy = try QuackDeckCore.parseManufacturerData(prefix + Data([192, 0, 2, 10]))
        XCTAssertTrue(legacy.hasAddressField)
        XCTAssertEqual(legacy.ipv4, "192.0.2.10")
        XCTAssertFalse(legacy.isExtended)
        XCTAssertFalse(legacy.isBusy)

        // 5-byte extended (4-byte IPv4 followed by 0x01 marker)
        let extended = try QuackDeckCore.parseManufacturerData(prefix + Data([192, 0, 2, 10, 0x01]))
        XCTAssertTrue(extended.hasAddressField)
        XCTAssertEqual(extended.ipv4, "192.0.2.10")
        XCTAssertTrue(extended.isExtended)
        XCTAssertFalse(extended.isBusy)

        // 5-byte busy (4-byte IPv4 followed by 0x02 marker)
        let busy = try QuackDeckCore.parseManufacturerData(prefix + Data([192, 0, 2, 10, 0x02]))
        XCTAssertTrue(busy.hasAddressField)
        XCTAssertEqual(busy.ipv4, "192.0.2.10")
        XCTAssertFalse(busy.isExtended)
        XCTAssertTrue(busy.isBusy)

        // 9-byte Apple-joined legacy (4B) + extended (5B)
        let joinedPayload = Data([192, 0, 2, 10, 192, 0, 2, 10, 0x01])
        let joined = try QuackDeckCore.parseManufacturerData(prefix + joinedPayload)
        XCTAssertTrue(joined.hasAddressField)
        XCTAssertEqual(joined.ipv4, "192.0.2.10")
        XCTAssertFalse(joined.isBusy)

        // 0.0.0.0 means address field is present without Wi-Fi IPv4
        let noWifi = try QuackDeckCore.parseManufacturerData(prefix + Data([0, 0, 0, 0]))
        XCTAssertTrue(noWifi.hasAddressField)
        XCTAssertNil(noWifi.ipv4)
    }

    func testSetupCodeValidAndInvalidParsing() throws {
        let upperHex = String(repeating: "AB", count: 32)
        let parsed = try QuackDeckCore.parseSetupCode("  md1:duck-01:\(upperHex) \n")
        XCTAssertEqual(parsed.robotId, "duck-01")
        XCTAssertEqual(parsed.pskHex, String(repeating: "ab", count: 32))

        XCTAssertThrowsError(try QuackDeckCore.parseSetupCode("md2:duck-01:\(upperHex)"))
        XCTAssertThrowsError(try QuackDeckCore.parseSetupCode("md1::\(upperHex)"))
        XCTAssertThrowsError(try QuackDeckCore.parseSetupCode("md1:duck-01:short"))
        XCTAssertThrowsError(try QuackDeckCore.parseSetupCode("md1:duck-01:" + String(repeating: "zz", count: 32)))
        XCTAssertThrowsError(try QuackDeckCore.parseSetupCode("md1:duck-01:\(upperHex):extra"))
    }

    func testSetupCodeFactoryQrPrefixAndInvalidPrefixes() throws {
        let upperHex = String(repeating: "CD", count: 32)
        let parsed = try QuackDeckCore.parseSetupCode("  SN-12345:md1:duck-932e:\(upperHex) \n")
        XCTAssertEqual(parsed.robotId, "duck-932e")
        XCTAssertEqual(parsed.pskHex, String(repeating: "cd", count: 32))

        XCTAssertThrowsError(try QuackDeckCore.parseSetupCode("notmd1:duck-932e:\(upperHex)"))
        XCTAssertThrowsError(try QuackDeckCore.parseSetupCode("SN-12345:notmd1:duck-932e:\(upperHex)"))
    }

    func testBleNoiseSessionBeginProducesFramedChunksAndRejectsBadKey() throws {
        let validHex = String(repeating: "5a", count: 32)
        let (session, initialChunks) = try BleNoiseSession.begin(
            pskHex: validHex,
            robotId: "duck-01",
            mtu: 20
        )
        XCTAssertFalse(initialChunks.isEmpty)
        XCTAssertTrue(initialChunks.allSatisfy { $0.count <= 20 })

        // Sealing before handshake completion must fail cleanly.
        XCTAssertThrowsError(try session.seal(jsonLine: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"system.info\"}", mtu: 185))

        // Invalid PSK length fails in begin.
        XCTAssertThrowsError(try BleNoiseSession.begin(pskHex: "deadbeef", robotId: "duck-01", mtu: 20))
    }

    func testRobotVaultPreservesCorruptBackupAndRecoversValidEntries() throws {
        let suiteName = "quackdeck.vaultTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultsKey = "pairedDucks.\(UUID().uuidString)"
        let vault = RobotVault(
            keychainService: "com.caricio.quackdeck.vaultTests.\(UUID().uuidString)",
            defaultsKey: defaultsKey,
            defaults: defaults
        )

        // Case 1: Mixed JSON array where one entry is valid and one is malformed -> lossy recovery + backup
        let mixedPayload = """
        [
          {"robotId":"duck-good","name":"Good Duck","pairedAt":1000},
          {"robotId":123,"broken":true}
        ]
        """.data(using: .utf8)!
        defaults.set(mixedPayload, forKey: defaultsKey)

        let recovered = vault.loadPairedDucks()
        XCTAssertTrue(vault.hasCorruptIndexBackup)
        XCTAssertEqual(recovered.map(\.robotId), ["duck-good"])

        // Case 2: Completely unparseable index blocks silent overwrite
        let corruptSuite = "quackdeck.corruptTests.\(UUID().uuidString)"
        let corruptDefaults = UserDefaults(suiteName: corruptSuite)!
        defer { corruptDefaults.removePersistentDomain(forName: corruptSuite) }
        let corruptKey = "pairedDucks.\(UUID().uuidString)"
        let corruptVault = RobotVault(
            keychainService: "com.caricio.quackdeck.corruptTests.\(UUID().uuidString)",
            defaultsKey: corruptKey,
            defaults: corruptDefaults
        )
        let rawGarbage = Data("not-json-at-all".utf8)
        corruptDefaults.set(rawGarbage, forKey: corruptKey)
        XCTAssertEqual(corruptVault.loadPairedDucks(), [])
        XCTAssertTrue(corruptVault.hasCorruptIndexBackup)
        XCTAssertEqual(corruptDefaults.data(forKey: "\(corruptKey).corruptBackup"), rawGarbage)
        XCTAssertThrowsError(
            try corruptVault.save(
                duck: PairedDuck(robotId: "duck-new", name: "New"),
                pskHex: String(repeating: "ab", count: 32)
            )
        )
    }

    func testRobotVaultPersistsPerDuckPreferencesAcrossMetadataAndReconnectSaves() throws {
        let suiteName = "quackdeck.prefVaultTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultsKey = "pairedDucks.\(UUID().uuidString)"
        let keychainService = "com.caricio.quackdeck.prefVaultTests.\(UUID().uuidString)"
        let vault = RobotVault(
            keychainService: keychainService,
            defaultsKey: defaultsKey,
            defaults: defaults
        )
        let psk = String(repeating: "cd", count: 32)
        defer {
            try? vault.remove(robotId: "duck-a")
            try? vault.remove(robotId: "duck-b")
        }

        try vault.save(duck: PairedDuck(robotId: "duck-a", name: "Phoebe"), pskHex: psk)
        try vault.save(duck: PairedDuck(robotId: "duck-b", name: "Daisy"), pskHex: psk)

        vault.updatePreferences(robotId: "duck-a", preferences: DuckPreferences(maxLinearSpeed: 0.15))
        vault.updatePreferences(robotId: "duck-b", preferences: DuckPreferences(maxLinearSpeed: 0.20))

        XCTAssertEqual(vault.pairedDuck(for: "duck-a")?.preferences.maxLinearSpeed ?? 0, 0.15, accuracy: 0.0001)
        XCTAssertEqual(vault.pairedDuck(for: "duck-b")?.preferences.maxLinearSpeed ?? 0, 0.20, accuracy: 0.0001)

        // Updating connection metadata must preserve per-duck preferences
        vault.updateConnectionMetadata(robotId: "duck-a", lastIp: "192.168.1.170", connectedAt: Date())
        XCTAssertEqual(vault.pairedDuck(for: "duck-a")?.preferences.maxLinearSpeed ?? 0, 0.15, accuracy: 0.0001)

        // Re-saving with preserved preferences keeps distinct caps isolated
        if var existingA = vault.pairedDuck(for: "duck-a") {
            existingA.name = "Phoebe Renamed"
            try vault.save(duck: existingA, pskHex: psk)
        }
        XCTAssertEqual(vault.pairedDuck(for: "duck-a")?.name, "Phoebe Renamed")
        XCTAssertEqual(vault.pairedDuck(for: "duck-a")?.preferences.maxLinearSpeed ?? 0, 0.15, accuracy: 0.0001)
        XCTAssertEqual(vault.pairedDuck(for: "duck-b")?.preferences.maxLinearSpeed ?? 0, 0.20, accuracy: 0.0001)
    }
}
