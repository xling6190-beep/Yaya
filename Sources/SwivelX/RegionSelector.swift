import AppKit
import ScreenCaptureKit

// MARK: - 区域选择器（冻结画面 + 十字准星 + 局部放大镜 + 拖拽框选）
// 进入选择时先抓一张全屏快照当底图：画面就此「定格」，之后拖框、放大镜都基于这张图。

@MainActor
final class RegionSelector {

    static let shared = RegionSelector()
    private init() {}

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<NSRect?, Never>?

    /// 刚关掉的选框面板的 windowNumber。
    /// 采集时只精确排除这一个窗口，**不能排除 Yaya 的全部窗口** ——
    /// 否则连提示条、录完卡片这些「用户想截的东西」也会被一起排掉。
    private(set) var lastPanelWindowID: CGWindowID?

    func pick(hint: String? = nil, clickMeansFullScreen: Bool = false,
              adjustable: Bool = false) async -> NSRect? {
        guard let screen = NSScreen.main else { return nil }

        // 圆环刚收起来，几乎立刻抓图（延迟尽量小，减少「按下到定格」的时差）
        try? await Task.sleep(for: .milliseconds(5))
        let snapshot = await CaptureEngine.shared.snapshotFullScreen()

        return await withCheckedContinuation { cont in
            continuation = cont

            let container = NSView(frame: screen.frame)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.black.cgColor

            if let snap = snapshot {
                // 快照直接交给图层显示（layer.contents），不要用 NSImageView：
                // 后者每次鼠标移动都会被重新栅格化/插值，画面就跟着「颤」。
                // 关键：contentsScale 必须等于屏幕缩放（2x），图像与图层 1:1 对应，
                // 否则系统每帧都要把 4K 图重采样成 1x，出现细微抖动。
                let scale = screen.backingScaleFactor
                // 不压暗：定格图按原亮度显示（压暗会让人误以为屏幕变灰，也容易被一起截进图）
                let frozen = snap
                let bg = NSView(frame: container.bounds)
                bg.wantsLayer = true
                CATransaction.begin()
                CATransaction.setDisableActions(true)      // 关掉隐式动画，避免内容淡入
                bg.layer?.contents = frozen
                bg.layer?.contentsScale = scale
                bg.layer?.contentsGravity = .resize
                bg.layer?.magnificationFilter = .nearest
                bg.layer?.minificationFilter = .nearest
                bg.layer?.opacity = 0
                CATransaction.commit()
                bg.autoresizingMask = [.width, .height]
                container.addSubview(bg)

                // 120ms 淡入：抓图那一下到定格之间的时差，用渐变掩盖掉，避免「硬切」
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.12
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bg.layer?.opacity = 1
                bg.layer?.add(fade, forKey: "fadeIn")
            } else {
                // 拿不到快照就退回纯暗底
                let bg = NSView(frame: container.bounds)
                bg.wantsLayer = true
                bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
                bg.autoresizingMask = [.width, .height]
                container.addSubview(bg)
            }

            // 压暗已经烘进底图，不再单独叠一层半透明视图（少一层混合，画面更稳）

            // 交互与绘制层（十字线、放大镜、选框）
            let overlay = OverlayView(frame: container.bounds)
            overlay.wantsLayer = true
            overlay.snapshot = snapshot
            overlay.hint = hint
            overlay.clickMeansFullScreen = clickMeansFullScreen
            overlay.adjustable = adjustable
            overlay.autoresizingMask = [.width, .height]
            overlay.onFinish = { [weak self] rect in self?.finish(rect) }
            container.addSubview(overlay)

            let p = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = container
            p.setFrameOrigin(.zero)
            p.acceptsMouseMovedEvents = true
            p.orderFrontRegardless()
            p.makeKey()
            p.makeFirstResponder(overlay)
            panel = p
            lastPanelWindowID = CGWindowID(p.windowNumber)
        }
    }

    private func finish(_ rect: NSRect?) {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        let c = continuation
        continuation = nil
        // 让窗口真正从合成器消失后再截图/录屏：
        // orderOut 只是发出请求，画面里真正没有它要等下一帧，否则遮罩/选框会被一起截进去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            c?.resume(returning: rect)
        }
    }
}

// MARK: - 交互层

private final class OverlayView: NSView {

