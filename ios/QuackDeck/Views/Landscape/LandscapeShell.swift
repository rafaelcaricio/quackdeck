import SwiftUI

struct LandscapeShell: View {
    let appState: AppState
    @Binding var isSensorsDrawerOpen: Bool

    var body: some View {
        GeometryReader { geo in
            let drawerWidth = min(308, max(248, geo.size.width * 0.38))

            ZStack(alignment: .trailing) {
                // Full-bleed edge-to-edge video canvas
                VideoStageView(appState: appState)
                    .ignoresSafeArea()

                // Subtle top & bottom legibility gradients
                VStack {
                    LinearGradient(
                        colors: [QuackTheme.inkBg.opacity(0.75), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 78)

                    Spacer()

                    LinearGradient(
                        colors: [.clear, QuackTheme.inkBg.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 86)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Safe-area respecting HUD controls
                LandscapeHudOverlay(
                    appState: appState,
                    isSensorsDrawerOpen: $isSensorsDrawerOpen,
                    drawerWidth: drawerWidth
                )

                // Right-side slide-over frosted glass Sensors drawer
                if isSensorsDrawerOpen {
                    sensorsDrawer(width: drawerWidth)
                        .padding(.top, 60)
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(QuackTheme.inkBg.ignoresSafeArea())
            .onAppear {
                appState.reconcileCockpitState()
            }
            .onChange(of: isSensorsDrawerOpen) { _, _ in
                appState.reconcileCockpitState()
            }
        }
        .defersSystemGestures(on: .all)
    }

    private func sensorsDrawer(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("LIVE SENSORS")
                    .font(QuackTheme.condensedDisplay(size: 16))
                    .foregroundStyle(QuackTheme.creamText)

                Spacer()

                Button {
                    QuackHaptics.light()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                        isSensorsDrawerOpen = false
                    }
                } label: {
                    Image(systemName: QuackIcon.close)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(QuackTheme.creamText.opacity(0.88))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(QuackTheme.creamText.opacity(0.14)))
                        .frame(width: QuackTheme.minTouchTarget, height: QuackTheme.minTouchTarget)
                        .contentShape(Circle())
                }
                .buttonStyle(.quackTouch)
                .accessibilityLabel("Close Sensors")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 4)

            Divider()
                .overlay(QuackTheme.creamText.opacity(0.12))

            SensorsDashboardView(appState: appState, isCompactDrawer: true)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .quackGlassPill(cornerRadius: 24)
        .shadow(color: .black.opacity(0.5), radius: 18, x: -4, y: 6)
    }
}
