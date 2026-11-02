import AppKit

// MARK: - 设置窗口（目前只有快捷键一项）

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    static let shared = SettingsWindow()
    private override init() { super.init() }

    private var window: NSWindow?
    private var fields: [String: ShortcutField] = [:]

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let actions = HotKeyCenter.actions
        let rowH: CGFloat = 46
        let width: CGFloat = 440
        let height = 96 + CGFloat(actions.count) * rowH + 56

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let title = NSTextField(labelWithString: "快捷键")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 24, y: height - 44, width: 200, height: 18)
        content.addSubview(title)

        let note = NSTextField(labelWithString: "点右侧方框后按下组合键；留空表示不设置。全局生效，不需要额外授权。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 24, y: height - 66, width: width - 48, height: 16)
        content.addSubview(note)

        var y = height - 96
        for item in actions {
            let label = NSTextField(labelWithString: item.title)
            label.font = .systemFont(ofSize: 13)
            label.frame = NSRect(x: 24, y: y + 6, width: 140, height: 18)
            content.addSubview(label)

            let field = ShortcutField(action: item.id)
            field.frame = NSRect(x: width - 24 - 160, y: y, width: 160, height: 30)
            field.shortcut = HotKeyCenter.shared.shortcuts[item.id]
            field.onRecord = { [weak self] sc in
                self?.apply(sc, to: item.id, field: field)
            }
            content.addSubview(field)
            fields[item.id] = field

            y -= rowH
        }

        let clearBtn = NSButton(title: "全部清除", target: self, action: #selector(clearAll))
        clearBtn.bezelStyle = .rounded
        clearBtn.frame = NSRect(x: 24, y: 18, width: 96, height: 30)
        content.addSubview(clearBtn)

        let doneBtn = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        doneBtn.frame = NSRect(x: width - 24 - 96, y: 18, width: 96, height: 30)
        content.addSubview(doneBtn)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Yaya 设置"
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    private func apply(_ sc: Shortcut?, to action: String, field: ShortcutField) {
        let ok = HotKeyCenter.shared.set(sc, for: action)
        if !ok, sc != nil {
            field.shortcut = nil
            field.flashError()
            NSSound.beep()
        } else {
            field.shortcut = HotKeyCenter.shared.shortcuts[action]
        }
    }

    @objc private func clearAll() {
        HotKeyCenter.shared.clearAll()
        for (id, field) in fields { field.shortcut = HotKeyCenter.shared.shortcuts[id] }
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // 记住窗口，下次复用；清掉引用避免野指针
        window = nil
        fields.removeAll()
    }
}

// MARK: - 快捷键录制框

@MainActor
final class ShortcutField: NSView {

    let action: String
    var shortcut: Shortcut? { didSet { needsDisplay = true } }
    var onRecord: ((Shortcut?) -> Void)?

    private var recording = false
    private var errorFlash = false

    init(action: String) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        guard recording else { return }
        if event.keyCode == 53 {              // Esc 退出录制
            recording = false
            needsDisplay = true
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = Shortcut.carbonModifiers(flags)
        // 必须带修饰键（功能键可单独用）
        guard mods != 0 || KeyName.isFunctionKey(UInt32(event.keyCode)) else { return }

        let sc = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
        recording = false
        onRecord?(sc)
    }

    func flashError() {
        errorFlash = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.errorFlash = false
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)

        if errorFlash {
            NSColor.systemRed.withAlphaComponent(0.18).setFill()
        } else if recording {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
        }
        path.fill()

        if recording {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        } else if errorFlash {
            NSColor.systemRed.withAlphaComponent(0.8).setStroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        let text: String
        if recording {
            text = "按下组合键…"
        } else if errorFlash {
            text = "已被占用"
        } else {
            text = shortcut?.display ?? "未设置"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: (shortcut == nil && !recording && !errorFlash)
                ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                           y: bounds.midY - size.height / 2),
               withAttributes: attrs)
    }
}
