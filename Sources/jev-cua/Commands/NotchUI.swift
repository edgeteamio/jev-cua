import AppKit
import Foundation
import JevCore

/// Notch-style overlay: a black shape that continues the MacBook notch below the menu bar. When
/// idle it is the notch plus a small listening dot beside the cutout; while you speak it widens
/// and drops the transcript and the action chips out of it. On a display without a notch it
/// draws a simulated one at the top center. Never takes focus or mouse events.
@MainActor
final class NotchWindow: OverlayRenderer {
    private let panel: NSPanel
    private let shape = NotchShapeView()
    private let meter = LevelMeterView()
    private let transcriptField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let chipRow = NSStackView()
    private let dot = NSView()
    private var expanded = false
    private var collapseTask: Task<Void, Never>?
    private var lastModel = OverlayModel()
    private var hoverTimer: Timer?
    private var hovering = false
    private var hoverSince: TimeInterval?
    /// A phrase to suggest on hover (the app in front's examples); picked once per hover so the
    /// hint does not reshuffle while the pointer rests there.
    var hoverHint: (() -> String?)?
    private var hoverText: String?
    /// Render trace into the run log (kind "ui"), for diagnosing a notch that does not update.
    var trace: ((String, [String: JSONValue]) -> Void)?
    private var renders = 0
    private var lastSig = ""

    /// Geometry of the notch on `screen`, in points. `height` is the menu-bar band on a
    /// notched display (the safe-area inset), the menu-bar thickness elsewhere.
    struct Geometry {
        var screen: NSScreen
        var notchWidth: CGFloat
        var height: CGFloat
        var real: Bool
    }

