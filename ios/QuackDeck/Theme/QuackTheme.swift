import SwiftUI
import UIKit

enum QuackTheme {
    // Core visual tokens
    static let inkBg = Color(hex: 0x08080c)
    static let inkSurface = Color(hex: 0x101018)
    static let inkCard = Color(hex: 0x14141d)
    static let creamText = Color(hex: 0xfaf8f2)
    static let duckOrange = Color(hex: 0xff7a2f)
    static let warnYellow = Color(hex: 0xffd23f)
    static let acidCyan = Color(hex: 0x2ff0e6)
    static let acidMagenta = Color(hex: 0xff2fa8)
    static let okGreen = Color(hex: 0x4ce08a)
    static let dangerRed = Color(hex: 0xff4b3a)

    static let subtleBorder = creamText.opacity(0.14)
    static let cardBorder = creamText.opacity(0.11)
    static let glassFill = inkSurface.opacity(0.72)

    // Apple HIG touchscreen metrics
    static let minTouchTarget: CGFloat = 44
    static let controlSpacing: CGFloat = 10
    static let primaryButtonHeight: CGFloat = 54
    static let secondaryButtonHeight: CGFloat = 48

    static func condensedDisplay(size: CGFloat) -> Font {
        Font.system(size: size, weight: .black).width(.condensed)
    }

    static func monoValue(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }
}

/// Centralized SF Symbol catalog.
/// Navigation, controls, and actions use outlined symbols; `.fill` variants are
/// reserved for alert severity and validation status badges.
enum QuackIcon {
    static let live = "video"
    static let liveUnavailable = "video.slash"
    static let sensors = "waveform.path.ecg"
    static let ducks = "dot.radiowaves.left.and.right"

    static let lookCenter = "scope"
    static let turnLeft = "arrow.counterclockwise"
    static let turnRight = "arrow.clockwise"
    static let refresh = "arrow.clockwise"

    static let wifi = "wifi"
    static let power = "power"
    static let disconnect = "xmark.circle"
    static let qrScanner = "qrcode.viewfinder"
    static let licenses = "doc.text"
    static let delete = "trash"
    static let close = "xmark"

    static let chevronUp = "chevron.up"
    static let chevronDown = "chevron.down"
    static let chevronLeft = "chevron.left"
    static let chevronRight = "chevron.right"

    static let eye = "eye"
    static let eyeSlash = "eye.slash"

    static let thermalWarm = "thermometer.high"
    static let thermalHot = "flame.fill"

    static let statusSuccess = "checkmark.circle.fill"
    static let statusError = "exclamationmark.circle.fill"

    static func thermal(for level: ThermalAlertLevel) -> String {
        level == .hot ? thermalHot : thermalWarm
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >> 8) & 0xff) / 255.0
        let b = Double(hex & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

struct QuackGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 999
    var borderColor: Color = QuackTheme.subtleBorder

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(QuackTheme.glassFill)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
    }
}

struct QuackInsetCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 20
    var borderColor: Color = QuackTheme.cardBorder

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(QuackTheme.inkCard.opacity(0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
    }
}

extension View {
    func quackGlassPill(
        cornerRadius: CGFloat = 999,
        borderColor: Color = QuackTheme.subtleBorder
    ) -> some View {
        modifier(QuackGlassModifier(cornerRadius: cornerRadius, borderColor: borderColor))
    }

    func quackInsetCard(
        cornerRadius: CGFloat = 20,
        borderColor: Color = QuackTheme.cardBorder
    ) -> some View {
        modifier(QuackInsetCardModifier(cornerRadius: cornerRadius, borderColor: borderColor))
    }
}

struct QuackTouchButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    var pressedOpacity: Double = 0.85

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == QuackTouchButtonStyle {
    static var quackTouch: QuackTouchButtonStyle { QuackTouchButtonStyle() }
    static var quackRow: QuackTouchButtonStyle {
        QuackTouchButtonStyle(pressedScale: 0.99, pressedOpacity: 0.78)
    }
}

struct HalftoneDotBackground: View {
    var dotColor: Color = QuackTheme.duckOrange.opacity(0.20)
    var spacing: CGFloat = 12
    var dotRadius: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            var y: CGFloat = spacing * 0.5
            while y < size.height {
                var x: CGFloat = spacing * 0.5
                while x < size.width {
                    let nx = x / max(size.width, 1)
                    let ny = y / max(size.height, 1)
                    let fade = max(0, 1.0 - (nx * 0.75 + ny * 0.95))
                    if fade > 0.02 {
                        let rect = CGRect(
                            x: x - dotRadius,
                            y: y - dotRadius,
                            width: dotRadius * 2,
                            height: dotRadius * 2
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(dotColor.opacity(fade))
                        )
                    }
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

enum QuackHaptics {
    @MainActor
    private static let lightGenerator: UIImpactFeedbackGenerator = {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        return generator
    }()

    @MainActor
    private static let mediumGenerator: UIImpactFeedbackGenerator = {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        return generator
    }()

    @MainActor
    private static let heavyGenerator: UIImpactFeedbackGenerator = {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        return generator
    }()

    @MainActor
    private static let notificationGenerator: UINotificationFeedbackGenerator = {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        return generator
    }()

    @MainActor
    static func light() {
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }

    @MainActor
    static func medium() {
        mediumGenerator.impactOccurred()
        mediumGenerator.prepare()
    }

    @MainActor
    static func heavy() {
        heavyGenerator.impactOccurred()
        heavyGenerator.prepare()
    }

    @MainActor
    static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    @MainActor
    static func warning() {
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }

    @MainActor
    static func error() {
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }
}
