import AppKit

// MARK: - 录屏控制条（一条搞定）
// 挂在录制区域正上方，居中。
// 视觉：黑色半透明圆角条（与 Yaya 的提示条同一套语言），白色文字。
// 阶段一：红点 + 「开始录制」。
// 阶段二：约 1.2s 后原位切换成「实时时长 + 停止按钮」，宽度不变、不跳位。

@MainActor
final class RecordingBar {

    private var panel: NSPanel?
    private var timeLabel: ToastText?
    private var stopButton: NSButton?
    private var stopIcon: NSView?
    private var dot: NSView?
    private var timer: Timer?
    private var revealTimer: Timer?
    private var startDate: Date?

    var onStop: (() -> Void)?

    // 尺寸：扁一点，贴合黑色提示条的观感
    private let barWidth: CGFloat = 136
    private let barHeight: CGFloat = 40
    /// 圆角与提示条保持一致（全 UI 统一 12）
    private let barRadius: CGFloat = 12
    /// 黑色半透明底，和提示条同款
    private let backdrop = NSColor.black.withAlphaComponent(0.75)
    /// 红点 / 停止块用同一个红
    private let accent = NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.21, alpha: 1)
    /// 「开始录制」停留时长，之后自动切到计时状态
    private let hintDuration: TimeInterval = 1.2

    // MARK: 展示

    /// target = 录制区域（屏幕坐标，左下原点）。控制条贴在它的正上方居中。
    func show(above target: NSRect) {
        close()

        let w = barWidth
        let h = barHeight
        let view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.wantsLayer = true
        view.layer?.backgroundColor = backdrop.cgColor
        view.layer?.cornerRadius = barRadius
        view.layer?.cornerCurve = .continuous

        // 红点（垂直居中）
        let dotSize: CGFloat = 8
        let dotView = NSView(frame: NSRect(x: 34, y: (h - dotSize) / 2, width: dotSize, height: dotSize))
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = accent.cgColor
        dotView.layer?.cornerRadius = dotSize / 2
        view.addSubview(dotView)
        dot = dotView

        // 文字：用自绘控件，两个轴都真正居中（NSTextField 会从框顶画字、整体偏上）
        // 两态共用一个等宽数字字体：切到计时不会因为换字体而抖动
        let label = ToastText("开始录制",
                              font: .monospacedDigitSystemFont(ofSize: 13.5, weight: .medium),
                              color: NSColor(calibratedWhite: 0.96, alpha: 1),
                              alignment: .left)
        label.frame = NSRect(x: 50, y: 0, width: 64, height: h)
        view.addSubview(label)
        timeLabel = label

        // 停止按钮（命中区比图标大一点，好点）。阶段一先藏起来。
        let stop = NSButton(frame: NSRect(x: w - 40, y: 4, width: 34, height: h - 8))
        stop.title = ""
        stop.isBordered = false
        stop.wantsLayer = true
        stop.layer?.backgroundColor = NSColor.clear.cgColor
        stop.target = self
        stop.action = #selector(stopTapped)
        stop.alphaValue = 0
        view.addSubview(stop)
        stopButton = stop

        let iconSize: CGFloat = 14
        let icon = NSView(frame: NSRect(x: w - 16 - iconSize, y: (h - iconSize) / 2, width: iconSize, height: iconSize))
        icon.wantsLayer = true
        icon.layer?.backgroundColor = accent.cgColor
        icon.layer?.cornerRadius = 3
        icon.alphaValue = 0
        view.addSubview(icon)
        stopIcon = icon

        let p = NSPanel(contentRect: view.bounds,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = view

        // 位置：录制区域正上方、水平居中对齐区域中点；贴到屏幕顶时翻到区域内侧顶部
        let host = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: target.midX, y: target.midY))
        } ?? NSScreen.main
        var origin = NSPoint(x: target.midX - w / 2, y: target.maxY + 10)
        var inside = false
        if let vis = host?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - w - 8)
            if origin.y + h > vis.maxY - 8 {
                origin.y = target.maxY - h - 10   // 没空间了，落到区域内侧顶部
                inside = true
            }
            if origin.y < vis.minY + 8 { origin.y = vis.minY + 8 }
        }
        // 落到区域内侧时略微降透明度，尽量少挡内容（也会入镜，无法避免）
        if inside {
            view.alphaValue = 0.9
        }
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        panel = p

        startDate = Date()
        // 停留一会儿「开始录制」，再原位切成计时 + 停止
        revealTimer = Timer.scheduledTimer(withTimeInterval: hintDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterTimingState() }
        }
    }

    /// 外部可强制立刻进入计时状态（正常由内部定时器触发）
    func startTimer() {
        enterTimingState()
    }

    private func enterTimingState() {
        revealTimer?.invalidate()
        revealTimer = nil
        guard let label = timeLabel else { return }

        // 红点在计时状态下保持：它表示「正在录」
        label.text = formatted(0)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            stopButton?.animator().alphaValue = 1
            stopIcon?.animator().alphaValue = 1
        }
        stopButton?.isEnabled = true

        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            // Timer 在主 runloop 上回调，这里可直接断言主 actor
            MainActor.assumeIsolated { self?.updateTime() }
        }
        updateTime()
    }

    func close() {
        revealTimer?.invalidate()
        revealTimer = nil
        timer?.invalidate()
        timer = nil
        startDate = nil
        panel?.close()
        panel = nil
        timeLabel = nil
        stopButton = nil
        stopIcon = nil
        dot = nil
    }

    // MARK: 计时

    private func updateTime() {
        guard let start = startDate, let label = timeLabel else { return }
        label.text = formatted(Int(Date().timeIntervalSince(start)))
    }

    private func formatted(_ elapsed: Int) -> String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    @objc private func stopTapped() {
        onStop?()
    }
}
