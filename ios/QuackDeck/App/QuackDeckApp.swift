import SwiftUI

@main
struct QuackDeckApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()
    @State private var didHandleLaunchArgs = false

    var body: some Scene {
        WindowGroup {
            RootView(appState: appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    guard !didHandleLaunchArgs else { return }
                    didHandleLaunchArgs = true
                    let args = CommandLine.arguments
                    if args.contains("--demo-walking") {
                        appState.startDemoMode(startWalking: true)
                    } else if args.contains("--demo") {
                        appState.startDemoMode(startWalking: false)
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            appState.handleScenePhaseChange(newPhase)
        }
    }
}
