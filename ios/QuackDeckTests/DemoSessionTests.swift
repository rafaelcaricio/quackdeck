import SwiftUI
import XCTest
@testable import QuackDeck

@MainActor
final class DemoSessionTests: XCTestCase {
    private func waitUntil(
        timeoutSeconds: TimeInterval,
        pollIntervalNs: UInt64 = 50_000_000,
        condition: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return true
            }
            try await Task.sleep(nanoseconds: pollIntervalNs)
        }
        return condition()
    }

    func testDemoSessionBootsLimpByDefaultAndWalkingWhenRequested() async throws {
        let demoLimp = DemoRobotSession()
        demoLimp.connect()

        XCTAssertTrue(demoLimp.phase.isConnected)
        XCTAssertTrue(demoLimp.isDemoMode)
        XCTAssertEqual(demoLimp.videoSource, .demo)
        XCTAssertNotNil(demoLimp.telemetry.systemInfo)
        XCTAssertNotNil(demoLimp.telemetry.model)
        XCTAssertEqual(demoLimp.telemetry.model?.joint_names.count, 15)
        XCTAssertNotNil(demoLimp.telemetry.mediaVideo)
        XCTAssertEqual(demoLimp.telemetry.policies?.homed, false)
        XCTAssertEqual(demoLimp.telemetry.robotState?.policy, "held")
        XCTAssertEqual(demoLimp.telemetry.robotState?.safety.limp, false)

        let initialLimpState = CockpitStateResolver.resolve(
            phase: demoLimp.phase,
            health: demoLimp.telemetry.health,
            policies: demoLimp.telemetry.policies,
            subscribeAck: demoLimp.telemetry.subscribeAck,
            robotState: demoLimp.telemetry.robotState
        )
        XCTAssertEqual(initialLimpState, .limp(fallen: false))

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(demoLimp.telemetry.tofFrame)
        XCTAssertNotNil(demoLimp.telemetry.robotState)
        XCTAssertNotNil(demoLimp.telemetry.health)
        await demoLimp.disconnect()

        let demoWalking = DemoRobotSession(startWalking: true)
        demoWalking.connect()
        XCTAssertEqual(demoWalking.telemetry.policies?.homed, true)
        XCTAssertEqual(demoWalking.telemetry.robotState?.policy, "walk")
        let initialWalkState = CockpitStateResolver.resolve(
            phase: demoWalking.phase,
            health: demoWalking.telemetry.health,
            policies: demoWalking.telemetry.policies,
            subscribeAck: demoWalking.telemetry.subscribeAck,
            robotState: demoWalking.telemetry.robotState
        )
        XCTAssertEqual(initialWalkState, .walking(hasSitstand: true))
        await demoWalking.disconnect()
    }

    func testOperatorLifecycleThroughAppState() async throws {
        let appState = AppState()
        appState.startDemoMode()
        defer {
            Task { @MainActor in
                await appState.disconnect()
            }
        }

        XCTAssertEqual(appState.cockpitState, .limp(fallen: false))
        XCTAssertEqual(appState.telemetry.policies?.homed, false)
        XCTAssertEqual(appState.telemetry.robotState?.safety.limp, false)

        // U2 Limp -> confirm Init -> U3 Initializing
        await appState.requestAction(.initMotors)
        XCTAssertEqual(appState.pendingConfirmation, .initMotors)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .initializing)

        // U3 Initializing -> U4b Ready (~2.0 s homing ramp)
        let reachedReady = try await waitUntil(timeoutSeconds: 3.5) {
            appState.cockpitState == .readyHome(hasPolicy: true)
        }
        XCTAssertTrue(reachedReady, "Expected U4b Ready, got \(appState.cockpitState)")

        // U4b Ready -> confirm Walk -> U5 Walking
        await appState.requestAction(.walk)
        XCTAssertEqual(appState.pendingConfirmation, .startWalk(hotTempC: nil))
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))

        // Wait for 600 ms slot guard to expire, verify STOP keeps U5 Walking and zeroes motion
        let slotGuardCleared = try await waitUntil(timeoutSeconds: 1.2) {
            !appState.slotGuardActive
        }
        XCTAssertTrue(slotGuardCleared)

        appState.updateDriveStick(forward: 0.6, strafeLeft: -0.3)
        await appState.requestAction(.stopMoving)
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        XCTAssertEqual(appState.stickForward, 0)
        XCTAssertEqual(appState.stickStrafeLeft, 0)
        XCTAssertEqual(appState.telemetry.robotState?.movement.requested, [0, 0, 0])

        // U5 Walking -> Sit -> U6a Sitting -> U6b Seated (~2.2 s settle)
        await appState.requestAction(.sit)
        XCTAssertEqual(appState.pendingConfirmation, .sitExperimental)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .sittingDown)

        let reachedSeated = try await waitUntil(timeoutSeconds: 3.5) {
            appState.cockpitState == .seated
        }
        XCTAssertTrue(reachedSeated, "Expected U6b Seated, got \(appState.cockpitState)")

        // U6b Seated -> Stand -> U7 Rising -> U5 Walking (~1.0 s rise)
        await appState.requestAction(.standUp)
        XCTAssertEqual(appState.cockpitState, .rising)

        let returnedToWalking = try await waitUntil(timeoutSeconds: 2.5) {
            appState.cockpitState == .walking(hasSitstand: true)
        }
        XCTAssertTrue(returnedToWalking, "Expected U5 Walking after Stand, got \(appState.cockpitState)")

        // U5 Walking -> Relax (robot.relax) -> U2 Limp
        await appState.requestAction(.relax)
        XCTAssertEqual(appState.pendingConfirmation, .relaxOrRest(isSeated: false))
        await appState.confirmRelaxNow()
        XCTAssertEqual(appState.cockpitState, .limp(fallen: false))
        XCTAssertEqual(appState.telemetry.policies?.homed, false)

        await appState.disconnect()
    }

    func testSitAndRelaxRestLifecycleTransitionsThroughU11ToU2() async throws {
        let appState = AppState()
        appState.startDemoMode(startWalking: true)
        defer {
            Task { @MainActor in
                await appState.disconnect()
            }
        }

        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))

        await appState.requestAction(.relax)
        XCTAssertEqual(appState.pendingConfirmation, .relaxOrRest(isSeated: false))
        await appState.confirmRestAndRelax()
        XCTAssertEqual(appState.cockpitState, .resting(homed: true))

        let returnedToLimp = try await waitUntil(timeoutSeconds: 6.5) {
            appState.cockpitState == .limp(fallen: false)
        }
        XCTAssertTrue(returnedToLimp, "Expected U2 Limp after rest sequence, got \(appState.cockpitState)")
        XCTAssertEqual(appState.telemetry.policies?.homed, false)

        await appState.disconnect()
    }

    func testMoveLookQuackAndSensorsUpgrade() async throws {
        let demo = DemoRobotSession(startWalking: true)
        demo.connect()

        // Sensors visible upgrades rate and activates Head IMU updates
        demo.setSensorsVisible(true)
        XCTAssertEqual(demo.telemetry.tofHz, 15.0)

        demo.setMove(vx: 0.25, vy: -0.1, vyaw: 0.8)
        demo.setLook(y: 0.4, z: 0.35)
        XCTAssertNotEqual(demo.virtualGazeNormalized.x, 0)

        await demo.playQuack()
        XCTAssertNotNil(demo.lastQuackAt)
        XCTAssertEqual(demo.telemetry.statusBanner, "Quack!")

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(demo.telemetry.headImu)
        XCTAssertEqual(demo.telemetry.robotState?.movement.requested, [0.25, -0.1, 0.8])

        demo.lookCenter()
        XCTAssertEqual(demo.virtualGazeNormalized.x, 0)
        XCTAssertEqual(demo.virtualGazeNormalized.y, 0)
        XCTAssertFalse(demo.telemetry.lookClamped)

        await demo.disconnect()
        XCTAssertEqual(demo.phase, .disconnected)
        XCTAssertEqual(demo.videoSource, .none)
    }

    func testBackgroundingAppZeroesMotionIntents() async throws {
        let appState = AppState()
        appState.startDemoMode(startWalking: true)
        try await Task.sleep(nanoseconds: 100_000_000)

        appState.updateDriveStick(forward: 0.9, strafeLeft: -0.6)
        appState.updateTurnRocker(yawLeft: 0.75)
        XCTAssertEqual(appState.stickForward, 0.9, accuracy: 0.001)
        XCTAssertEqual(appState.stickStrafeLeft, -0.6, accuracy: 0.001)
        XCTAssertEqual(appState.turnYawLeft, 0.75, accuracy: 0.001)

        appState.handleScenePhaseChange(.background)
        XCTAssertEqual(appState.stickForward, 0)
        XCTAssertEqual(appState.stickStrafeLeft, 0)
        XCTAssertEqual(appState.turnYawLeft, 0)

        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(appState.telemetry.robotState?.movement.requested ?? [1, 1, 1], [0, 0, 0])

        await appState.disconnect()
    }

    func testLandscapeRotationRequestGeometryUpdate() async throws {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            XCTFail("Missing UIWindowScene")
            return
        }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { error in
            XCTFail("Geometry update failed: \(error)")
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let winSize = windowScene.windows.first?.bounds.size ?? .zero
        XCTAssertGreaterThan(winSize.width, winSize.height)

        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    func testForceReconnectZeroesMotionClearsConfirmationAndReconnectsDemoSession() async throws {
        let suiteName = "quackdeck.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vault = RobotVault(
            keychainService: "com.caricio.quackdeck.tests.\(UUID().uuidString)",
            defaultsKey: "pairedDucks.\(UUID().uuidString)",
            defaults: defaults
        )

        let appState = AppState(vault: vault)
        appState.startDemoMode(startWalking: true)
        defer {
            Task { @MainActor in
                await appState.disconnect()
            }
        }

        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        appState.updateDriveStick(forward: 0.75, strafeLeft: -0.5)
        appState.updateTurnRocker(yawLeft: 0.6)
        await appState.requestAction(.relax)
        XCTAssertEqual(appState.pendingConfirmation, .relaxOrRest(isSeated: false))

        await appState.forceReconnect()

        XCTAssertEqual(appState.stickForward, 0)
        XCTAssertEqual(appState.stickStrafeLeft, 0)
        XCTAssertEqual(appState.turnYawLeft, 0)
        XCTAssertNil(appState.pendingConfirmation)
        XCTAssertFalse(appState.isRetryingConnection)
        XCTAssertNil(appState.activeAlertMessage)
        XCTAssertTrue(appState.isDemoMode)
        XCTAssertTrue(appState.isConnected)
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        XCTAssertEqual(appState.telemetry.robotState?.movement.requested ?? [1, 1, 1], [0, 0, 0])

        await appState.disconnect()
    }

    func testForegroundAfterBackgroundKeepsMotionZeroed() async throws {
        let appState = AppState()
        appState.startDemoMode(startWalking: true)
        try await Task.sleep(nanoseconds: 100_000_000)

        appState.updateDriveStick(forward: 0.8, strafeLeft: -0.4)
        appState.updateTurnRocker(yawLeft: -0.7)
        appState.handleScenePhaseChange(.background)

        XCTAssertEqual(appState.stickForward, 0)
        XCTAssertEqual(appState.stickStrafeLeft, 0)
        XCTAssertEqual(appState.turnYawLeft, 0)

        appState.handleScenePhaseChange(.active)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(appState.stickForward, 0)
        XCTAssertEqual(appState.stickStrafeLeft, 0)
        XCTAssertEqual(appState.turnYawLeft, 0)
        XCTAssertEqual(appState.telemetry.robotState?.movement.requested ?? [1, 1, 1], [0, 0, 0])

        await appState.disconnect()
    }

    func testShutdownFromLimpPowersOffCleanlyAndAllowsReconnect() async throws {
        let appState = AppState()
        appState.startDemoMode()
        defer {
            Task { @MainActor in
                await appState.disconnect()
            }
        }

        XCTAssertEqual(appState.cockpitState, .limp(fallen: false))
        await appState.requestAction(.shutdown)
        XCTAssertEqual(appState.pendingConfirmation, .shutdown(mode: .immediateMotorsOff))
        await appState.confirmDialogAction()

        XCTAssertEqual(appState.cockpitState, .shuttingDown(homed: false))
        XCTAssertFalse(appState.canDrive)
        XCTAssertFalse(appState.canLook)

        let poweredOff = try await waitUntil(timeoutSeconds: 2.0) {
            appState.cockpitState == .offline && appState.telemetry.isPoweredOff
        }
        XCTAssertTrue(poweredOff, "Expected clean powered-off offline state, got \(appState.cockpitState)")
        XCTAssertEqual(appState.phase, .disconnected)
        XCTAssertEqual(appState.videoSource, .none)
        XCTAssertTrue(appState.canForceRetry)
        XCTAssertFalse(appState.telemetry.isAutoReconnecting)
        XCTAssertEqual(appState.guidanceTone, .neutral)
        XCTAssertTrue(appState.guidanceText?.contains("powered off") == true)

        // Reconnecting after simulated power-off brings Demo cleanly back to U2 Limp
        await appState.forceReconnect()
        XCTAssertTrue(appState.isConnected)
        XCTAssertFalse(appState.telemetry.isPoweredOff)
        XCTAssertEqual(appState.cockpitState, .limp(fallen: false))

        await appState.disconnect()
    }

    func testShutdownFromWalkingSitsAndSupportsMidShutdownRelaxBeforePowerOff() async throws {
        let appState = AppState()
        appState.startDemoMode(startWalking: true)
        defer {
            Task { @MainActor in
                await appState.disconnect()
            }
        }

        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        await appState.requestAction(.shutdown)
        XCTAssertEqual(appState.pendingConfirmation, .shutdown(mode: .sitAndPowerOff))
        await appState.confirmDialogAction()

        XCTAssertEqual(appState.cockpitState, .shuttingDown(homed: true))
        XCTAssertFalse(appState.canDrive)
        XCTAssertFalse(appState.canLook)

        // Emergency Relax during shutdown cuts torque immediately while power-off timer still completes
        await appState.requestAction(.relax)
        XCTAssertEqual(appState.pendingConfirmation, .relaxDirect)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .shuttingDown(homed: false))

        let poweredOff = try await waitUntil(timeoutSeconds: 6.5) {
            appState.cockpitState == .offline && appState.telemetry.isPoweredOff
        }
        XCTAssertTrue(poweredOff, "Expected shutdown timer to finish with power-off, got \(appState.cockpitState)")
        XCTAssertTrue(appState.canForceRetry)

        await appState.disconnect()
    }

    func testDemoSessionDefaultEmotionsAndOlderDaemonSimulation() async throws {
        let demo = DemoRobotSession(startWalking: true)
        demo.connect()

        XCTAssertEqual(demo.telemetry.policies?.skills, ["kick_left", "kick_right"])
        XCTAssertEqual(demo.telemetry.subscribeAck?.skills, ["kick_left", "kick_right"] + MicroduckEmotions.defaultShippedNames)
        XCTAssertEqual(demo.telemetry.availableEmotions, MicroduckEmotions.defaultShippedNames)
        XCTAssertEqual(demo.telemetry.availableEmotions.count, 13)
        XCTAssertEqual(demo.telemetry.availableKickSides, [.left, .right])

        // Older daemons advertise no emotions
        demo.simulateEmotions([])
        XCTAssertEqual(demo.telemetry.subscribeAck?.skills, ["kick_left", "kick_right"])
        XCTAssertEqual(demo.telemetry.availableEmotions, [])

        let refusedResult = await demo.triggerEmotion("curious")
        XCTAssertFalse(refusedResult.accepted)
        XCTAssertNil(demo.activeDemoEmotionName)

        demo.simulateEmotions(["curious", "yes"])
        XCTAssertEqual(demo.telemetry.availableEmotions, ["curious", "yes"])

        await demo.disconnect()
    }

    func testDemoSessionCuriousIgnoresStickAndDropsOverlappingRequests() async throws {
        let demo = DemoRobotSession(startWalking: true)
        demo.connect()

        demo.setMove(vx: 0.25, vy: -0.1, vyaw: 0.8)
        let first = await demo.triggerEmotion("curious")
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(demo.activeDemoEmotionName, "curious")
        XCTAssertEqual(demo.telemetry.robotState?.movement.requested, [0, 0, 0])
        XCTAssertEqual(demo.telemetry.robotState?.movement.applied, [0, 0, 0])

        // Stick updates while emotion plays must keep applied twist zeroed
        demo.setMove(vx: 0.2, vy: 0.1, vyaw: 0.5)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(demo.activeDemoEmotionName, "curious")
        XCTAssertEqual(demo.telemetry.robotState?.movement.applied, [0, 0, 0])

        // Overlapping robot.do is accepted on RPC and dropped silently by the control loop
        let overlap = await demo.triggerEmotion("yes")
        XCTAssertTrue(overlap.accepted)
        XCTAssertEqual(demo.lastDroppedEmotionName, "yes")
        XCTAssertEqual(demo.activeDemoEmotionName, "curious")

        let finished = try await waitUntil(timeoutSeconds: 4.0) {
            demo.activeDemoEmotionName == nil
        }
        XCTAssertTrue(finished, "Expected curious emotion to finish within 4.0 s")

        // Once emotion ends, stick velocity resumes applying
        let resumedStick = try await waitUntil(timeoutSeconds: 1.0) {
            (demo.telemetry.robotState?.movement.applied.first ?? 0) > 0.1
        }
        XCTAssertTrue(resumedStick)

        await demo.disconnect()
    }

    func testDemoSessionDevastatedSitsAndYesPlaysWhileSeated() async throws {
        let appState = AppState()
        appState.startDemoMode(startWalking: true)
        defer {
            Task { @MainActor in
                await appState.disconnect()
            }
        }

        // devastated sits the robot from U5 Walking into U6b Seated
        let devastatedResult = await appState.triggerEmotion("devastated")
        XCTAssertTrue(devastatedResult.accepted)
        XCTAssertEqual(appState.demoSessionInstance?.activeDemoEmotionName, "devastated")
        XCTAssertEqual(appState.telemetry.robotState?.policy, "sit")
        XCTAssertEqual(appState.telemetry.policies?.sitting, true)
        XCTAssertEqual(appState.cockpitState, .sittingDown)

        let reachedSeated = try await waitUntil(timeoutSeconds: 3.5) {
            appState.cockpitState == .seated
        }
        XCTAssertTrue(reachedSeated, "Expected U6b Seated after devastated sit settle")
        await appState.disconnect()

        // Fresh seated session verifies yes plays cleanly while seated
        let seatedAppState = AppState()
        seatedAppState.startDemoMode(startWalking: true)
        let slotGuardCleared = try await waitUntil(timeoutSeconds: 1.2) { !seatedAppState.slotGuardActive }
        XCTAssertTrue(slotGuardCleared)

        await seatedAppState.requestAction(.sit)
        await seatedAppState.confirmDialogAction()
        let isSeated = try await waitUntil(timeoutSeconds: 3.5) { seatedAppState.cockpitState == .seated }
        XCTAssertTrue(isSeated)

        let yesResult = await seatedAppState.triggerEmotion("yes")
        XCTAssertTrue(yesResult.accepted)
        XCTAssertEqual(seatedAppState.activeEmotionName, "yes")
        XCTAssertEqual(seatedAppState.demoSessionInstance?.activeDemoEmotionName, "yes")
        XCTAssertEqual(seatedAppState.telemetry.robotState?.policy, "sit")

        let yesFinished = try await waitUntil(timeoutSeconds: 2.5) {
            seatedAppState.demoSessionInstance?.activeDemoEmotionName == nil && seatedAppState.activeEmotionName == nil
        }
        XCTAssertTrue(yesFinished)
        XCTAssertEqual(seatedAppState.cockpitState, .seated)

        // Seated duck refuses kicks cleanly
        let seatedKick = await seatedAppState.triggerKick(.left)
        XCTAssertFalse(seatedKick.accepted)

        await seatedAppState.disconnect()
    }

    func testDemoSessionKickPlays0_5sAndReturnsToWalking() async throws {
        let demo = DemoRobotSession(startWalking: true)
        demo.connect()

        demo.setMove(vx: 0.2, vy: 0.0, vyaw: 0.3)
        let rightResult = await demo.triggerKick(.right)
        XCTAssertTrue(rightResult.accepted)
        XCTAssertEqual(demo.activeDemoKickSide, .right)
        XCTAssertEqual(demo.telemetry.robotState?.policy, "kick_right")
        XCTAssertEqual(demo.telemetry.robotState?.movement.requested, [0, 0, 0])

        let finished = try await waitUntil(timeoutSeconds: 1.5) {
            demo.activeDemoKickSide == nil && demo.telemetry.robotState?.policy == "walk"
        }
        XCTAssertTrue(finished)

        await demo.disconnect()
    }
}
