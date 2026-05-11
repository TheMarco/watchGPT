import SwiftUI

struct PhoneSettingsView: View {
    @AppStorage(PhoneConfiguration.openAIAPIKeyKey) private var apiKey = PhoneConfiguration.defaultOpenAIAPIKey
    @AppStorage(PhoneConfiguration.defaultVoiceEngineKey) private var defaultEngine = VoiceEngine.realtime.rawValue
    @AppStorage(PhoneConfiguration.realtimeVoiceKey) private var realtimeVoice = PhoneConfiguration.defaultRealtimeVoice
    @AppStorage(PhoneConfiguration.thinkVoiceKey) private var thinkVoice = PhoneConfiguration.defaultThinkVoice
    @AppStorage(PhoneConfiguration.realtimeVADEagernessKey) private var vadEagerness = RealtimeVADEagerness.low.rawValue
    @AppStorage(PhoneConfiguration.regularReasoningEffortKey) private var reasoningEffort = ReasoningEffort.low.rawValue
    @AppStorage(PhoneConfiguration.assistantLanguageKey) private var language = AssistantLanguage.auto.rawValue

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
    }
}

private struct PhoneHelpTopic: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let tint: Color
    let rows: [String]
}

struct PhoneHelpView: View {
    private let topics: [PhoneHelpTopic] = [
        PhoneHelpTopic(
            title: "What WatchGPT Does",
            icon: "applewatch",
            tint: .blue,
            rows: [
                "Talk to ChatGPT from your Apple Watch.",
                "The watch captures microphone audio and plays the reply.",
                "The iPhone companion owns OpenAI networking, settings, diagnostics, and transcript history."
            ]
        ),
        PhoneHelpTopic(
            title: "First Setup",
            icon: "key.fill",
            tint: .orange,
            rows: [
                "Install and run the iPhone app first.",
                "Add your OpenAI API key in Settings, or bake it into the local debug build.",
                "Keep the iPhone app open the first time so WatchConnectivity can activate.",
                "Open WatchGPT on the watch and allow microphone access."
            ]
        ),
        PhoneHelpTopic(
            title: "Starting A Chat",
            icon: "mic.circle.fill",
            tint: .green,
            rows: [
                "Open WatchGPT on the watch.",
                "Check the iPhone icon at the top of the watch screen. Green means the companion is reachable.",
                "Tap the main button to start.",
                "Tap the stop button to end the session."
            ]
        ),
        PhoneHelpTopic(
            title: "Fast Mode",
            icon: "bolt.circle.fill",
            tint: .yellow,
            rows: [
                "Uses OpenAI Realtime for streaming speech-to-speech conversation.",
                "Best for quick questions, natural back-and-forth, and conversational flow.",
                "Voice and turn-taking are configured on the iPhone.",
                "Patient waits longer before replying; Quick responds sooner after pauses."
            ]
        ),
        PhoneHelpTopic(
            title: "Think Mode",
            icon: "brain.head.profile",
            tint: .purple,
            rows: [
                "Records a spoken turn, transcribes it, sends it to the smarter model, then speaks the answer.",
                "Slower than Fast Mode, but better for questions that need more reasoning.",
                "Reasoning effort and TTS voice are configured on the iPhone."
            ]
        ),
        PhoneHelpTopic(
            title: "Hands-Free And Push-To-Talk",
            icon: "hand.tap.fill",
            tint: .teal,
            rows: [
                "Hands-free lets you speak naturally after the session starts.",
                "Push-to-talk makes the main button behave like a hold-to-speak control.",
                "Push-to-talk helps in noisy rooms or when you want stricter turn control."
            ]
        ),
        PhoneHelpTopic(
            title: "Interrupting Replies",
            icon: "waveform.path.ecg",
            tint: .pink,
            rows: [
                "Tap the main button while WatchGPT is speaking to interrupt.",
                "Voice barge-in lets speech interrupt the assistant automatically.",
                "If the assistant cuts itself off because of speaker echo, turn voice barge-in off."
            ]
        ),
        PhoneHelpTopic(
            title: "Audio And Microphone",
            icon: "speaker.wave.2.fill",
            tint: .indigo,
            rows: [
                "Mic sensitivity lives on the watch because it affects capture from the watch microphone.",
                "Use Low sensitivity in loud rooms and High sensitivity in quiet rooms."
            ]
        ),
        PhoneHelpTopic(
            title: "Language",
            icon: "globe",
            tint: .cyan,
            rows: [
                "Auto makes WatchGPT respond in the language it clearly hears.",
                "If the input is uncertain, Auto falls back to English.",
                "Pick a specific language to force both transcription and replies toward that language."
            ]
        ),
        PhoneHelpTopic(
            title: "Web Search",
            icon: "magnifyingglass.circle.fill",
            tint: .mint,
            rows: [
                "Both modes use OpenAI's hosted web search automatically — no extra key required.",
                "Fast Mode briefly says \"Let me check\" before searches, which take a couple of seconds.",
                "Use search for crypto and stock prices, FX rates, weather, news, sports, and anything time-sensitive."
            ]
        ),
        PhoneHelpTopic(
            title: "Transcripts",
            icon: "text.bubble.fill",
            tint: .brown,
            rows: [
                "The iPhone saves each session locally as a transcript.",
                "Open a transcript to read, copy, share, or delete it.",
                "After a session ends, WatchGPT generates a better title and a short summary when an OpenAI key is available.",
                "Usage counters show duration, approximate microphone audio, searches, reconnects, and event counts."
            ]
        ),
        PhoneHelpTopic(
            title: "Diagnostics",
            icon: "waveform.path",
            tint: .red,
            rows: [
                "The companion dashboard shows live status, audio chunks, OpenAI events, search count, mic peak, and reconnects.",
                "Use it when tuning latency, diagnosing noisy input, or checking whether the watch is actually streaming."
            ]
        ),
        PhoneHelpTopic(
            title: "Runtime And Battery",
            icon: "figure.mind.and.body",
            tint: .green,
            rows: [
                "The watch can start a lightweight workout-style runtime to keep the app alive longer.",
                "This does not record workout data or read health data.",
                "The session still ends automatically after idle silence to protect battery and token usage."
            ]
        ),
        PhoneHelpTopic(
            title: "Troubleshooting",
            icon: "wrench.and.screwdriver.fill",
            tint: .orange,
            rows: [
                "If the watch says the iPhone is unavailable, open WatchGPT on the iPhone.",
                "If a reconnect happens during your request, repeat the last thing you said.",
                "If the first reply is slow, try a second turn; the first response often has more startup latency.",
                "If echo causes interruptions, turn off voice barge-in or use AirPods."
            ]
        )
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                helpHero

                ForEach(topics) { topic in
                    helpCard(topic)
                }

                privacyCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Help")
    }

