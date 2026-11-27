import SwiftUI

struct ImuAttitudeCard: View {
    let robotState: RobotState?
    let headImu: HeadImuFrame?
    let imuHealth: ImuHealth?
    let bodyPitchRoll: (pitch: Double, roll: Double)?
    var isCompact: Bool = false

    private var headPitchRoll: (pitch: Double, roll: Double)? {
        headImu?.pitchRollDegrees
    }

    private var statusBadge: (label: String, color: Color) {
        guard let imuHealth else {
            return (robotState?.imu == nil ? "WAITING" : "LIVE", robotState?.imu == nil ? QuackTheme.creamText.opacity(0.5) : QuackTheme.okGreen)
        }
        if imuHealth.missing {
            return ("MISSING", QuackTheme.dangerRed)
        }
        if imuHealth.isFrozen {
            return ("FROZEN", QuackTheme.dangerRed)
        }
        if !imuHealth.ready {
            return ("CAL...", QuackTheme.warnYellow)
        }
        return ("READY", QuackTheme.okGreen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            HStack(spacing: 6) {
                Text("BODY & HEAD IMU")
                    .font(QuackTheme.condensedDisplay(size: isCompact ? 13 : 14))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.85))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(statusBadge.label)
                    .font(QuackTheme.monoValue(size: 10, weight: .bold))
                    .foregroundStyle(statusBadge.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(statusBadge.color.opacity(0.15)))
            }

            HStack(alignment: .center, spacing: isCompact ? 8 : 14) {
                ArtificialHorizonDial(
                    bodyAngles: bodyPitchRoll,
                    headAngles: headPitchRoll,
                    diameter: isCompact ? 56 : 82
                )

                VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
                    imuAngleRow(
                        tag: "BODY",
                        tagColor: QuackTheme.duckOrange,
                        angles: bodyPitchRoll
                    )

                    imuAngleRow(
                        tag: "HEAD",
                        tagColor: QuackTheme.acidCyan,
                        angles: headPitchRoll,
                        extraText: isCompact ? nil : headImu.map { String(format: "%.1f°C", $0.temp_c) }
                    )

                    safetyPills
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isCompact {
                Divider()
                    .overlay(QuackTheme.subtleBorder)

                VStack(alignment: .leading, spacing: 8) {
                    if let bodyGyro = robotState?.imu?.gyro, bodyGyro.count >= 3 {
                        gyroStrip(
                            title: "BODY GYRO (rad/s)",
                            accent: QuackTheme.duckOrange,
                            values: bodyGyro
                        )
                    } else if let gravity = robotState?.safety.gravity, gravity.count >= 3 {
                        Text(String(format: "GRAVITY  X %.2f  Y %.2f  Z %.2f", gravity[0], gravity[1], gravity[2]))
                            .font(QuackTheme.monoValue(size: 11, weight: .medium))
                            .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                    } else {
                        Text("Body IMU waiting for state stream")
                            .font(.caption2)
                            .foregroundStyle(QuackTheme.creamText.opacity(0.5))
                    }

                    if let head = headImu, head.gyro.count >= 3 {
                        gyroStrip(
                            title: "HEAD GYRO (rad/s)",
                            accent: QuackTheme.acidCyan,
                            values: head.gyro.map(Double.init)
                        )
                    } else {
                        Text("Head IMU stream active when Sensors tab is open")
                            .font(.caption2)
                            .foregroundStyle(QuackTheme.creamText.opacity(0.45))
                    }

                    if let gravity = robotState?.safety.gravity, gravity.count >= 3 {
                        Text(String(format: "GRAVITY  [%.2f, %.2f, %.2f]", gravity[0], gravity[1], gravity[2]))
                            .font(QuackTheme.monoValue(size: 11, weight: .medium))
                            .foregroundStyle(QuackTheme.creamText.opacity(0.6))
                    }
                }
            } else {
                if let bodyGyro = robotState?.imu?.gyro, bodyGyro.count >= 3 {
                    Text(String(format: "B-GYRO %+.2f %+.2f %+.2f", bodyGyro[0], bodyGyro[1], bodyGyro[2]))
                        .font(QuackTheme.monoValue(size: 10, weight: .medium))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                        .lineLimit(1)
                }
                if let head = headImu {
                    Text(String(format: "H-GYRO %+.2f %+.2f %+.2f",
                                head.gyro.first ?? 0,
                                head.gyro.count > 1 ? head.gyro[1] : 0,
                                head.gyro.count > 2 ? head.gyro[2] : 0))
                        .font(QuackTheme.monoValue(size: 10, weight: .medium))
                        .foregroundStyle(QuackTheme.acidCyan.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .padding(isCompact ? 10 : 14)
        .quackInsetCard(cornerRadius: isCompact ? 16 : 20)
    }

    private func imuAngleRow(
        tag: String,
        tagColor: Color,
        angles: (pitch: Double, roll: Double)?,
        extraText: String? = nil
    ) -> some View {
        HStack(spacing: isCompact ? 4 : 6) {
            Text(tag)
                .font(QuackTheme.condensedDisplay(size: isCompact ? 10 : 11))
                .foregroundStyle(tagColor)
                .frame(width: isCompact ? 30 : 34, alignment: .leading)

            if let angles {
                Text(String(format: "P %+.1f° · R %+.1f°", angles.pitch, angles.roll))
                    .font(QuackTheme.monoValue(size: isCompact ? 10.5 : 12, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            } else {
                Text("Not read")
                    .font(QuackTheme.monoValue(size: isCompact ? 10.5 : 12, weight: .medium))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.45))
            }

            if let extraText {
                Spacer(minLength: 2)
                Text(extraText)
                    .font(QuackTheme.monoValue(size: 10, weight: .medium))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.6))
            }
        }
    }

    private var safetyPills: some View {
        let safety = robotState?.safety
        return HStack(spacing: 5) {
            if let safety {
                if safety.fallen {
                    pill("FALLEN", color: QuackTheme.dangerRed)
                }
                if safety.picked_up {
                    pill("PICKED UP", color: QuackTheme.warnYellow)
                }
                if safety.limp {
                    pill("LIMP", color: QuackTheme.dangerRed)
                }
                if !safety.fallen && !safety.picked_up && !safety.limp {
                    pill("UPRIGHT", color: QuackTheme.okGreen)
                }
            } else {
                pill("NO STATE", color: QuackTheme.creamText.opacity(0.45))
            }

            if isCompact, let head = headImu {
                pill(String(format: "%.1f°C", head.temp_c), color: QuackTheme.acidCyan)
            }
        }
    }

    private func pill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(QuackTheme.monoValue(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func gyroStrip(title: String, accent: Color, values: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(QuackTheme.condensedDisplay(size: 11))
                .foregroundStyle(accent.opacity(0.9))

            HStack(spacing: 8) {
                gyroBar(axis: "X", value: values[0], accent: accent)
                gyroBar(axis: "Y", value: values[1], accent: accent)
                gyroBar(axis: "Z", value: values[2], accent: QuackTheme.acidMagenta)
            }
        }
    }

    private func gyroBar(axis: String, value: Double, accent: Color) -> some View {
        let norm = min(1.0, abs(value) / 3.0)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(axis)
                    .font(QuackTheme.monoValue(size: 10, weight: .bold))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.6))
                Spacer()
                Text(String(format: "%+.2f", value))
                    .font(QuackTheme.monoValue(size: 10, weight: .semibold))
                    .foregroundStyle(QuackTheme.creamText)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(2, geo.size.width * norm))
                }
            }
            .frame(height: 4)
        }
    }
}