    static func geometry() -> Geometry? {
        let screens = NSScreen.screens
        if let s = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let left = s.auxiliaryTopLeftArea?.width ?? 0, right = s.auxiliaryTopRightArea?.width ?? 0
            let width = (left > 0 && right > 0) ? s.frame.width - left - right : 200
            return Geometry(screen: s, notchWidth: max(120, width), height: s.safeAreaInsets.top, real: true)
        }
        guard let s = NSScreen.main ?? screens.first else { return nil }
        return Geometry(screen: s, notchWidth: 190, height: max(24, NSStatusBar.system.thickness), real: false)
    }

    // Layout constants (points).
    private let sideDot: CGFloat = 40          // collapsed: extra width per side for the dot
    private let flare: CGFloat = 12            // concave top corners that blend into the menu bar
    private let expandedWidth: CGFloat = 620
    private let bottomRadius: CGFloat = 22

    init() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)   // above the menu bar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = false      // a click on the notch toggles listening
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = shape
        panel = p

        for v in [meter, transcriptField, chipRow, dot] { v.translatesAutoresizingMaskIntoConstraints = false; shape.addSubview(v) }
        statusField.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        // A soft glow so the collapsed indicator reads on the black band.
        dot.layer?.shadowOpacity = 0.85
        dot.layer?.shadowRadius = 4
        dot.layer?.shadowOffset = .zero
        transcriptField.lineBreakMode = .byTruncatingHead
        transcriptField.maximumNumberOfLines = 2
        transcriptField.textColor = .white
        transcriptField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusField.textColor = NSColor.white.withAlphaComponent(0.55)
        // Evidence can be long (a URL): ellipsize in the middle and let it give way to the chips
        // rather than run past the panel's edge (seen 2026-09-22 on a Wikipedia search).
        statusField.lineBreakMode = .byTruncatingMiddle
        statusField.maximumNumberOfLines = 1
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        statusField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chipRow.orientation = .horizontal
        chipRow.spacing = 6
        chipRow.alignment = .centerY
        chipRow.addArrangedSubview(statusField)
        layoutSubviews()
        applyFrame(animated: false)
        // Hover: the panel is click-through, so poll the pointer. Resting on the notch for 150 ms
        // opens it (showing the last transcript and chips, or a hint); leaving it lets it fold.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollHover() }
        }
    }

    private func pollHover() {
        let p = NSEvent.mouseLocation
        let inside = panel.frame.insetBy(dx: -6, dy: -6).contains(p)
        if inside {
            if hoverSince == nil { hoverSince = Mono.now() }
            if !hovering, let since = hoverSince, Mono.now() - since >= 0.15 { hovering = true; hoverText = hoverHint?(); render(lastModel) }
        } else if hovering || hoverSince != nil {
            hovering = false; hoverSince = nil; render(lastModel)
        }
    }

    var isVisible: Bool { panel.isVisible }
    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    var debugPanel: NSPanel { panel }
    /// Called on a click anywhere on the notch shape.
    var onClick: (() -> Void)? {
        get { shape.onClick }
        set { shape.onClick = newValue }
    }

    private var geo: Geometry? { Self.geometry() }

    private func layoutSubviews() {
        guard let g = geo else { return }
        let top = g.height + 10   // content starts below the cutout band
        NSLayoutConstraint.activate([
            // Collapsed indicator: beside the cutout, in the menu-bar band.
            dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            dot.trailingAnchor.constraint(equalTo: shape.trailingAnchor, constant: -(flare + 15)),
            dot.topAnchor.constraint(equalTo: shape.topAnchor, constant: (g.height - 10) / 2),
            // Expanded content.
            meter.leadingAnchor.constraint(equalTo: shape.leadingAnchor, constant: flare + 18),
            meter.topAnchor.constraint(equalTo: shape.topAnchor, constant: top + 4),
            meter.widthAnchor.constraint(equalToConstant: 26), meter.heightAnchor.constraint(equalToConstant: 20),
            transcriptField.leadingAnchor.constraint(equalTo: meter.trailingAnchor, constant: 12),
            transcriptField.trailingAnchor.constraint(equalTo: shape.trailingAnchor, constant: -(flare + 18)),
            transcriptField.topAnchor.constraint(equalTo: shape.topAnchor, constant: top),
            chipRow.leadingAnchor.constraint(equalTo: transcriptField.leadingAnchor),
            chipRow.trailingAnchor.constraint(lessThanOrEqualTo: transcriptField.trailingAnchor),
            chipRow.topAnchor.constraint(equalTo: transcriptField.bottomAnchor, constant: 8),
            chipRow.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func render(_ m: OverlayModel) {
        lastModel = m
        renders += 1
        let sig = "\(m.rawText)|\(m.chips.count)|\(expanded)|\(panel.isVisible)|\(m.pending ?? "")|\(m.badgeCount)|\(m.armed ?? "")|\(m.offline ?? "")|\(m.help?.count ?? 0)|\(m.engaged)"
        if sig != lastSig {
            lastSig = sig
            trace?("render", ["n": .number(Double(renders)), "text": .string(String(m.rawText.suffix(40))), "chips": .number(Double(m.chips.count)),
                              "active": .bool(m.active), "expanded": .bool(expanded), "visible": .bool(panel.isVisible), "hover": .bool(hovering),
                              "frame": .string("\(Int(panel.frame.minX)),\(Int(panel.frame.minY)) \(Int(panel.frame.width))x\(Int(panel.frame.height))"),
                              "screen": .string(geo.map { "\(Int($0.screen.frame.width))x\(Int($0.screen.frame.height)) notch=\($0.real)" } ?? "none"),
                              "thread": .bool(Thread.isMainThread)])
        }
        transcriptField.attributedStringValue = OverlayText.transcript(m, size: 16, bright: .white, dim: NSColor.white.withAlphaComponent(0.4))
        // Status line, most urgent last: a notice or the evidence, the outage, then what needs an answer.
        var status = m.notice ?? m.statusLine
        var needsUser = false
        if let why = m.offline { status = "can't reach Jev · \(why)"; needsUser = true }
        if let pending = m.pending { status = "confirm? \(pending)  ·  say \"confirm\" or \"cancel\""; needsUser = true }
        if m.badgeCount > 0 { status = "which one? say a number, 1 to \(m.badgeCount)"; needsUser = true }
        if let help = m.help, m.rawText.isEmpty {
            transcriptField.attributedStringValue = OverlayText.help(help, size: 15, bright: .white, dim: NSColor.white.withAlphaComponent(0.45))
            status = m.holdToTalk ? "hold \(m.hotKey) and speak  ·  \"stop\" cancels" : "\"stop\" cancels  ·  \(m.hotKey) pauses"
        }
        if m.dryRun { status = "[dry run] " + status }
        statusField.stringValue = OverlayText.compactEvidence(status.replacingOccurrences(of: " -> ", with: " → "))
        statusField.textColor = needsUser ? .systemOrange : NSColor.white.withAlphaComponent(0.55)
        statusField.isHidden = status.isEmpty
        dot.layer?.backgroundColor = OverlayText.dotColor(m).cgColor
        dot.layer?.shadowColor = OverlayText.dotColor(m).cgColor
        meter.level = m.listening ? m.level : 0
        meter.tint = m.listening ? .systemGreen : (m.paused ? .systemYellow : NSColor.white.withAlphaComponent(0.5))
        rebuildChips(m.chips, armed: m.armed)

        if m.rawText.isEmpty, m.chips.isEmpty, m.help == nil, m.armed == nil, hovering {
            // Hover with nothing to show: a hint instead of "Listening…".
            let hint: String
            if m.paused { hint = "Paused  ·  \(m.hotKey) to listen" }
            else if m.holdToTalk, !m.listening { hint = "Hold \(m.hotKey) and speak  ·  click for examples" }
            else if let s = hoverText { hint = "Try “\(s)”  ·  or ask “what can I say?”" }
            else { hint = "Say a command, e.g. \"open notes\"" }
            transcriptField.attributedStringValue = OverlayText.transcript({ var h = m; h.rawText = hint; h.consumed = ""; return h }(),
                                                                         size: 16, bright: NSColor.white.withAlphaComponent(0.6), dim: NSColor.white.withAlphaComponent(0.4))
        }
        let wantExpanded = (m.active && !m.paused) || hovering
        if wantExpanded != expanded {
            collapseTask?.cancel(); collapseTask = nil
            if wantExpanded { setExpanded(true) }
            else if m.paused { setExpanded(false) }   // paused: fold at once, no linger
            else {
                // Linger so the last chip state is readable, then fold back into the notch.
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(1800))
                    guard !Task.isCancelled, let self, !self.lastModel.active, !self.hovering else { return }
                    self.setExpanded(false)
                }
            }
        }
        let contentVisible = expanded
        for v in [meter, transcriptField, chipRow] { v.isHidden = !contentVisible }
        dot.isHidden = contentVisible
        if expanded { applyFrame(animated: true) }   // height follows one or two transcript lines
    }

    private func setExpanded(_ on: Bool) {
        expanded = on
        applyFrame(animated: true)
        for v in [meter, transcriptField, chipRow] { v.isHidden = !on }
        dot.isHidden = on
    }

    /// Height of the transcript at the expanded width: one line, or two for long commands.
    private func transcriptHeight(width: CGFloat) -> CGFloat {
        let available = width - 2 * flare - 18 - 26 - 12 - 18
        let rect = transcriptField.attributedStringValue.boundingRect(with: NSSize(width: available, height: 200), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineHeight: CGFloat = 20
        return rect.height > lineHeight * 1.4 ? lineHeight * 2 + 2 : lineHeight
    }

    private func applyFrame(animated: Bool) {
        guard let g = geo else { return }
        let width = expanded ? max(expandedWidth, g.notchWidth + 2 * flare + 200) : g.notchWidth + 2 * flare + 2 * sideDot
        let height = expanded ? g.height + 10 + transcriptHeight(width: width) + 8 + 20 + 14 : g.height
        let x = g.screen.frame.midX - width / 2
        let y = g.screen.frame.maxY - height
        let frame = NSRect(x: x, y: y, width: width, height: height)
        guard frame != panel.frame || !animated else { return }
        shape.notchWidth = g.notchWidth
        shape.bandHeight = g.height
        shape.flare = flare
        shape.bottomRadius = expanded ? bottomRadius : min(bottomRadius, g.height / 2 + 4)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func rebuildChips(_ chips: [OverlayModel.Chip], armed: String?) {
        for v in chipRow.arrangedSubviews where v !== statusField { chipRow.removeArrangedSubview(v); v.removeFromSuperview() }
        defer {
            // After the chips: the action that runs when the words stop, dashed so it reads as
            // not yet done (item 1b).
            if let armed { chipRow.insertArrangedSubview(GhostChipView(text: "⋯ \(armed)"), at: chips.count) }
        }
        for (i, c) in chips.enumerated() {
            let (mark, color): (String, NSColor) = {
                switch c.state {
                case .running: return ("▶", NSColor.systemBlue)
                case .verified: return ("✓", NSColor.systemGreen)
                case .unknown: return ("?", NSColor.systemGray)
                case .failed: return ("✗", NSColor.systemRed)
                }
            }()
            let label = NSTextField(labelWithString: "\(mark) \(c.label)")
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            let chip = NSView()
            chip.wantsLayer = true
            chip.layer?.backgroundColor = color.withAlphaComponent(0.28).cgColor
            chip.layer?.borderColor = color.withAlphaComponent(0.7).cgColor
            chip.layer?.borderWidth = 1
            chip.layer?.cornerRadius = 10
            chip.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                chip.heightAnchor.constraint(equalToConstant: 20),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            ])
            chipRow.insertArrangedSubview(chip, at: i)
        }
    }
}

