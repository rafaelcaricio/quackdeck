# QuackDeck: Native iPhone App for Microduck

QuackDeck is a native iPhone app for Microduck-compatible robots, including official Pollen Robotics Microducks and community/hardware forks. It pairs a SwiftUI adaptive cockpit with `stasel/WebRTC` hardware video decoding and a Rust static core compiled directly from upstream Microduck protocol crates.

## Direction

- **Protocol truth stays in upstream Rust crates.** BLE advertising/framing, `Noise_NNpsk0` crypto, and wire JSON schemas live in upstream `pollen-robotics/microduck` (`duck-ble`, `duck-auth`, `duck-ipc-proto`). Do not re-implement Noise handshakes or BLE chunk framing in Swift.
- **Keep the Swift <-> Rust boundary thin.** `quackdeck-core` exposes JSON-over-C-ABI functions (`qd_*`) bundled into `QuackDeckCore.xcframework`. `QuackDeckCore.swift` wraps every C call and frees returned strings with `qd_string_free`.
- **Behaviour follows official Microduck while supporting forks cleanly.** Fork-specific hardware traits (H.264 High profile `64001f`, absent `updaterd`/`hello`, 9-byte Apple-joined BLE advertisements, inverted camera mounts, `policy_on_arrival = false`, higher-load servo thermal limits) are handled cleanly without breaking official Microducks.
- **Minimal UI:** few buttons, little text. The operator has no gamepad.

## Repository layout

