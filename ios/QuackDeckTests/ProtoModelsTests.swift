import XCTest
@testable import QuackDeck

final class ProtoModelsTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func testHealthResultRoundTripDecode() throws {
        let json = """
        {
          "healthy": true,
          "degraded": false,
          "reason": null,
          "battery": { "volts": 11.84, "percent": 74.5 },
          "goal_pwm": 640,
          "motors": { "hottest": "left_knee", "max_c": 54.2, "mean_c": 46.8 },
          "cpu_temp_c": 57.1,
          "cpu_throttle": { "level": 1, "max_level": 4, "khz": 1400000, "max_khz": 1800000 },
          "control_loop": { "target_hz": 50.0, "achieved_hz": 49.9, "ticks": 12450, "missed": 2, "last_tick_age_ms": 4 },
          "bus": { "consecutive_errors": 0, "startup_failures": 0, "missing": [14] },
          "imu": { "ready": true, "stale_blocks": 1, "consecutive_stale_blocks": 0, "missing": false }
        }
        """
        let decoded = try decoder.decode(HealthResult.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.healthy)
        XCTAssertEqual(decoded.battery?.volts ?? 0, 11.84, accuracy: 0.001)
        XCTAssertEqual(decoded.motors?.hottest, "left_knee")
        XCTAssertTrue(decoded.motors?.isWarning ?? false)
        XCTAssertFalse(decoded.motors?.isHot ?? true)
        XCTAssertTrue(decoded.cpu_throttle?.isThrottled ?? false)
        XCTAssertEqual(decoded.bus.missing, [14])
        XCTAssertTrue(decoded.imu?.ready ?? false)

