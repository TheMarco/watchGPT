import SwiftUI

struct PhoneContentView: View {
    @ObservedObject private var bridge = PhoneRealtimeBridge.shared
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 80, weight: .light))
                    .foregroundStyle(.cyan)

                VStack(spacing: 6) {
                    Text("WatchGPT")
                        .font(.title.weight(.semibold))
                    Text("Companion")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                statusBadge

                Text("Open WatchGPT on your Apple Watch and tap the orb. This phone holds the connection to OpenAI Realtime.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("WatchGPT")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    PhoneSettingsView()
                }
            }
        }
    }

    private var statusBadge: some View {
        VStack(spacing: 4) {
            Text(bridge.statusText)
                .font(.headline)
                .foregroundStyle(bridge.isActive ? Color.green : .secondary)

            Text(keyStatusText)
                .font(.caption)
                .foregroundStyle(PhoneConfiguration.openAIAPIKey.isEmpty ? .orange : .secondary)

            if bridge.isActive {
                Text("watch \(bridge.audioChunksFromWatch) → openai \(bridge.audioChunksToOpenAI)  ·  events \(bridge.eventsFromOpenAI)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(String(format: "mic raw %.4f · post %d", bridge.lastWatchInputPeak, bridge.lastAudioPeak))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(bridge.lastWatchInputPeak == 0 ? .red : .secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var keyStatusText: String {
        PhoneConfiguration.openAIAPIKey.isEmpty
            ? "Add an OpenAI API key in Settings"
            : "API key configured"
    }
}

#Preview {
    PhoneContentView()
}
