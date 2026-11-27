import XCTest
@testable import QuackDeck

@MainActor
final class CockpitStateTests: XCTestCase {
    // MARK: - Fixtures

    private func makeHealth(
        healthy: Bool = true,
        degraded: Bool = false,
        reason: String? = nil,
        ticks: UInt64 = 120,
        startupFailures: UInt32 = 0,
        missingIds: [UInt8] = [],
        imuReady: Bool = true,
        imuMissing: Bool = false,
        consecutiveStaleBlocks: UInt64 = 0
    ) -> HealthResult {
        HealthResult(
            healthy: healthy,
            degraded: degraded,
            reason: reason,
            battery: Battery(volts: 11.9, percent: 80.0),
            goal_pwm: 640,
            motors: MotorThermal(hottest: "left_knee", max_c: 42.0, mean_c: 38.0),
            cpu_temp_c: 50.0,
            cpu_throttle: CpuThrottle(level: 0, max_level: 4, khz: 1800000, max_khz: 1800000),
            control_loop: LoopHealth(target_hz: 50.0, achieved_hz: 50.0, ticks: ticks, missed: 0, last_tick_age_ms: 2),
            bus: BusHealth(consecutive_errors: 0, startup_failures: startupFailures, missing: missingIds),
            imu: ImuHealth(
                ready: imuReady,
                stale_blocks: consecutiveStaleBlocks,
                consecutive_stale_blocks: consecutiveStaleBlocks,
                missing: imuMissing
            )
        )
    }

    private func makePolicies(
        enabled: Bool = true,
        hasWalkSlot: Bool = true,
        hasSitstandSlot: Bool = true,
        skills: [String]? = nil,
        homed: Bool? = true,
        sitting: Bool? = false
    ) -> PoliciesResult {
        let effectiveSkills = skills ?? (hasSitstandSlot ? ["sit_toggle"] : [])
        let slots: [PolicySlot] = [
            PolicySlot(slot: "walk", path: hasWalkSlot ? "velstand.onnx" : nil, origin: hasWalkSlot ? "official" : nil),
            PolicySlot(slot: "sitstand", path: hasSitstandSlot ? "alpha_sitstand.onnx" : nil, origin: hasSitstandSlot ? "official" : nil)
        ]
        return PoliciesResult(
            mode: "walk",
            enabled: enabled,
            slots: slots,
            skills: effectiveSkills,
            homed: homed,
            sitting: sitting,
            change_error: nil
        )
    }

    private func makeSubscribe(
        walk: String? = "velstand.onnx",
        sitstand: String? = "alpha_sitstand.onnx",
        unavailable: String? = nil
    ) -> SubscribeResult {
        SubscribeResult(
            accepted: true,
            walk: walk,
            stand: nil,
            sitstand: sitstand,
            ground_pick: nil,
            skills: sitstand != nil ? ["sit_toggle"] : [],
            unavailable: unavailable
        )
    }

    private func makeRobotState(
        policy: String = "held",
        fallen: Bool = false,
        limp: Bool = false,
        pickedUp: Bool = false
    ) -> RobotState {
        RobotState(
            policy: policy,
            safety: SafetyState(fallen: fallen, limp: limp, picked_up: pickedUp)
        )
    }

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

    // MARK: - Priority Rules (U0 - U11)

    func testRule1OfflineForAllNonConnectedPhases() {
        let nonConnected: [ConnectionPhase] = [
            .disconnected,
            .scanning,
            .connectingBle,
            .authenticatingBle,
            .configuringWifi,
            .connectingLan,
            .connectingVideo,
            .error("LAN unreachable")
        ]
        let health = makeHealth()
        let policies = makePolicies()
        let robotState = makeRobotState(policy: "walk")

        for phase in nonConnected {
            let resolved = CockpitStateResolver.resolve(
                phase: phase,
                health: health,
                policies: policies,
                subscribeAck: makeSubscribe(),
                robotState: robotState
            )
            XCTAssertEqual(resolved, .offline, "Phase \(phase) must resolve to .offline")
        }
    }