    var snapshot: CGImage?
    var hint: String?
    var clickMeansFullScreen = false
    var onFinish: ((NSRect?) -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var mousePoint: NSPoint?
    private var tracking: NSTrackingArea?

    // MARK: 三阶段：空 → 正在拖 → 可调整
    private enum Phase { case idle, dragging, adjusting }
    private var phase: Phase = .idle
    /// 松手后是否停在可调整状态（区域截图不开，标注/录屏开）
    var adjustable = false

    /// 拖拽手柄可命中的区域
    private enum Zone { case tl, tr, bl, br, left, right, top, bottom, inside }
    private var activeZone: Zone?
    private var zoneDragOrigin: NSPoint?
    private var rectAtDragStart: NSRect?
    /// 停手多久自动完成（一动就重新计时，所以短一点也不怕打断调整）
    private let idleCommitDelay: TimeInterval = 0.5
    private var idleTimer: Timer?

    private let handleSide: CGFloat = 8

    private let loupeSize: CGFloat = 110
    private let loupeZoom: CGFloat = 5
    /// 十字线总长（含中间留空的空隙）
    private let crossLength: CGFloat = 40
    private let crossGap: CGFloat = 6

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        updateMouse(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateMouse(p)
        if phase == .adjusting {
            // 还在动 → 重新计时，绝不在人家调整的时候自动结束
            scheduleIdleCommit()
            updateAdjustCursor(at: p)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if phase == .adjusting {
            cancelIdleCommit()
            // 双击选框内部 = 直接确认
            if event.clickCount == 2, currentRect.contains(p) {
                commit()
                return
            }
            if let z = zone(at: p) {
                activeZone = z
                zoneDragOrigin = p
                rectAtDragStart = currentRect
            } else {
                onFinish?(nil)          // 点选框外面 = 取消
            }
            return
        }

        // 准星和放大镜要消失，先把它们占的地方标脏
        invalidateMouseDecorations(at: mousePoint)
        mousePoint = p
        startPoint = p
        currentRect = NSRect(origin: p, size: .zero)
        phase = .dragging
        setNeedsDisplay(bounds)      // 提示文字要一并消失
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if phase == .adjusting {
            guard let z = activeZone, let o = zoneDragOrigin, let base = rectAtDragStart else { return }
            currentRect = resized(base, zone: z,
                                  dx: p.x - o.x, dy: p.y - o.y)
            setNeedsDisplay(bounds)
            return
        }

        guard let s = startPoint else { return }
        let previousRect = currentRect
        let oldPoint = mousePoint
        mousePoint = p
        currentRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                             width: abs(p.x - s.x), height: abs(p.y - s.y))
        // 只重绘新旧选框 + 放大镜经过的区域
        var dirty = previousRect.insetBy(dx: -60, dy: -60)
            .union(currentRect.insetBy(dx: -60, dy: -60))
        if let oldPoint { dirty = dirty.union(loupeFrame(at: oldPoint).insetBy(dx: -4, dy: -4)) }
        dirty = dirty.union(loupeFrame(at: p).insetBy(dx: -4, dy: -4))
        setNeedsDisplay(dirty)
    }

    /// 鼠标移动：只重绘准星和放大镜这两小块，不再整屏重绘
    private func updateMouse(_ p: NSPoint) {
        let old = mousePoint
        mousePoint = p
        invalidateMouseDecorations(at: old)
        invalidateMouseDecorations(at: p)
    }

    private func invalidateMouseDecorations(at p: NSPoint?) {
        guard let p else { return }
        setNeedsDisplay(crossRect(at: p))
        setNeedsDisplay(loupeFrame(at: p).insetBy(dx: -4, dy: -4))
    }

    private func crossRect(at p: NSPoint) -> NSRect {
        NSRect(x: p.x - crossLength / 2 - 2, y: p.y - crossLength / 2 - 2,
               width: crossLength + 4, height: crossLength + 4)
    }

    override func mouseUp(with event: NSEvent) {
        if phase == .adjusting {
            // 松手后进入「停手才完成」：不立刻定死，给 0.8 秒继续调
            activeZone = nil
            zoneDragOrigin = nil
            rectAtDragStart = nil
            scheduleIdleCommit()
            return
        }

        guard phase == .dragging else { return }
        if currentRect.width < 4 || currentRect.height < 4 {
            if clickMeansFullScreen, let f = window?.frame {
                onFinish?(f)              // 单击 = 整屏
            } else {
                onFinish?(nil)            // 截图沿用：视为取消
            }
            return
        }
        // 拖完了：可调整模式停在原地给手柄；区域截图（高频）直接交付，不多一步
        guard adjustable else {
            onFinish?(currentRect)
            return
        }
        phase = .adjusting
        activeZone = nil
        scheduleIdleCommit()
        setNeedsDisplay(bounds)
    }

    // MARK: 可调整状态

    /// 停手 0.8 秒自动完成（一动就重新计时）
    private func scheduleIdleCommit() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleCommitDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
    }

