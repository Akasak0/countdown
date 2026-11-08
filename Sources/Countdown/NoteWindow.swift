import AppKit
import CountdownCore

final class CountdownWindow: NSWindow {
    var compactMode = false
    private var dragStart: NSPoint?
    private var dragOrigin = NSPoint.zero

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func setCompactMode(_ compact: Bool) {
        compactMode = compact
        let savedFrame = frame
        // A hidden title bar still carries the system's titled-window movement
        // restrictions. Remove the title bar itself in the compact mode.
        styleMask = compact ? [.borderless, .closable, .miniaturizable, .resizable]
            : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = !compact
        isMovableByWindowBackground = !compact
        setFrame(savedFrame, display: true)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard compactMode else { return super.constrainFrameRect(frameRect, to: screen) }
        // Compact notes may occupy the unused space beside the Dock.
        guard let screen else { return frameRect }
        var result = frameRect
        result.origin.x = max(screen.frame.minX, min(result.minX, screen.frame.maxX - result.width))
        result.origin.y = max(screen.frame.minY, min(result.minY, screen.visibleFrame.maxY - result.height))
        return result
    }

    override func performClose(_ sender: Any?) {
        if compactMode { close() }
        else { super.performClose(sender) }
    }

    private func startNoteDrag(with event: NSEvent) {
        dragStart = convertPoint(toScreen: event.locationInWindow)
        dragOrigin = frame.origin
    }

    private func dragNote(with event: NSEvent) {
        guard let dragStart else { return }
        let mouse = convertPoint(toScreen: event.locationInWindow)
        let proposed = NSRect(x: dragOrigin.x + mouse.x - dragStart.x,
                              y: dragOrigin.y + mouse.y - dragStart.y, width: frame.width, height: frame.height)
        let target = NSScreen.screens.first { $0.frame.contains(mouse) } ?? screen
        setFrameOrigin(constrainFrameRect(proposed, to: target).origin)
    }

    override func sendEvent(_ event: NSEvent) {
        guard compactMode else { super.sendEvent(event); return }
        switch event.type {
        case .leftMouseDown where event.clickCount == 1:
            // Keep the outer edge available for the native resize interaction.
            let interior = NSRect(origin: .zero, size: frame.size).insetBy(dx: 6, dy: 6)
            if interior.contains(event.locationInWindow) {
                makeKeyAndOrderFront(nil)
                startNoteDrag(with: event)
            } else { super.sendEvent(event) }
        case .leftMouseDragged where dragStart != nil: dragNote(with: event)
        case .leftMouseUp where dragStart != nil: dragStart = nil
        default: super.sendEvent(event)
        }
    }
}

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
    var doubleClick: (() -> Void)?
    var rounded = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        if rounded { NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill() }
        else { bounds.fill() }
    }
    override func layout() { super.layout(); relayout?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { doubleClick?() }
        else { super.mouseDown(with: event) }
    }
}

final class CountdownLabel: NSTextField {
    var doubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { doubleClick?() }
        else { super.mouseDown(with: event) }
    }
}

