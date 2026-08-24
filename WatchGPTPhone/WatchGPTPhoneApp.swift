import SwiftUI

@main
struct WatchGPTPhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PhoneConfiguration.registerDefaults()
        PhoneConfiguration.migrateAPIKeyToKeychainIfNeeded()
        PhoneRealtimeBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                PhoneRealtimeBridge.shared.flushTranscriptHistory()
            }
        }
    }
}
