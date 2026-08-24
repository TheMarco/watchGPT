import SwiftUI

struct SettingsView: View {
    @AppStorage(AppConfiguration.automaticConversationKey) private var automaticConversation = true
    @AppStorage(AppConfiguration.workoutRuntimeKey) private var workoutRuntime = true
    @AppStorage(AppConfiguration.micSensitivityKey) private var micSensitivity = MicSensitivity.default.rawValue
    @AppStorage(AppConfiguration.outputVolumeKey) private var outputVolume = OutputVolume.default.rawValue
    @AppStorage(AppConfiguration.voiceBargeInKey) private var voiceBargeIn = false
    @State private var showingClearDisplayConfirmation = false

    let onReset: () -> Void

    var body: some View {
        List {
            Section {
                Toggle(isOn: $automaticConversation) {
                    Label("Hands-free conversation", systemImage: "waveform.and.person.filled")
                }
                .tint(.accentColor)
            } header: {
                Text("Voice")
            } footer: {
                Text("Pick Fast Mode, Think Mode, language, voice, and model settings in WatchGPT on your iPhone.")
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
                Text("Lower sensitivity if background noise interferes. Turn barge-in off if the assistant keeps cutting itself off — you can still tap the main button to interrupt.")
            }

            Section {
                Picker("Reply volume", selection: $outputVolume) {
                    ForEach(OutputVolume.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("How loud spoken replies are. Loud uses smooth limiting so it won't crackle.")
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
                    showingClearDisplayConfirmation = true
                } label: {
                    Label("Clear watch display", systemImage: "trash")
                }
            } footer: {
                Text("Clears the conversation shown on this watch. Saved transcripts on your iPhone are not deleted.")
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Settings")
        .alert("Clear watch display?", isPresented: $showingClearDisplayConfirmation) {
            Button("Clear", role: .destructive) {
                onReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears only the conversation shown on the watch. Saved iPhone transcripts remain available.")
        }
    }
}

#Preview {
    SettingsView {}
}
