import SwiftUI

@main
struct WatchGPTApp: App {
    init() {
        AppConfiguration.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

