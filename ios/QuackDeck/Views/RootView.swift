import SwiftUI
import UIKit

struct RootView: View {
    let appState: AppState

    @State private var selectedPortraitTab: PortraitTab = .live
    @State private var isLandscapeSensorsOpen: Bool = false
    @State private var currentIsLandscape: Bool = false
    @State private var didApplyLaunchArgs: Bool = false

    var body: some View {
        @Bindable var bindableState = appState

        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            Group {
                if isLandscape {
                    LandscapeShell(
                        appState: appState,
                        isSensorsDrawerOpen: $isLandscapeSensorsOpen
                    )
                } else {
                    PortraitShell(
                        appState: appState,
                        selectedTab: $selectedPortraitTab
                    )
                }
            }
            .onAppear {
                if !didApplyLaunchArgs {
                    didApplyLaunchArgs = true
                    if CommandLine.arguments.contains("--sensors") {
                        selectedPortraitTab = .sensors
                        isLandscapeSensorsOpen = true
                    }
                    if CommandLine.arguments.contains("--landscape") {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                                .requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft))
                        }
                    }
                }
                currentIsLandscape = isLandscape
                syncSensorsVisibility(isLandscape: isLandscape)
            }
            .onChange(of: isLandscape) { _, newValue in
                appState.stopAllMotion()
                currentIsLandscape = newValue
                syncSensorsVisibility(isLandscape: newValue)
            }
            .onChange(of: selectedPortraitTab) { _, newTab in
                if newTab != .live {
                    appState.stopAllMotion()
                }
                syncSensorsVisibility(isLandscape: currentIsLandscape)
            }
            .onChange(of: appState.isDucksSheetPresented) { _, presented in
                if presented {
                    appState.stopAllMotion()
                }
            }
            .onChange(of: isLandscapeSensorsOpen) { _, _ in
                syncSensorsVisibility(isLandscape: currentIsLandscape)
            }
            .onChange(of: appState.isConnected) { _, connected in
                if connected {
                    syncSensorsVisibility(isLandscape: currentIsLandscape)
                }
            }
        }
        .background(QuackTheme.inkBg.ignoresSafeArea())
        .sheet(isPresented: $bindableState.isDucksSheetPresented) {
            DucksSheetView(appState: appState)
        }
        .alert(
            "Robot Notice",
            isPresented: Binding(
                get: { appState.activeAlertMessage != nil },
                set: { if !$0 { appState.activeAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                appState.activeAlertMessage = nil
            }
        } message: {
            Text(appState.activeAlertMessage ?? "")
        }
    }

    private func syncSensorsVisibility(isLandscape: Bool) {
        let visible = isLandscape ? isLandscapeSensorsOpen : (selectedPortraitTab == .sensors)
        appState.setSensorsVisible(visible)
    }
}
