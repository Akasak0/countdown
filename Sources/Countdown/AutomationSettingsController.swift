import AppKit
import UniformTypeIdentifiers
import CountdownCore

private final class AutomationStepField: NSTextField {
    var activateRow: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        activateRow?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { activateRow?() }
        return accepted
    }
}

private final class AutomationStepModeButton: NSPopUpButton {
    var activateRow: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        activateRow?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { activateRow?() }
        return accepted
    }
}

final class AutomationSettingsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    unowned let app: AppController
    private var draft: AutomationLibrary
    private var baseline: Data?
    private var dirty = false
    private let list = NSTableView()
    private let steps = NSTableView()
    private let name = NSTextField()
    private let effects = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let editor = NSStackView()
    private var removeStepButton: NSButton?
    private var moveStepUpButton: NSButton?
    private var moveStepDownButton: NSButton?
    private var selected: Int? { draft.automations.indices.contains(list.selectedRow) ? list.selectedRow : nil }

    init(app: AppController) {
        self.app = app
        draft = app.automations
        baseline = app.automationData
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "オートメーション"
        window.contentMinSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        let introduction = NSTextField(wrappingLabelWithString: "名前をタイマーの入力欄に入れて開始します。時刻は今日、時間の長さは前の区間の終了から計算します。")
        introduction.font = .systemFont(ofSize: 12)
        introduction.textColor = .secondaryLabelColor
        root.addArrangedSubview(introduction)

        let body = NSStackView()
        body.alignment = .top
        body.spacing = 18
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 8
        setupTable(list, columns: [("name", "名前", 180)])
        list.headerView = nil
        list.setAccessibilityLabel("保存するオートメーション")
        let listScroll = scroll(list)
        listScroll.widthAnchor.constraint(equalToConstant: 190).isActive = true
        sidebar.addArrangedSubview(listScroll)
        let listActions = row([
            button("追加", #selector(addDefinition)), button("複製", #selector(duplicateDefinition)), button("削除", #selector(removeDefinition))
        ])
        sidebar.addArrangedSubview(listActions)
        body.addArrangedSubview(sidebar)

        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 12
        name.placeholderString = "例：月曜の講義"
        name.setAccessibilityLabel("オートメーション名")
        name.delegate = self
        let nameRow = row([NSTextField(labelWithString: "名前"), name])
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        editor.addArrangedSubview(nameRow)
        effects.addItems(withTitles: AutomationEffect.allCases.map(\.title))
        effects.target = self
        effects.action = #selector(effectChanged)
        effects.setAccessibilityLabel("区間の終了を知らせるタイミング")
        editor.addArrangedSubview(row([NSTextField(labelWithString: "終了の知らせ方"), effects]))
        setupTable(steps, columns: [("label", "ラベル", 150), ("time", "終了の指定", 305)])
        steps.rowHeight = 32
        steps.setAccessibilityLabel("実行する区間")
        let stepScroll = scroll(steps)
        editor.addArrangedSubview(stepScroll)
        stepScroll.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        let remove = button("区間を削除", #selector(removeStep))
        let up = button("↑", #selector(moveStepUp))
        let down = button("↓", #selector(moveStepDown))
        removeStepButton = remove
        moveStepUpButton = up
        moveStepDownButton = down
        remove.toolTip = "選択した区間を削除"
        editor.addArrangedSubview(row([button("区間を追加", #selector(addStep)), remove, up, down]))
        let note = NSTextField(wrappingLabelWithString: "音・通知・紙吹雪は一般設定に従います。実行中の内容は、ここで編集しても変わりません。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        editor.addArrangedSubview(note)
        body.addArrangedSubview(editor)
        root.addArrangedSubview(body)
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalTo: root.widthAnchor),
            sidebar.heightAnchor.constraint(equalTo: body.heightAnchor),
            editor.heightAnchor.constraint(equalTo: body.heightAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 290)
        ])
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 3
        root.addArrangedSubview(status)
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        root.addArrangedSubview(row([
            button("JSONを編集…", #selector(openJSON)), button("Finderで表示", #selector(revealJSON)),
            button("再読み込み", #selector(reload)), button("保存", #selector(save))
        ]))
        list.reloadData()
        if !draft.automations.isEmpty { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        loadEditor()
        showLoadError(app.automationError)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.spacing = 8
        return row
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if title == "↑" { button.setAccessibilityLabel("区間を上へ移動") }
        if title == "↓" { button.setAccessibilityLabel("区間を下へ移動") }
        return button
    }

    private func setupTable(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 28
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    }

    private func scroll(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        table.autoresizingMask = [.width]
        return scroll
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === list ? draft.automations.count : selected.map { draft.automations[$0].steps.count } ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === list {
            let label = NSTextField(labelWithString: draft.automations[row].name)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = label.stringValue
            return label
        }
        guard let selected else { return nil }
        let step = draft.automations[selected].steps[row]
        let field = AutomationStepField()
        field.activateRow = { [weak self] in self?.selectStep(row) }
        field.tag = row
        field.delegate = self
        field.font = .systemFont(ofSize: 12)
        if tableColumn?.identifier.rawValue == "label" {
            field.identifier = NSUserInterfaceItemIdentifier("label")
            field.stringValue = step.label
            field.placeholderString = "ラベル（任意）"
            field.setAccessibilityLabel("区間\(row + 1)のラベル")
            return field
        }
        field.identifier = NSUserInterfaceItemIdentifier("time")
        field.stringValue = step.until ?? step.duration ?? ""
        field.placeholderString = step.until != nil ? "10:30" : "25m"
        field.setAccessibilityLabel("区間\(row + 1)の時間")
        let mode = AutomationStepModeButton()
        mode.activateRow = { [weak self] in self?.selectStep(row) }
        mode.controlSize = .small
        mode.addItems(withTitles: ["時刻まで", "時間の長さ"])
        mode.selectItem(at: step.until != nil ? 0 : 1)
        mode.tag = row
        mode.target = self
        mode.action = #selector(stepModeChanged(_:))
        mode.setAccessibilityLabel("区間\(row + 1)の指定方法")
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        return self.row([mode, field])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === list { loadEditor() }
        else if notification.object as? NSTableView === steps { updateStepActions() }
    }

    private func selectStep(_ index: Int) {
        guard let selected, draft.automations[selected].steps.indices.contains(index) else { return }
        steps.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        updateStepActions()
    }

    private func updateStepActions() {
        let count = selected.map { draft.automations[$0].steps.count } ?? 0
        let index = steps.selectedRow
        let valid = (0..<count).contains(index)
        removeStepButton?.isEnabled = valid
        moveStepUpButton?.isEnabled = valid && index > 0
        moveStepDownButton?.isEnabled = valid && index + 1 < count
    }

    private func loadEditor() {
        let definition = selected.map { draft.automations[$0] }
        name.stringValue = definition?.name ?? ""
        name.isEnabled = definition != nil
        effects.isEnabled = definition != nil
        effects.selectItem(at: AutomationEffect.allCases.firstIndex(of: definition?.completionEffect ?? .each) ?? 0)
        steps.deselectAll(nil)
        steps.reloadData()
        updateStepActions()
    }

    private func changed() {
        dirty = true
        status.textColor = .secondaryLabelColor
        status.stringValue = "変更は未保存です。「保存」で入力欄から使えるようになります。"
        window?.isDocumentEdited = true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let selected else { return }
        if field === name {
            draft.automations[selected].name = field.stringValue
            list.reloadData(forRowIndexes: IndexSet(integer: selected), columnIndexes: IndexSet(integer: 0))
        } else {
            let index = field.tag
            guard draft.automations[selected].steps.indices.contains(index) else { return }
            if field.identifier?.rawValue == "label" { draft.automations[selected].steps[index].label = field.stringValue }
            else if draft.automations[selected].steps[index].until != nil { draft.automations[selected].steps[index].until = field.stringValue }
            else { draft.automations[selected].steps[index].duration = field.stringValue }
        }
        changed()
    }

    @objc private func effectChanged() {
        guard let selected else { return }
        draft.automations[selected].completionEffect = AutomationEffect.allCases[effects.indexOfSelectedItem]
        changed()
    }

    @objc private func stepModeChanged(_ sender: NSPopUpButton) {
        guard let selected else { return }
        let index = sender.tag
        selectStep(index)
        let wasClock = draft.automations[selected].steps[index].until != nil
        guard (sender.indexOfSelectedItem == 0) != wasClock else { return }
        if sender.indexOfSelectedItem == 0 {
            draft.automations[selected].steps[index].until = "10:30"
            draft.automations[selected].steps[index].duration = nil
        } else {
            draft.automations[selected].steps[index].duration = "25m"
            draft.automations[selected].steps[index].until = nil
        }
        steps.reloadData()
        selectStep(index)
        changed()
    }

    private func uniqueName(_ base: String) -> String {
        var result = base, number = 2
        while draft.named(result) != nil { result = "\(base) \(number)"; number += 1 }
        return result
    }

    @objc private func addDefinition() {
        draft.automations.append(AutomationDefinition(name: uniqueName("新しいオートメーション"), steps: [AutomationStep(duration: "3m")]))
        selectDefinition(draft.automations.count - 1)
        window?.makeFirstResponder(name)
        name.selectText(nil)
    }

    @objc private func duplicateDefinition() {
        guard let selected else { return }
        var copy = draft.automations[selected]
        copy.name = uniqueName(copy.name + " のコピー")
        draft.automations.append(copy)
        selectDefinition(draft.automations.count - 1)
    }

    @objc private func removeDefinition() {
        guard let selected else { return }
        draft.automations.remove(at: selected)
        selectDefinition(min(selected, draft.automations.count - 1))
    }

    private func selectDefinition(_ index: Int) {
        list.reloadData()
        if index >= 0 { list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { list.deselectAll(nil) }
        loadEditor()
        changed()
    }

    @objc private func addStep() {
        guard let selected else { return }
        draft.automations[selected].steps.append(AutomationStep(duration: "5m"))
        steps.reloadData()
        steps.selectRowIndexes(IndexSet(integer: draft.automations[selected].steps.count - 1), byExtendingSelection: false)
        changed()
    }

    @objc private func removeStep() {
        guard let selected, draft.automations[selected].steps.indices.contains(steps.selectedRow) else { return }
        let index = steps.selectedRow
        window?.makeFirstResponder(steps)
        draft.automations[selected].steps.remove(at: index)
        steps.reloadData()
        let count = draft.automations[selected].steps.count
        if count > 0 { selectStep(min(index, count - 1)) }
        else { steps.deselectAll(nil); updateStepActions() }
        changed()
    }

    @objc private func moveStepUp() { moveStep(-1) }
    @objc private func moveStepDown() { moveStep(1) }
    private func moveStep(_ delta: Int) {
        guard let selected else { return }
        let source = steps.selectedRow, destination = source + delta
        guard draft.automations[selected].steps.indices.contains(source),
              draft.automations[selected].steps.indices.contains(destination) else { return }
        window?.makeFirstResponder(steps)
        draft.automations[selected].steps.swapAt(source, destination)
        steps.reloadData()
        steps.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        changed()
    }

    @objc private func save() {
        window?.makeFirstResponder(nil)
        do {
            try app.saveAutomations(draft, replacing: baseline)
            baseline = app.automationData
            dirty = false
            window?.isDocumentEdited = false
            status.textColor = .secondaryLabelColor
            status.stringValue = "保存しました。タイマーの入力欄に名前を入れて開始できます。"
        } catch { showLoadError(error.localizedDescription) }
    }

    @objc private func reload() {
        if dirty {
            let alert = NSAlert()
            alert.messageText = "未保存の変更を破棄して再読み込みしますか？"
            alert.addButton(withTitle: "再読み込み")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        app.reloadAutomations()
        guard app.automationError == nil else { return }
        draft = app.automations
        baseline = app.automationData
        dirty = false
        window?.isDocumentEdited = false
        list.reloadData()
        if !draft.automations.isEmpty { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        loadEditor()
        status.textColor = .secondaryLabelColor
        status.stringValue = "JSONを再読み込みしました。"
    }

    func showLoadError(_ message: String?) {
        if let message {
            status.textColor = .systemRed
            status.stringValue = message
            status.toolTip = message
        } else if !dirty {
            status.textColor = .secondaryLabelColor
            status.stringValue = "設定は「保存」で反映されます。JSONを編集した後は「再読み込み」してください。"
            status.toolTip = nil
        }
    }

    func refreshIfUnedited() {
        guard !dirty, app.automationError == nil else { return }
        let index = list.selectedRow
        draft = app.automations
        baseline = app.automationData
        list.reloadData()
        if !draft.automations.isEmpty {
            list.selectRowIndexes(IndexSet(integer: max(0, min(index, draft.automations.count - 1))), byExtendingSelection: false)
        }
        loadEditor()
    }

    private func ensureJSON() throws {
        if try app.automationStore.data() == nil {
            _ = try app.automationStore.save(app.automations, replacing: nil)
            app.reloadAutomations()
            baseline = app.automationData
        }
    }

    @objc private func openJSON() {
        do { try ensureJSON() } catch { showLoadError(error.localizedDescription); return }
        let panel = NSOpenPanel()
        panel.title = "JSONを編集するアプリを選択"
        panel.prompt = "このアプリで開く"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let editor = panel.url else { return }
            NSWorkspace.shared.open([self.app.automationStore.url], withApplicationAt: editor, configuration: .init()) { _, error in
                if let error { DispatchQueue.main.async { self.showLoadError(error.localizedDescription) } }
            }
        }
    }

    @objc private func revealJSON() {
        do { try ensureJSON(); NSWorkspace.shared.activateFileViewerSelecting([app.automationStore.url]) }
        catch { showLoadError(error.localizedDescription) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "変更を保存しますか？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "保存せず閉じる")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return !dirty
        case .alertThirdButtonReturn:
            draft = app.automations; baseline = app.automationData; dirty = false
            sender.isDocumentEdited = false
            list.reloadData(); loadEditor()
            return true
        default: return false
        }
    }
}
