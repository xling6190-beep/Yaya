import AppKit

// MARK: - 录屏开始前的 3-2-1 倒计时
// 屏幕中央一个大数字，不拦截鼠标事件，不抢焦点。

@MainActor
enum Countdown {

    /// 在屏幕坐标 point 处显示倒计时，返回时倒计时已结束
    static func run(seconds: Int = 3, centerAt point: NSPoint) async {
        guard seconds > 0 else { return }

        let side: CGFloat = 140
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let box = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        box.layer?.cornerRadius = side / 2

        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .systemFont(ofSize: 64, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (side - 76) / 2, width: side, height: 76)
        box.addSubview(label)

        panel.contentView = box
        panel.setFrameOrigin(NSPoint(x: point.x - side / 2, y: point.y - side / 2))
        panel.orderFrontRegardless()

        for n in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(n)"
            try? await Task.sleep(for: .milliseconds(800))
        }
        panel.close()
    }
}
