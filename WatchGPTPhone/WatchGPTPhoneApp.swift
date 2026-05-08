import SwiftUI

@main
struct WatchGPTPhoneApp: App {
    init() {
        PhoneConfiguration.registerDefaults()
        PhoneRealtimeBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
        }
    }
}
