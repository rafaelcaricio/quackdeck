import SwiftUI

struct BatteryHealthCard: View {
    let health: HealthResult?
    var isCompact: Bool = false

    private var batteryColor: Color {
        guard let battery = health?.battery else {
            return QuackTheme.creamText.opacity(0.35)
        }
        if battery.isCritical { return QuackTheme.dangerRed }
        if battery.isLow { return QuackTheme.warnYellow }
        return QuackTheme.okGreen
    }

    private var busBadge: (text: String, color: Color) {
        guard let bus = health?.bus else {
            return ("Not read", QuackTheme.creamText.opacity(0.45))
        }
        if !bus.missing.isEmpty {
            return ("\(bus.missing.count) missing", QuackTheme.dangerRed)
        }
        if bus.startup_failures > 0 {
            return ("Bus down", QuackTheme.dangerRed)
        }
        if bus.consecutive_errors > 0 {
            return ("\(bus.consecutive_errors) errs", QuackTheme.warnYellow)
        }
        return ("OK", QuackTheme.okGreen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            HStack(spacing: 8) {
                Text("POWER & SYSTEM")
                    .font(QuackTheme.condensedDisplay(size: isCompact ? 13 : 14))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.85))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let battery = health?.battery {
                    Text(String(format: "%.2f V · %.0f%%", battery.volts, battery.percent))
                        .font(QuackTheme.monoValue(size: isCompact ? 11 : 12, weight: .bold))
                        .foregroundStyle(batteryColor)
                } else {
                    Text("Not read")
                        .font(QuackTheme.monoValue(size: isCompact ? 11 : 12, weight: .semibold))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.45))
                }
            }

            // Battery Bar
            GeometryReader { geo in
                let pct = max(0, min(100, health?.battery?.percent ?? 0)) / 100.0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                    if health?.battery != nil {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [batteryColor.opacity(0.85), batteryColor],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, geo.size.width * pct))
                    }
                }
            }
            .frame(height: isCompact ? 6 : 8)

            // Metrics Grid
            VStack(spacing: isCompact ? 5 : 7) {
                metricRow(
                    label: "Control Loop",
                    value: loopText,
                    valueColor: loopColor
                )

                metricRow(
                    label: "SoC Temp",
                    value: cpuText,
                    valueColor: cpuColor
                )

                metricRow(
                    label: "Motor Bus",
                    value: busBadge.text,
                    valueColor: busBadge.color
                )
            }

            if let missing = health?.bus.missing, !missing.isEmpty {
                Text("Missing servos: \(describeMissingServos(missing))")
                    .font(QuackTheme.monoValue(size: 11, weight: .medium))
                    .foregroundStyle(QuackTheme.dangerRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reason = health?.reason, health?.healthy == false {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(health?.degraded == true ? QuackTheme.warnYellow : QuackTheme.dangerRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(isCompact ? 10 : 14)
        .quackInsetCard(cornerRadius: isCompact ? 16 : 20)
    }

    private var loopText: String {
        guard let loop = health?.control_loop else { return "Not read" }
        let hzText = loop.achieved_hz.map { String(format: "%.1f Hz", $0) } ?? "Not read"
        if loop.missed > 0 {
            return "\(hzText) · \(loop.missed) missed"
        }
        return "\(hzText) / \(Int(loop.target_hz.rounded())) Hz"
    }

    private var loopColor: Color {
        guard let loop = health?.control_loop else { return QuackTheme.creamText.opacity(0.45) }
        if loop.missed > 5 { return QuackTheme.warnYellow }
        if let achieved = loop.achieved_hz, achieved < loop.target_hz * 0.85 {
            return QuackTheme.warnYellow
        }
        return loop.achieved_hz == nil ? QuackTheme.creamText.opacity(0.55) : QuackTheme.okGreen
    }

    private var cpuText: String {
        let tempPart: String
        if let cpu = health?.cpu_temp_c {
            tempPart = String(format: "%.0f °C", cpu)
        } else {
            tempPart = "Not read"
        }

        guard let throttle = health?.cpu_throttle else {
            return tempPart
        }
        if throttle.isThrottled {
            let mhz = throttle.khz / 1000
            return "\(tempPart) · THROTTLED (\(mhz) MHz)"
        }
        if throttle.khz > 0 {
            return "\(tempPart) · OK (\(throttle.khz / 1000) MHz)"
        }
        return "\(tempPart) · OK"
    }

    private var cpuColor: Color {
        if health?.cpu_throttle?.isThrottled == true {
            return QuackTheme.dangerRed
        }
        if let temp = health?.cpu_temp_c {
            if temp >= 85 { return QuackTheme.dangerRed }
            if temp >= 70 { return QuackTheme.warnYellow }
            return QuackTheme.creamText
        }
        return QuackTheme.creamText.opacity(0.45)
    }

    private func metricRow(label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: isCompact ? 11 : 12, weight: .medium))
                .foregroundStyle(QuackTheme.creamText.opacity(0.65))
            Spacer(minLength: 4)
            Text(value)
                .font(QuackTheme.monoValue(size: isCompact ? 11 : 12, weight: .semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func describeMissingServos(_ ids: [UInt8]) -> String {
        ids.map { id in
            if let index = MicroduckJoints.defaultIds.firstIndex(of: id),
               index < MicroduckJoints.defaultNames.count {
                return "\(id) \(MicroduckJoints.defaultNames[index])"
            }
            return "\(id)"
        }.joined(separator: ", ")
    }
}
