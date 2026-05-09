import SwiftUI
import UIKit

struct PhoneContentView: View {
    @ObservedObject private var bridge = PhoneRealtimeBridge.shared
    @State private var showingSettings = false
    @State private var showingClearConfirmation = false
    @State private var isDiagnosticsExpanded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusHero
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                mainActions
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                diagnosticsPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                transcriptsList
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("WatchGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .confirmationDialog(
                "Clear all transcripts?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear all", role: .destructive) {
                    bridge.clearTranscriptSessions()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently remove every saved transcript.")
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    PhoneSettingsView()
                }
            }
            .animation(.smooth(duration: 0.35), value: bridge.isActive)
            .animation(.smooth(duration: 0.25), value: bridge.statusText)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
                NavigationLink {
                    PhoneHelpView()
                } label: {
                    Image(systemName: "questionmark.circle")
                }

                NavigationLink {
                    PhoneAboutView()
                } label: {
                    Image(systemName: "info.circle")
                }

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    // MARK: - Hero

    private var statusHero: some View {
        VStack(spacing: 14) {
            heroIcon

            VStack(spacing: 4) {
                Text(bridge.statusText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                    .multilineTextAlignment(.center)

                Text(heroSubline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minHeight: 40)
            }

            if bridge.isActive {
                metricsStrip
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [
                            heroTint.opacity(bridge.isActive ? 0.26 : 0.16),
                            Color.purple.opacity(PhoneConfiguration.openAIAPIKey.isEmpty ? 0.02 : 0.08),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(heroTint.opacity(0.12))
                        .frame(width: 130, height: 130)
                        .blur(radius: 36)
                        .offset(x: 44, y: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(heroTint.opacity(0.22), lineWidth: 0.7)
                }
        }
    }

    private var heroIcon: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !bridge.isActive)) { timeline in
            let phase = bridge.isActive
                ? (sin(timeline.date.timeIntervalSinceReferenceDate * 2.2) + 1) / 2
                : 0.0

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(heroTint.opacity(0.16))
                    .frame(width: 78, height: 78)

                if bridge.isActive {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(heroTint.opacity(0.18 + phase * 0.32), lineWidth: 1.5)
                        .frame(width: 78 + phase * 14, height: 78 + phase * 14)
                }

                PhoneAppIconImage()
                    .frame(width: 70, height: 70)
                    .shadow(color: heroTint.opacity(0.26), radius: 14, y: 6)

                if PhoneConfiguration.openAIAPIKey.isEmpty {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.orange, in: Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                        }
                        .offset(x: 28, y: 28)
                }
            }
        }
    }

    private var heroSubline: String {
        if PhoneConfiguration.openAIAPIKey.isEmpty {
            return "Add your OpenAI API key in Settings to begin."
        }
        if bridge.isActive {
            return "Streaming to OpenAI. Keep both apps open."
        }
        return "Tap the main button on your Apple Watch to start a conversation."
    }

    private var heroTint: Color {
        if PhoneConfiguration.openAIAPIKey.isEmpty {
            return .orange
        }
        return bridge.isActive ? .green : .accentColor
    }

    private var metricsStrip: some View {
        HStack(spacing: 0) {
            metric("WATCH", "\(bridge.audioChunksFromWatch)")
            metricDivider
            metric("OPENAI", "\(bridge.audioChunksToOpenAI)")
            metricDivider
            metric("EVENTS", "\(bridge.eventsFromOpenAI)")
            metricDivider
            metric("SEARCH", "\(bridge.webSearchCount)")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1, height: 22)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private var mainActions: some View {
        HStack(spacing: 10) {
            NavigationLink {
                PhoneHelpView()
            } label: {
                mainAction("Help", icon: "questionmark.circle.fill", tint: .blue)
            }
            .buttonStyle(.plain)

            NavigationLink {
                PhoneAboutView()
            } label: {
                mainAction("About", icon: "info.circle.fill", tint: .purple)
            }
            .buttonStyle(.plain)
        }
    }

    private func mainAction(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay {
                    LinearGradient(
                        colors: [tint.opacity(0.10), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 0.5)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.smooth(duration: 0.24)) {
                    isDiagnosticsExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("Diagnostics", systemImage: "waveform.path")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(bridge.isActive ? "Live" : "Idle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(bridge.isActive ? .green : .secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isDiagnosticsExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if isDiagnosticsExpanded {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    diagnostic("Mode", PhoneConfiguration.defaultVoiceEngine.displayName)
                    diagnostic("Turn-taking", PhoneConfiguration.realtimeEagerness.displayName)
                    diagnostic("Last event", bridge.lastOpenAIEventType)
                    diagnostic("Reconnects", "\(bridge.reconnectCount)")
                    diagnostic("Mic peak", String(format: "%.2f", bridge.lastWatchInputPeak))
                    diagnostic("Watch chunks", "\(bridge.audioChunksFromWatch)")
                }

                if let reconnect = bridge.lastReconnectMessage {
                    Text(reconnect)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Transcripts

    private func diagnostic(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var transcriptsList: some View {
        if bridge.transcriptSessions.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(bridge.transcriptSessions.reversed()) { session in
                        NavigationLink {
                            PhoneTranscriptDetailView(session: session)
                        } label: {
                            transcriptSessionRow(session)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                bridge.deleteTranscriptSession(id: session.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Transcripts")
                        Spacer()
                        Button {
                            showingClearConfirmation = true
                        } label: {
                            Text("Clear all")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 100, height: 100)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(spacing: 6) {
                Text("Nothing here yet")
                    .font(.title3.weight(.semibold))
                Text("Talk to WatchGPT on your Apple Watch.\nYour conversations will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private func transcriptSessionRow(_ session: PhoneTranscriptSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(sessionPreview(session))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(session.date, style: .date)
                    Text("·")
                    Text("\(session.lines.count) message\(session.lines.count == 1 ? "" : "s")")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.top, 1)
        }
        .padding(.vertical, 4)
    }

    private func sessionPreview(_ session: PhoneTranscriptSession) -> String {
        session.summary ?? session.lines.first?.text ?? "No messages yet"
    }

}

struct PhoneTranscriptDetailView: View {
    @ObservedObject private var bridge = PhoneRealtimeBridge.shared
    let session: PhoneTranscriptSession
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyTranscript = false
    @State private var showingDeleteConfirmation = false

    private var currentSession: PhoneTranscriptSession {
        bridge.transcriptSessions.first(where: { $0.id == session.id }) ?? session
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                transcriptHeader

                if currentSession.lines.isEmpty {
                    emptyDetailState
                        .padding(.top, 80)
                } else {
                    ForEach(Array(currentSession.lines.enumerated()), id: \.element.id) { index, line in
                        transcriptBubble(line, isFirstOfSpeaker: isFirstOfSpeaker(at: index))
                    }
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(currentSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = transcriptText
                    didCopyTranscript = true
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(currentSession.lines.isEmpty)

                ShareLink(item: transcriptText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(currentSession.lines.isEmpty)

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                bridge.deleteTranscriptSession(id: currentSession.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This transcript will be permanently removed.")
        }
        .overlay(alignment: .bottom) {
            if didCopyTranscript {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Copied")
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 20)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .onChange(of: didCopyTranscript) { _, didCopy in
            guard didCopy else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                await MainActor.run {
                    didCopyTranscript = false
                }
            }
        }
    }

    private func isFirstOfSpeaker(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return currentSession.lines[index].speaker != currentSession.lines[index - 1].speaker
    }

    private var emptyDetailState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 84, height: 84)
                Image(systemName: "text.bubble")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            }
            Text("No messages yet")
                .font(.headline)
            Text("This transcript hasn't captured any messages.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var transcriptHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = currentSession.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                usageTile("Mode", currentSession.engine.displayName)
                usageTile("Duration", formattedDuration(currentSession.usage.durationSeconds))
                usageTile("Events", "\(currentSession.usage.eventsFromOpenAI)")
                usageTile("Searches", "\(currentSession.usage.webSearchCount)")
                usageTile("Reconnects", "\(currentSession.usage.reconnectCount)")
                usageTile("Approx mic", formattedDuration(currentSession.usage.audioChunksFromWatch / 5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func usageTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formattedDuration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "Live" }
        let minutes = seconds / 60
        let remaining = seconds % 60
        if minutes == 0 {
            return "\(remaining)s"
        }
        return "\(minutes)m \(remaining)s"
    }

    private var transcriptText: String {
        let header = [
            currentSession.title,
            currentSession.summary,
            "Mode: \(currentSession.engine.displayName)",
            "Duration: \(formattedDuration(currentSession.usage.durationSeconds))",
            "Approx mic audio: \(formattedDuration(currentSession.usage.audioChunksFromWatch / 5))",
            "Searches: \(currentSession.usage.webSearchCount)",
            "Reconnects: \(currentSession.usage.reconnectCount)"
        ]
        .compactMap { $0 }
        .joined(separator: "\n")

        let body = currentSession.lines.map { line in
            let speaker = line.speaker == .user ? "You" : "WatchGPT"
            return "\(speaker): \(line.text)"
        }
        .joined(separator: "\n\n")

        return body.isEmpty ? header : "\(header)\n\n\(body)"
    }

    private func transcriptBubble(_ line: PhoneTranscriptLine, isFirstOfSpeaker: Bool) -> some View {
        let isUser = line.speaker == .user

        return HStack(alignment: .bottom, spacing: 0) {
            if isUser {
                Spacer(minLength: 56)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if isFirstOfSpeaker {
                    Text(isUser ? "You" : "WatchGPT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }

                Text(line.text)
                    .font(.body)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        bubbleFill(isUser: isUser),
                        in: bubbleShape(isUser: isUser)
                    )
                    .textSelection(.enabled)

                Text(line.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = line.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                ShareLink(item: line.text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            if !isUser {
                Spacer(minLength: 56)
            }
        }
        .padding(.top, isFirstOfSpeaker ? 8 : 0)
    }

    private func bubbleFill(isUser: Bool) -> Color {
        isUser ? .accentColor : Color(.secondarySystemGroupedBackground)
    }

    private func bubbleShape(isUser: Bool) -> some Shape {
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: 18,
                bottomLeading: isUser ? 18 : 4,
                bottomTrailing: isUser ? 4 : 18,
                topTrailing: 18
            ),
            style: .continuous
        )
    }
}

struct PhoneAppIconImage: View {
    var body: some View {
        if let image = Self.brandIcon {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                LinearGradient(
                    colors: [.blue, .purple, .pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private static var brandIcon: UIImage? {
        if let brand = UIImage(named: "BrandIcon") {
            return brand
        }

        guard
            let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String],
            let iconName = files.last
        else {
            return UIImage(named: "PhoneAppIcon")
        }

        return UIImage(named: iconName) ?? UIImage(named: "PhoneAppIcon")
    }
}

#Preview {
    PhoneContentView()
}
