import AppKit
import Foundation
import JevCore

/// `jev-cua ui-preview [--ui notch|pill] [--out runs/ui-preview] [--hold N]`
/// Drives the overlay through scripted states (idle, listening, transcript growing, chips,
/// confirmation, badges) and writes one PNG per state, composited over a menu-bar-like
/// background. The window is also shown live for `--hold` seconds per state.
enum UIPreview {
    @MainActor
    static func run(_ args: Args) async throws {
        let app = NSApplication.shared
        let style = RunUI.Style(rawValue: args.string("ui") ?? "notch") ?? .notch
        let out = URL(fileURLWithPath: args.string("out") ?? "runs/ui-preview", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let hold = Double(args.string("hold") ?? "0.6") ?? 0.6
        let renderer: any OverlayRenderer = style == .pill ? PillWindow() : NotchWindow()
        let window = (renderer as? NotchWindow)?.debugPanel ?? (renderer as? PillWindow)?.debugPanel

        var m = OverlayModel()
        m.listening = true
        func chip(_ label: String, _ st: OverlayModel.Chip.State) -> OverlayModel.Chip { .init(label: label, state: st) }
        let states: [(String, OverlayModel)] = [
            ("01-idle", m),
            ("02-partial", { var x = m; x.rawText = "open the"; x.level = 0.03; x.micLoud = true; x.statusLine = "nothing yet"; return x }()),
            ("03-partial2", { var x = m; x.rawText = "open the notes app and"; x.level = 0.06; x.micLoud = true; x.statusLine = "waiting for the rest of the command"; return x }()),
            ("04-dispatched", { var x = m; x.rawText = "open the notes app and cre"; x.consumed = "open the notes app"; x.level = 0.05; x.micLoud = true
                                x.chips = [chip("Open Notes", .running)]; x.statusLine = ""; return x }()),
            ("05-verified", { var x = m; x.rawText = "open the notes app and create a new note"; x.consumed = "open the notes app and create a new note"; x.level = 0.01
                              x.chips = [chip("Open Notes", .verified), chip("New note", .verified)]; x.statusLine = "Cmd+N · note list 12 → 13 rows"; return x }()),
            ("06-search", { var x = m; x.rawText = "google search norbert wiener"; x.consumed = "google search norbert wiener"; x.level = 0.02
                            x.chips = [chip("Search wikipedia for “Michael Jordan”", .verified)]; x.statusLine = "opened · https://en.wikipedia.org/w/index.php?search=Michael+Jordan&title=Special%3ASearch&ns0=1"; return x }()),
            ("07-failed", { var x = m; x.rawText = "take a picture of me"; x.consumed = "take a picture of me"; x.level = 0.0
                            x.chips = [chip("Take photo", .failed)]; x.statusLine = "Photo Booth did not come to the front"; return x }()),
            ("08-confirm", { var x = m; x.rawText = "send the message"; x.consumed = "send the message"; x.pending = "press_enter"; x.statusLine = "confirm"; return x }()),
            ("09-badges", { var x = m; x.rawText = "click share"; x.consumed = "click share"; x.badgeCount = 2; x.statusLine = "which one?"; return x }()),
            ("10-paused", { var x = m; x.listening = false; x.statusLine = "paused"; return x }()),
        ]
        // Menu-bar icons, as they appear on a light and a dark menu bar.
        if let sheet = Self.iconSheet() { try? sheet.write(to: out.appending(path: "menubar-icons.png")) }
        renderer.show()
        var index = 0
        for (name, state) in states {
            index += 1
            renderer.render(state)
            // Let the expand/collapse animation and layout settle.
            try? await Task.sleep(for: .milliseconds(Int(max(0.35, hold) * 1000)))
            if let window, let image = Self.capture(window) {
                let file = out.appending(path: "\(style.rawValue)-\(name).png")
                try? image.write(to: file)
                print("wrote \(file.path)")
            }
        }
        // Idle again so the collapse (after its 1.8 s linger) is captured too.
        renderer.render(m)
        try? await Task.sleep(for: .milliseconds(2400))
        if let window, let image = Self.capture(window) { try? image.write(to: out.appending(path: "\(style.rawValue)-11-collapsed.png")) }
        app.terminate(nil)
    }

    @MainActor
    static func iconSheet() -> Data? {
        let states: [StatusIcon.State] = [.listening, .speaking, .paused]
        let cell: CGFloat = 44
        let size = NSSize(width: cell * CGFloat(states.count) + 16, height: cell * 2 + 24)
        let img = NSImage(size: size)
        img.lockFocus()
        for (row, bg) in [(0, NSColor(calibratedWhite: 0.90, alpha: 1)), (1, NSColor(calibratedWhite: 0.16, alpha: 1))] {
            let y = size.height - CGFloat(row + 1) * (cell + 8)
            bg.setFill()
            NSRect(x: 8, y: y, width: size.width - 16, height: cell).fill()
            for (i, st) in states.enumerated() {
                guard let icon = StatusIcon.image(for: st) else { continue }
                let tint: NSColor = row == 0 ? .black : .white
                let tinted = NSImage(size: icon.size, flipped: false) { rect in
                    icon.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let r = NSRect(x: 8 + CGFloat(i) * cell + (cell - icon.size.width) / 2, y: y + (cell - icon.size.height) / 2, width: icon.size.width, height: icon.size.height)
                tinted.draw(in: r)
            }
        }
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return nil }
        return out.representation(using: .png, properties: [:])
    }

    /// Renders the window's content view over a flat menu-bar-like background.
    @MainActor
    static func capture(_ window: NSWindow) -> Data? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let pad: CGFloat = 40
        let size = NSSize(width: bounds.width + 2 * pad, height: bounds.height + pad)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        // A menu-bar band across the top so the flares read correctly.
        NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: size.height - 32, width: size.width, height: 32).fill()
        rep.draw(in: NSRect(x: pad, y: size.height - bounds.height, width: bounds.width, height: bounds.height))
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return nil }
        return out.representation(using: .png, properties: [:])
    }
}
