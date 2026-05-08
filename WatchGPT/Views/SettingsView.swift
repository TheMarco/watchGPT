import SwiftUI

struct SettingsView: View {
    @AppStorage(AppConfiguration.speakRepliesKey) private var speakReplies = true

    let onReset: () -> Void

    var body: some View {
        List {
            Section("Voice") {
                Toggle(isOn: $speakReplies) {
                    Label("Audio replies", systemImage: "speaker.wave.2.fill")
                }
                .tint(.accentColor)
            }

            Section {
                Button(role: .destructive) {
                    onReset()
                } label: {
                    Label("Clear chat", systemImage: "trash")
                }
            } footer: {
                Text("Set the OpenAI API key in WatchGPT on your iPhone.")
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsView {}
}
