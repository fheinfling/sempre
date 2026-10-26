import AppKit
import SwiftUI
import SempreCore

enum Palette {
    static let colors: [Color] = [
        Color(red: 0.36, green: 0.47, blue: 0.96), // indigo
        Color(red: 0.13, green: 0.70, blue: 0.62), // teal
        Color(red: 0.96, green: 0.55, blue: 0.24), // orange
        Color(red: 0.89, green: 0.33, blue: 0.47), // rose
        Color(red: 0.55, green: 0.40, blue: 0.90), // violet
        Color(red: 0.35, green: 0.70, blue: 0.30), // green
        Color(red: 0.92, green: 0.74, blue: 0.20), // amber
        Color(red: 0.40, green: 0.62, blue: 0.85), // sky
    ]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }

    /// A coloured dot for menus, which otherwise draw symbols as black templates.
    static func menuSwatch(_ i: Int, checked: Bool) -> Image {
        let config = NSImage.SymbolConfiguration(paletteColors: checked ? [.white, NSColor(color(i))] : [NSColor(color(i))])
        let image = NSImage(systemSymbolName: checked ? "checkmark.circle.fill" : "circle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

extension Project {
    var swatch: Color {
        guard let rgb else { return Palette.color(color) }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

extension Store {
    func revealDataFile() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

extension TymeImporter {
    /// Asks for Tyme's data folder (or its database file) and imports it. nil when cancelled.
    @MainActor
    static func pickAndImport() throws -> Result? {
        let panel = NSOpenPanel()
        panel.title = "Choose your Tyme 2 data folder or database"
        panel.message = "Select Tyme's \"Application Support\" folder or the Tyme2.data file. Sempre only reads it."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultLocation
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try importFrom(url)
    }
}

/// MenuBarExtra's window doesn't always follow its content's height (switching from Track to the
/// taller Stats tab left it short, centring the panel and clipping its top and bottom).
/// This sizes the window to the content itself, keeping its top edge under the menu bar.
struct FitsWindowToContent: ViewModifier {
    @State private var window: NSWindow?
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0; fit() }
            .background(WindowReader { window = $0; fit() })
            // Reopening the panel can bring back a stale window size while the content's height is unchanged.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if note.object as? NSWindow === window { fit() }
            }
    }

    /// Deferred: the geometry callback runs during layout, and resizing the window there re-enters it.
    private func fit() {
        DispatchQueue.main.async { resize() }
    }

    private func resize() {
        guard let window, let view = window.contentView, height > 0,
              abs(view.frame.height - height) > 0.5 else { return }
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: view.frame.width, height: height)).size
        var frame = window.frame
        frame.origin.y = frame.maxY - size.height
        frame.size.height = size.height
        window.setFrame(frame, display: true)
    }
}

/// Hands over the window a SwiftUI view ends up in.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(found: found) }
    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { self.found(window) }
        }
    }
}
