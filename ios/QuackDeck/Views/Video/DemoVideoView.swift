import SwiftUI

struct DemoVideoView: View {
    let appState: AppState
    var demoSession: DemoRobotSession?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                drawScene(context: &context, size: size, time: now)
            }
        }
        .background(Color(hex: 0x0d0e15))
    }

    private func drawScene(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return }

        let gaze = demoSession?.virtualGazeNormalized ?? (x: 0, y: 0)
        let pitchDeg = demoSession?.virtualPitchDeg ?? 0
        let rollDeg = demoSession?.virtualRollDeg ?? 0
        let odom = appState.telemetry.robotState?.odom
        let moveTravel = (odom?.position.first ?? 0) * 1.4
        let dist = max(0.32, min(1.8, appState.telemetry.nearestTofMeters ?? 0.75))

        let isMoving = abs(appState.stickForward) > 0.02 ||
            abs(appState.stickStrafeLeft) > 0.02 ||
            abs(appState.turnYawLeft) > 0.02
        let bob = isMoving ? sin(time * 9.0) * 3.5 : sin(time * 1.8) * 1.0

        let horizonY = h * 0.46
            - CGFloat(gaze.y) * h * 0.14
            + CGFloat(pitchDeg / 25.0) * h * 0.12
            + CGFloat(bob)
        let clampedHorizon = max(h * 0.20, min(h * 0.72, horizonY))
        let vanishX = w * 0.5 - CGFloat(gaze.x) * w * 0.22

        context.drawLayer { layerCtx in
            let rollRad = CGFloat(rollDeg) * .pi / 180.0 * 0.55
            layerCtx.translateBy(x: w * 0.5, y: h * 0.5)
            layerCtx.rotate(by: Angle(radians: rollRad))
            layerCtx.translateBy(x: -w * 0.5, y: -h * 0.5)

            // Wall / sky gradient
            let skyRect = CGRect(x: -w * 0.2, y: -h * 0.2, width: w * 1.4, height: clampedHorizon + h * 0.2)
            layerCtx.fill(
                Path(skyRect),
                with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x11121c), Color(hex: 0x23273a)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: clampedHorizon)
                )
            )

            // Floor gradient
            let floorRect = CGRect(x: -w * 0.2, y: clampedHorizon, width: w * 1.4, height: h * 1.2 - clampedHorizon)
            layerCtx.fill(
                Path(floorRect),
                with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x181b27), Color(hex: 0x090a10)]),
                    startPoint: CGPoint(x: 0, y: clampedHorizon),
                    endPoint: CGPoint(x: 0, y: h)
                )
            )

            // Horizon accent line
            var horizonLine = Path()
            horizonLine.move(to: CGPoint(x: -w * 0.2, y: clampedHorizon))
            horizonLine.addLine(to: CGPoint(x: w * 1.2, y: clampedHorizon))
            layerCtx.stroke(horizonLine, with: .color(QuackTheme.creamText.opacity(0.18)), lineWidth: 1)

            // Radial floor grid lines
            var radialPath = Path()
            for i in -6...6 {
                let topX = vanishX + CGFloat(i) * w * 0.08
                let botX = vanishX + CGFloat(i) * w * 0.29
                radialPath.move(to: CGPoint(x: topX, y: clampedHorizon))
                radialPath.addLine(to: CGPoint(x: botX, y: h * 1.15))
            }

            // Depth cross lines scrolling with odometry
            let zFract = moveTravel.truncatingRemainder(dividingBy: 1.0)
            let zOff = zFract < 0 ? zFract + 1.0 : zFract
            for r in 1...7 {
                let p = (Double(r) - zOff) / 7.0
                if p <= 0.03 { continue }
                let y = clampedHorizon + CGFloat(pow(p, 1.78)) * (h - clampedHorizon)
                radialPath.move(to: CGPoint(x: -w * 0.2, y: y))
                radialPath.addLine(to: CGPoint(x: w * 1.2, y: y))
            }
            layerCtx.stroke(radialPath, with: .color(QuackTheme.creamText.opacity(0.12)), lineWidth: 1)

            // Target sphere reacting to ToF distance
            let floorSpan = max(40, h - clampedHorizon)
            let ballX = vanishX + w * 0.07
            let ballY = clampedHorizon + floorSpan * CGFloat(min(0.85, 0.28 / dist))
            let ballRadius = CGFloat(max(9.0, min(32.0, 17.0 / dist)))
            let ballRect = CGRect(
                x: ballX - ballRadius,
                y: ballY - ballRadius,
                width: ballRadius * 2,
                height: ballRadius * 2
            )
            let ballPath = Path(ellipseIn: ballRect)
            layerCtx.fill(ballPath, with: .color(QuackTheme.acidMagenta.opacity(0.92)))
            layerCtx.stroke(ballPath, with: .color(QuackTheme.creamText.opacity(0.9)), lineWidth: 1.5)
        }
    }
}
