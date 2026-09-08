import SwiftUI

@main
struct OBD2DashApp: App {
    @StateObject private var model = DashboardModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { model.setActive(true) }
                    else if phase == .background { model.setActive(false) }
                }
        }
    }
}