    private func cancelIdleCommit() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func commit() {
        cancelIdleCommit()
        guard phase == .adjusting, currentRect.width >= 4, currentRect.height >= 4 else { return }
        phase = .idle
        let r = currentRect
        currentRect = .zero
        onFinish?(r)
    }

    /// 鼠标落在哪个手柄上（角优先，其次边，最后内部）
    private func zone(at p: NSPoint) -> Zone? {
        let r = currentRect
        guard r.width > 1, r.height > 1 else { return nil }
        let t: CGFloat = 10      // 命中范围比视觉上的手柄大一圈，好点
        let nearL = abs(p.x - r.minX) <= t, nearR = abs(p.x - r.maxX) <= t
        let nearB = abs(p.y - r.minY) <= t, nearT = abs(p.y - r.maxY) <= t
        let inY = p.y >= r.minY - t && p.y <= r.maxY + t
        let inX = p.x >= r.minX - t && p.x <= r.maxX + t

        if nearL && nearB { return .bl }
        if nearR && nearB { return .br }
        if nearL && nearT { return .tl }
        if nearR && nearT { return .tr }
        if nearL && inY { return .left }
        if nearR && inY { return .right }
        if nearB && inX { return .bottom }
        if nearT && inX { return .top }
        if r.contains(p) { return .inside }
        return nil
    }

    /// 按手柄方向改矩形；最小 8×8，且不越出屏幕
    private func resized(_ base: NSRect, zone: Zone, dx: CGFloat, dy: CGFloat) -> NSRect {
        var r = base
        switch zone {
        case .inside:
            r.origin.x += dx
            r.origin.y += dy
        case .left, .tl, .bl:
            r.origin.x += dx
            r.size.width -= dx
        case .right, .tr, .br:
            r.size.width += dx
        case .bottom:
            r.origin.y += dy
            r.size.height -= dy
        case .top:
            r.size.height += dy
        default:
            break
        }
        // 修掉负宽度：拖过头时翻面
        if r.size.width < 0 { r.origin.x += r.size.width; r.size.width = -r.size.width }
        if r.size.height < 0 { r.origin.y += r.size.height; r.size.height = -r.size.height }
        r.size.width = max(8, r.size.width)
        r.size.height = max(8, r.size.height)

        // 限制在屏幕内
        let b = bounds
        if r.minX < b.minX { r.origin.x = b.minX }
        if r.minY < b.minY { r.origin.y = b.minY }
        if r.maxX > b.maxX { r.size.width = b.maxX - r.minX }
        if r.maxY > b.maxY { r.size.height = b.maxY - r.minY }
        return r
    }

    private func updateAdjustCursor(at p: NSPoint) {
        switch zone(at: p) {
        case .tl, .br:        NSCursor.crosshair.set()
        case .tr, .bl:        NSCursor.crosshair.set()
        case .left, .right:   NSCursor.resizeLeftRight.set()
        case .top, .bottom:   NSCursor.resizeUpDown.set()
        case .inside:         NSCursor.openHand.set()
        case nil:             NSCursor.crosshair.set()
        }
    }

    override func keyDown(with event: NSEvent) {
        if phase == .adjusting {
            if event.keyCode == 36 || event.keyCode == 76 {   // Enter / 小键盘 Enter
                commit()
                return
            }
            if event.keyCode == 53 {                           // Esc
                cancelIdleCommit()
                phase = .idle
                onFinish?(nil)
                return
            }
            // 方向键微调
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var r = currentRect
            switch event.keyCode {
            case 123: r.origin.x -= step
            case 124: r.origin.x += step
            case 125: r.origin.y -= step
            case 126: r.origin.y += step
            default:  return super.keyDown(with: event)
            }
            currentRect = r
            scheduleIdleCommit()
            setNeedsDisplay(bounds)
            return
        }
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dragging = !currentRect.isEmpty

        if dragging {
            // 选框：18pt 圆角 + 黑色 65% 发丝线（1 物理像素），和标注浮层同一套观感
            let scale = window?.backingScaleFactor ?? 2
            let path = NSBezierPath(roundedRect: currentRect, xRadius: 12, yRadius: 12)
            path.lineWidth = 1.0 / scale
            NSColor.black.withAlphaComponent(0.5).setStroke()
            path.stroke()
        } else if let hint {
            drawHint(hint)
        }

        // 放大镜全程显示（拖拽时也保留），十字准星只在未开始拖拽时显示
        if let p = mousePoint {
            if !dragging { drawCrosshair(at: p, in: ctx) }
            drawLoupe(at: p)
        }

        if dragging { drawSizeLabel() }
        if phase == .adjusting { drawHandles() }
    }

