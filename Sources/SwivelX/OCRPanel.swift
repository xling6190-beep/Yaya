import AppKit

// MARK: - 「文字」识别结果浮层
// 框选 → 识别 → 原地弹出可编辑文本，校对/改错字后再复制。
// 视觉沿用全 UI 统一的那一套：黑透 0.75 + 圆角 12。

@MainActor
final class OCRResultPanel: NSObject {

    static let shared = OCRResultPanel()

    private var panel: OverlayPanel?
    private var textView: NSTextView?
    private var statusLabel: ToastText?
    private var sourceText = ""

    private let width: CGFloat = 420
    private let headerH: CGFloat = 40
    private let footerH: CGFloat = 52
    private let padX: CGFloat = 16
    private let textFont = NSFont.systemFont(ofSize: 13)

    // MARK: 展示

    func show(_ text: String) {
        close()
        sourceText = text

        let textH = measuredHeight(for: text)
        let h = headerH + textH + footerH

        let host = OCRHostView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        host.headerHeight = headerH
        host.onCancel = { [weak self] in self?.close() }

        // 与 Yaya 其它浮层同一套：黑透 0.75 + 12pt 连续圆角
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        host.layer?.cornerRadius = 12
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        buildHeader(in: host)
        buildTextView(text, height: textH, in: host)
        buildFooter(in: host)

        let panel = OverlayPanel(contentRect: host.bounds,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.isMovableByWindowBackground = true   // 空白处也能拖
        centerOnMouseScreen(panel)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        textView.map { panel.makeFirstResponder($0) }

        // 识别完直接进剪贴板，省一步；改错了还能在下面再点「复制」覆盖
        OCREngine.copyToPasteboard(text)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        textView = nil
        statusLabel = nil
    }

    // MARK: 构建

    private func buildHeader(in host: NSView) {
        let title = ToastText("识别结果",
                              font: .systemFont(ofSize: 13, weight: .semibold),
                              color: NSColor(calibratedWhite: 0.97, alpha: 1))
        title.frame = NSRect(x: padX, y: 11, width: 160, height: 18)
        host.addSubview(title)

        // 字数放标题栏，别挤在底部
        let counter = ToastText("\(sourceText.count) 字",
                                font: .systemFont(ofSize: 11.5),
                                color: NSColor(calibratedWhite: 0.52, alpha: 1),
                                alignment: .right)
        counter.frame = NSRect(x: width - padX - 24 - 72, y: 13, width: 68, height: 15)
        host.addSubview(counter)

        let closeBtn = NSButton(title: "", target: self, action: #selector(closeTapped))
        closeBtn.isBordered = false
        closeBtn.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
            .font: NSFont.systemFont(ofSize: 12)
        ])
        closeBtn.frame = NSRect(x: width - padX - 24, y: 9, width: 24, height: 22)
        host.addSubview(closeBtn)
    }

    private func buildTextView(_ text: String, height textH: CGFloat, in host: NSView) {
        let scroll = NSScrollView(frame: NSRect(x: padX, y: headerH,
                                                width: width - padX * 2, height: textH))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        scroll.layer?.cornerRadius = 8
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.masksToBounds = true

        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 10, height: 9)
        tv.drawsBackground = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.font = textFont
        tv.textColor = NSColor(calibratedWhite: 0.94, alpha: 1)
        tv.insertionPointColor = .white
        tv.appearance = NSAppearance(named: .darkAqua)
        tv.string = text

        scroll.documentView = tv
        host.addSubview(scroll)
        textView = tv
    }

    private func buildFooter(in host: NSView) {
        let btnH: CGFloat = 28
        let btnW: CGFloat = 84
        let y = host.bounds.height - footerH + 12

        let copy = NSButton(title: "", target: self, action: #selector(copyTapped))
        copy.isBordered = false
        copy.wantsLayer = true
        copy.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        copy.layer?.cornerRadius = btnH / 2
        copy.layer?.cornerCurve = .continuous
        copy.attributedTitle = NSAttributedString(string: "复制", attributes: [
            .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ])
        copy.frame = NSRect(x: width - padX - btnW, y: y, width: btnW, height: btnH)
        host.addSubview(copy)

        // 只保留一行状态：默认给快捷键提示，复制后短暂变成「已复制 N 字」
        let status = ToastText("⌘C 复制选中 · Esc 关闭",
                               font: .systemFont(ofSize: 11),
                               color: NSColor(calibratedWhite: 0.45, alpha: 1))
        status.frame = NSRect(x: padX, y: y + 7, width: 220, height: 15)
        host.addSubview(status)
        statusLabel = status
    }

    // MARK: 动作

    @objc private func copyTapped() {
        guard let tv = textView else { return }
        let selected = tv.selectedRange()
        let text = selected.length > 0
            ? (tv.string as NSString).substring(with: selected)
            : tv.string
        OCREngine.copyToPasteboard(text)
        flashStatus("已复制 \(text.count) 字")
    }

    @objc private func closeTapped() { close() }

    private func flashStatus(_ text: String) {
        guard let status = statusLabel else { return }
        status.text = text
        status.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let status = self?.statusLabel else { return }
            status.text = "⌘C 复制选中 · Esc 关闭"
            status.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        }
    }

    // MARK: 布局辅助

    /// 按文本量算高度：最少 88，最多 320（超了滚动）
    private func measuredHeight(for text: String) -> CGFloat {
        let probe = (text as NSString).boundingRect(
            with: NSSize(width: width - padX * 2 - 22, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont])
        return min(max(ceil(probe.height) + 24, 88), 320)
    }

    private func centerOnMouseScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let host = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let area = host?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2,
                                     y: area.midY - panel.frame.height / 2))
    }
}

// MARK: - 翻转坐标的容器（y 从顶往下，布局好算）

@MainActor
final class OCRHostView: NSView {
    var onCancel: (() -> Void)?
    /// 头部高度：这块区域用来拖动整个浮层
    var headerHeight: CGFloat = 40

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// 背景空白处也能拖（系统会把它交给窗口移动）
    override var mouseDownCanMoveWindow: Bool { true }

    private var dragMouse: NSPoint?
    private var dragFrame: NSPoint?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // 头部整条都能拖：标题文字本身是 label，不接事件，正好落在我们这里
        guard p.y <= headerHeight else { return super.mouseDown(with: event) }
        dragMouse = NSEvent.mouseLocation
        dragFrame = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragMouse, let origin = dragFrame, let win = window else {
            return super.mouseDragged(with: event)
        }
        // 用屏幕坐标算位移：窗口一动 locationInWindow 就变，会漂
        let now = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: origin.x + (now.x - start.x),
                                   y: origin.y + (now.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        dragMouse = nil
        dragFrame = nil
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight),
                      cursor: .openHand)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }
}
