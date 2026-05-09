import SwiftUI

struct ContentView: View {
    @StateObject private var session = RealtimeVoiceSession()
    @State private var isShowingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            background

            VStack(spacing: 7) {
                topBar

                VoiceOrb(
                    phase: session.phase,
                    gradient: statusGradient,
                    isActive: session.isConnected,
                    onPressDown: handleOrbPressDown,
                    onPressUp: handleOrbPressUp
                )
                .frame(width: 72, height: 72)
                .padding(.top, 1)

                statusCopy
                transcriptView
                controls
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 7)
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView(onReset: session.resetTranscript)
            }
        }
        .alert("WatchGPT", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "Something went wrong.")
        }
        .onAppear {
            session.prewarmAudio()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                session.handleSceneReactivated()
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("WatchGPT")
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("Voice")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 8)

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.11), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var statusCopy: some View {
        VStack(spacing: 1) {
            Text(session.statusText)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.opacity)

            Text(statusSubtitle)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice status, \(session.statusText)")
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if session.transcriptLines.isEmpty {
                        emptyTranscript
                    }

                    ForEach(session.transcriptLines) { line in
                        RealtimeTranscriptBubble(line: line)
                            .id(line.id)
                    }

                    if !session.latestAssistantTranscript.isEmpty, session.phase == .speaking {
                        RealtimeTranscriptBubble(
                            line: RealtimeTranscriptLine(
                                speaker: .assistant,
                                text: session.latestAssistantTranscript
                            )
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.055))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.09), lineWidth: 0.5)
                    }
            }
            .onChange(of: session.transcriptLines.count) { _, _ in
                if let lastID = session.transcriptLines.last?.id {
                    withAnimation(.smooth(duration: 0.24)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyTranscript: some View {
        VStack(spacing: 5) {
            Image(systemName: session.isConnected ? "mic.fill" : "waveform")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(statusGradient)

            Text(session.isConnected ? "Listening for you" : "Tap the orb")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)

            Text(session.isConnected ? "Speak naturally." : "Start a realtime chat.")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text(controlsHint)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 38)
                .multilineTextAlignment(.center)

            if session.isConnected {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .background(.red.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End session")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.22), value: session.isConnected)
    }

    private var controlsHint: String {
        switch session.phase {
        case .disconnected:
            return "Tap the orb to start"
        case .connecting:
            return "Connecting…"
        case .connected:
            return session.isAutomaticConversationEnabled ? "Speak anytime" : "Hold the orb to talk"
        case .listening:
            return session.isAutomaticConversationEnabled ? "Listening hands-free" : "Release to send"
        case .speaking:
            return session.isAutomaticConversationEnabled ? "Speak to interrupt" : "Replying…"
        }
    }

    private func handleOrbPressDown() {
        switch session.phase {
        case .disconnected:
            session.start()
        case .connected, .speaking:
            session.beginTurn()
        case .listening, .connecting:
            break
        }
    }

    private func handleOrbPressUp() {
        if session.phase == .listening {
            session.commitTurn()
        }
    }

    private var background: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            Circle()
                .fill(statusGradient.opacity(session.isConnected ? 0.30 : 0.18))
                .frame(width: 150, height: 150)
                .blur(radius: 30)
                .offset(y: -48)

            LinearGradient(
                colors: [
                    .white.opacity(0.08),
                    .clear,
                    .black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            session.errorMessage != nil
        } set: { isPresented in
            if !isPresented {
                session.errorMessage = nil
            }
        }
    }

    private var statusGradient: LinearGradient {
        switch session.phase {
        case .disconnected:
            return LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .connecting:
            return LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .connected:
            return LinearGradient(colors: [.mint, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .listening:
            return LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .speaking:
            return LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var statusSubtitle: String {
        switch session.phase {
        case .disconnected:
            return "Tap the orb"
        case .connecting:
            return "Opening session"
        case .connected:
            return session.isAutomaticConversationEnabled ? "Speak naturally" : "Hold the orb to talk"
        case .listening:
            return session.isAutomaticConversationEnabled ? "Listening for your turn" : "Recording your voice"
        case .speaking:
            return session.isAutomaticConversationEnabled ? "You can interrupt" : "Playing the reply"
        }
    }
}

private struct VoiceOrb: View {
    let phase: RealtimeVoiceSession.Phase
    let gradient: LinearGradient
    let isActive: Bool
    let onPressDown: () -> Void
    let onPressUp: () -> Void

    @State private var isPressed = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = isActive ? (sin(time * 2.6) + 1) / 2 : 0
            let ringScale = 1 + pulse * 0.12

            ZStack {
                Circle()
                    .stroke(gradient, lineWidth: 2)
                    .opacity(isActive ? 0.34 : 0.16)
                    .scaleEffect(ringScale)

                Circle()
                    .fill(gradient)
                    .shadow(color: glowColor.opacity(isActive ? 0.62 : 0.24), radius: isActive ? 14 : 7)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.66), .white.opacity(0.05), .clear],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 42
                        )
                    )

                Image(systemName: iconName)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, value: phase == .listening)
            }
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.spring(duration: 0.18), value: isPressed)
        }
        .contentShape(Circle())
        .onLongPressGesture(
            minimumDuration: 0,
            maximumDistance: .greatestFiniteMagnitude,
            perform: {},
            onPressingChanged: { pressing in
                if pressing {
                    isPressed = true
                    onPressDown()
                } else {
                    isPressed = false
                    onPressUp()
                }
            }
        )
        .onDisappear {
            if isPressed {
                isPressed = false
                onPressUp()
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch phase {
        case .disconnected:
            return "Start session"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Voice session ready"
        case .listening:
            return "Listening"
        case .speaking:
            return "Replying"
        }
    }

    private var iconName: String {
        switch phase {
        case .disconnected:
            return "waveform"
        case .connecting:
            return "antenna.radiowaves.left.and.right"
        case .connected:
            return "mic.fill"
        case .listening:
            return "ear.fill"
        case .speaking:
            return "speaker.wave.2.fill"
        }
    }

    private var glowColor: Color {
        switch phase {
        case .disconnected, .connected:
            return .cyan
        case .connecting:
            return .orange
        case .listening:
            return .green
        case .speaking:
            return .purple
        }
    }
}

#Preview {
    ContentView()
}