    /// 可调整状态下的 8 个手柄：白底 + 深色描边，深浅壁纸都看得见
    private func drawHandles() {
        let r = currentRect
        let s = handleSide
        let points: [NSPoint] = [
            NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
            NSPoint(x: r.minX, y: r.midY),                                   NSPoint(x: r.maxX, y: r.midY),
            NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
        ]
        for p in points {
            let box = NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.96).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// 十字准星：短十字（总长 40pt），中心留空隙不挡视点
    private func drawCrosshair(at p: NSPoint, in ctx: CGContext) {
        let half = crossLength / 2
        let gap = crossGap
        let lines = NSBezierPath()
        // 水平
        lines.move(to: NSPoint(x: p.x - half, y: p.y))
        lines.line(to: NSPoint(x: p.x - gap, y: p.y))
        lines.move(to: NSPoint(x: p.x + gap, y: p.y))
        lines.line(to: NSPoint(x: p.x + half, y: p.y))
        // 垂直
        lines.move(to: NSPoint(x: p.x, y: p.y - half))
        lines.line(to: NSPoint(x: p.x, y: p.y - gap))
        lines.move(to: NSPoint(x: p.x, y: p.y + gap))
        lines.line(to: NSPoint(x: p.x, y: p.y + half))
        lines.lineWidth = 1

        NSGraphicsContext.saveGraphicsState()
        // 黑 55% 粗线垫底当描边（与录制四角同一套），白 90% 细线压上面
        NSColor.black.withAlphaComponent(0.55).setStroke()
        let shadow = lines.copy() as! NSBezierPath
        shadow.lineWidth = 2.5
        shadow.stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        lines.stroke()
        NSGraphicsContext.restoreGraphicsState()
        _ = ctx
    }

    /// 放大镜位置（贴边自动翻转）
    private func loupeFrame(at p: NSPoint) -> NSRect {
        let side = loupeSize
        let offset: CGFloat = 26
        var ox = p.x + offset
        var oy = p.y - side - offset
        if ox + side > bounds.maxX - 8 { ox = p.x - side - offset }
        if oy < bounds.minY + 8 { oy = p.y + offset }
        ox = max(bounds.minX + 8, min(ox, bounds.maxX - side - 8))
        oy = max(bounds.minY + 8, min(oy, bounds.maxY - side - 8))
        return NSRect(x: ox, y: oy, width: side, height: side)
    }

    /// 放大镜：方形，无描边，贴边自动翻转
    private func drawLoupe(at p: NSPoint) {
        guard let snap = snapshot else { return }
        let side = loupeSize
        let loupe = loupeFrame(at: p)

        // 快照是像素尺寸，视图是点尺寸
        let scale = CGFloat(snap.width) / max(bounds.width, 1)
        let srcSide = side / loupeZoom * scale
        let src = CGRect(x: p.x * scale - srcSide / 2,
                         y: (bounds.height - p.y) * scale - srcSide / 2,
                         width: srcSide, height: srcSide)
        guard let crop = snap.cropping(to: src.integral) else { return }

        NSGraphicsContext.saveGraphicsState()
        let clipPath = NSBezierPath(roundedRect: loupe, xRadius: 12, yRadius: 12)
        clipPath.addClip()
        NSColor.black.setFill()
        loupe.fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.interpolationQuality = .none      // 放大后看清像素格
            ctx.draw(crop, in: loupe)
        }
        NSGraphicsContext.restoreGraphicsState()

        // 不要描边：方形放大镜直接贴图

        // 中心十字
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: loupe.midX - 6, y: loupe.midY))
        cross.line(to: NSPoint(x: loupe.midX + 6, y: loupe.midY))
        cross.move(to: NSPoint(x: loupe.midX, y: loupe.midY - 6))
        cross.line(to: NSPoint(x: loupe.midX, y: loupe.midY + 6))
        cross.lineWidth = 1
        NSColor.black.setStroke()
        cross.stroke()
    }

    /// 拖拽时在选区右上角显示尺寸
    private func drawSizeLabel() {
        let s = "\(Int(currentRect.width)) × \(Int(currentRect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = s.size(withAttributes: attrs)
        var box = NSRect(x: currentRect.minX, y: currentRect.maxY + 6,
                         width: size.width + 14, height: size.height + 8)
        if box.maxY > bounds.maxY - 4 {
            box.origin.y = currentRect.minY - box.height - 6
        }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: box.minX + 7, y: box.minY + 4), withAttributes: attrs)
    }

    /// 屏幕中央的操作提示
    private func drawHint(_ text: String) {
        let s = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let size = s.size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2 - 18,
                         y: bounds.midY - size.height / 2 - 12,
                         width: size.width + 36, height: size.height + 24)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        s.draw(at: NSPoint(x: box.minX + 18, y: box.minY + 12), withAttributes: attrs)
    }
}
