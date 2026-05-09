import SwiftUI

struct SettingsView: View {
    @AppStorage(AppConfiguration.automaticConversationKey) private var automaticConversation = true
    @AppStorage(AppConfiguration.voiceEngineKey) private var voiceEngine = VoiceEngine.realtime.rawValue
    @AppStorage(AppConfiguration.workoutRuntimeKey) private var workoutRuntime = true
    @AppStorage(AppConfiguration.speakRepliesKey) private var speakReplies = true
    @AppStorage(AppConfiguration.micSensitivityKey) private var micSensitivity = MicSensitivity.default.rawValue
    @AppStorage(AppConfiguration.voiceBargeInKey) private var voiceBargeIn = true

    let onReset: () -> Void

    private var currentEngine: VoiceEngine {
        VoiceEngine(rawValue: voiceEngine) ?? .realtime
    }

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $voiceEngine) {
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
            } header: {
                Text("Voice")
            } footer: {
                Text(currentEngine.modelDescription)
            }

            Section {
                Picker("Mic sensitivity", selection: $micSensitivity) {
                    ForEach(MicSensitivity.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }

                Toggle(isOn: $voiceBargeIn) {
                    Label("Voice barge-in", systemImage: "waveform.path.ecg")
                }
                .tint(.accentColor)
            } header: {
                Text("Microphone")
            } footer: {
                Text("Lower sensitivity if background noise interferes. Turn barge-in off if the assistant keeps cutting itself off — you can still tap the orb to interrupt.")
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
