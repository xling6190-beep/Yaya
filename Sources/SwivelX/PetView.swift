import AppKit
import UniformTypeIdentifiers

/// 宠物本体：猫脸贴图 + 呼吸/眨眼/兴奋/吞咽动画
/// 交互：拖入文件张嘴、吞咽 Q 弹、扇环展开时点按取消
@MainActor
final class PetView: NSView {

    enum Phase {
        case idle
        case excited          // 文件拖近：张大嘴等投喂
        case gulp             // 吞下：眯眼 + 身体被压扁又弹回
        case proud            // 扇环展开期间：保持满足的 ^ ^ 表情
    }

    var onFiles: (([URL], NSEvent.ModifierFlags, NSPoint) -> Void)?
    /// 扇环展开时赋值：点宠物 = 取消收起；平时为 nil，点按落到窗口拖动逻辑
    var onTap: (() -> Void)?
    /// 单击宠物（几乎没移动）时触发：弹出 Snapzy 功能圆环
    var onSingleClick: ((NSPoint) -> Void)?

    private var phase: Phase = .idle
    private var breath: CGFloat = 0
    private var blink = false
    private var nextBlink: Date = .distantPast

    // 录制中状态：头顶红点 + 呼吸加快
    var recording = false {
        didSet { needsDisplay = true }
    }

    // 拖动检测：按下位置 + 是否已判定为拖动
    private var dragStartPoint: NSPoint?
    private var isDragging = false

    // 可打断的过渡（规范：交互态用过渡，阶段性序列才用关键帧）
    private let squash = Anim(1.0, duration: 0.14)
    private let press  = Anim(1.0, duration: Timing.press)
    private let lift   = Anim(0.0, duration: Timing.popover)   // 拖近时的抬升
    /// 被点开圆环时的「弹一下」：只放大 6%，带一点过冲，克制即可
    private let proud  = Spring(0, omega: 24, zeta: 0.52)
    private var idleTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?

    // 猫脸贴图
    private let catImage: NSImage? = {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets/cat-face.png"),
            Bundle.main.resourceURL?.appendingPathComponent("assets/cat-face.png"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/assets/cat-face.png"),
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            return NSImage(contentsOf: c)
        }
        return nil
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        startLoops()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    deinit {
        idleTask?.cancel()
        renderTask?.cancel()
    }

    // MARK: 循环（呼吸/眨眼 + 重绘）

    private func startLoops() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if MotionPreference.reduceMotion {
                    self.breath = 0
                } else {
                    // 录制中呼吸加快（频率翻倍）
                    let freq: TimeInterval = self.recording ? 4.4 : 2.2
                    self.breath = sin(Date().timeIntervalSinceReferenceDate * freq)
                }
                if !self.blink, Date() > self.nextBlink {
                    self.blink = true
                    self.nextBlink = Date().addingTimeInterval(2.5 + .random(in: 0...3.5))
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(130))
                        self?.blink = false
                    }
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var needs = false
                needs = self.squash.tick() || needs
                needs = self.press.tick() || needs
                needs = self.lift.tick() || needs
                needs = self.proud.tick() || needs
                if needs || self.phase != .idle { self.needsDisplay = true }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: 吞咽（阶段性序列，规范允许关键帧）

    func playGulp() {
        if MotionPreference.reduceMotion { return }
        Task { [weak self] in
            self?.phase = .gulp
            self?.squash.to(0.86, duration: 0.10)
            try? await Task.sleep(for: .milliseconds(130))
            self?.squash.to(1.08, duration: 0.12)
            try? await Task.sleep(for: .milliseconds(120))
            self?.squash.to(1.0, duration: 0.18)
            try? await Task.sleep(for: .milliseconds(200))
            self?.phase = .idle
        }
    }

    func setProud(_ on: Bool) {
        phase = on ? .proud : .idle
        lift.to(on ? 1 : 0)
        proud.to(on ? 1 : 0)
        needsDisplay = true
    }

    // MARK: 拖放与点按

    private func files(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let has = !files(sender).isEmpty
        phase = has ? .excited : .idle
        lift.to(has ? 1 : 0)
        needsDisplay = true
        return has ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        phase = .idle
        lift.to(0)
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        guard !urls.isEmpty, let window = self.window else { return false }

        let centerInWindow = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let screenPoint = window.convertPoint(toScreen: centerInWindow)

        let flags = NSEvent.modifierFlags.intersection(
            NSEvent.ModifierFlags([.shift, .command, .option, .control]))

        playGulp()
        onFiles?(urls, flags, screenPoint)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // 扇环展开期间：点宠物 = 取消收起（优先级最高）
        if let onTap {
            press.to(0.90)
            onTap()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                self?.press.to(1.0, duration: 0.16)
            }
            return
        }

