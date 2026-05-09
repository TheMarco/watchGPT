import SwiftUI

struct ContentView: View {
    @StateObject private var session = RealtimeVoiceSession()
    @State private var isShowingSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @AppStorage(AppConfiguration.voiceBargeInKey) private var voiceBargeIn = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 7) {
                topBar

                VoiceOrb(
                    phase: session.phase,
                    gradient: statusGradient,
                    tint: statusTint,
                    isActive: session.isConnected,
                    onPressDown: handleOrbPressDown,
                    onPressUp: handleOrbPressUp
                )
                .frame(width: 76, height: 76)
                .padding(.top, 2)

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
            Text("WatchGPT")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .opacity(0.94)

            Spacer(minLength: 8)

            connectionPill

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var connectionPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(session.isCompanionReachable ? .green : .orange)
                .frame(width: 5, height: 5)

            Image(systemName: session.isCompanionReachable ? "iphone" : "iphone.slash")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(session.isCompanionReachable ? .green : .orange)
        .frame(width: 34, height: 24)
        .background((session.isCompanionReachable ? Color.green : Color.orange).opacity(0.14), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder((session.isCompanionReachable ? Color.green : Color.orange).opacity(0.22), lineWidth: 0.5)
        }
        .accessibilityLabel(session.connectionStatusText)
    }

    private var statusCopy: some View {
        VStack(spacing: 1) {
            Text(session.statusText)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(statusTitleStyle)
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.045))
                    .overlay {
                        LinearGradient(
                            colors: [.white.opacity(0.13), .white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(statusTint.opacity(session.isConnected ? 0.22 : 0.10), lineWidth: 0.7)
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
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusGradient)
                .frame(width: 34, height: 34)
                .background(statusTint.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Text(session.isConnected ? "Listening for you" : "Tap the button")
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
                .padding(.horizontal, 10)
                .background(.white.opacity(0.045), in: Capsule())

            if session.isConnected {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.red.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(.white.opacity(0.28), lineWidth: 0.6)
                        }
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
            return "Tap the button to start"
        case .connecting:
            return "Connecting…"
        case .connected:
            return session.isAutomaticConversationEnabled ? "Speak anytime" : "Hold the button to talk"
        case .listening:
            return session.isAutomaticConversationEnabled ? "Listening hands-free" : "Release to send"
        case .speaking:
            if !session.isAutomaticConversationEnabled {
                return "Replying…"
            }
            return voiceBargeIn ? "Speak/tap to interrupt" : "Tap to interrupt"
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
        let normalizedPeak = isLuminanceReduced
            ? 0
            : Double(min(1.0, session.lastInputPeak * 2.5))
        let baseHaloOpacity = isLuminanceReduced
            ? 0.06
            : (session.isConnected ? 0.30 : 0.18)
        let haloOpacity = baseHaloOpacity + normalizedPeak * 0.22
        let haloScale = 1.0 + normalizedPeak * 0.34
        let haloBlur = 30 + normalizedPeak * 8
        let haloGradient: LinearGradient = isLuminanceReduced
            ? LinearGradient(
                colors: [.gray.opacity(0.5), .gray.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            : statusGradient

        return ZStack {
            Color.black
                .ignoresSafeArea()

            Circle()
                .fill(haloGradient.opacity(haloOpacity))
                .frame(width: 150, height: 150)
                .scaleEffect(haloScale)
                .blur(radius: haloBlur)
                .offset(y: -48)
                .animation(.smooth(duration: 0.18), value: session.lastInputPeak)
                .animation(.smooth(duration: 0.30), value: session.isConnected)

            Circle()
                .fill(statusTint.opacity(isLuminanceReduced ? 0 : 0.12))
                .frame(width: 110, height: 110)
                .blur(radius: 36)
                .offset(x: 58, y: 80)

            LinearGradient(
                colors: [
                    statusTint.opacity(isLuminanceReduced ? 0.04 : 0.11),
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

    private var statusTint: Color {
        switch session.phase {
        case .disconnected:
            return .cyan
        case .connecting:
            return .orange
        case .connected:
            return .mint
        case .listening:
            return .green
        case .speaking:
            return .purple
        }
    }

    private var statusTitleStyle: some ShapeStyle {
        statusGradient
    }

    private var statusSubtitle: String {
        switch session.phase {
        case .disconnected:
            return session.isCompanionReachable ? "Tap the button" : session.connectionStatusText
        case .connecting:
            return session.connectionStatusText == "iPhone ready" ? "Opening session" : session.connectionStatusText
        case .connected:
            return session.isAutomaticConversationEnabled ? "Speak naturally" : "Hold the button to talk"
        case .listening:
            return session.isAutomaticConversationEnabled ? "Listening for your turn" : "Recording your voice"
        case .speaking:
            if !session.isAutomaticConversationEnabled {
                return "Playing the reply"
            }
            return voiceBargeIn ? "Speak/tap to interrupt" : "Tap to interrupt"
        }
    }
}

private struct VoiceOrb: View {
    let phase: RealtimeVoiceSession.Phase
    let gradient: LinearGradient
    let tint: Color
    let isActive: Bool
    let onPressDown: () -> Void
    let onPressUp: () -> Void

    @State private var isPressed = false
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var dimmedGradient: LinearGradient {
        LinearGradient(
            colors: [.gray.opacity(0.7), .gray.opacity(0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (isActive && !isLuminanceReduced) ? (sin(time * 2.6) + 1) / 2 : 0
            let ringScale = 1 + pulse * 0.12
            let activeGradient = isLuminanceReduced ? dimmedGradient : gradient
            let activeIcon = isLuminanceReduced ? "waveform" : iconName
            let activeGlow = isLuminanceReduced ? Color.white.opacity(0.18) : glowColor.opacity(isActive ? 0.62 : 0.24)
            let glowRadius: CGFloat = isLuminanceReduced ? 4 : (isActive ? 18 : 9)

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(activeGradient, lineWidth: 2)
                    .opacity(isLuminanceReduced ? 0.10 : (isActive ? 0.34 : 0.16))
                    .scaleEffect(ringScale)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(activeGradient)
                    .shadow(color: activeGlow, radius: glowRadius)

                if !isLuminanceReduced {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.66), .white.opacity(0.05), .clear],
                                center: .topLeading,
                                startRadius: 2,
                                endRadius: 42
                            )
                        )

                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.8)

                    if phase == .listening {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(tint.opacity(0.18 - Double(index) * 0.035), lineWidth: 1)
                                .scaleEffect(1.12 + pulse * 0.16 + CGFloat(index) * 0.10)
                        }
                    }
                }

                Image(systemName: activeIcon)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white.opacity(isLuminanceReduced ? 0.78 : 1.0))
                    .symbolEffect(.pulse, options: .repeating, value: !isLuminanceReduced && phase == .listening)
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
