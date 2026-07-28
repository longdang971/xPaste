import SwiftUI
import AppKit

/// Background material for the floating panel.
///
/// On macOS 26 this is real Liquid Glass (`NSGlassEffectView`): it refracts and
/// tints toward whatever sits behind the window, which is what gives the bar its
/// mirror-like look over the wallpaper, plus a specular rim along the rounded edge.
/// Older systems fall back to the most transparent vibrancy material available, so
/// the wallpaper still bleeds through. Both follow the system light/dark appearance.
struct PanelGlassBackground: View {
    var cornerRadius: CGFloat

    var body: some View {
        if #available(macOS 26.0, *) {
            LiquidGlassView(cornerRadius: cornerRadius)
        } else {
            VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
        }
    }
}

@available(macOS 26.0, *)
private struct LiquidGlassView: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }
}