final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let id: UUID
    unowned let app: AppController
    let surface = NoteView()
    let labelField = NSTextField()
    let inputField = NSTextField()
    let value = CountdownLabel(labelWithString: "")
    let hint = NSTextField(wrappingLabelWithString: "")
    let start = NSButton(title: "開始", target: nil, action: nil)
    let edit = NSButton(title: "変更", target: nil, action: nil)
    let details = NSButton(title: "詳細…", target: nil, action: nil)
    let look = NSButton(title: "外観…", target: nil, action: nil)
    let pause = NSButton(title: "一時停止", target: nil, action: nil)
    var editing = false
    private var error: String?
    private var compactMenuItem: NSMenuItem?

    init(note: TimerNote, app: AppController) {
        self.id = note.id
        self.app = app
        let window = CountdownWindow(contentRect: NSRect(x: 0, y: 0, width: 286, height: 196),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.setCompactMode(note.isCompact)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 1
        window.isMovableByWindowBackground = !note.isCompact
        window.contentMinSize = note.isCompact ? NSSize(width: 120, height: 60) : NSSize(width: 220, height: 164)
        window.contentMaxSize = NSSize(width: 900, height: 600)
        window.contentView = surface
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        surface.relayout = { [weak self] in self?.layoutContents() }
        surface.doubleClick = { [weak self] in self?.editTime() }
        value.doubleClick = { [weak self] in self?.editTime() }
        value.maximumNumberOfLines = 1
        value.lineBreakMode = .byClipping
        value.setAccessibilityHelp("ダブルクリックで時間を設定。右クリックで操作UIを表示できます。")
        makeContextMenu()
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
            if NSScreen.screens.contains(where: {
                let bounds = note.isCompact ? $0.frame : $0.visibleFrame
                return bounds.intersection(saved).width >= 80 && bounds.intersection(saved).height >= 60
            }) {
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
        let compact = note.isCompact
        surface.rounded = compact
        let inputMode = !compact && (editing || !running)
        let justFinished = inputField.isHidden && inputMode && note.isFinished(at: now)
        labelField.isHidden = compact
        hint.isHidden = compact
        details.isHidden = compact
        let menuTitle = compact ? "操作UIを表示" : "操作UIを隠す"
        if compactMenuItem?.title != menuTitle { compactMenuItem?.title = menuTitle }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = compact
        }
        inputField.isHidden = !inputMode
        start.isHidden = !inputMode
        value.isHidden = !compact && inputMode
        edit.isHidden = compact || !running || editing
        pause.isHidden = compact || !running || editing || (!app.state.preferences.pauseEnabled && note.pausedRemaining == nil)
            || note.specification?.canPause != true
        pause.title = note.pausedRemaining == nil ? "一時停止" : "再開"
        if let seconds = note.remaining(at: now) {
            value.stringValue = RemainingTime.text(seconds: seconds, showSeconds: app.state.preferences.showSeconds)
        }
        if compact {
            if note.isFinished(at: now) { value.stringValue = "終了しました" }
            else if note.remaining(at: now) == nil { value.stringValue = "時間を設定" }
            else if note.pausedRemaining != nil { value.stringValue += " ⏸" }
        }
        value.toolTip = [note.label, note.deadline.map { app.deadlineDescription($0) + " に終了" } ?? "",
            "ダブルクリックで時間を設定 · 右クリックで操作UIを表示"].filter { !$0.isEmpty }.joined(separator: "\n")
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
        if app.note(id)?.isCompact == true {
            look.isHidden = true
            let reference = NSFont.monospacedDigitSystemFont(ofSize: 36, weight: .medium)
            let measured = (value.stringValue as NSString).size(withAttributes: [.font: reference])
            let scale = min((w - 16) / max(1, measured.width), (h - 12) / max(1, measured.height))
            value.font = .monospacedDigitSystemFont(ofSize: min(82, max(12, floor(36 * scale))), weight: .medium)
            let height = (value.stringValue as NSString).size(withAttributes: [.font: value.font!]).height + 2
            value.frame = NSRect(x: 8, y: (h - height) / 2, width: w - 16, height: height)
            return
        }
        labelField.frame = NSRect(x: 16, y: 32, width: w - 32, height: 22)
        inputField.frame = NSRect(x: 16, y: 65, width: w - 86, height: 28)
        start.frame = NSRect(x: w - 66, y: 65, width: 52, height: 28)
        value.frame = NSRect(x: 12, y: 56, width: w - 24, height: max(32, h - 128))
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
        guard app.note(id)?.isCompact != true else { return }
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
        if app.note(id)?.isCompact == true { toggleControls() }
        editing = true
        error = nil
        inputField.stringValue = ""
        update(at: Date())
        focusInput()
    }

    @objc func showDetails() { app.showDatePicker(for: id) }
    @objc func showAppearance() { app.showAppearance(for: id) }
    @objc func togglePause() { app.togglePause(id) }

    @objc func editLabel() {
        if app.note(id)?.isCompact == true { toggleControls() }
        window?.makeFirstResponder(labelField)
        labelField.selectText(nil)
    }

    @objc func toggleControls() {
        guard let window, let note = app.note(id) else { return }
        window.makeFirstResponder(nil)
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        let compact = !note.isCompact
        if compact { saveFrame() }
        app.modify(id) {
            if compact { $0.expandedFrame = $0.frame }
            $0.controlsHidden = compact
        }
        (window as? CountdownWindow)?.setCompactMode(compact)
        window.contentMinSize = compact ? NSSize(width: 120, height: 60) : NSSize(width: 220, height: 164)
        update(at: Date())
        let size: NSSize
        if compact { size = NSSize(width: 176, height: 64) }
        else if let frame = note.expandedFrame {
            // Stored frame is an outer-window frame; convert back to content size.
            size = window.contentRect(forFrameRect: NSRect(x: 0, y: 0, width: frame.width, height: frame.height)).size
        } else { size = NSSize(width: 286, height: 196) }
        window.setContentSize(size)
        window.setFrameTopLeftPoint(topLeft)
        if let screen = window.screen {
            var frame = window.constrainFrameRect(window.frame, to: screen)
            if !compact {
                let bounds = screen.visibleFrame
                frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
                frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
            }
            window.setFrame(frame, display: true)
        }
        saveFrame()
        if !compact, note.deadline == nil || note.isFinished(at: Date()) { focusInput() }
    }

    private func makeContextMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        compactMenuItem = add("操作UIを隠す", #selector(contextToggle(_:)))
        menu.addItem(.separator())
        _ = add("時間を設定…", #selector(contextEdit(_:)))
        _ = add("ラベルを編集…", #selector(contextLabel(_:)))
        _ = add("外観…", #selector(contextAppearance(_:)))
        let close = NSMenuItem(title: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        close.target = window
        menu.addItem(.separator())
        menu.addItem(close)
        surface.menu = menu
        value.menu = menu
    }

    @objc private func contextToggle(_ sender: NSMenuItem) { toggleControls() }
    @objc private func contextEdit(_ sender: NSMenuItem) { editTime() }
    @objc private func contextLabel(_ sender: NSMenuItem) { editLabel() }
    @objc private func contextAppearance(_ sender: NSMenuItem) { showAppearance() }

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
