import SwiftUI

struct ServoLoadGridCard: View {
    let robotState: RobotState?
    let model: ModelResult?
    let motors: MotorThermal?
    var isCompact: Bool = false

    private var jointNames: [String] {
        if let names = model?.joint_names, names.count >= 15 {
            return Array(names.prefix(15))
        }
        return MicroduckJoints.defaultNames
    }

    private var thermalColor: Color {
        guard let motors else { return QuackTheme.creamText.opacity(0.5) }
        if motors.isHot { return QuackTheme.dangerRed }
        if motors.isWarning { return QuackTheme.warnYellow }
        return QuackTheme.okGreen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
            HStack(alignment: .center, spacing: 6) {
                Text("15 JOINTS · LOAD & ERROR")
                    .font(QuackTheme.condensedDisplay(size: isCompact ? 13 : 14))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.85))
                    .lineLimit(1)

                Spacer(minLength: 4)

                hottestPill
            }

            if let motors {
                HStack(spacing: 8) {
                    Text("Hottest: \(formatJointName(motors.hottest))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(thermalColor)
                    Spacer()
                    Text(String(format: "Max %.0f °C · Mean %.0f °C", motors.max_c, motors.mean_c))
                        .font(QuackTheme.monoValue(size: 11, weight: .medium))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.7))
                }

                if motors.isHot {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: QuackIcon.thermalHot)
                            .font(.system(size: 12, weight: .bold))
                        Text("Servos hot (>= 58 °C). Rest robot and let cool below 40 °C.")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(QuackTheme.dangerRed)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(QuackTheme.dangerRed.opacity(0.14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(QuackTheme.dangerRed.opacity(0.45), lineWidth: 1)
                            )
                    )
                }
            }

            Divider()
                .overlay(QuackTheme.subtleBorder)

            VStack(spacing: isCompact ? 5 : 7) {
                ForEach(Array(jointNames.enumerated()), id: \.offset) { idx, name in
                    jointRow(index: idx, name: name)
                }
            }
        }
        .padding(isCompact ? 10 : 14)
        .quackInsetCard(cornerRadius: isCompact ? 16 : 20)
    }

    private var hottestPill: some View {
        Group {
            if let motors {
                Text(String(format: "%.0f °C MAX", motors.max_c))
                    .font(QuackTheme.monoValue(size: 10, weight: .bold))
                    .foregroundStyle(thermalColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(thermalColor.opacity(0.16)))
            } else {
                Text("TEMP --")
                    .font(QuackTheme.monoValue(size: 10, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.45))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }
        }
    }

    private func jointRow(index: Int, name: String) -> some View {
        let currentMa: Double? = {
            guard let list = robotState?.currents_ma, index < list.count else { return nil }
            return list[index]
        }()

        let errorDeg: Double? = {
            guard let joints = robotState?.joints,
                  let targets = robotState?.targets,
                  index < joints.count,
                  index < targets.count else { return nil }
            return abs(targets[index] - joints[index]) * 180.0 / .pi
        }()

        let isHottest = motors?.hottest == name
        let loadRatio = currentMa.map { max(0, min(1, $0 / 1200.0)) } ?? 0
        let loadColor = colorForCurrent(currentMa)

        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(formatJointName(name))
                    .font(.system(size: isCompact ? 11 : 12, weight: isHottest ? .bold : .medium))
                    .foregroundStyle(isHottest ? thermalColor : QuackTheme.creamText.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 4)

                Text(errorDeg.map { String(format: "Δ%.1f°", $0) } ?? "Δ--")
                    .font(QuackTheme.monoValue(size: isCompact ? 10 : 11, weight: .medium))
                    .foregroundStyle(errorColor(errorDeg))
                    .frame(width: isCompact ? 42 : 48, alignment: .trailing)

                Text(currentMa.map { "\(Int($0.rounded())) mA" } ?? "-- mA")
                    .font(QuackTheme.monoValue(size: isCompact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(currentMa == nil ? QuackTheme.creamText.opacity(0.4) : loadColor)
                    .frame(width: isCompact ? 54 : 62, alignment: .trailing)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    if currentMa != nil {
                        Capsule()
                            .fill(loadColor)
                            .frame(width: max(2, geo.size.width * loadRatio))
                    }
                }
            }
            .frame(height: isCompact ? 3 : 4)
        }
    }

    private func colorForCurrent(_ currentMa: Double?) -> Color {
        guard let ma = currentMa else { return QuackTheme.creamText.opacity(0.4) }
        if ma >= 850 { return QuackTheme.dangerRed }
        if ma >= 500 { return QuackTheme.duckOrange }
        if ma >= 250 { return QuackTheme.warnYellow }
        return QuackTheme.acidCyan
    }

    private func errorColor(_ deg: Double?) -> Color {
        guard let deg else { return QuackTheme.creamText.opacity(0.4) }
        if deg >= 8.0 { return QuackTheme.dangerRed }
        if deg >= 3.5 { return QuackTheme.warnYellow }
        return QuackTheme.creamText.opacity(0.65)
    }

    private func formatJointName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