        // 平时：记录按下点（屏幕坐标，避免窗口移动导致坐标抖动），等待判断「单击弹圆环」还是「按住拖动」
        dragStartPoint = NSEvent.mouseLocation
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let p = NSEvent.mouseLocation   // 屏幕坐标，不随窗口移动而变
        let dx = p.x - start.x, dy = p.y - start.y
        // 移动超过阈值才判定为「拖动」，否则仍算单击
        if !isDragging && (abs(dx) > 3 || abs(dy) > 3) {
            isDragging = true
        }
        if isDragging, let window = self.window {
            var origin = window.frame.origin
            origin.x += dx
            origin.y += dy
            window.setFrameOrigin(origin)
            dragStartPoint = p
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartPoint = nil
            isDragging = false
        }
        // 扇环展开期间点击 = 取消，已在 mouseDown 处理
        if onTap != nil { return }
        // 未拖动 → 单击：弹 Snapzy 功能圆环
        if !isDragging, let window = self.window {
            let centerInWindow = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let screenPoint = window.convertPoint(toScreen: centerInWindow)
            onSingleClick?(screenPoint)
        }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let cx = bounds.midX
        let liftAmount = lift.value * 3
        let breathLift = breath * 1.1
        let s = squash.value * press.value

        // 猫脸尺寸与中心
        let faceW: CGFloat = 62 * (1 + (1 - s) * 0.4)
        let faceH: CGFloat = 62 * s
        let centerY: CGFloat = 46 + breathLift + liftAmount

        // 地面阴影
        let shadowW = 50 * (1 + (1 - s) * 0.5)
        let shadowAlpha = 0.20 - lift.value * 0.10
        ctx.setFillColor(NSColor(oklchL: 0.25, chroma: 0.03, hue: 60, alpha: max(0.05, shadowAlpha)).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - shadowW / 2, y: centerY - faceH / 2 - 4, width: shadowW, height: 7))

        guard let cat = catImage else {
            // 兜底：图片没找到时画个圆
            ctx.setFillColor(Palette.catFur.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - faceW / 2, y: centerY - faceH / 2, width: faceW, height: faceH))
            return
        }

        // 眨眼：上下压缩模拟（眨眼瞬间压扁）
        var scaleY: CGFloat = 1.0
        if blink { scaleY = 0.85 }

        // 兴奋（拖近）：放大
        let excitedScale: CGFloat = phase == .excited ? 1.15 : 1.0
        // 点开圆环：弹簧驱动，先弹到约 7% 再落回 6%（很轻的一下）
        let proudScale: CGFloat = 1 + 0.06 * max(0, proud.value)

        let drawW = faceW * excitedScale * proudScale
        let drawH = faceH * scaleY * excitedScale * proudScale

        let rect = CGRect(x: cx - drawW / 2, y: centerY - drawH / 2, width: drawW, height: drawH)

        // 投影（吞咽/骄傲时更强）
        if phase == .excited || phase == .proud {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18,
                          color: NSColor(oklchL: 0.25, chroma: 0.03, hue: 60, alpha: 0.18).cgColor)
            cat.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            ctx.restoreGState()
        } else {
            cat.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        if phase == .excited {
            let star = "✦" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: Palette.sparkle
            ]
            star.draw(at: CGPoint(x: bounds.maxX - 17, y: bounds.maxY - 21), withAttributes: attrs)
        }

        // 录制中：头顶红点（带呼吸闪烁）
        if recording {
            let blinkOn = Int(Date().timeIntervalSinceReferenceDate * 2) % 2 == 0
            let dotR: CGFloat = 5
            let dotY = centerY + faceH / 2 * excitedScale * proudScale + 6
            ctx.setFillColor(NSColor(calibratedRed: 0.89, green: 0.20, blue: 0.20, alpha: blinkOn ? 1.0 : 0.5).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - dotR, y: dotY, width: dotR * 2, height: dotR * 2))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - 2, y: dotY + 3, width: 4, height: 4))
        }
    }
}
