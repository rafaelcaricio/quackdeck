import SwiftUI

enum PortraitTab: Hashable {
    case live
    case sensors
}

struct PortraitShell: View {
    let appState: AppState
    @Binding var selectedTab: PortraitTab

    var body: some View {
        ZStack {
            QuackTheme.inkBg
                .ignoresSafeArea()

            Group {
                switch selectedTab {
                case .live:
                    PortraitLiveView(
                        appState: appState,
                        onOpenSensorsTab: {
                            selectedTab = .sensors
                        }
                    )

                case .sensors:
                    SensorsDashboardView(appState: appState, isCompactDrawer: false)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            floatingTabBar
        }
        .onAppear {
            appState.reconcileCockpitState()
        }
        .onChange(of: selectedTab) { _, _ in
            appState.reconcileCockpitState()
        }
    }

    private var floatingTabBar: some View {
        HStack(spacing: 6) {
            tabButton(
                title: "Live",
                systemImage: QuackIcon.live,
                isActive: selectedTab == .live
            ) {
                QuackHaptics.light()
                selectedTab = .live
            }

            tabButton(
                title: "Sensors",
                systemImage: QuackIcon.sensors,
                isActive: selectedTab == .sensors
            ) {
                QuackHaptics.light()
                selectedTab = .sensors
            }

            tabButton(
                title: "Ducks",
                systemImage: QuackIcon.ducks,
                isActive: appState.isDucksSheetPresented
            ) {
                QuackHaptics.light()
                appState.isDucksSheetPresented = true
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(height: 60)
        .quackGlassPill(cornerRadius: 30)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func tabButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: isActive ? .bold : .semibold))
            }
            .foregroundStyle(isActive ? QuackTheme.inkSurface : QuackTheme.creamText.opacity(0.78))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                if isActive {
                    Capsule().fill(QuackTheme.duckOrange)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.quackTouch)
    }
}