/// The black notch continuation: straight top edge (against the screen edge), concave "flare"
/// corners at the top that blend into the menu bar, rounded bottom corners.
final class NotchShapeView: NSView {
    var notchWidth: CGFloat = 200 { didSet { needsLayout = true } }
    var bandHeight: CGFloat = 32 { didSet { needsLayout = true } }
    var flare: CGFloat = 12 { didSet { needsLayout = true } }
    var bottomRadius: CGFloat = 22 { didSet { needsLayout = true } }
    private let fill = CAShapeLayer()
    private let edge = CAShapeLayer()
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        fill.fillColor = NSColor.black.cgColor
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        edge.lineWidth = 1
        layer?.addSublayer(fill)
        layer?.addSublayer(edge)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }   // y down: 0 is the screen's top edge

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let r = min(bottomRadius, h / 2)
        let f = min(flare, w / 4)
        let path = CGMutablePath()
        // Top edge, full width (the flares eat into the outer corners).
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))
        // Right flare: concave quarter curve from the top edge down onto the body's right side.
        path.addQuadCurve(to: CGPoint(x: w - f, y: f), control: CGPoint(x: w - f, y: 0))
        path.addLine(to: CGPoint(x: w - f, y: h - r))
        path.addArc(tangent1End: CGPoint(x: w - f, y: h), tangent2End: CGPoint(x: w - f - r, y: h), radius: r)
        path.addLine(to: CGPoint(x: f + r, y: h))
        path.addArc(tangent1End: CGPoint(x: f, y: h), tangent2End: CGPoint(x: f, y: h - r), radius: r)
        path.addLine(to: CGPoint(x: f, y: f))
        path.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: f, y: 0))
        path.closeSubpath()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.path = path
        // Hairline on the visible outline only (not the top edge, which meets the bezel).
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: w, y: 0))
        outline.addQuadCurve(to: CGPoint(x: w - f, y: f), control: CGPoint(x: w - f, y: 0))
        outline.addLine(to: CGPoint(x: w - f, y: h - r))
        outline.addArc(tangent1End: CGPoint(x: w - f, y: h), tangent2End: CGPoint(x: w - f - r, y: h), radius: r)
        outline.addLine(to: CGPoint(x: f + r, y: h))
        outline.addArc(tangent1End: CGPoint(x: f, y: h), tangent2End: CGPoint(x: f, y: h - r), radius: r)
        outline.addLine(to: CGPoint(x: f, y: f))
        outline.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: f, y: 0))
        edge.path = outline
        CATransaction.commit()
    }
}

