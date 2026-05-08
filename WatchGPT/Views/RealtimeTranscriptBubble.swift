import SwiftUI

struct RealtimeTranscriptBubble: View {
    let line: RealtimeTranscriptLine

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            if line.speaker == .user {
                Spacer(minLength: 20)
            }

            if line.speaker == .assistant {
                speakerGlyph
            }

            bubbleText

            if line.speaker == .assistant {
                Spacer(minLength: 20)
            }
        }
        .transition(.scale(scale: 0.96, anchor: line.speaker == .user ? .trailing : .leading).combined(with: .opacity))
    }

    private var bubbleText: some View {
        Text(line.text)
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(line.speaker == .user ? .white : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.white.opacity(line.speaker == .user ? 0.18 : 0.08), lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if line.speaker == .user {
            LinearGradient(
                colors: [.accentColor, .cyan],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color.white.opacity(0.12)
        }
    }

    private var speakerGlyph: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.cyan)
            .frame(width: 18, height: 18)
            .background(.white.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }
}
