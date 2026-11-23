import SwiftUI

@main
struct SideloadUpdaterApp: App {
    @StateObject private var model = UpdaterModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
