import AppKit

/// A floating capsule that shows dictation is actually happening.
///
/// Without this the only feedback is a menu bar icon swap, which is far too
/// subtle to tell you whether the app is listening, whether it can hear you,
/// or whether anything landed on the clipboard.
///
/// The panel must never take focus: the user is dictating into another app,
/// and stealing key focus would both break "paste directly" and interrupt
/// whatever they were typing into. Hence `.nonactivatingPanel`,
/// `ignoresMouseEvents`, and `orderFrontRegardless()`.
final class DictationHUD {

    enum Mode {
        case listening
        case transcribing
        case copied(String)
        case failed(String)
    }

    static let shared = DictationHUD()

    // MARK: - Metrics

    private enum Metrics {
        static let height: CGFloat = 38
        static let horizontalInset: CGFloat = 14
        static let spacing: CGFloat = 9
        static let iconSize: CGFloat = 15
        static let meterWidth: CGFloat = 22
        static let maxTextWidth: CGFloat = 460
        /// Gap above the bottom of the *visible* frame, so this already sits
        /// clear of the Dock. Kept small so the pill hugs the bottom edge and
        /// stays out of the way of whatever you are dictating into.
        static let bottomMargin: CGFloat = 24
        /// Distance the panel travels while fading in. Small — this is a
        /// hint of origin, not a journey.
        static let slideDistance: CGFloat = 6
    }

    /// Motion constants.
    ///
    /// Dictation is triggered from the keyboard (Fn Fn), and keyboard-initiated
    /// actions must feel instantaneous — the user may start speaking the moment
    /// they tap. So the entrance is short and uses a strong ease-out, which puts
    /// most of the movement in the first few frames. The exit is shorter still:
    /// the user has already got what they came for.
    private enum Motion {
        /// Strong ease-out. AppKit's built-in `.easeOut` is far too weak to
        /// read as intentional.
        static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        /// Strong ease-in-out, for morphing between states on screen.
        static let easeInOut = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)

