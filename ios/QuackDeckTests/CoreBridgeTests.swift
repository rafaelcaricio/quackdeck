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
}
