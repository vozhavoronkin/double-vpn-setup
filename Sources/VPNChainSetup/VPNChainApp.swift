import SwiftUI

@main
struct VPNChainApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
                .frame(minWidth: 780, minHeight: 540)
        }
        .windowResizability(.contentMinSize)
    }
}
