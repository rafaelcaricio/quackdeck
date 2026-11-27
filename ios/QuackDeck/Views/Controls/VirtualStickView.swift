import SwiftUI

struct VirtualStickView: View {
    let appState: AppState
    var size: CGFloat = 136
    var isGlass: Bool = false

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
    @State private var requiresFreshTouch: Bool = false

    private var isInhibited: Bool {
        appState.isDrivingInputInhibited
    }

    private var maxRadius: CGFloat {
        size * 0.33
    }

    private var nubSize: CGFloat {
        size >= 132 ? 54 : 50
    }

    var body: some View {
        ZStack {
            if isGlass {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(QuackTheme.glassFill))
                    .overlay(Circle().strokeBorder(QuackTheme.subtleBorder, lineWidth: 1))
            } else {
                Circle()
                    .fill(Color(hex: 0x13131c))
                    .overlay(Circle().strokeBorder(QuackTheme.creamText.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
            }

            Circle()
                .strokeBorder(
                    QuackTheme.creamText.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .padding(16)

            let chevronOpacity = isGlass ? 0.22 : 0.28
            ZStack {
                VStack {
                    Image(systemName: QuackIcon.chevronUp)
                    Spacer()
                    Image(systemName: QuackIcon.chevronDown)
                }
                .padding(.vertical, 8)

                HStack {
                    Image(systemName: QuackIcon.chevronLeft)
                    Spacer()
                    Image(systemName: QuackIcon.chevronRight)
                }
                .padding(.horizontal, 8)
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(QuackTheme.creamText.opacity(chevronOpacity))
            .allowsHitTesting(false)

            Circle()
                .fill(QuackTheme.duckOrange)
                .frame(width: nubSize, height: nubSize)
                .overlay(
                    Circle()
                        .strokeBorder(QuackTheme.creamText.opacity(0.9), lineWidth: 2)
                )
                .overlay(
                    Circle()
                        .fill(QuackTheme.inkSurface.opacity(0.55))
                        .frame(width: 9, height: 9)
                )
                .shadow(color: QuackTheme.duckOrange.opacity(isDragging ? 0.65 : 0.45), radius: 10, y: 3)
                .offset(dragOffset)
        }
        .frame(width: size, height: size)
        .opacity(isInhibited ? 0.45 : 1.0)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !isInhibited else {
                        requiresFreshTouch = true
                        if isDragging {
                            isDragging = false
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                dragOffset = .zero
                            }
                        }
                        return
                    }
                    guard !requiresFreshTouch else { return }

                    if !isDragging {
                        isDragging = true
                        QuackHaptics.light()
                    }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let dist = hypot(dx, dy)
                    let clampedX: CGFloat
                    let clampedY: CGFloat
                    if dist > maxRadius, dist > 0 {
                        clampedX = dx / dist * maxRadius
                        clampedY = dy / dist * maxRadius
                    } else {
                        clampedX = dx
                        clampedY = dy
                    }
                    dragOffset = CGSize(width: clampedX, height: clampedY)

                    // Up is +forward, left is +strafeLeft
                    let forward = Double(-clampedY / maxRadius)
                    let strafeLeft = Double(-clampedX / maxRadius)
                    appState.updateDriveStick(forward: forward, strafeLeft: strafeLeft)
                }
                .onEnded { _ in
                    requiresFreshTouch = false
                    isDragging = false
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                        dragOffset = .zero
                    }
                    appState.updateDriveStick(forward: 0, strafeLeft: 0)
                }
        )
        .onChange(of: isInhibited) { _, inhibited in
            if inhibited {
                if isDragging {
                    requiresFreshTouch = true
                }
                isDragging = false
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    dragOffset = .zero
                }
            }
        }
        .onChange(of: appState.inputResetGeneration) { _, _ in
            if isDragging {
                requiresFreshTouch = true
            }
            isDragging = false
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                dragOffset = .zero
            }
        }
        .onChange(of: appState.stickForward) { _, newValue in
            if !isDragging && newValue == 0 && appState.stickStrafeLeft == 0 && dragOffset != .zero {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    dragOffset = .zero
                }
            }
        }
        .onDisappear {
            if isDragging || dragOffset != .zero {
                isDragging = false
                dragOffset = .zero
                appState.updateDriveStick(forward: 0, strafeLeft: 0)
            }
        }
        .accessibilityLabel("Drive thumbstick")
    }
}
