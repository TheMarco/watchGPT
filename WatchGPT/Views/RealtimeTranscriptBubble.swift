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
            .clipShape(bubbleShape)
            .overlay {
                bubbleShape
                    .strokeBorder(.white.opacity(line.speaker == .user ? 0.18 : 0.08), lineWidth: 0.5)
            }
            .shadow(color: bubbleShadow, radius: 8, y: 3)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if line.speaker == .user {
            LinearGradient(
                colors: [.blue, .cyan],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [.white.opacity(0.16), .white.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: 14,
                bottomLeading: line.speaker == .user ? 14 : 5,
                bottomTrailing: line.speaker == .user ? 5 : 14,
                topTrailing: 14
            ),
            style: .continuous
        )
    }

    private var bubbleShadow: Color {
        line.speaker == .user ? .cyan.opacity(0.16) : .black.opacity(0.14)
    }

    private var speakerGlyph: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(
                LinearGradient(
                    colors: [.purple, .pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