private struct ArtificialHorizonDial: View {
    let bodyAngles: (pitch: Double, roll: Double)?
    let headAngles: (pitch: Double, roll: Double)?
    let diameter: CGFloat

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let radius = min(size.width, size.height) * 0.5 - 1
            let circlePath = Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))

            context.fill(circlePath, with: .color(QuackTheme.inkBg))

            context.drawLayer { layer in
                layer.clip(to: circlePath)

                if let bodyAngles {
                    let pitchShift = CGFloat(max(-35, min(35, bodyAngles.pitch))) / 35.0 * (radius * 0.55)

                    layer.translateBy(x: center.x, y: center.y)
                    layer.rotate(by: .degrees(-bodyAngles.roll))

                    let groundRect = CGRect(
                        x: -radius * 1.6,
                        y: pitchShift,
                        width: radius * 3.2,
                        height: radius * 2.2
                    )
                    layer.fill(Path(groundRect), with: .color(QuackTheme.duckOrange.opacity(0.22)))

                    var horizon = Path()
                    horizon.move(to: CGPoint(x: -radius * 1.4, y: pitchShift))
                    horizon.addLine(to: CGPoint(x: radius * 1.4, y: pitchShift))
                    layer.stroke(horizon, with: .color(QuackTheme.duckOrange), lineWidth: 2)

                    if let head = headAngles {
                        let headShift = CGFloat(max(-35, min(35, head.pitch))) / 35.0 * (radius * 0.55)
                        layer.rotate(by: .degrees(bodyAngles.roll - head.roll))
                        var headLine = Path()
                        headLine.move(to: CGPoint(x: -radius * 0.8, y: headShift))
                        headLine.addLine(to: CGPoint(x: radius * 0.8, y: headShift))
                        layer.stroke(
                            headLine,
                            with: .color(QuackTheme.acidCyan.opacity(0.75)),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                    }
                } else {
                    var dashed = Path()
                    dashed.move(to: CGPoint(x: center.x - radius * 0.8, y: center.y))
                    dashed.addLine(to: CGPoint(x: center.x + radius * 0.8, y: center.y))
                    layer.stroke(
                        dashed,
                        with: .color(QuackTheme.creamText.opacity(0.28)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                    )
                }
            }

            // Fixed center reticle
            var reticle = Path()
            reticle.move(to: CGPoint(x: center.x - 10, y: center.y))
            reticle.addLine(to: CGPoint(x: center.x - 3, y: center.y))
            reticle.move(to: CGPoint(x: center.x + 3, y: center.y))
            reticle.addLine(to: CGPoint(x: center.x + 10, y: center.y))
            context.stroke(reticle, with: .color(QuackTheme.creamText.opacity(0.85)), lineWidth: 1.5)

            let dotRect = CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: dotRect), with: .color(QuackTheme.creamText))

            context.stroke(circlePath, with: .color(QuackTheme.creamText.opacity(0.22)), lineWidth: 1.5)
        }
        .frame(width: diameter, height: diameter)
    }
}
