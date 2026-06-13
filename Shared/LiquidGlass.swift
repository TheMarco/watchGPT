import SwiftUI

// Liquid Glass adoption helpers (iOS 26 / watchOS 26).
//
// Every glass API is 26-only, but the apps deploy to iOS 17 / watchOS 11, so
// each use is availability-guarded with the previous look preserved as the
// fallback. Centralizing it here keeps call sites a single modifier and makes
// the floor behavior non-regressive.

extension View {
    /// Applies a Liquid Glass background on OS 26+, falling back to the supplied
    /// background view on older systems (so the existing custom look is kept).
    ///
    /// - Parameters:
    ///   - shape: the glass capsule/rounded-rect shape.
    ///   - tint: optional brand tint blended into the glass.
    ///   - interactive: whether the glass reacts to touch (for tappable surfaces).
    ///   - fallback: the background used below OS 26 (typically the prior design).
    @ViewBuilder
    func glassSurface<Fallback: View>(
        in shape: some Shape,
        tint: Color? = nil,
        interactive: Bool = false,
        @ViewBuilder fallback: () -> Fallback
    ) -> some View {
        if #available(iOS 26.0, watchOS 26.0, *) {
            glassEffect(makeLiquidGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            background { fallback() }
        }
    }
}

@available(iOS 26.0, watchOS 26.0, *)
private func makeLiquidGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

/// Wraps adjacent glass surfaces so they blend/morph correctly and render
/// efficiently. A passthrough below OS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, watchOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}
