import SwiftUI
import UIKit

struct PhoneContentView: View {
    @ObservedObject private var bridge = PhoneRealtimeBridge.shared
    @State private var showingSettings = false
    @State private var showingClearConfirmation = false
    @State private var sessionPendingDeletion: PhoneTranscriptSession?
    @State private var didCopyTranscript = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusHero
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

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
            .confirmationDialog(
                deletionDialogTitle,
                isPresented: deletionDialogBinding,
                titleVisibility: .visible,
                presenting: sessionPendingDeletion
            ) { session in
                Button("Delete", role: .destructive) {
                    bridge.deleteTranscriptSession(id: session.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This transcript will be permanently removed.")
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    PhoneSettingsView()
                }
            }
            .overlay(alignment: .bottom) {
                if didCopyTranscript {
                    copiedToast
                }
            }
            .animation(.smooth(duration: 0.35), value: bridge.isActive)
            .animation(.smooth(duration: 0.25), value: bridge.statusText)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ShareLink(item: transcriptText) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(bridge.transcriptSessions.isEmpty)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
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
                        colors: [heroTint.opacity(bridge.isActive ? 0.18 : 0.10), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(heroTint.opacity(0.16), lineWidth: 0.5)
                }
        }
    }

    private var heroIcon: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !bridge.isActive)) { timeline in
            let phase = bridge.isActive
                ? (sin(timeline.date.timeIntervalSinceReferenceDate * 2.2) + 1) / 2
                : 0.0

            ZStack {
                Circle()
                    .fill(heroTint.opacity(0.16))
                    .frame(width: 72, height: 72)

                if bridge.isActive {
                    Circle()
                        .stroke(heroTint.opacity(0.18 + phase * 0.32), lineWidth: 1.5)
                        .frame(width: 72 + phase * 14, height: 72 + phase * 14)
                }

                Image(systemName: heroIconName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(heroTint)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }

    private var heroIconName: String {
        if PhoneConfiguration.openAIAPIKey.isEmpty {
            return "key.horizontal"
        }
        if bridge.isActive {
            return "applewatch.radiowaves.left.and.right"
        }
        return "applewatch"
    }

    private var heroSubline: String {
        if PhoneConfiguration.openAIAPIKey.isEmpty {
            return "Add your OpenAI API key in Settings to begin."
        }
        if bridge.isActive {
            return "Streaming to OpenAI. Keep WatchGPT open on both devices."
        }
        return "Tap the orb on your Apple Watch to start a conversation."
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
            metric("MIC", String(format: "%.2f", bridge.lastWatchInputPeak))
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

    // MARK: - Transcripts

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
                                sessionPendingDeletion = session
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
        session.lines.first?.text ?? "No messages yet"
    }

    // MARK: - Helpers

    private var deletionDialogBinding: Binding<Bool> {
        Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )
    }

    private var deletionDialogTitle: String {
        if let title = sessionPendingDeletion?.title, !title.isEmpty {
            return "Delete \"\(title)\"?"
        }
        return "Delete this transcript?"
    }

    private var transcriptText: String {
        bridge.transcriptSessions.map { session in
            let lines = session.lines.map { line in
                let speaker = line.speaker == .user ? "You" : "WatchGPT"
                return "\(speaker): \(line.text)"
            }
            .joined(separator: "\n\n")

            return "\(session.title)\n\(lines)"
        }
        .joined(separator: "\n\n---\n\n")
    }

    private var copiedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Copied")
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 24)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
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
            LazyVStack(spacing: 6) {
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

    private var transcriptText: String {
        currentSession.lines.map { line in
            let speaker = line.speaker == .user ? "You" : "WatchGPT"
            return "\(speaker): \(line.text)"
        }
        .joined(separator: "\n\n")
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

#Preview {
    PhoneContentView()
}
