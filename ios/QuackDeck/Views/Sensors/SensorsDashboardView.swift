import SwiftUI

struct SensorsDashboardView: View {
    let appState: AppState
    let isCompactDrawer: Bool

    init(appState: AppState, isCompactDrawer: Bool = false) {
        self.appState = appState
        self.isCompactDrawer = isCompactDrawer
    }

    private var loopBadge: (text: String, color: Color) {
        guard let health = appState.telemetry.health else {
            return appState.isConnected ? ("SYNC...", QuackTheme.warnYellow) : ("OFFLINE", QuackTheme.creamText.opacity(0.45))
        }
        if let hz = health.control_loop?.achieved_hz {
            let label = String(format: "%.0f HZ", hz)
            if !health.healthy {
                return ("\(label) \(health.degraded ? "WARN" : "FAULT")", health.degraded ? QuackTheme.warnYellow : QuackTheme.dangerRed)
            }
            return ("\(label) OK", QuackTheme.okGreen)
        }
        return (health.healthy ? "OK" : "CHECK", health.healthy ? QuackTheme.okGreen : QuackTheme.warnYellow)
    }

    var body: some View {
        Group {
            if isCompactDrawer {
                compactContent
            } else {
                fullPageContent
            }
        }
    }

    private var fullPageContent: some View {
        ZStack(alignment: .top) {
            QuackTheme.inkBg.ignoresSafeArea()

            HalftoneDotBackground()
                .frame(height: 180)
                .ignoresSafeArea(edges: .top)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(appState.currentDuckName.uppercased()) · LIVE TELEMETRY")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(QuackTheme.duckOrange)
                            .tracking(0.8)
                            .lineLimit(1)

                        Text("SENSORS")
                            .font(QuackTheme.condensedDisplay(size: 28))
                            .foregroundStyle(QuackTheme.creamText)
                    }

                    Spacer()

                    Text(loopBadge.text)
                        .font(QuackTheme.monoValue(size: 12, weight: .bold))
                        .foregroundStyle(loopBadge.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(loopBadge.color.opacity(0.15))
                                .overlay(Capsule().strokeBorder(loopBadge.color.opacity(0.35), lineWidth: 1))
                        )
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                if appState.motorThermalLevel != .normal, let banner = appState.thermalBannerText {
                    ThermalCautionBanner(level: appState.motorThermalLevel, message: banner, style: .inline)
                        .padding(.horizontal, 16)
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        cardsStack(compact: false)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var compactContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                if appState.motorThermalLevel != .normal, let banner = appState.thermalBannerText {
                    ThermalCautionBanner(level: appState.motorThermalLevel, message: banner, style: .inline)
                }
                cardsStack(compact: true)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func cardsStack(compact: Bool) -> some View {
        let t = appState.telemetry

        TofHeatmapCard(
            frame: t.tofFrame,
            tofHz: t.tofHz,
            isCompact: compact,
            isOverlayEnabled: Binding(
                get: { appState.isTofOverlayEnabled },
                set: { appState.isTofOverlayEnabled = $0 }
            ),
            overlayOpacity: Binding(
                get: { appState.tofOverlayOpacity },
                set: { appState.tofOverlayOpacity = $0 }
            )
        )

        ImuAttitudeCard(
            robotState: t.robotState,
            headImu: t.headImu,
            imuHealth: t.health?.imu,
            bodyPitchRoll: t.bodyPitchRollDegrees,
            isCompact: compact
        )

        BatteryHealthCard(
            health: t.health,
            isCompact: compact
        )

        ServoLoadGridCard(
            robotState: t.robotState,
            model: t.model,
            motors: t.health?.motors,
            isCompact: compact
        )
    }
}
