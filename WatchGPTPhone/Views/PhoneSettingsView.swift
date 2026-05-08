import SwiftUI

struct PhoneSettingsView: View {
    @AppStorage(PhoneConfiguration.openAIAPIKeyKey) private var apiKey = PhoneConfiguration.defaultOpenAIAPIKey
    @AppStorage(PhoneConfiguration.realtimeVoiceKey) private var voice = PhoneConfiguration.defaultRealtimeVoice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                SecureField("sk-...", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                Button("Reset to build default") {
                    apiKey = PhoneConfiguration.defaultOpenAIAPIKey
                }
                .disabled(PhoneConfiguration.defaultOpenAIAPIKey.isEmpty)
            } header: {
                Text("OpenAI API key")
            } footer: {
                Text("Stored only on this iPhone. Never sent to the watch — the iPhone holds the WebSocket to OpenAI and relays audio to the watch over Bluetooth.")
            }

            Section {
                Picker("Voice", selection: $voice) {
                    ForEach(PhoneConfiguration.availableVoices, id: \.self) { name in
                        Text(name.capitalized).tag(name)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Realtime voice")
            } footer: {
                Text("Applied on the next session start. OpenAI recommends \"marin\" or \"cedar\" for best quality with gpt-realtime.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

#Preview {
    NavigationStack { PhoneSettingsView() }
}
