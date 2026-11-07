import AppKit
import CountdownCore

extension NoteColor {
    var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb: (CGFloat, CGFloat, CGFloat)
            switch self {
            case .yellow: rgb = (0.99, 0.91, 0.57)
            case .mint: rgb = (0.66, 0.89, 0.74)
            case .blue: rgb = (0.66, 0.83, 0.98)
            case .pink: rgb = (0.98, 0.74, 0.79)
            case .purple: rgb = (0.82, 0.74, 0.98)
            case .neutral: rgb = (0.91, 0.91, 0.91)
            }
            let color = NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            return dark ? color.blended(withFraction: 0.72, of: .black)! : color
        }
    }
}

final class NoteView: NSView {
    var background: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var relayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
    }
    override func layout() { super.layout(); relayout?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let id: UUID
    unowned let app: AppController
    let surface = NoteView()
    let labelField = NSTextField()
    let inputField = NSTextField()
    let value = NSTextField(labelWithString: "")
    let hint = NSTextField(wrappingLabelWithString: "")
    let start = NSButton(title: "開始", target: nil, action: nil)
    let edit = NSButton(title: "変更", target: nil, action: nil)
    let details = NSButton(title: "詳細…", target: nil, action: nil)
    let look = NSButton(title: "外観…", target: nil, action: nil)
    let pause = NSButton(title: "一時停止", target: nil, action: nil)
    var editing = false
    private var error: String?

    init(note: TimerNote, app: AppController) {
        self.id = note.id
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 286, height: 196),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 1
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 232, height: 176)
        window.contentMaxSize = NSSize(width: 900, height: 600)
        window.contentView = surface
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        surface.relayout = { [weak self] in self?.layoutContents() }
        labelField.isBordered = false
        labelField.drawsBackground = false
        labelField.placeholderString = "ラベル（任意）"
        labelField.font = .systemFont(ofSize: 13, weight: .medium)
        labelField.delegate = self
        labelField.stringValue = note.label
        labelField.setAccessibilityLabel("タイマーのラベル")
        inputField.placeholderString = "17:45 または 3m"
        inputField.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        inputField.bezelStyle = .roundedBezel
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(beginTimer)
        inputField.setAccessibilityLabel("時刻または時間の長さ")
        value.alignment = .center
        value.setAccessibilityLabel("残り時間")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        for (button, action) in [(start, #selector(beginTimer)), (edit, #selector(editTime)),
            (details, #selector(showDetails)), (look, #selector(showAppearance)), (pause, #selector(togglePause))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = action
        }
        for view in [labelField, inputField, value, hint, start, edit, details, look, pause] { surface.addSubview(view) }
        if let frame = note.frame {
            let saved = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(saved).width >= 80 && $0.visibleFrame.intersection(saved).height >= 60 }) {
                window.setFrame(saved, display: false)
            } else { positionNewWindow() }
        } else { positionNewWindow() }
        applyAppearance(note.appearance)
        update(at: Date())
        if let editor = window.fieldEditor(true, for: inputField) as? NSTextView { editor.allowsUndo = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func positionNewWindow() {
        guard let screen = NSScreen.main, let window else { return }
        let step = CGFloat(app.controllers.count % 8) * 28
        let bounds = screen.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: bounds.maxX - window.frame.width - 24 - step, y: bounds.maxY - 24 - step))
    }

    func applyAppearance(_ appearance: Appearance) {
        window?.level = appearance.floating ? .floating : .normal
        surface.background = appearance.color.nsColor.withAlphaComponent(appearance.opacity)
        window?.invalidateShadow()
    }

    func update(at now: Date) {
        guard let note = app.note(id) else { return }
        window?.title = note.label.isEmpty ? "タイマー" : note.label
        let running = note.deadline != nil && !note.isFinished(at: now) || note.pausedRemaining != nil
        let inputMode = editing || !running
        let justFinished = inputField.isHidden && inputMode && note.isFinished(at: now)
        inputField.isHidden = !inputMode
        start.isHidden = !inputMode
        value.isHidden = inputMode
        edit.isHidden = !running || editing
        pause.isHidden = !running || editing || (!app.state.preferences.pauseEnabled && note.pausedRemaining == nil)
            || note.specification?.canPause != true
        pause.title = note.pausedRemaining == nil ? "一時停止" : "再開"
        if let seconds = note.remaining(at: now) {
            value.stringValue = RemainingTime.text(seconds: seconds, showSeconds: app.state.preferences.showSeconds)
        }
        if inputMode { updatePreview(at: now) }
        else if note.pausedRemaining != nil { hint.stringValue = "一時停止中 · 再開するまで時間は進みません" }
        else if let deadline = note.deadline { hint.stringValue = app.deadlineDescription(deadline) + " に終了" }
        hint.textColor = error == nil ? .secondaryLabelColor : .systemRed
        layoutContents()
        if justFinished, NSApp.isActive, window?.isKeyWindow == true,
           !(window?.firstResponder is NSTextView) { focusInput() }
    }

    private func updatePreview(at now: Date) {
        if let error { hint.stringValue = error; return }
        let finished = app.note(id)?.isFinished(at: now) == true && !editing
        let prefix = finished ? "終了しました\n" : ""
        let raw = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if raw.isEmpty {
                if let previous = app.state.previous, let input = previous.input, let spec = previous.specification {
                    let deadline = try spec.deadline(from: now)
                    hint.stringValue = prefix + "Enterで \(input) · \(app.deadlineDescription(deadline)) に終了"
                } else { hint.stringValue = prefix + "時刻は 17:45、長さは 3m · Enterで開始" }
            } else {
                let spec = try TimeSpecification.parse(raw)
                let deadline = try spec.deadline(from: now)
                hint.stringValue = prefix + app.deadlineDescription(deadline) + " に終了 · あと "
                    + RemainingTime.text(seconds: deadline.timeIntervalSince(now), showSeconds: true)
            }
        } catch { hint.stringValue = prefix + (error.localizedDescription) }
    }

    private func layoutContents() {
        let w = surface.bounds.width, h = surface.bounds.height
        guard w > 0 else { return }
        labelField.frame = NSRect(x: 16, y: 32, width: w - 32, height: 22)
        inputField.frame = NSRect(x: 16, y: 65, width: w - 86, height: 28)
        start.frame = NSRect(x: w - 66, y: 65, width: 52, height: 28)
        value.frame = NSRect(x: 12, y: 58, width: w - 24, height: max(40, h - 128))
        let count = CGFloat(max(5, value.stringValue.count))
        value.font = .monospacedDigitSystemFont(ofSize: max(22, min(82, min((w - 28) / (count * 0.65), (h - 110) * 0.7))), weight: .medium)
        hint.frame = NSRect(x: 16, y: h - 70, width: w - 32, height: 28)
        details.frame = NSRect(x: 10, y: h - 34, width: 54, height: 24)
        edit.frame = NSRect(x: 65, y: h - 34, width: 48, height: 24)
        pause.frame = NSRect(x: 112, y: h - 34, width: 70, height: 24)
        look.frame = NSRect(x: w - 64, y: h - 34, width: 54, height: 24)
        // At compact widths, appearance stays available from the menu.
        look.isHidden = !pause.isHidden && w < 260
    }

    func focusInput() {
        window?.makeFirstResponder(inputField)
        inputField.selectText(nil)
    }

    @objc func beginTimer() {
        do {
            try app.start(id, raw: inputField.stringValue)
            inputField.stringValue = ""
            editing = false
            error = nil
            window?.makeFirstResponder(nil)
            update(at: Date())
        } catch {
            self.error = error.localizedDescription
            update(at: Date())
            focusInput()
        }
    }

    @objc func editTime() {
        editing = true
        error = nil
        inputField.stringValue = ""
        update(at: Date())
        focusInput()
    }

    @objc func showDetails() { app.showDatePicker(for: id) }
    @objc func showAppearance() { app.showAppearance(for: id) }
    @objc func togglePause() { app.togglePause(id) }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === labelField {
            app.modify(id) { $0.label = String(field.stringValue.prefix(100)) }
            window?.title = field.stringValue.isEmpty ? "タイマー" : field.stringValue
        } else { error = nil; updatePreview(at: Date()) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), control === inputField, editing {
            editing = false
            error = nil
            inputField.stringValue = ""
            window?.makeFirstResponder(nil)
            update(at: Date())
            return true
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { app.close(id) }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    func saveFrame() {
        guard let frame = window?.frame, app.note(id) != nil else { return }
        app.modify(id) { $0.frame = WindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height) }
    }

    func celebrate() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let layer = CALayer()
        layer.frame = surface.bounds
        surface.wantsLayer = true
        surface.layer?.addSublayer(layer)
        let palette: [NSColor] = [.systemPink, .systemYellow, .systemBlue, .systemGreen, .systemPurple]
        for i in 0..<36 {
            let piece = CALayer()
            piece.bounds = CGRect(x: 0, y: 0, width: 5, height: 9)
            piece.backgroundColor = palette[i % palette.count].cgColor
            let x = CGFloat.random(in: 0...surface.bounds.width)
            piece.position = CGPoint(x: x, y: 0)
            layer.addSublayer(piece)
            let animation = CABasicAnimation(keyPath: "position")
            animation.fromValue = NSValue(point: NSPoint(x: x, y: -10))
            animation.toValue = NSValue(point: NSPoint(x: x + CGFloat.random(in: -65...65), y: surface.bounds.height + 20))
            animation.duration = Double.random(in: 1.0...1.8)
            animation.isRemovedOnCompletion = false
            animation.fillMode = .forwards
            piece.add(animation, forKey: "fall")
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.toValue = Double.random(in: -8...8)
            rotation.duration = animation.duration
            piece.add(rotation, forKey: "turn")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { layer.removeFromSuperlayer() }
    }
}