        let reencoded = try encoder.encode(decoded)
        let roundTrip = try decoder.decode(HealthResult.self, from: reencoded)
        XCTAssertEqual(roundTrip, decoded)
    }

    func testRobotStateRoundTripDecode() throws {
        let joints = (0..<15).map { Double($0) * 0.05 }
        let targets = (0..<15).map { Double($0) * 0.05 + 0.01 }
        let currents = (0..<15).map { 150.0 + Double($0) * 10.0 }
        let json = """
        {
          "t": 42.5,
          "move": {
            "requested": [0.2, -0.1, 0.5],
            "applied": [0.18, -0.09, 0.45],
            "source": "webrtc",
            "limited_by": ["accel"]
          },
          "head": [0.1, -0.05, 0.25, 0.0],
          "policy": "walk",
          "safety": {
            "fallen": false,
            "limp": false,
            "gravity": [0.02, -0.01, -0.999],
            "gain": 650,
            "picked_up": false
          },
          "loop": { "hz": 50.0, "missed": 1 },
          "joints": \(joints),
          "targets": \(targets),
          "velocities": \(Array(repeating: 0.1, count: 15)),
          "currents_ma": \(currents),
          "odom": { "position": [1.2, -0.3, 0.24], "yaw": 0.42 },
          "t_ns": 42500000000,
          "imu": { "gyro": [0.01, -0.02, 0.45], "quat": [0.99, 0.01, -0.02, 0.12] }
        }
        """
        let decoded = try decoder.decode(RobotState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.policy, "walk")
        XCTAssertEqual(decoded.movement.requested, [0.2, -0.1, 0.5])
        XCTAssertEqual(decoded.movement.limited_by, ["accel"])
        XCTAssertEqual(decoded.control_loop.hz, 50.0)
        XCTAssertEqual(decoded.joints.count, 15)
        XCTAssertEqual(decoded.currents_ma.count, 15)
        XCTAssertEqual(decoded.imu?.quat.count, 4)

        let reencoded = try encoder.encode(decoded)
        let roundTrip = try decoder.decode(RobotState.self, from: reencoded)
        XCTAssertEqual(roundTrip, decoded)
    }

    func testTofFrameRoundTripAndValidity() throws {
        var distances = Array(repeating: 1200, count: 64)
        var statuses = Array(repeating: 5, count: 64)
        distances[0] = 180
        statuses[0] = 255 // Invalid ST status must be ignored
        distances[10] = 350
        statuses[10] = 9  // Valid ST status 9

        let json = """
        {
          "seq": 99,
          "at_us": 1234567,
          "t_ns": 987654321,
          "rows": 8,
          "cols": 8,
          "distance_mm": \(distances),
          "status": \(statuses)
        }
        """
        let decoded = try decoder.decode(TofFrame.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rows, 8)
        XCTAssertEqual(decoded.cols, 8)
        XCTAssertFalse(decoded.isValidZone(at: 0))
        XCTAssertTrue(decoded.isValidZone(at: 10))
        XCTAssertEqual(decoded.nearestValidDistanceMeters ?? 0, 0.35, accuracy: 0.0001)

        let reencoded = try encoder.encode(decoded)
        let roundTrip = try decoder.decode(TofFrame.self, from: reencoded)
        XCTAssertEqual(roundTrip, decoded)
    }

    func testHeadImuFrameRoundTripDecode() throws {
        let json = """
        {
          "seq": 501,
          "at_us": 555000,
          "t_ns": 555000000,
          "gyro": [0.1, -0.2, 0.3],
          "accel": [0.0, 0.0, -9.81],
          "quat": [1.0, 0.0, 0.0, 0.0],
          "temp_c": 36.4
        }
        """
        let decoded = try decoder.decode(HeadImuFrame.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.seq, 501)
        XCTAssertEqual(decoded.temp_c, 36.4, accuracy: 0.01)
        XCTAssertEqual(decoded.pitchRollDegrees.pitch, 0, accuracy: 0.001)
        XCTAssertEqual(decoded.pitchRollDegrees.roll, 0, accuracy: 0.001)

        let reencoded = try encoder.encode(decoded)
        let roundTrip = try decoder.decode(HeadImuFrame.self, from: reencoded)
        XCTAssertEqual(roundTrip, decoded)
    }

    func testNetStatusWithJoiningAndNetScanRoundTripDecode() throws {
        let statusJson = """
        {
          "state": "connecting",
          "ssid": "OldNet",
          "signal": 42,
          "ip4": null,
          "ip6": null,
          "mac": "02:11:22:33:44:55",
          "iface": "wlan0",
          "joining": {
            "ssid": "DuckLab",
            "step": "authenticating",
            "elapsed_seconds": 4,
            "timeout_seconds": 30
          }
        }
        """
        let status = try decoder.decode(NetStatusResult.self, from: Data(statusJson.utf8))
        XCTAssertEqual(status.state, .connecting)
        XCTAssertEqual(status.joining?.ssid, "DuckLab")
        XCTAssertEqual(status.joining?.step, .authenticating)

        let reencodedStatus = try encoder.encode(status)
        XCTAssertEqual(try decoder.decode(NetStatusResult.self, from: reencodedStatus), status)

        let scanJson = """
        {
          "networks": [
            { "ssid": "DuckLab", "signal": 91, "security": "wpa3_sae", "saved": true },
            { "ssid": "Guest", "signal": 65, "security": "open", "saved": false },
            { "ssid": "CorpNet", "signal": 50, "security": "enterprise", "saved": false }
          ]
        }
        """
        let scan = try decoder.decode(NetScanResult.self, from: Data(scanJson.utf8))
        XCTAssertEqual(scan.networks.count, 3)
        XCTAssertTrue(scan.networks[0].security.isSupported)
        XCTAssertTrue(scan.networks[1].security.isSupported)
        XCTAssertFalse(scan.networks[2].security.isSupported)

        let reencodedScan = try encoder.encode(scan)
        XCTAssertEqual(try decoder.decode(NetScanResult.self, from: reencodedScan), scan)

        let failedJson = """
        { "outcome": "failed", "reason": "bad_key", "detail": "802.11 auth failed" }
        """
        let connectFailed = try decoder.decode(ConnectResult.self, from: Data(failedJson.utf8))
        XCTAssertEqual(connectFailed, .failed(reason: .badKey, detail: "802.11 auth failed"))
    }

    func testPoliciesResultRoundTripDecodeAndSitstandVariants() throws {
        let fullJson = """
        {
          "mode": "walk",
          "enabled": true,
          "slots": [
            { "slot": "walk", "path": "velstand.onnx", "origin": "official", "overridden": false, "error": null },
            { "slot": "sitstand", "path": "alpha_sitstand.onnx", "origin": "custom", "overridden": true, "error": null }
          ],
          "skills": ["sit_toggle"],
          "homed": true,
          "sitting": false,
          "change_error": "busy"
        }
        """
        let decoded = try decoder.decode(PoliciesResult.self, from: Data(fullJson.utf8))
        XCTAssertEqual(decoded.mode, "walk")
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.homed, true)
        XCTAssertEqual(decoded.sitting, false)
        XCTAssertEqual(decoded.change_error, "busy")
        XCTAssertEqual(decoded.slots.count, 2)
        XCTAssertEqual(decoded.slots[1].origin, "custom")
        XCTAssertTrue(decoded.slots[1].overridden)
        XCTAssertEqual(decoded.skills, ["sit_toggle"])
        XCTAssertTrue(decoded.hasSitstandSlot)

        let reencoded = try encoder.encode(decoded)
        let roundTrip = try decoder.decode(PoliciesResult.self, from: reencoded)
        XCTAssertEqual(roundTrip, decoded)

        let nullSitstandJson = """
        {
          "mode": "walk",
          "enabled": true,
          "slots": [
            { "slot": "walk", "path": "velstand.onnx", "origin": "official", "overridden": false, "error": null },
            { "slot": "sitstand", "path": null, "origin": null, "overridden": false, "error": "missing file" }
          ],
          "skills": [],
          "homed": false,
          "sitting": false,
          "change_error": null
        }
        """
        let withoutSitstand = try decoder.decode(PoliciesResult.self, from: Data(nullSitstandJson.utf8))
        XCTAssertFalse(withoutSitstand.hasSitstandSlot)
        XCTAssertEqual(withoutSitstand.slots[1].error, "missing file")
        XCTAssertEqual(withoutSitstand.homed, false)

        // Older robotd builds may omit newer optional fields.
        let legacyJson = """
        {
          "mode": "walk",
          "enabled": true
        }
        """
        let legacy = try decoder.decode(PoliciesResult.self, from: Data(legacyJson.utf8))
        XCTAssertEqual(legacy.mode, "walk")
        XCTAssertTrue(legacy.enabled)
        XCTAssertEqual(legacy.slots, [])
        XCTAssertEqual(legacy.skills, [])
        XCTAssertNil(legacy.homed)
        XCTAssertNil(legacy.sitting)
        XCTAssertNil(legacy.change_error)
        XCTAssertFalse(legacy.hasSitstandSlot)
    }

    func testSubscribeResultRoundTripDecodeAndCompatibility() throws {
        let fullJson = """
        {
          "accepted": true,
          "walk": "velstand.onnx",
          "stand": "stand.onnx",
          "sitstand": "alpha_sitstand.onnx",
          "ground_pick": "ground_pick.onnx",
          "skills": ["sit_toggle", "ground_pick"],
          "unavailable": null
        }
        """
        let decoded = try decoder.decode(SubscribeResult.self, from: Data(fullJson.utf8))
        XCTAssertTrue(decoded.accepted)
        XCTAssertEqual(decoded.walk, "velstand.onnx")
        XCTAssertEqual(decoded.stand, "stand.onnx")
        XCTAssertEqual(decoded.sitstand, "alpha_sitstand.onnx")
        XCTAssertEqual(decoded.ground_pick, "ground_pick.onnx")
        XCTAssertEqual(decoded.skills, ["sit_toggle", "ground_pick"])
        XCTAssertNil(decoded.unavailable)

        let reencoded = try encoder.encode(decoded)
        let roundTrip = try decoder.decode(SubscribeResult.self, from: reencoded)
        XCTAssertEqual(roundTrip, decoded)

        let unavailableJson = """
        {
          "accepted": true,
          "walk": null,
          "stand": null,
          "sitstand": null,
          "skills": [],
          "unavailable": "no policy configured; holding the startup pose"
        }
        """
        let unavailable = try decoder.decode(SubscribeResult.self, from: Data(unavailableJson.utf8))
        XCTAssertEqual(unavailable.unavailable, "no policy configured; holding the startup pose")
        XCTAssertNil(unavailable.walk)
        XCTAssertNil(unavailable.sitstand)

        let minimalJson = "{}"
        let minimal = try decoder.decode(SubscribeResult.self, from: Data(minimalJson.utf8))
        XCTAssertTrue(minimal.accepted)
        XCTAssertEqual(minimal.skills, [])
        XCTAssertNil(minimal.walk)
        XCTAssertNil(minimal.stand)
        XCTAssertNil(minimal.sitstand)
        XCTAssertNil(minimal.unavailable)
    }

    func testSubscribeResultDecodeWithEmotionsAndDiscovery() throws {
        let json = """
        {
          "accepted": true,
          "walk": "velstand.onnx",
          "stand": null,
          "sitstand": "alpha_sitstand.onnx",
          "ground_pick": null,
          "skills": ["sit_toggle", "angry", "curious", "devastated", "yes_fast"],
          "unavailable": null
        }
        """
        let subscribe = try decoder.decode(SubscribeResult.self, from: Data(json.utf8))
        XCTAssertEqual(subscribe.skills, ["sit_toggle", "angry", "curious", "devastated", "yes_fast"])

        let reencoded = try encoder.encode(subscribe)
        XCTAssertEqual(try decoder.decode(SubscribeResult.self, from: reencoded), subscribe)

        let policies = PoliciesResult(
            mode: "walk",
            enabled: true,
            slots: [
                PolicySlot(slot: "walk", path: "velstand.onnx", origin: "official"),
                PolicySlot(slot: "sitstand", path: "alpha_sitstand.onnx", origin: "official")
            ],
            skills: ["sit_toggle"],
            homed: true,
            sitting: false
        )
        XCTAssertEqual(
            MicroduckEmotions.discover(subscribeAck: subscribe, policies: policies),
            ["angry", "curious", "devastated", "yes_fast"]
        )
    }

    func testMicroduckEmotionsHelpersAndDiscoveryEdgeCases() {
        XCTAssertEqual(MicroduckEmotions.defaultShippedNames.count, 13)
        XCTAssertEqual(
            MicroduckEmotions.defaultShippedNames,
            [
                "angry",
                "curious",
                "defiant",
                "devastated",
                "excited",
                "impatient",
                "laugh",
                "mmh",
                "mock",
                "no",
                "sad",
                "yes",
                "yes_fast"
            ]
        )

        // Display labels
        XCTAssertEqual(MicroduckEmotions.displayLabel(for: "yes_fast"), "Yes Fast")
        XCTAssertEqual(MicroduckEmotions.displayLabel(for: "mmh"), "Mmh")
        XCTAssertEqual(MicroduckEmotions.displayLabel(for: "curious"), "Curious")
        XCTAssertEqual(MicroduckEmotions.displayLabel(for: "super-happy_duck"), "Super Happy Duck")

        // Sitting predicate
        XCTAssertTrue(MicroduckEmotions.maySitRobot("devastated"))
        XCTAssertFalse(MicroduckEmotions.maySitRobot("curious"))
        XCTAssertFalse(MicroduckEmotions.maySitRobot("sad"))
        XCTAssertFalse(MicroduckEmotions.maySitRobot("sit_toggle"))

        // Shipped durations
        let expectedDurations: [String: TimeInterval] = [
            "angry": 2.5,
            "curious": 2.9,
            "defiant": 2.1,
            "devastated": 8.5,
            "excited": 3.3,
            "impatient": 2.5,
            "laugh": 2.9,
            "mmh": 1.9,
            "mock": 2.5,
            "no": 1.7,
            "sad": 7.5,
            "yes": 1.4,
            "yes_fast": 1.4
        ]
        for (name, expected) in expectedDurations {
            XCTAssertEqual(MicroduckEmotions.knownDurationSeconds(for: name), expected, "Duration mismatch for \(name)")
        }
        XCTAssertNil(MicroduckEmotions.knownDurationSeconds(for: "custom_dance"))

        // Nil ack gating
        let samplePolicies = PoliciesResult(skills: ["sit_toggle"])
        let sampleSubscribe = SubscribeResult(skills: ["sit_toggle", "curious"])
        XCTAssertEqual(MicroduckEmotions.discover(subscribeAck: nil, policies: nil), [])
        XCTAssertEqual(MicroduckEmotions.discover(subscribeAck: nil, policies: samplePolicies), [])
        XCTAssertEqual(MicroduckEmotions.discover(subscribeAck: sampleSubscribe, policies: nil), [])

        // Older daemons without emotion names in SubscribeResult.skills yield []
        let legacySubscribe = SubscribeResult(skills: ["sit_toggle", "ground_pick"])
        XCTAssertEqual(MicroduckEmotions.discover(subscribeAck: legacySubscribe, policies: samplePolicies), [])

        // Default 13 discovery after policy skills
        let defaultSubscribe = SubscribeResult(
            skills: ["sit_toggle", "ground_pick"] + MicroduckEmotions.defaultShippedNames
        )
        let fullPolicies = PoliciesResult(skills: ["sit_toggle", "ground_pick"])
        XCTAssertEqual(
            MicroduckEmotions.discover(subscribeAck: defaultSubscribe, policies: fullPolicies),
            MicroduckEmotions.defaultShippedNames
        )

        // Custom emotions, order preservation, deduplication, whitespace trimming, and policy-wins exclusion
        let customSubscribe = SubscribeResult(
            skills: [
                "  ",
                "sit_toggle",
                "happy_flap",
                "custom_policy",
                "ground_pick",
                "curious",
                "happy_flap",
                "  proud_spin  "
            ]
        )
        let customPolicies = PoliciesResult(skills: ["sit_toggle", "custom_policy"])
        XCTAssertEqual(
            MicroduckEmotions.discover(subscribeAck: customSubscribe, policies: customPolicies),
            ["happy_flap", "curious", "proud_spin"]
        )

        // Built-in kick skills are never treated as emotions
        let withKickSubscribe = SubscribeResult(skills: ["kick_left", "kick_right", "curious"])
        let noKickPolicies = PoliciesResult(skills: ["sit_toggle"])
        XCTAssertEqual(
            MicroduckEmotions.discover(subscribeAck: withKickSubscribe, policies: noKickPolicies),
            ["curious"]
        )
    }

    func testMicroduckKicksDiscoveryVariants() {
        let subAck = SubscribeResult(skills: ["kick_left", "kick_right", "curious"])
        // Never trust subscribeAck before PoliciesResult arrives
        XCTAssertEqual(MicroduckKicks.discover(policies: nil, subscribeAck: subAck), [])

        // Both kick slots loaded + present in skills
        let bothLoaded = PoliciesResult(
            slots: [
                PolicySlot(slot: "kick_left", path: "ball_kick_left.onnx", origin: "official"),
                PolicySlot(slot: "kick_right", path: "ball_kick_right.onnx", origin: "official")
            ],
            skills: ["kick_left", "kick_right"]
        )
        XCTAssertEqual(MicroduckKicks.discover(policies: bothLoaded, subscribeAck: subAck), [.left, .right])

        // Single loaded foot; explicit nil slot never advertises even if in skills
        let onlyLeft = PoliciesResult(
            slots: [
                PolicySlot(slot: "kick_left", path: "ball_kick_left.onnx", origin: "official"),
                PolicySlot(slot: "kick_right", path: nil, origin: nil)
            ],
            skills: ["kick_left", "kick_right"]
        )
        XCTAssertEqual(MicroduckKicks.discover(policies: onlyLeft, subscribeAck: subAck), [.left])

        // Legacy schema without kick slots falls back to PoliciesResult.skills
        let legacyRight = PoliciesResult(
            slots: [PolicySlot(slot: "walk", path: "velstand.onnx", origin: "official")],
            skills: ["kick_right"]
        )
        XCTAssertEqual(MicroduckKicks.discover(policies: legacyRight, subscribeAck: subAck), [.right])

        // Layout projection only flattens brief kick skills
        XCTAssertEqual(
            CockpitState.runningSkill(name: "kick_left").layoutProjected(hasSitstand: true),
            .walking(hasSitstand: true)
        )
        XCTAssertEqual(
            CockpitState.runningSkill(name: "ground_pick").layoutProjected(hasSitstand: true),
            .runningSkill(name: "ground_pick")
        )
    }

    func testVideoStageGeometryFillFitAndRotation() {
        let stage = CGSize(width: 375, height: 300)
        let media = MediaVideoInfo(width: 1280, height: 720, rotate: 0)

        let fit = VideoStageGeometry.compute(stageSize: stage, mediaVideo: media, framing: .fit)
        XCTAssertEqual(fit.imageRect.width, 375, accuracy: 0.01)
        XCTAssertEqual(fit.imageRect.height, 210.94, accuracy: 0.05)
        XCTAssertEqual(fit.imageRect.minY, 44.53, accuracy: 0.05)
        XCTAssertEqual(fit.visibleRect, fit.imageRect)
        // Touch inside top letterbox bar sends no gaze
        XCTAssertNil(fit.normalizedAim(forStagePoint: CGPoint(x: 180, y: 12)))
        // Center of visible video maps to (0, 0)
        let centerAim = fit.normalizedAim(forStagePoint: CGPoint(x: 187.5, y: 150))
        XCTAssertNotNil(centerAim)
        XCTAssertEqual(centerAim?.x ?? 99, 0, accuracy: 0.01)
        XCTAssertEqual(centerAim?.y ?? 99, 0, accuracy: 0.01)

        let fill = VideoStageGeometry.compute(stageSize: stage, mediaVideo: media, framing: .fill)
        XCTAssertEqual(fill.imageRect.width, 533.33, accuracy: 0.1)
        XCTAssertEqual(fill.imageRect.height, 300, accuracy: 0.01)
        XCTAssertEqual(fill.imageRect.minX, -79.17, accuracy: 0.1)
        XCTAssertEqual(fill.visibleRect, CGRect(x: 0, y: 0, width: 375, height: 300))
        // Aim on cropped left edge is hidden in Fill mode
        XCTAssertNil(fill.stagePoint(forNormalizedAim: CGPoint(x: -0.95, y: 0)))

        // 90° rotated stream swaps source aspect -> side letterbox bars in Full frame
        let rotatedMedia = MediaVideoInfo(width: 1280, height: 720, rotate: 90)
        let fit90 = VideoStageGeometry.compute(stageSize: stage, mediaVideo: rotatedMedia, framing: .fit)
        XCTAssertEqual(fit90.uprightSourceSize, CGSize(width: 720, height: 1280))
        XCTAssertEqual(fit90.imageRect.height, 300, accuracy: 0.01)
        XCTAssertLessThan(fit90.imageRect.width, 375)
        XCTAssertGreaterThan(fit90.imageRect.minX, 0)
    }
}
