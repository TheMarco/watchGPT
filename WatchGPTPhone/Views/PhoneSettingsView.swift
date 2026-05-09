import SwiftUI

struct PhoneSettingsView: View {
    @AppStorage(PhoneConfiguration.openAIAPIKeyKey) private var apiKey = PhoneConfiguration.defaultOpenAIAPIKey
    @AppStorage(PhoneConfiguration.defaultVoiceEngineKey) private var defaultEngine = VoiceEngine.realtime.rawValue
    @AppStorage(PhoneConfiguration.realtimeVoiceKey) private var realtimeVoice = PhoneConfiguration.defaultRealtimeVoice
    @AppStorage(PhoneConfiguration.thinkVoiceKey) private var thinkVoice = PhoneConfiguration.defaultThinkVoice
    @AppStorage(PhoneConfiguration.realtimeVADEagernessKey) private var vadEagerness = RealtimeVADEagerness.low.rawValue
    @AppStorage(PhoneConfiguration.regularReasoningEffortKey) private var reasoningEffort = ReasoningEffort.low.rawValue
    @AppStorage(PhoneConfiguration.assistantLanguageKey) private var language = AssistantLanguage.auto.rawValue
    @AppStorage(PhoneConfiguration.braveSearchAPIKeyKey) private var braveSearchKey = PhoneConfiguration.defaultBraveSearchAPIKey
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
                Picker("Default mode", selection: $defaultEngine) {
                    ForEach(VoiceEngine.allCases, id: \.rawValue) { engine in
                        Text(engine.displayName).tag(engine.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Session")
            } footer: {
                Text("The watch starts whichever mode is selected here.")
            }

            Section {
                Picker("Voice", selection: $realtimeVoice) {
                    ForEach(PhoneConfiguration.availableVoices, id: \.self) { name in
                        Text(name.capitalized).tag(name)
                    }
                }
                .pickerStyle(.navigationLink)

                Picker("Turn-taking", selection: $vadEagerness) {
                    ForEach(RealtimeVADEagerness.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Fast Mode")
            } footer: {
                Text("Voice changes can apply during a live Fast Mode session. Turn-taking controls how quickly the assistant decides your turn has ended.")
            }

            Section {
                Picker("Voice", selection: $thinkVoice) {
                    ForEach(PhoneConfiguration.availableTTSVoices, id: \.self) { name in
                        Text(name.capitalized).tag(name)
                    }
                }
                .pickerStyle(.navigationLink)

                Picker("Reasoning", selection: $reasoningEffort) {
                    ForEach(ReasoningEffort.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Think Mode")
            } footer: {
                Text("Higher reasoning may improve hard answers, but it starts speaking later.")
            }

            Section {
                Picker("Language", selection: $language) {
                    ForEach(AssistantLanguage.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Assistant language")
            } footer: {
                Text("Auto matches whatever language you speak. Pick a specific language to lock the assistant to it. Applied immediately if a session is live.")
            }

            Section {
                SecureField("Brave Search API key (optional)", text: $braveSearchKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Web search (Realtime)")
            } footer: {
                Text("When set, Realtime mode can search the web during a conversation. Get a free key at api.search.brave.com. Leave blank to disable web search in Realtime mode. Think Mode uses OpenAI's built-in search and does not need this key.")
            }

            Section {
                NavigationLink {
                    PhoneHelpView()
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }

                NavigationLink {
                    PhoneAboutView()
                } label: {
                    Label("About WatchGPT", systemImage: "info.circle")
                }
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

private struct PhoneHelpView: View {
    var body: some View {
        List {
            helpSection(
                "What WatchGPT Does",
                icon: "applewatch",
                rows: [
                    "WatchGPT lets you talk to ChatGPT from your Apple Watch.",
                    "The watch captures microphone audio and plays the reply.",
                    "The iPhone companion holds your OpenAI connection and stores your settings."
                ]
            )

            helpSection(
                "First Setup",
                icon: "key",
                rows: [
                    "Install and run the iPhone app first.",
                    "Add your OpenAI API key in Settings, or bake it into the local debug build.",
                    "Keep the iPhone app open the first time so WatchConnectivity can activate.",
                    "Open WatchGPT on the watch and allow microphone access."
                ]
            )

            helpSection(
                "Starting A Chat",
                icon: "mic.circle",
                rows: [
                    "Open WatchGPT on the watch.",
                    "Check the iPhone icon at the top of the watch screen. Green means the companion is reachable.",
                    "Tap the orb to start.",
                    "Tap the stop button to end the session."
                ]
            )

            helpSection(
                "Fast Mode",
                icon: "bolt.circle",
                rows: [
                    "Fast Mode uses OpenAI Realtime for streaming speech-to-speech conversation.",
                    "Use it for natural back-and-forth, quick questions, and conversational flow.",
                    "Voice and turn-taking are configured here on the iPhone.",
                    "Turn-taking Patient waits longer before replying; Quick responds sooner after pauses."
                ]
            )

            helpSection(
                "Think Mode",
                icon: "brain.head.profile",
                rows: [
                    "Think Mode records a spoken turn, transcribes it, sends it to the smarter model, then speaks the answer.",
                    "It is slower than Fast Mode, but better for questions that need more reasoning.",
                    "Reasoning effort and TTS voice are configured here on the iPhone."
                ]
            )

            helpSection(
                "Hands-Free And Push-To-Talk",
                icon: "hand.tap",
                rows: [
                    "Hands-free lets you speak naturally after the session starts.",
                    "Push-to-talk makes the orb behave like a hold-to-speak button.",
                    "Push-to-talk can help in noisy rooms or when you want stricter turn control."
                ]
            )

            helpSection(
                "Interrupting Replies",
                icon: "waveform.path.ecg",
                rows: [
                    "Tap the orb while WatchGPT is speaking to interrupt.",
                    "Voice barge-in lets speech interrupt the assistant automatically.",
                    "If the assistant cuts itself off because of speaker echo, turn voice barge-in off."
                ]
            )

            helpSection(
                "Audio And Microphone",
                icon: "speaker.wave.2",
                rows: [
                    "Audio replies can be turned off on the watch for text-only responses.",
                    "Mic sensitivity lives on the watch because it affects capture from the watch microphone.",
                    "Use Low sensitivity in loud rooms and High sensitivity in quiet rooms."
                ]
            )

            helpSection(
                "Language",
                icon: "globe",
                rows: [
                    "Auto makes WatchGPT respond in the language it clearly hears.",
                    "If the input is uncertain, Auto falls back to English.",
                    "Pick a specific language to force both transcription and replies toward that language."
                ]
            )

            helpSection(
                "Web Search",
                icon: "magnifyingglass",
                rows: [
                    "Think Mode can use OpenAI's built-in web search automatically.",
                    "Fast Mode needs a Brave Search API key to search the web.",
                    "Use web search for current news, prices, recent releases, weather, sports, and anything time-sensitive."
                ]
            )

            helpSection(
                "Transcripts",
                icon: "text.bubble",
                rows: [
                    "The iPhone saves each session locally as a transcript.",
                    "Open a transcript to read, copy, share, or delete it.",
                    "After a session ends, WatchGPT generates a better title and a short summary when an OpenAI key is available.",
                    "Usage counters show duration, approximate microphone audio, searches, reconnects, and event counts."
                ]
            )

            helpSection(
                "Diagnostics",
                icon: "waveform.path",
                rows: [
                    "The companion dashboard shows live status, audio chunks, OpenAI events, search count, mic peak, and reconnects.",
                    "Use it when tuning latency, diagnosing noisy input, or checking whether the watch is actually streaming."
                ]
            )

            helpSection(
                "Runtime And Battery",
                icon: "figure.mind.and.body",
                rows: [
                    "The watch can start a lightweight workout-style runtime to keep the app alive longer.",
                    "This does not record workout data or read health data.",
                    "The session still ends automatically after idle silence to protect battery and token usage."
                ]
            )

            helpSection(
                "Troubleshooting",
                icon: "wrench.and.screwdriver",
                rows: [
                    "If the watch says the iPhone is unavailable, open WatchGPT on the iPhone.",
                    "If a reconnect happens during your request, repeat the last thing you said.",
                    "If the first reply is slow, try a second turn; the first response often has more startup latency.",
                    "If echo causes interruptions, turn off voice barge-in or use AirPods."
                ]
            )

            Section {
                Text("Your OpenAI API key stays on the iPhone. The watch never receives it. Audio and transcripts are sent to OpenAI only for conversations you start.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Help")
    }

    private func helpSection(_ title: String, icon: String, rows: [String]) -> some View {
        Section {
            ForEach(rows, id: \.self) { row in
                Text(row)
            }
        } header: {
            Label(title, systemImage: icon)
        }
    }
}

private struct PhoneAboutView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WatchGPT")
                        .font(.title2.weight(.semibold))
                    Text("Realtime ChatGPT voice for Apple Watch.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Creator") {
                LabeledContent("Created by", value: "Marco van Hylckama Vlieg")

                Link(destination: URL(string: "https://ai-created.com/")!) {
                    Label("Website", systemImage: "safari")
                }

                Link(destination: URL(string: "https://x.com/AIandDesign")!) {
                    Label("X / AI and Design", systemImage: "link")
                }
            }

            Section("License") {
                Text("WatchGPT is licensed under the PolyForm Noncommercial License 1.0.0.")

                Text("You may use, copy, modify, and share this software for non-commercial purposes. Commercial use requires a separate commercial license.")
                    .foregroundStyle(.secondary)

                Link(destination: URL(string: "https://polyformproject.org/licenses/noncommercial/1.0.0/")!) {
                    Label("Read the license", systemImage: "doc.text")
                }
            }

            Section("Privacy") {
                Text("This is a personal sideloading project. There is no analytics, telemetry, or remote logging.")

                Text("Your OpenAI API key is stored on this iPhone. Do not share app builds that contain your key.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
    }
}

#Preview {
    NavigationStack { PhoneSettingsView() }
}
