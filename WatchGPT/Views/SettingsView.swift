import SwiftUI

struct SettingsView: View {
    @AppStorage(AppConfiguration.automaticConversationKey) private var automaticConversation = true
    @AppStorage(AppConfiguration.voiceEngineKey) private var voiceEngine = VoiceEngine.realtime.rawValue
    @AppStorage(AppConfiguration.workoutRuntimeKey) private var workoutRuntime = true
    @AppStorage(AppConfiguration.speakRepliesKey) private var speakReplies = true

    let onReset: () -> Void

    var body: some View {
        List {
            Section("Voice") {
                Picker("Engine", selection: $voiceEngine) {
                    ForEach(VoiceEngine.allCases, id: \.rawValue) { engine in
                        Text(engine.displayName).tag(engine.rawValue)
                    }
                }

                Toggle(isOn: $automaticConversation) {
                    Label("Hands-free conversation", systemImage: "waveform.and.person.filled")
                }
                .tint(.accentColor)

                Toggle(isOn: $speakReplies) {
                    Label("Audio replies", systemImage: "speaker.wave.2.fill")
                }
                .tint(.accentColor)
            }

            Section {
                Toggle(isOn: $workoutRuntime) {
                    Label("Workout keep-alive", systemImage: "figure.mind.and.body")
                }
                .tint(.accentColor)
            } header: {
                Text("Runtime")
            } footer: {
                Text("May help listening continue after wrist-down. It cannot keep the display bright.")
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
