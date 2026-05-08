import SwiftUI

@main
struct PPGMonitorApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(appModel)
        }
    }
}

