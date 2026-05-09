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
                statusCard
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                transcriptsList
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("WatchGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
                    Text("Copied")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
    }

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

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusTint.opacity(0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .font(.title3)
                        .foregroundStyle(statusTint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(bridge.statusText)
                        .font(.headline)
                    Text(keyStatusText)
                        .font(.caption)
                        .foregroundStyle(PhoneConfiguration.openAIAPIKey.isEmpty ? .orange : .secondary)
                }

                Spacer()
            }

            if bridge.isActive {
                HStack(spacing: 14) {
                    metric("watch", "\(bridge.audioChunksFromWatch)")
                    metric("openai", "\(bridge.audioChunksToOpenAI)")
                    metric("events", "\(bridge.eventsFromOpenAI)")
                    Spacer()
                    Text(String(format: "mic %.3f", bridge.lastWatchInputPeak))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(bridge.lastWatchInputPeak == 0 ? .red : .secondary)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var statusTint: Color {
        bridge.isActive ? .green : .cyan
    }

    @ViewBuilder
    private var transcriptsList: some View {
        if bridge.transcriptSessions.isEmpty {
            VStack {
                Spacer()
                ContentUnavailableView(
                    "No transcripts yet",
                    systemImage: "text.bubble",
                    description: Text("Chats from the watch will appear here.")
                )
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var keyStatusText: String {
        PhoneConfiguration.openAIAPIKey.isEmpty
            ? "Add an OpenAI API key in Settings"
            : "API key configured"
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

    private func transcriptSessionRow(_ session: PhoneTranscriptSession) -> some View {
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
                Text("\(session.lines.count) msg")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func sessionPreview(_ session: PhoneTranscriptSession) -> String {
        session.lines.first?.text ?? "No messages yet"
    }

    private func copyTranscript() {
        UIPasteboard.general.string = transcriptText
        didCopyTranscript = true

        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                didCopyTranscript = false
            }
        }
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
        List {
            if currentSession.lines.isEmpty {
                ContentUnavailableView(
                    "No messages",
                    systemImage: "text.bubble",
                    description: Text("This transcript has not captured any messages yet.")
                )
            } else {
                ForEach(currentSession.lines) { line in
                    transcriptRow(line)
                }
            }
        }
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
                Text("Copied")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 20)
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

    private var transcriptText: String {
        currentSession.lines.map { line in
            let speaker = line.speaker == .user ? "You" : "WatchGPT"
            return "\(speaker): \(line.text)"
        }
        .joined(separator: "\n\n")
    }

    private func transcriptRow(_ line: PhoneTranscriptLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(line.speaker == .user ? "You" : "WatchGPT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(line.speaker == .user ? .blue : .green)

                Spacer()

                Text(line.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(line.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
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
    }
}

#Preview {
    PhoneContentView()
}