    func testRule2HardwareBlockedBypassesSyncAndAllowsSoftDegradedWarnings() {
        let connected = ConnectionPhase.connected(transportLabel: "LAN")

        // startup_failures > 0
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: makeHealth(healthy: false, degraded: true, reason: "bus startup failed", startupFailures: 2),
                policies: nil,
                subscribeAck: nil,
                robotState: nil
            ),
            .hardwareBlocked(reason: "bus startup failed", homed: false)
        )

        // ticks == 0 with robotState == nil bypasses U-Sync
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: makeHealth(healthy: false, degraded: true, reason: nil, ticks: 0),
                policies: nil,
                subscribeAck: nil,
                robotState: nil
            ),
            .hardwareBlocked(reason: "check battery/motors", homed: false)
        )

        // missing servo IDs
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: makeHealth(healthy: false, degraded: true, reason: "missing servo 14", missingIds: [14]),
                policies: makePolicies(homed: false),
                subscribeAck: nil,
                robotState: makeRobotState()
            ),
            .hardwareBlocked(reason: "missing servo 14", homed: false)
        )

        // imu.missing == true
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: makeHealth(healthy: false, degraded: true, reason: "imu missing", imuReady: false, imuMissing: true),
                policies: makePolicies(homed: false),
                subscribeAck: nil,
                robotState: makeRobotState()
            ),
            .hardwareBlocked(reason: "imu missing", homed: false)
        )

        // Battery pack refusal ("torque stays off")
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: makeHealth(healthy: false, degraded: true, reason: "battery: 8.4 V too low; torque stays off"),
                policies: makePolicies(homed: false),
                subscribeAck: nil,
                robotState: makeRobotState()
            ),
            .hardwareBlocked(reason: "battery: 8.4 V too low; torque stays off", homed: false)
        )

        // Mid-run fault preserves homed: true so Relax remains accessible
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: makeHealth(healthy: false, degraded: true, reason: "servo 23 disconnected", missingIds: [23]),
                policies: makePolicies(homed: true),
                subscribeAck: nil,
                robotState: makeRobotState(policy: "walk")
            ),
            .hardwareBlocked(reason: "servo 23 disconnected", homed: true)
        )

        // Soft degraded warnings (cpu_throttle / servo status) must NOT block
        let softCpuThrottle = makeHealth(healthy: false, degraded: true, reason: "cpu throttled at 1.4 GHz")
        XCTAssertFalse(CockpitStateResolver.isHardBlocked(softCpuThrottle))
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: softCpuThrottle,
                policies: nil,
                subscribeAck: nil,
                robotState: nil
            ),
            .syncing
        )

        let softServoWarning = makeHealth(healthy: false, degraded: true, reason: "servo status: temperature warning")
        XCTAssertFalse(CockpitStateResolver.isHardBlocked(softServoWarning))
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: softServoWarning,
                policies: makePolicies(homed: true),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "walk")
            ),
            .walking(hasSitstand: true)
        )
    }

    func testRule3SyncingWhenAnyCoreTelemetryMissing() {
        let connected = ConnectionPhase.connected(transportLabel: "BLE")
        let health = makeHealth()
        let policies = makePolicies()
        let robotState = makeRobotState()

        XCTAssertEqual(
            CockpitStateResolver.resolve(phase: connected, health: nil, policies: policies, subscribeAck: nil, robotState: robotState),
            .syncing
        )
        XCTAssertEqual(
            CockpitStateResolver.resolve(phase: connected, health: health, policies: nil, subscribeAck: nil, robotState: robotState),
            .syncing
        )
        XCTAssertEqual(
            CockpitStateResolver.resolve(phase: connected, health: health, policies: policies, subscribeAck: nil, robotState: nil),
            .syncing
        )
    }

    func testRule4RestingPrecedenceAndHomedVariants() {
        let connected = ConnectionPhase.connected(transportLabel: "LAN")
        let health = makeHealth()

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: true),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "rest")
            ),
            .resting(homed: true)
        )

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: false),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "rest")
            ),
            .resting(homed: false)
        )

        // isRestingPending covers the sit phase of robot.rest before "rest" begins
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: true, sitting: true),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "sit"),
                isRestingPending: true
            ),
            .resting(homed: true)
        )
    }

    func testRule5InitializingAndPostHomingLatch() {
        let connected = ConnectionPhase.connected(transportLabel: "LAN")
        let health = makeHealth()

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: false),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "homing")
            ),
            .initializing
        )

        // Latch prevents 50 ms U2 Limp flash across homing -> held before policies refresh returns
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: false),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "held"),
                awaitingPostHomingPolicies: true
            ),
            .initializing
        )
    }

    func testRule6LimpVsReadyHomeAndStaleHomedFalse() {
        let connected = ConnectionPhase.connected(transportLabel: "LAN")
        let health = makeHealth()

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: false),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "held", fallen: false)
            ),
            .limp(fallen: false)
        )

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: false),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "held", fallen: true)
            ),
            .limp(fallen: true)
        )

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: true),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "held", fallen: false)
            ),
            .readyHome(hasPolicy: true)
        )

        // Stale homed == false when policy is already "walk" must not flicker U2 Limp
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: false),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "walk")
            ),
            .walking(hasSitstand: true)
        )
    }

    func testRules7And8FallenRecoveringAndFallenParked() {
        let connected = ConnectionPhase.connected(transportLabel: "LAN")
        let health = makeHealth()
        let homedPolicies = makePolicies(homed: true)

        // Rule 7: limp_fall, limp_pose, walk && fallen, sit && fallen, skill && fallen
        for policy in ["limp_fall", "limp_pose"] {
            XCTAssertEqual(
                CockpitStateResolver.resolve(
                    phase: connected,
                    health: health,
                    policies: homedPolicies,
                    subscribeAck: makeSubscribe(),
                    robotState: makeRobotState(policy: policy, fallen: true, limp: policy == "limp_fall")
                ),
                .fallenRecovering
            )
        }

        for policy in ["walk", "stand", "sit", "rise", "ground_pick"] {
            XCTAssertEqual(
                CockpitStateResolver.resolve(
                    phase: connected,
                    health: health,
                    policies: homedPolicies,
                    subscribeAck: makeSubscribe(),
                    robotState: makeRobotState(policy: policy, fallen: true)
                ),
                .fallenRecovering,
                "Policy \(policy) with fallen == true must resolve to .fallenRecovering"
            )
        }

        // Rule 8: policy == "held" && fallen (disarmed false vs true)
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: homedPolicies,
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "held", fallen: true, pickedUp: true),
                disarmedWhileFallen: false
            ),
            .fallenParked(disarmed: false)
        )

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: homedPolicies,
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "held", fallen: true),
                disarmedWhileFallen: true
            ),
            .fallenParked(disarmed: true)
        )
    }

    func testRule9PickedUpAndCapabilityFlags() {
        let connected = ConnectionPhase.connected(transportLabel: "LAN")
        let health = makeHealth()
        let policies = makePolicies(homed: true)

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: policies,
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "held", fallen: false, pickedUp: true)
            ),
            .pickedUp
        )

        // Verify U9 AppState safety capabilities through DemoRobotSession
        let appState = AppState()
        appState.startDemoMode(startWalking: true)
        appState.demoSessionInstance?.simulatePickedUp(true)
        appState.reconcileCockpitState()

        XCTAssertEqual(appState.cockpitState, .pickedUp)
        XCTAssertFalse(appState.canDrive)
        XCTAssertFalse(appState.canLook)
        XCTAssertFalse(appState.canSafeRest)

        Task { @MainActor in
            await appState.disconnect()
        }
    }

    func testRules10Through17RisingSitSeatedWalkingSkillImuAndReadyVariants() {
        let connected = ConnectionPhase.connected(transportLabel: "LAN")
        let health = makeHealth()
        let subscribe = makeSubscribe()

        // Rule 10: Rising
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: true),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "rise")
            ),
            .rising
        )
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: true, sitting: true),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "sit"),
                isAutoRising: true
            ),
            .rising
        )

        // Rule 11: Sitting Down (U6a) vs Rule 12: Seated (U6b)
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: true, sitting: true),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "sit"),
                isSitSettling: true
            ),
            .sittingDown
        )
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: true, sitting: true),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "sit"),
                isSitSettling: false
            ),
            .seated
        )

        // Rule 13: Walking (walk & stand, with and without sitstand)
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(hasSitstandSlot: true, homed: true),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "walk")
            ),
            .walking(hasSitstand: true)
        )
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(hasSitstandSlot: false, homed: true),
                subscribeAck: makeSubscribe(sitstand: nil),
                robotState: makeRobotState(policy: "stand")
            ),
            .walking(hasSitstand: false)
        )

        // Rule 14: Running Skill
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: true),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "ground_pick")
            ),
            .runningSkill(name: "ground_pick")
        )

        // Rule 15: Calibrating IMU (normal vs frozen)
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: makeHealth(imuReady: false, consecutiveStaleBlocks: 5),
                policies: makePolicies(homed: true),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "held")
            ),
            .calibratingImu(frozen: false)
        )
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: makeHealth(imuReady: false, consecutiveStaleBlocks: ImuHealth.frozenRun),
                policies: makePolicies(homed: true),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "held")
            ),
            .calibratingImu(frozen: true)
        )

        // Rule 16: Ready Seated (U4c) with and without walk policy
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(enabled: true, hasWalkSlot: true, homed: true, sitting: true),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "held")
            ),
            .readySeated(hasPolicy: true)
        )
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(enabled: false, hasWalkSlot: false, homed: true, sitting: true),
                subscribeAck: makeSubscribe(walk: nil, unavailable: "no policy configured"),
                robotState: makeRobotState(policy: "held")
            ),
            .readySeated(hasPolicy: false)
        )

        // Rule 17: Ready Home (U4b) with and without walk policy
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(enabled: true, hasWalkSlot: true, homed: true, sitting: false),
                subscribeAck: subscribe,
                robotState: makeRobotState(policy: "held")
            ),
            .readyHome(hasPolicy: true)
        )
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(enabled: true, hasWalkSlot: false, homed: true, sitting: false),
                subscribeAck: makeSubscribe(walk: nil),
                robotState: makeRobotState(policy: "held")
            ),
            .readyHome(hasPolicy: false)
        )
    }

    // MARK: - AppState Safety Guards & canLook

    func testStaleConfirmationAutoDismissesOnStateChange() async {
        let appState = AppState()
        appState.startDemoMode()

        // U2 Limp confirmation dismissed if hardware fault transitions to U1
        await appState.requestAction(.initMotors)
        XCTAssertEqual(appState.pendingConfirmation, .initMotors)

        appState.demoSessionInstance?.simulateHardwareBlocked(true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .hardwareBlocked(reason: "battery: 8.4 V too low; torque stays off", homed: false))
        XCTAssertNil(appState.pendingConfirmation)

        // U5 Walking Relax/Rest dialog dismissed if picked up transitions to U9
        await appState.disconnect()
        appState.startDemoMode(startWalking: true)
        await appState.requestAction(.relax)
        XCTAssertEqual(appState.pendingConfirmation, .relaxOrRest(isSeated: false))

        appState.demoSessionInstance?.simulatePickedUp(true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .pickedUp)
        XCTAssertNil(appState.pendingConfirmation)

        // confirmRestAndRelax pre-dispatch guard refuses if canSafeRest is false
        await appState.confirmRestAndRelax()
        XCTAssertEqual(appState.cockpitState, .pickedUp)
        XCTAssertNotNil(appState.activeAlertMessage)

        await appState.disconnect()
    }

    func testSlotGuardExemptsStopAndSafetyStates() async throws {
        let appState = AppState()
        appState.startDemoMode()

        // U2 -> U3 arms slot guard on .relax while initializing, but never on .stopMoving
        await appState.requestAction(.initMotors)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .initializing)
        XCTAssertTrue(appState.slotGuardActive)
        XCTAssertTrue(appState.isActionBlockedBySlotGuard(.relax))
        XCTAssertFalse(appState.isActionBlockedBySlotGuard(.stopMoving))

        // Safety/fault state clears slot guard immediately
        appState.demoSessionInstance?.simulateHardwareBlocked(true)
        appState.reconcileCockpitState()
        XCTAssertFalse(appState.slotGuardActive)
        XCTAssertFalse(appState.isActionBlockedBySlotGuard(.relax))

        // Reset to U4b Ready -> Walk -> U5 Walking to check walking slot guard
        await appState.disconnect()
        appState.startDemoMode()
        await appState.requestAction(.initMotors)
        await appState.confirmDialogAction()
        let reachedReady = try await waitUntil(timeoutSeconds: 3.5) {
            appState.cockpitState == .readyHome(hasPolicy: true)
        }
        XCTAssertTrue(reachedReady)

        await appState.requestAction(.walk)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        XCTAssertTrue(appState.slotGuardActive)
        XCTAssertTrue(appState.isActionBlockedBySlotGuard(.sit))
        XCTAssertTrue(appState.isActionBlockedBySlotGuard(.hold))
        XCTAssertFalse(appState.isActionBlockedBySlotGuard(.relax))
        XCTAssertFalse(appState.isActionBlockedBySlotGuard(.stopMoving))

        // STOP executes immediately even while slotGuardActive == true
        appState.updateDriveStick(forward: 0.8, strafeLeft: 0.4)
        await appState.requestAction(.stopMoving)
        XCTAssertEqual(appState.stickForward, 0)
        XCTAssertEqual(appState.stickStrafeLeft, 0)

        // Transitioning into a safety state (U9 Picked Up) clears slot guard immediately
        appState.demoSessionInstance?.simulatePickedUp(true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .pickedUp)
        XCTAssertFalse(appState.slotGuardActive)
        XCTAssertFalse(appState.isActionBlockedBySlotGuard(.hold))
        XCTAssertFalse(appState.isActionBlockedBySlotGuard(.relax))

        // Same when entering U10a Fallen Recovering
        appState.demoSessionInstance?.simulatePickedUp(false)
        appState.reconcileCockpitState()
        appState.demoSessionInstance?.simulateFallen(true, recovering: true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .fallenRecovering)
        XCTAssertFalse(appState.slotGuardActive)
        XCTAssertFalse(appState.isActionBlockedBySlotGuard(.cancelRecovery))

        await appState.disconnect()
    }

    func testCanLookTrueOnlyInWalkingAndSeated() async throws {
        let appState = AppState()

        // U0 Offline
        XCTAssertEqual(appState.cockpitState, .offline)
        XCTAssertFalse(appState.canLook)

        // U2 Limp
        appState.startDemoMode()
        XCTAssertEqual(appState.cockpitState, .limp(fallen: false))
        XCTAssertFalse(appState.canLook)

        // U1 Hardware Blocked
        appState.demoSessionInstance?.simulateHardwareBlocked(true)
        appState.reconcileCockpitState()
        XCTAssertFalse(appState.canLook)
        appState.demoSessionInstance?.simulateHardwareBlocked(false)
        appState.reconcileCockpitState()

        // U3 Initializing
        await appState.requestAction(.initMotors)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .initializing)
        XCTAssertFalse(appState.canLook)

        // U4b Ready Home
        let reachedReady = try await waitUntil(timeoutSeconds: 3.5) {
            appState.cockpitState == .readyHome(hasPolicy: true)
        }
        XCTAssertTrue(reachedReady)
        XCTAssertFalse(appState.canLook)

        // Verify setLook is ignored when canLook == false
        appState.setLook(y: 0.5, z: 0.4)
        XCTAssertEqual(appState.demoSessionInstance?.virtualGazeNormalized.x ?? -1, 0)

        // U4a Calibrating IMU
        appState.demoSessionInstance?.simulateImuCalibrating(true, frozen: false)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .calibratingImu(frozen: false))
        XCTAssertFalse(appState.canLook)
        appState.demoSessionInstance?.simulateImuCalibrating(false)
        appState.reconcileCockpitState()

        // U5 Walking -> canLook == true
        await appState.requestAction(.walk)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        XCTAssertTrue(appState.canLook)

        appState.setLook(y: 0.5, z: 0.35)
        XCTAssertNotEqual(appState.demoSessionInstance?.virtualGazeNormalized.x ?? 0, 0)
        appState.lookCenter()

        // U9 Picked Up -> canLook == false
        appState.demoSessionInstance?.simulatePickedUp(true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .pickedUp)
        XCTAssertFalse(appState.canLook)
        appState.demoSessionInstance?.simulatePickedUp(false)
        appState.reconcileCockpitState()

        // U10a Fallen Recovering -> canLook == false
        appState.demoSessionInstance?.simulateFallen(true, recovering: true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .fallenRecovering)
        XCTAssertFalse(appState.canLook)

        // U10b Fallen Parked -> canLook == false
        await appState.requestAction(.cancelRecovery)
        XCTAssertEqual(appState.cockpitState, .fallenParked(disarmed: true))
        XCTAssertFalse(appState.canLook)

        // Reset to U5 Walking to check U6a Sitting Down, U6b Seated, U7 Rising, U11 Resting
        await appState.disconnect()
        appState.startDemoMode(startWalking: true)
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        XCTAssertTrue(appState.canLook)

        // U6a Sitting Down -> canLook == false
        await appState.requestAction(.sit)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .sittingDown)
        XCTAssertFalse(appState.canLook)

        // U6b Seated -> canLook == true
        let reachedSeated = try await waitUntil(timeoutSeconds: 3.5) {
            appState.cockpitState == .seated
        }
        XCTAssertTrue(reachedSeated)
        XCTAssertTrue(appState.canLook)

        // U7 Rising -> canLook == false
        await appState.requestAction(.standUp)
        XCTAssertEqual(appState.cockpitState, .rising)
        XCTAssertFalse(appState.canLook)

        let returnedWalking = try await waitUntil(timeoutSeconds: 2.5) {
            appState.cockpitState == .walking(hasSitstand: true)
        }
        XCTAssertTrue(returnedWalking)

        // U11 Resting -> canLook == false
        await appState.requestAction(.relax)
        await appState.confirmRestAndRelax()
        XCTAssertEqual(appState.cockpitState, .resting(homed: true))
        XCTAssertFalse(appState.canLook)

        await appState.disconnect()
    }

    func testFreshAppStateOfflineCannotForceRetryAndShowsDefaultGuidance() {
        let suiteName = "quackdeck.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vault = RobotVault(
            keychainService: "com.caricio.quackdeck.tests.\(UUID().uuidString)",
            defaultsKey: "pairedDucks.\(UUID().uuidString)",
            defaults: defaults
        )

        let appState = AppState(vault: vault)
        XCTAssertTrue(appState.pairedDucks.isEmpty)
        XCTAssertNil(appState.lastConnectedDuck)
        XCTAssertNil(appState.activeSession)
        XCTAssertEqual(appState.cockpitState, .offline)
        XCTAssertFalse(appState.canForceRetry)
        XCTAssertEqual(appState.guidanceText, "Not connected · Open Ducks to pair or demo")
        XCTAssertEqual(appState.guidanceTone, .neutral)
    }

    func testShuttingDownPrecedenceAndHomedVariants() {
        let connected = ConnectionPhase.connected(transportLabel: "LAN")
        let health = makeHealth()
        let blockedHealth = makeHealth(healthy: false, degraded: true, reason: "battery: 8.4 V too low; torque stays off")

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: true),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "sit"),
                isShutdownPending: true
            ),
            .shuttingDown(homed: true)
        )

        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: health,
                policies: makePolicies(homed: false),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "held"),
                isShutdownPending: true
            ),
            .shuttingDown(homed: false)
        )

        // Shutdown precedence overrides hardwareBlocked while still connected
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: connected,
                health: blockedHealth,
                policies: makePolicies(homed: false),
                subscribeAck: nil,
                robotState: nil,
                isShutdownPending: true
            ),
            .shuttingDown(homed: false)
        )

        // Once link drops after OS power-off, .offline takes precedence
        XCTAssertEqual(
            CockpitStateResolver.resolve(
                phase: .disconnected,
                health: health,
                policies: makePolicies(homed: false),
                subscribeAck: makeSubscribe(),
                robotState: makeRobotState(policy: "held"),
                isShutdownPending: true
            ),
            .offline
        )
    }

    func testShutdownConfirmationModesRelaxMenuPickedUpBlockAndSlotGuard() async throws {
        let appState = AppState()
        appState.startDemoMode()
        defer {
            Task { @MainActor in
                await appState.disconnect()
            }
        }

        // U2 Limp -> immediate motors-off confirmation
        XCTAssertEqual(appState.cockpitState, .limp(fallen: false))
        await appState.requestAction(.shutdown)
        XCTAssertEqual(appState.pendingConfirmation, .shutdown(mode: .immediateMotorsOff))
        appState.cancelPendingConfirmation()

        // U1 Hardware Blocked (!homed) -> immediate motors-off confirmation
        appState.demoSessionInstance?.simulateHardwareBlocked(true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.shutdownConfirmationMode, .immediateMotorsOff)
        appState.demoSessionInstance?.simulateHardwareBlocked(false)
        appState.reconcileCockpitState()

        // U4b Ready -> Relax offers Relax or Shut Down; shutdown warns to hold robot
        await appState.requestAction(.initMotors)
        await appState.confirmDialogAction()
        let reachedReady = try await waitUntil(timeoutSeconds: 3.5) {
            appState.cockpitState == .readyHome(hasPolicy: true)
        }
        XCTAssertTrue(reachedReady)
        XCTAssertTrue(appState.canShutdownFromRelaxMenu)
        await appState.requestAction(.relax)
        XCTAssertEqual(appState.pendingConfirmation, .relaxOrShutdown)
        appState.cancelPendingConfirmation()
        await appState.requestAction(.shutdown)
        XCTAssertEqual(appState.pendingConfirmation, .shutdown(mode: .immediateCutTorque))
        appState.cancelPendingConfirmation()

        // U5 Walking (with sitstand) -> Relax offers Sit & Relax / Relax / Shut Down; shutdown sits then powers off
        await appState.requestAction(.walk)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        let guardCleared = try await waitUntil(timeoutSeconds: 1.2) { !appState.slotGuardActive }
        XCTAssertTrue(guardCleared)

        await appState.requestAction(.relax)
        XCTAssertEqual(appState.pendingConfirmation, .relaxOrRest(isSeated: false))
        appState.cancelPendingConfirmation()
        await appState.requestAction(.shutdown)
        XCTAssertEqual(appState.pendingConfirmation, .shutdown(mode: .sitAndPowerOff))

        // Transitioning to U9 Picked Up dismisses stale shutdown confirmation and blocks shutdown
        appState.demoSessionInstance?.simulatePickedUp(true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .pickedUp)
        XCTAssertNil(appState.pendingConfirmation)
        XCTAssertFalse(appState.canShutdownFromRelaxMenu)
        XCTAssertNil(appState.shutdownConfirmationMode)

        // Stale confirm is ignored while picked up
        await appState.confirm(.shutdown(mode: .sitAndPowerOff))
        XCTAssertEqual(appState.cockpitState, .pickedUp)

        // Relax in U9 Picked Up uses direct alert (never offers shutdown)
        await appState.requestAction(.relax)
        XCTAssertEqual(appState.pendingConfirmation, .relaxDirect)
        appState.cancelPendingConfirmation()

        // Direct shutdown request in U9 Picked Up surfaces safety notice
        await appState.requestAction(.shutdown)
        XCTAssertNil(appState.pendingConfirmation)
        XCTAssertNotNil(appState.activeAlertMessage)
        appState.activeAlertMessage = nil

        // Back to U5 Walking without sitstand -> immediateCutTorque + relaxOrShutdown
        appState.demoSessionInstance?.simulatePickedUp(false)
        appState.demoSessionInstance?.simulateNoSitstand(true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: false))
        await appState.requestAction(.relax)
        XCTAssertEqual(appState.pendingConfirmation, .relaxOrShutdown)
        appState.cancelPendingConfirmation()
        await appState.requestAction(.shutdown)
        XCTAssertEqual(appState.pendingConfirmation, .shutdown(mode: .immediateCutTorque))
        appState.cancelPendingConfirmation()

        // Relax -> U2 Limp arms 600 ms slot guard on .shutdown so stray taps cannot trigger shutdown
        await appState.confirmRelaxNow()
        XCTAssertEqual(appState.cockpitState, .limp(fallen: false))
        XCTAssertTrue(appState.slotGuardActive)
        XCTAssertTrue(appState.isActionBlockedBySlotGuard(.shutdown))

        let limpGuardCleared = try await waitUntil(timeoutSeconds: 1.2) { !appState.slotGuardActive }
        XCTAssertTrue(limpGuardCleared)
        XCTAssertFalse(appState.isActionBlockedBySlotGuard(.shutdown))

        await appState.disconnect()
    }

    func testTofOverlaySettingsDefaultClampAndPersist() {
        let suiteName = "quackdeck.tests.tof.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vault = RobotVault(
            keychainService: "com.caricio.quackdeck.tests.\(UUID().uuidString)",
            defaultsKey: "pairedDucks.\(UUID().uuidString)",
            defaults: defaults
        )

        let first = AppState(vault: vault, defaults: defaults)
        XCTAssertTrue(first.isTofOverlayEnabled)
        XCTAssertEqual(first.tofOverlayOpacity, AppState.defaultTofOverlayOpacity, accuracy: 0.001)

        // Clamp bounds and NaN
        first.tofOverlayOpacity = 0.0
        XCTAssertEqual(first.tofOverlayOpacity, AppState.tofOverlayOpacityRange.lowerBound, accuracy: 0.001)

        first.tofOverlayOpacity = 1.8
        XCTAssertEqual(first.tofOverlayOpacity, AppState.tofOverlayOpacityRange.upperBound, accuracy: 0.001)

        XCTAssertEqual(AppState.clampTofOverlayOpacity(.nan), AppState.defaultTofOverlayOpacity, accuracy: 0.001)

        // Persist across re-initialization
        first.isTofOverlayEnabled = false
        first.tofOverlayOpacity = 0.75

        let reloaded = AppState(vault: vault, defaults: defaults)
        XCTAssertFalse(reloaded.isTofOverlayEnabled)
        XCTAssertEqual(reloaded.tofOverlayOpacity, 0.75, accuracy: 0.001)
    }

    func testTofDepthPaletteNearestValidZoneIgnoresInvalidZones() {
        var distances = [Int16](repeating: 1200, count: 64)
        var statuses = [UInt8](repeating: 5, count: 64)
        // Invalid status with closer reading must be ignored
        distances[3] = 90
        statuses[3] = 255
        // Non-positive distance with valid status must be ignored
        distances[4] = 0
        statuses[4] = 5
        // Closest valid zone (status 9)
        distances[27] = 310
        statuses[27] = 9

        let frame = TofFrame(rows: 8, cols: 8, distance_mm: distances, status: statuses)
        let nearest = TofDepthPalette.nearestValidZone(in: frame)
        XCTAssertEqual(nearest?.index, 27)
        XCTAssertEqual(nearest?.distanceMm, 310)
    }

    func testFilterUnpairedDiscoveredDucksExcludesPairedByUuidIpAndName() {
        let now = Date()
        let duckAlphaUuid = UUID()
        let pairedByUuid = PairedDuck(
            robotId: "duck-alpha",
            name: "QuackOne",
            lastIp: "192.0.2.10",
            peripheralId: duckAlphaUuid
        )
        let pairedByLanOnly = PairedDuck(
            robotId: "duck-beta",
            name: "QuackBot",
            lastIp: "192.0.2.20",
            peripheralId: nil
        )
        let pairedGeneric = PairedDuck(
            robotId: "duck-generic",
            name: "Microduck",
            lastIp: "192.0.2.30",
            peripheralId: UUID()
        )
        let pairedList = [pairedByUuid, pairedByLanOnly, pairedGeneric]

        let matchUuid = DiscoveredDuck(
            id: duckAlphaUuid,
            name: "Microduck A1B2",
            advInfo: AdvInfo(),
            rssi: -45,
            lastSeen: now
        )
        let matchIp = DiscoveredDuck(
            id: UUID(),
            name: "Microduck 9999",
            advInfo: AdvInfo(hasAddressField: true, ipv4: "192.0.2.20"),
            rssi: -50,
            lastSeen: now
        )
        let matchCustomNameRotatedUuid = DiscoveredDuck(
            id: UUID(),
            name: "quackone",
            advInfo: AdvInfo(),
            rssi: -52,
            lastSeen: now
        )
        let matchRobotId = DiscoveredDuck(
            id: UUID(),
            name: "duck-beta",
            advInfo: AdvInfo(),
            rssi: -55,
            lastSeen: now
        )
        let newGenericDuck = DiscoveredDuck(
            id: UUID(),
            name: "Microduck",
            advInfo: AdvInfo(hasAddressField: true, ipv4: nil),
            rssi: -60,
            lastSeen: now
        )
        let newNamedDuck = DiscoveredDuck(
            id: UUID(),
            name: "Donald",
            advInfo: AdvInfo(hasAddressField: true, ipv4: "192.0.2.40"),
            rssi: -62,
            lastSeen: now
        )

        let filtered = AppState.filterUnpairedDiscoveredDucks(
            [matchUuid, matchIp, matchCustomNameRotatedUuid, matchRobotId, newGenericDuck, newNamedDuck],
            pairedDucks: pairedList
        )
        XCTAssertEqual(filtered.map(\.id), [newGenericDuck.id, newNamedDuck.id])

        // Once forgotten, its BLE entry reappears for pairing
        let afterForgettingAlpha = AppState.filterUnpairedDiscoveredDucks(
            [matchUuid, newNamedDuck],
            pairedDucks: [pairedByLanOnly, pairedGeneric]
        )
        XCTAssertEqual(afterForgettingAlpha.map(\.id), [matchUuid.id, newNamedDuck.id])
    }

    func testCanTriggerEmotionsAcrossAllCockpitStates() {
        let allStates: [CockpitState] = [
            .offline,
            .syncing,
            .hardwareBlocked(reason: "fault", homed: false),
            .hardwareBlocked(reason: "fault", homed: true),
            .limp(fallen: false),
            .limp(fallen: true),
            .initializing,
            .calibratingImu(frozen: false),
            .calibratingImu(frozen: true),
            .readyHome(hasPolicy: true),
            .readyHome(hasPolicy: false),
            .readySeated(hasPolicy: true),
            .readySeated(hasPolicy: false),
            .walking(hasSitstand: true),
            .walking(hasSitstand: false),
            .sittingDown,
            .seated,
            .rising,
            .runningSkill(name: "ground_pick"),
            .pickedUp,
            .fallenRecovering,
            .fallenParked(disarmed: false),
            .fallenParked(disarmed: true),
            .resting(homed: true),
            .resting(homed: false),
            .shuttingDown(homed: true),
            .shuttingDown(homed: false)
        ]

        let emotions = ["curious", "yes"]
        for state in allStates {
            let expected: Bool
            switch state {
            case .walking, .seated:
                expected = true
            default:
                expected = false
            }
            XCTAssertEqual(
                AppState.canTriggerEmotions(for: state, availableEmotions: emotions),
                expected,
                "Unexpected canTriggerEmotions for \(state) with non-empty emotions"
            )
            XCTAssertFalse(
                AppState.canTriggerEmotions(for: state, availableEmotions: []),
                "canTriggerEmotions must be false when availableEmotions is empty for \(state)"
            )
        }
    }

    func testTriggerEmotionGatingBusyNoteAndStateTransitionClearing() async throws {
        let appState = AppState()

        // Disconnected state rejects emotion triggering
        XCTAssertFalse(appState.canTriggerEmotions)
        let offlineResult = await appState.triggerEmotion("curious")
        XCTAssertFalse(offlineResult.accepted)
        XCTAssertNil(appState.activeEmotionName)

        // U2 Limp rejects emotion triggering
        appState.startDemoMode()
        XCTAssertEqual(appState.cockpitState, .limp(fallen: false))
        XCTAssertFalse(appState.canTriggerEmotions)
        let limpResult = await appState.triggerEmotion("curious")
        XCTAssertFalse(limpResult.accepted)
        await appState.disconnect()

        // U5 Walking accepts emotion, zeroes stick, and drops overlapping requests with status note
        appState.startDemoMode(startWalking: true)
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        XCTAssertEqual(appState.availableEmotions, MicroduckEmotions.defaultShippedNames)
        XCTAssertTrue(appState.canTriggerEmotions)

        let unknownResult = await appState.triggerEmotion("unknown_emotion")
        XCTAssertFalse(unknownResult.accepted)
        XCTAssertNil(appState.activeEmotionName)

        appState.updateDriveStick(forward: 0.7, strafeLeft: 0.3)
        let curiousResult = await appState.triggerEmotion("curious")
        XCTAssertTrue(curiousResult.accepted)
        XCTAssertEqual(appState.stickForward, 0)
        XCTAssertEqual(appState.stickStrafeLeft, 0)
        XCTAssertEqual(appState.activeEmotionName, "curious")

        let overlapResult = await appState.triggerEmotion("yes")
        XCTAssertFalse(overlapResult.accepted)
        XCTAssertEqual(appState.activeEmotionName, "curious")
        XCTAssertEqual(appState.emotionStatusNote, "Curious is still playing")

        // Transition to .pickedUp clears active emotion and status note
        appState.demoSessionInstance?.simulatePickedUp(true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .pickedUp)
        XCTAssertNil(appState.activeEmotionName)
        XCTAssertNil(appState.emotionStatusNote)

        // Transition to .fallenRecovering clears active emotion and status note
        await appState.disconnect()
        appState.startDemoMode(startWalking: true)
        _ = await appState.triggerEmotion("curious")
        _ = await appState.triggerEmotion("yes")
        XCTAssertEqual(appState.activeEmotionName, "curious")
        XCTAssertNotNil(appState.emotionStatusNote)

        appState.demoSessionInstance?.simulateFallen(true, recovering: true)
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.cockpitState, .fallenRecovering)
        XCTAssertNil(appState.activeEmotionName)
        XCTAssertNil(appState.emotionStatusNote)

        // Transition to .readyHome (Hold) clears active emotion and status note
        await appState.disconnect()
        appState.startDemoMode(startWalking: true)
        _ = await appState.triggerEmotion("curious")
        _ = await appState.triggerEmotion("yes")
        let guardClearedForHold = try await waitUntil(timeoutSeconds: 1.2) { !appState.slotGuardActive }
        XCTAssertTrue(guardClearedForHold)
        await appState.requestAction(.hold)
        XCTAssertEqual(appState.cockpitState, .readyHome(hasPolicy: true))
        XCTAssertNil(appState.activeEmotionName)
        XCTAssertNil(appState.emotionStatusNote)

        // Transition to .limp (Relax) clears active emotion and status note
        await appState.requestAction(.walk)
        await appState.confirmDialogAction()
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true))
        _ = await appState.triggerEmotion("curious")
        _ = await appState.triggerEmotion("yes")
        await appState.confirmRelaxNow()
        XCTAssertEqual(appState.cockpitState, .limp(fallen: false))
        XCTAssertNil(appState.activeEmotionName)
        XCTAssertNil(appState.emotionStatusNote)

        // devastated preserves active emotion across U5 -> U6a Sitting Down -> U6b Seated
        await appState.disconnect()
        appState.startDemoMode(startWalking: true)
        let devastatedResult = await appState.triggerEmotion("devastated")
        XCTAssertTrue(devastatedResult.accepted)
        XCTAssertEqual(appState.cockpitState, .sittingDown)
        XCTAssertEqual(appState.activeEmotionName, "devastated")

        let reachedSeated = try await waitUntil(timeoutSeconds: 3.5) {
            appState.cockpitState == .seated
        }
        XCTAssertTrue(reachedSeated, "Expected U6b Seated during devastated, got \(appState.cockpitState)")
        XCTAssertEqual(appState.activeEmotionName, "devastated")

        // Older daemon with no emotions disables emotion triggering
        appState.demoSessionInstance?.simulateEmotions([])
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.availableEmotions, [])
        XCTAssertFalse(appState.canTriggerEmotions)
        let emptyResult = await appState.triggerEmotion("yes")
        XCTAssertFalse(emptyResult.accepted)

        await appState.disconnect()
    }

    func testKickProjectionInhibitionAndP0SafetyGuards() async throws {
        let appState = AppState()
        appState.startDemoMode(startWalking: true)

        XCTAssertTrue(appState.canShowKicks)
        XCTAssertTrue(appState.canTriggerKick(.left))
        XCTAssertTrue(appState.canTriggerKick(.right))

        let resetBefore = appState.inputResetGeneration
        appState.updateDriveStick(forward: 0.7, strafeLeft: 0.2)
        appState.updateTurnRocker(yawLeft: 1.0)

        let kickResult = await appState.triggerKick(.left)
        XCTAssertTrue(kickResult.accepted)
        XCTAssertGreaterThan(appState.inputResetGeneration, resetBefore)
        XCTAssertEqual(appState.stickForward, 0)
        XCTAssertEqual(appState.stickStrafeLeft, 0)
        XCTAssertEqual(appState.turnYawLeft, 0)

        // Layout projects kick onto walking so STOP/stick/posture stay mounted without jitter
        XCTAssertEqual(appState.cockpitState, .runningSkill(name: "kick_left"))
        XCTAssertEqual(appState.layoutCockpitState, .walking(hasSitstand: true))
        XCTAssertEqual(appState.displayedActiveKickSide, .left)
        XCTAssertTrue(appState.isDrivingInputInhibited)
        XCTAssertTrue(appState.canDrive)
        XCTAssertTrue(appState.canShowStop)

        // Stick/turn inputs are suppressed while kicking
        appState.updateDriveStick(forward: 0.8, strafeLeft: 0.0)
        XCTAssertEqual(appState.stickForward, 0)

        // Overlapping kick or emotion is rejected cleanly while kicking
        let overlapKick = await appState.triggerKick(.right)
        XCTAssertFalse(overlapKick.accepted)
        let overlapEmo = await appState.triggerEmotion("yes")
        XCTAssertFalse(overlapEmo.accepted)

        // Wait for 0.5 s kick to finish cleanly
        let finished = try await waitUntil(timeoutSeconds: 1.5) {
            appState.cockpitState == .walking(hasSitstand: true) && !appState.isDrivingInputInhibited
        }
        XCTAssertTrue(finished)
        XCTAssertNil(appState.displayedActiveKickSide)

        // Single-foot and zero-foot policy states
        appState.demoSessionInstance?.simulateKickSides([.right])
        appState.reconcileCockpitState()
        XCTAssertEqual(appState.availableKickSides, [.right])
        XCTAssertFalse(appState.canTriggerKick(.left))
        XCTAssertTrue(appState.canTriggerKick(.right))

        appState.demoSessionInstance?.simulateKickSides([])
        appState.reconcileCockpitState()
        XCTAssertFalse(appState.canShowKicks)

        // P0 #4: Stale BoundCockpitConfirmation from an earlier session does not execute after session change
        await appState.requestAction(.relax)
        let staleBound = appState.pendingBoundConfirmation
        XCTAssertNotNil(staleBound)

        await appState.disconnect()
        appState.startDemoMode(startWalking: true)
        let resetDuringRetry = appState.cockpitState
        XCTAssertEqual(resetDuringRetry, .walking(hasSitstand: true))

        await appState.confirmRelaxNow(bound: staleBound)
        XCTAssertEqual(appState.cockpitState, .walking(hasSitstand: true), "Stale confirmation from earlier session must be ignored")

        await appState.disconnect()
    }
}