        static let enter: TimeInterval = 0.15
        static let exit: TimeInterval = 0.12
        /// Resizing between states is the system responding, not the user
        /// waiting — it can be marginally slower to stay smooth.
        static let morph: TimeInterval = 0.20
    }

    private var panel: NSPanel?
    private var backdrop: NSVisualEffectView?
    private var iconView: NSImageView?
    private var label: NSTextField?
    private var meter: LevelMeterView?
    private var meterWidthConstraint: NSLayoutConstraint?
    private var hideTimer: Timer?
    private var isPresented = false
    /// Bumped on every present/dismiss so a stale animation completion cannot
    /// hide a panel that has since been shown again.
    private var generation: UInt64 = 0

    private init() {}

    // MARK: - Public API

    func show(_ mode: Mode) {
        DispatchQueue.main.async { [weak self] in
            self?.render(mode)
        }
    }

    /// Feed the live input level (0...1) so the user can see it hearing them.
    func updateLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.meter?.submit(level)
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    // MARK: - Rendering

    private func render(_ mode: Mode) {
        let panel = ensurePanel()

        hideTimer?.invalidate()
        hideTimer = nil

        let showMeter: Bool
        switch mode {
        case .listening:
            iconView?.image = symbol("mic.fill", tint: .systemRed)
            setText("Listening", detail: "Fn Fn to stop")
            showMeter = true
            meter?.isRunning = true

        case .transcribing:
            iconView?.image = symbol("waveform", tint: .secondaryLabelColor)
            setText("Transcribing", detail: nil)
            showMeter = false
            meter?.isRunning = false

        case .copied(let text):
            iconView?.image = symbol("checkmark.circle.fill", tint: .systemGreen)
            setText("Copied", detail: preview(text))
            showMeter = false
            meter?.isRunning = false
            scheduleHide(after: 2.5)

        case .failed(let message):
            iconView?.image = symbol("exclamationmark.triangle.fill", tint: .systemOrange)
            setText(message, detail: nil)
            showMeter = false
            meter?.isRunning = false
            scheduleHide(after: 4.0)
        }

        meter?.isHidden = !showMeter
        meterWidthConstraint?.constant = showMeter ? Metrics.meterWidth : 0

        present(panel)
    }

    /// Primary text plus an optional dimmed trailing detail, so "Copied" reads
    /// as a status and the transcript reads as content.
    private func setText(_ primary: String, detail: String?) {
        guard let label = label else { return }

        let string = NSMutableAttributedString(
            string: primary,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )

        if let detail = detail, !detail.isEmpty {
            string.append(NSAttributedString(
                string: "  \(detail)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        }

        label.attributedStringValue = string
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    private func preview(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= 64 ? flat : String(flat.prefix(64)) + "…"
    }

    /// Multicolour SF Symbols via the real symbol API rather than compositing
    /// a tint over a template image.
    private func symbol(_ name: String, tint: NSColor) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: name) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.iconSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        return image.withSymbolConfiguration(config) ?? image
    }

    // MARK: - Presentation

    private func present(_ panel: NSPanel) {
        // Invalidate any in-flight dismissal so its completion handler cannot
        // tear down a panel we are about to show again.
        generation &+= 1

        let width = panelWidth()
        let target = targetOrigin(for: width)
        let size = NSSize(width: width, height: Metrics.height)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Treat a panel that is mid-fade as still on screen. Re-triggering
        // dictation while the previous result fades out must pick up from the
        // current opacity — resetting to 0 first would flash.
        let alreadyVisible = panel.isVisible && panel.alphaValue > 0.01

        isPresented = true

        if alreadyVisible {
            // Morph in place. Replaying the entrance on every state change
            // would draw attention to the chrome rather than the content.
            let frame = NSRect(origin: target, size: size)
            guard !reduceMotion else {
                panel.setFrame(frame, display: true)
                panel.alphaValue = 1
                panel.invalidateShadow()
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.morph
                context.timingFunction = Motion.easeInOut
                context.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: {
                // The window shadow is cached and would otherwise keep the
                // outline of the previous, differently sized capsule.
                panel.invalidateShadow()
            })
            return
        }

        // Reduced motion keeps the fade but drops the movement — gentler,
        // not absent.
        if reduceMotion {
            panel.setFrame(NSRect(origin: target, size: size), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.enter
                panel.animator().alphaValue = 1
            }
            panel.invalidateShadow()
            return
        }

        // Rise into place while fading in. The panel lives near the bottom of
        // the screen, so entering from just below reads as coming from where
        // it belongs.
        panel.setFrame(
            NSRect(origin: NSPoint(x: target.x, y: target.y - Metrics.slideDistance), size: size),
            display: false
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.enter
            context.timingFunction = Motion.easeOut
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(origin: target, size: size), display: true)
        }, completionHandler: {
            panel.invalidateShadow()
        })
    }

    private func dismiss(animated: Bool) {
        hideTimer?.invalidate()
        hideTimer = nil
        meter?.isRunning = false

        guard let panel = panel, isPresented else { return }
        isPresented = false

        generation &+= 1
        let token = generation

        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        var frame = panel.frame
        frame.origin.y -= Metrics.slideDistance * 0.75

        // ease-out on the way out too. ease-in would hold the panel at full
        // opacity for the first half of the exit, which reads as sluggish.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.exit
            context.timingFunction = Motion.easeOut
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            // Bail out if dictation restarted while we were fading.
            guard let self = self, self.generation == token, !self.isPresented else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    // MARK: - Geometry

    /// Width is driven by content: insets + icon + meter + measured text.
    private func panelWidth() -> CGFloat {
        guard let label = label else { return 220 }

        let textWidth = min(ceil(label.attributedStringValue.size().width) + 2, Metrics.maxTextWidth)
        let meterPart = (meter?.isHidden == false) ? Metrics.meterWidth + Metrics.spacing : 0

        return Metrics.horizontalInset * 2
            + Metrics.iconSize
            + Metrics.spacing
            + meterPart
            + textWidth
    }

    /// Bottom-centre of whichever screen has the pointer, so on a
    /// multi-monitor setup it appears where the user is actually working.
    private func targetOrigin(for width: CGFloat) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }

        return NSPoint(
            x: (visible.midX - width / 2).rounded(),
            y: visible.minY + Metrics.bottomMargin
        )
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel = panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.animationBehavior = .none
        // Visible on every Space and over full-screen apps, and never
        // captured in screen recordings (consistent with the rest of Popy).
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.isEmphasized = true
        backdrop.wantsLayer = true
        // A true capsule reads as a floating status pill rather than a window.
        //
        // `maskImage` is the only thing that actually clips a behind-window
        // blur. Setting layer.cornerRadius/masksToBounds does NOT — the blur
        // is composited by the window server behind the view, outside the
        // layer tree, so a rounded layer just paints rounded corners on top
        // of a still-rectangular blur, leaving visible square edges.
        backdrop.maskImage = Self.capsuleMask(cornerRadius: Metrics.height / 2)

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let meter = LevelMeterView()
        meter.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, meter, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Metrics.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)

        let meterWidth = meter.widthAnchor.constraint(equalToConstant: Metrics.meterWidth)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: Metrics.horizontalInset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: backdrop.trailingAnchor, constant: -Metrics.horizontalInset),
            stack.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            meterWidth,
            meter.heightAnchor.constraint(equalToConstant: 14)
        ])

        panel.contentView = backdrop

        self.panel = panel
        self.backdrop = backdrop
        self.iconView = icon
        self.label = label
        self.meter = meter
        self.meterWidthConstraint = meterWidth
        return panel
    }

    /// A resizable rounded-rect mask for `NSVisualEffectView.maskImage`.
    ///
    /// Built at the minimum size that contains both corners and marked with
    /// cap insets, so AppKit stretches only the flat middle when the pill
    /// grows — the corners stay perfectly circular at any width.
    private static func capsuleMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Level meter

