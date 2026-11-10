import AppKit
import CountdownCore

private final class SuggestionsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A nonactivating child window keeps Japanese composition and keyboard focus in the input field.
final class AutomationSuggestions: NSObject {
    private let panel = SuggestionsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
    private let stack = NSStackView()
    private(set) var names: [String] = []
    private var selected = 0
    var choose: ((String) -> Void)?
    var isVisible: Bool { panel.isVisible }
    var selectedName: String? { names.indices.contains(selected) ? names[selected] : nil }

    override init() {
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        panel.contentView = background
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4)
        ])
    }

    func show(_ definitions: [AutomationDefinition], for field: NSTextField) {
        let next = Array(definitions.prefix(6).map(\.name))
        guard !next.isEmpty, let parent = field.window else { hide(); return }
        if names != next {
            names = next
            selected = 0
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            for (index, name) in names.enumerated() {
                let button = NSButton(title: name, target: self, action: #selector(clicked(_:)))
                button.tag = index
                button.alignment = .left
                button.bezelStyle = .recessed
                button.setButtonType(.pushOnPushOff)
                button.lineBreakMode = .byTruncatingTail
                button.toolTip = name
                stack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            }
        }
        highlight()
        let fieldRect = parent.convertToScreen(field.convert(field.bounds, to: nil))
        let width = max(180, fieldRect.width)
        let height = CGFloat(names.count * 26 + 8)
        let bounds = parent.screen?.visibleFrame ?? fieldRect
        let y = fieldRect.minY - height - 3 >= bounds.minY ? fieldRect.minY - height - 3 : fieldRect.maxY + 3
        panel.setFrame(NSRect(x: min(fieldRect.minX, bounds.maxX - width), y: y, width: width, height: height), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func move(_ delta: Int) {
        guard !names.isEmpty else { return }
        selected = (selected + delta + names.count) % names.count
        highlight()
    }

    private func highlight() {
        for (index, view) in stack.arrangedSubviews.enumerated() { (view as? NSButton)?.state = index == selected ? .on : .off }
    }

    @objc private func clicked(_ sender: NSButton) {
        selected = sender.tag
        if let selectedName { choose?(selectedName) }
    }

    func hide() {
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
    }
}