    private var helpHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Using WatchGPT")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Everything you need to get clean, reliable voice sessions from your watch.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            LinearGradient(
                colors: [.blue, .purple, .pink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func helpCard(_ topic: PhoneHelpTopic) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: topic.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(topic.tint)
                    .frame(width: 38, height: 38)
                    .background(topic.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(topic.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(topic.rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(topic.tint)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(row)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(topic.tint.opacity(0.18), lineWidth: 0.8)
        }
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 38, height: 38)
                .background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("Your OpenAI API key stays on the iPhone. The watch never receives it. Audio and transcripts are sent to OpenAI only for conversations you start.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct PhoneAboutView: View {
    @State private var showingLicense = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    PhoneAppIconImage()
                        .frame(width: 66, height: 66)
                        .shadow(color: Color.accentColor.opacity(0.18), radius: 10, y: 4)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("WatchGPT")
                            .font(.title2.weight(.semibold))
                        Text("Realtime ChatGPT voice for Apple Watch.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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

                Button {
                    showingLicense = true
                } label: {
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
        .sheet(isPresented: $showingLicense) {
            LicenseSheet()
        }
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(licenseText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("License")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "LICENSE file not found in app bundle."
        }
        return text
    }
}

#Preview {
    NavigationStack { PhoneSettingsView() }
}
