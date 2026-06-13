import SwiftUI

@main
struct WatchGPTPhoneApp: App {
    init() {
        PhoneConfiguration.registerDefaults()
        PhoneConfiguration.migrateAPIKeyToKeychainIfNeeded()
        PhoneRealtimeBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
        }
    }
}