/// Four bars that follow the microphone level.
final class LevelMeterView: NSView {
    var level: Float = 0 { didSet { needsLayout = true } }
    var tint: NSColor = .systemGreen { didSet { needsLayout = true } }
    private var bars: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let b = CALayer(); b.cornerRadius = 1.5; layer?.addSublayer(b); bars.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let gap: CGFloat = 3
        let bw = (w - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
        // Map RMS (~0.005 quiet, ~0.1 loud) to 0...1 on a log-ish curve; stagger the bars.
        let norm = CGFloat(min(1, max(0, (log10(Double(max(level, 0.0005))) + 3.3) / 2.3)))
        let weights: [CGFloat] = [0.55, 1.0, 0.8, 0.4]
        CATransaction.begin(); CATransaction.setAnimationDuration(0.08)
        for (i, b) in bars.enumerated() {
            let bh = max(3, h * min(1, norm * weights[i] + 0.12))
            b.frame = CGRect(x: CGFloat(i) * (bw + gap), y: (h - bh) / 2, width: bw, height: bh)
            b.backgroundColor = tint.withAlphaComponent(0.35 + 0.65 * norm).cgColor
        }
        CATransaction.commit()
    }
}

/// A chip for the action a clause will run once the words stop: the same shape as the action
/// chips, drawn with a dashed outline and softer text so it reads as pending, not done.
final class GhostChipView: NSView {
    private let border = CAShapeLayer()
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.cornerRadius = 10
        border.fillColor = nil
        border.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        border.lineWidth = 1
        border.lineDashPattern = [3, 3]
        layer?.addSublayer(border)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.8)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil)
        CATransaction.commit()
    }
}