| Path | What |
|---|---|
| `LICENSE` | Apache License, Version 2.0 for QuackDeck (matching Pollen Robotics' Microduck crates; bundled into `QuackDeck.app`) |
| `NOTICE` | Copyright (`2026 Rafael Caricio`), Pollen Robotics attribution, and trademark/non-affiliation notice (bundled into `QuackDeck.app`) |
| `THIRD_PARTY_NOTICES.md` | Complete third-party notices for Pollen Robotics crates, WebRTC, and iOS Rust dependencies (bundled into `QuackDeck.app`) |
| `LICENSES/` | Full verbatim third-party license texts (`WebRTC-BSD-3-Clause.txt`, bundled into `QuackDeck.app`) |
| `docs/robot-state-machine.md` | Authoritative `robotd` wire state machine (S0–S10), transition matrix, RPC semantics, and hardware safety caveats |
| `docs/assets/` | README logo and app screenshots |
| `rust/quackdeck-core/` | Rust C-ABI crate (`adv.rs`, `setup_code.rs`, `ble_session.rs`, `lan_rpc.rs`, `lan_signalling.rs`, `include/quackdeck_core.h`, `include/module.modulemap`) |
| `scripts/build-rust.sh` | Builds `libquackdeck_core.a` for `aarch64-apple-ios` and `aarch64-apple-ios-sim` (iOS 17.0) and bundles `QuackDeckCore.xcframework` |
| `ios/Frameworks/QuackDeckCore.xcframework` | Prebuilt static XCFramework imported as `QuackDeckCoreFFI` (gitignored build output) |
| `project.yml` | XcodeGen source of truth (iOS 17.0+, `WebRTC` SPM, includes `ios/Signing.xcconfig`) |
| `ios/Signing.xcconfig` | Shared signing settings (`QUACKDECK_BUNDLE_IDENTIFIER`, `CODE_SIGN_STYLE`) that optionally include gitignored `ios/Local.xcconfig` |
| `.github/workflows/ci.yml` | GitHub Actions workflow running `cargo test` in `rust/` on pushes and pull requests |
| `ios/QuackDeck/Info.plist` | Bluetooth, Camera (QR), Local Network descriptions, Portrait + Landscape orientations, `UILaunchScreen` |
| `ios/QuackDeck/Assets.xcassets/` | `AppIcon.appiconset` (Default, Dark, Tinted 1024×1024), `AccentColor`, `LaunchBackground`, `LaunchLogo` |
| `ios/QuackDeck/App/` | `QuackDeckApp.swift` (`--demo`, `--demo-walking`, `scenePhase` safety), `AppState.swift` |
| `ios/QuackDeck/Bridge/` | `QuackDeckCore.swift` (C-ABI wrapper), `ProtoModels.swift` (`duck-ipc-proto` Swift `Codable` models) |
| `ios/QuackDeck/Storage/` | `RobotVault.swift` (Keychain PSK storage + `UserDefaults` paired-duck index) |
| `ios/QuackDeck/Theme/` | `QuackTheme.swift` (color tokens, glass modifiers, halftone dots, haptics) |
| `ios/QuackDeck/Transport/` | `RobotTransport.swift`, `BleManager.swift`, `WebRTCSession.swift`, `LiveRobotSession.swift`, `DemoRobotSession.swift` |
| `ios/QuackDeck/Views/` | `RootView.swift` (`--sensors`, `--landscape`), `Portrait/`, `Landscape/`, `Video/`, `Controls/`, `Sensors/`, `Pairing/` (including `DuckSettingsView.swift`) |
| `ios/QuackDeckTests/` | `CoreBridgeTests.swift`, `ProtoModelsTests.swift`, `DemoSessionTests.swift`, `CockpitStateTests.swift`, `LegalNoticesTests.swift` |

## Protocol and hardware invariants

Do not break these invariants when changing transports, WebRTC, or UI:

1. **H.264 High profile (`64001f`) via VideoToolbox:** Hardware encoders on some Microduck forks (such as `omxh264videoenc`) emit H.264 High profile (`profile-level-id=64001f`), which `Safari`/`WKWebView` reject. `H264HighProfileVideoDecoderFactory` in `ios/QuackDeck/Transport/WebRTCSession.swift` wraps `RTCDefaultVideoDecoderFactory` and advertises `64001f` alongside `640c1f` and `42e01f`, decoding via VideoToolbox (`RTCVideoDecoderH264`). Never replace native `WebRTC` video with a webview.
2. **Camera mount rotation:** On control datachannel open, query `media.video` (`{width, height, rotate}`; e.g. `180` on inverted camera mounts). Apply the rotation transform to `RTCMTLVideoView` inside an upright container in `ios/QuackDeck/Views/Video/VideoStageView.swift` so drag-to-look touch coordinates remain upright.
3. **Never gate on `hello`:** `updaterd` may be absent or masked on forks. Verify readiness with `system.info` and `robot.health`.
4. **CoreBluetooth quirks:**
   - Scan unfiltered (`scanForPeripherals(withServices: nil, ...)`), because bonded peripherals omit service UUIDs.
   - Decode manufacturer data through `QuackDeckCore.parseManufacturerData` (`duck-ble` plus 9-byte Apple-joined normalization in `rust/quackdeck-core/src/adv.rs`), handling 4-byte legacy, 5-byte extended (`0x01`), 5-byte busy (`0x02`, shown as non-connectable `Busy`), and 9-byte Apple-joined payloads (when BlueZ device privacy is off).
   - Read `RPC_UUID` before subscribing to trigger the iOS BLE bond and read the 1-byte API version.
   - Pair with `md1:<robot_id>:<64-hex>` (`QuackDeckCore.parseSetupCode`), store the PSK in Keychain via `RobotVault`, and run `Noise_NNpsk0` (`BleNoiseSession`).
   - Clamp outgoing GATT write chunks to `min(maximumWriteValueLength(for: .withResponse), 512)`.
   - Send a read-only keepalive (`robot.health` or `net.status`) every 20 s while connected on BLE so `btd`'s 60 s idle lease does not expire.
5. **LAN `duck-gateway` Noise TCP tunnels (no loopback ports):**
   - `:9444` (`LanRpcClient` in `rust/quackdeck-core/src/lan_rpc.rs`): NDJSON JSON-RPC (`system.info`, `robot.health`, `net.status`, `net.scan`, `net.connect`, `net.forget`).
   - `:9443` (`LanSignallingClient` in `rust/quackdeck-core/src/lan_signalling.rs`): `tokio::io::duplex` + `tokio-tungstenite` WebSocket signalling (`welcome` -> `list` -> `startSession` -> `sessionStarted` -> SDP offer/answer + ICE candidates, empty `iceServers` on LAN).
   - The robot opens the `"control"` datachannel; QuackDeck waits for `peerConnection(_:didOpen:)` and polls `inbound-rtp` stats every 500 ms, auto-reconnecting if decoded frames stall for `> 1000 ms`.
6. **Drive, gaze, and adaptive telemetry:**
   - `robot.move`: resent at 10 Hz while non-zero (linear velocity capped per paired duck via `DuckPreferences.maxLinearSpeed` in `0.05...0.30` m/s, default `0.30`; `maxAngularSpeed = 1.5`), with immediate `{0, 0, 0}` on finger release (robot enforces a 500 ms deadman).
   - Speaker audio (`robot.volume`, `robot.setVolume`, `robot.sound`): queried on WebRTC control open or BLE/`:9444` connect and adjusted from `My Ducks` -> `Duck Settings` (`DuckSettingsView.swift`) with slider-release persistence, Mute/Unmute, `±10%` steps, and `Test Quack`. Handles `applies: false` and older daemons (`-32601`/`14` -> `.unsupported`).
   - `robot.look`: resent at 10 Hz while dragging (`x: 1.0`, `y` in `±0.7`, `z` in `0.2 ± 0.45`, `neck_pitch: 0`), showing a `Limit` badge when `clamped: true`.
   - Emotions (`robot.do { "skill": "<emotion_name>" }`): discovered dynamically via `MicroduckEmotions.discover(subscribeAck:policies:)` (`SubscribeResult.skills` minus `PoliciesResult.skills` and reserved policy skills, empty on older daemons). Triggerable via `AppState.triggerEmotion(_:)` only in `U5 Walking` and `U6b Seated` (`AppState.canTriggerEmotions`); zeroes motion before dispatch, drops overlapping taps client-side with `emotionStatusNote`, and preserves active playback state when `devastated` transitions `U5 -> U6a -> U6b`.
   - **Autonomous kicks (`robot.do { "skill": "kick_left" | "kick_right" }`):** Discovered from `PoliciesResult.slots`/`PoliciesResult.skills` via `MicroduckKicks.discover` (`0.5 s` non-chaining one-shots). Triggerable via `AppState.triggerKick(_:)` only in `U5 Walking`; `CockpitState.layoutProjected(hasSitstand:)` projects brief kick execution onto `.walking` so driving controls, `STOP`, and the posture bar never tear down mid-kick while stick/turn/gaze input stays inhibited until completion.
   - Adaptive rates: Live view runs `robot.subscribe { hz: 2 }`, `robot.health` every 2 s, and `tof.stream`; opening the Sensors tab/drawer upgrades `robot.subscribe` to `{ hz: 10 }` and activates `head_imu.stream`.
   - Honest telemetry only: show the 15-joint current load (`mA`) and tracking error (`deg`) from `RobotState`, and only the hottest servo summary (`HealthResult.motors`: `hottest`, `max_c`, `mean_c`). Never fabricate 15 per-servo temperatures.
7. **Robot state machine and bring-up truth (`docs/robot-state-machine.md`):**
   - `robot.state.safety.limp` is only `true` during `LimpFall::Limp`, NOT torque-off (`Bringup::Limp`). Determine torque-off vs homed/seated by polling `robot.policies` (`homed`, `sitting`, `slots`) alongside `robot.state` and `robot.health` (`imu.ready`). Note that `PoliciesResult.enabled` is the static `[policy] enabled` config flag, not runtime policy enable.
   - Do not map a generic "Stand" button to `robot.init`: `robot.init` powers joints and runs a 2 s homing ramp (and is a no-op when seated); use `robot.enable` (`on: true`/`false`) to start/stop driving and `robot.do { skill: "sit_toggle" }` for sit/stand when the `sitstand` slot is loaded. `robot.stop` only zeroes velocity twist.

## UI, theme, and assets

- **Portrait:** Camera-first live feed with a toggleable `Full frame` (`Fit`) vs `Fill screen` (`Fill`) framing preference (`@AppStorage("portraitVideoFraming")`, 44×44 corner toggle + double-tap on visible video, shared `VideoStageGeometry` aligning `RTCMTLVideoView`, `DemoVideoView`, 8×8 ToF overlay, and drag-to-look while ignoring letterbox touches), top floating glass status pill (showing robot name and battery percentage) + red `STOP` button (`U5 Walking` only), `ActiveEmotionBadgePill` below the top row while a kick or emotion plays, unified bottom-camera telemetry pill (`TOF` | temp | `FPS`) alongside the framing button, dedicated `48 pt` `P3` action strip between camera and drive controls (`Emote` leading -> auto-closing 3-column glass `EmotionsPickerPanel` with `May sit` badges, plus physical-left/right `Kick L` / `Kick R` `80×48` pair trailing in `U5`), bottom 1-line guidance strip + fixed-slot state-driven posture bar (`Shut Down` when motors are off, `Init`, `Walk`, `Hold`, `Sit`, `Stand`, `Relax` with `Sit & Relax` rest and `Shut Down Robot` options), virtual thumbstick + turn buttons (`U5` only), `QUACK` + `Look Center` (drag-to-look gated to `U5` Walking and `U6b` Seated), and floating glass tab bar (`Live` · `Sensors` · `Ducks`).
- **Landscape:** Full-bleed edge-to-edge `.fill` video (never alters saved Portrait framing) with the aligned 8×8 ToF depth overlay respecting Dynamic Island / safe-area insets, slim top floating glass bar (`TOF` chip opens live opacity controls, `—°` when pitch unavailable, `STOP` in `U5` only), centered `ActiveEmotionBadgePill` below the top bar, left thumbstick (`U5` only), bottom-center guidance pill + compact fixed-slot posture pill (including `Shut Down` when motors are off and inside `Relax`), right `L2` cluster (anchored `.overlay` 4-column glass `EmotionsPickerPanel`, compact `Emote` + `Center` + calm `QUACK` above `Kick L`/`Kick R` `48×48` tiles beside compact `Turn L`/`R` rocker in `U5`), and right slide-over glass `Sensors` drawer.
- **Visual tokens (`QuackTheme.swift`):** `inkBg` `#08080c`, `inkSurface` `#101018`, `inkCard` `#14141d`, `creamText` `#faf8f2`, `duckOrange` `#ff7a2f`, `warnYellow` `#ffd23f`, `acidCyan` `#2ff0e6`, `acidMagenta` `#ff2fa8`, `okGreen` `#4ce08a`, `dangerRed` `#ff4b3a`. SF Pro UI controls, condensed bold uppercase display headers, tabular monospace digits (`.monospacedDigit()`).
- **App icons & launch assets (`Assets.xcassets`):** `AppIcon` (Default, Dark, Tinted opaque 1024×1024 PNGs), `AccentColor` (`#FF7A2F`), `LaunchBackground` (`#171823`), and `LaunchLogo` (`@1x`/`@2x`/`@3x`).

## Build, signing, and verification workflow

Always edit `project.yml` rather than editing `QuackDeck.xcodeproj` directly. Machine-specific signing overrides belong in the gitignored `ios/Local.xcconfig` file (included by `ios/Signing.xcconfig`), and optional local Microduck crate overrides belong in the gitignored `rust/.cargo/config.toml`.

```bash
# 1. Rust core unit tests
cd rust && cargo test

# 2. Build QuackDeckCore.xcframework (use release for device builds)
./scripts/build-rust.sh debug

# 3. Regenerate Xcode project and run Swift unit tests on an available iOS Simulator
xcodegen generate && \
  xcodebuild test -project QuackDeck.xcodeproj -scheme QuackDeck \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Offline Demo Mode launch arguments for Simulator UI verification:
- `--demo` — starts `DemoRobotSession` in `U2 Limp` immediately on launch (`QuackDeckApp.swift`). Simulates all 13 default Microduck emotions (`MicroduckEmotions.defaultShippedNames`), per-emotion head/body/mouth animations, stick-ignore and silent-drop behavior during playback, and `devastated` sitting into `U6b Seated`.
- `--demo-walking` — starts `DemoRobotSession` directly in `U5 Walking` (combine with `--demo`).
- `--sensors` — opens the Sensors tab/drawer on launch (`RootView.swift`).
- `--landscape` — forces the Landscape cockpit layout (`RootView.swift`).

## Robot safety notes

- Always ask the operator to hold the robot before enabling torque, taking torque off, or starting a policy.
- `Relax` (`robot.relax`) must always prompt for confirmation before sending, because servos go limp immediately.
- `Shut Down` (`robot.shutdown`) runs over the WebRTC `"control"` datachannel only (`btd` refuses it on BLE/`:9444`), always prompts with state-specific confirmation (and is blocked while `picked_up`), and disables auto-reconnect once accepted so the app lands cleanly in a powered-off offline state.
- Whenever `scenePhase != .active`, immediately zero stick/turn state and close active motion intents.
- Monitor servo thermal warnings (`warnTempC = 52.0`, `hotTempC = 58.0`); keep standing/walking runs short on high-load servo builds and let servos cool below `40 °C`.
- Power the robot off before plugging or unplugging servos. Say "turn the robot off" rather than telling the operator to pull the battery.

## Local overrides

Machine-specific notes (local sibling repos, Apple Developer Team ID, test device identifiers, SSH hosts) belong in gitignored local files (`ios/Local.xcconfig`, `rust/.cargo/config.toml`, `.agents/rules/local.md`) and must not be committed to the public repository.