/// Audio-level bars with proper meter ballistics.
///
/// Raw per-buffer RMS jitters badly, so levels are smoothed with a fast attack
/// and slow release, and the bars are redrawn on a display-rate timer. That
/// keeps them decaying smoothly even when buffers arrive irregularly.
private final class LevelMeterView: NSView {

    private let barCount = 4
    private let barWidth: CGFloat = 2.5
    private let gap: CGFloat = 3.5

    /// Where each bar currently is, and where it is heading.
    private var current: [CGFloat]
    private var targets: [CGFloat]

    private var incoming: Float = 0
    private var smoothed: Float = 0
    private var timer: Timer?

    var isRunning: Bool = false {
        didSet {
            guard isRunning != oldValue else { return }
            isRunning ? startTicking() : stopTicking()
        }
    }

    override init(frame frameRect: NSRect) {
        current = Array(repeating: 0, count: barCount)
        targets = Array(repeating: 0, count: barCount)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        current = Array(repeating: 0, count: barCount)
        targets = Array(repeating: 0, count: barCount)
        super.init(coder: coder)
        wantsLayer = true
    }

    deinit { timer?.invalidate() }

    /// Accept a raw level from the audio thread's main-queue hop.
    func submit(_ level: Float) {
        incoming = max(0, min(1, level))
    }

    /// 60 Hz. The meter is the one continuously moving element on screen, and
    /// at 30 Hz the bars visibly step rather than glide.
    private static let frameInterval: TimeInterval = 1.0 / 60.0

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the meter keeps moving while a menu is open.
        if let timer = timer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
        smoothed = 0
        incoming = 0
        current = Array(repeating: 0, count: barCount)
        targets = Array(repeating: 0, count: barCount)
        needsDisplay = true
    }

    /// Meter ballistics as time constants rather than per-frame factors, so
    /// the feel does not change if the tick rate does.
    /// Fast attack: speech onset should register immediately.
    /// Slow release: a slow decay reads as natural falloff; a fast one flickers.
    private static let attackTau: Float = 0.025
    private static let releaseTau: Float = 0.180
    private static let barTau: Float = 0.035

    private func tick() {
        let dt = Float(Self.frameInterval)
        let tau = incoming > smoothed ? Self.attackTau : Self.releaseTau
        smoothed += (incoming - smoothed) * (1 - exp(-dt / tau))

        // Slight per-bar weighting reads as a waveform rather than one block
        // moving up and down.
        let weights: [CGFloat] = [0.62, 1.0, 0.84, 0.55]
        let barCoefficient = CGFloat(1 - exp(-dt / Self.barTau))
        for i in 0..<barCount {
            targets[i] = CGFloat(smoothed) * weights[i]
            current[i] += (targets[i] - current[i]) * barCoefficient
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isRunning else { return }

        let maxHeight = bounds.height
        let minHeight: CGFloat = 2.5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX = (bounds.width - totalWidth) / 2

        NSColor.systemRed.setFill()

        for i in 0..<barCount {
            let h = max(minHeight, maxHeight * min(current[i], 1))
            let rect = NSRect(
                x: startX + CGFloat(i) * (barWidth + gap),
                y: (maxHeight - h) / 2,
                width: barWidth,
                height: h
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
