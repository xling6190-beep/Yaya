import AppKit
import UniformTypeIdentifiers

// MARK: - 标注（原地浮层）
//
// 流程：区域截图 → 图片原地贴在刚框选的那块位置 → 图片正上方浮出一条工具条
//      → 直接在图上画（矩形 / 箭头 / 文字 / 马赛克 / 编号）→ 保存即覆盖原图。
//
// 和旧版的区别：不再另开一个居中的窗口；标注位置与截图位置一致，所见即所得。

@MainActor
final class AnnotateOverlay {

    // MARK: 数据

    enum Tool: Int, CaseIterable {
        case rect, arrow, text, blur, number

        var symbol: String {
            switch self {
            case .rect:   return "rectangle"
            case .arrow:  return "arrow.up.right"
            case .text:   return "textformat"
            case .blur:   return "square.grid.3x3.fill"
            case .number: return "number.circle"
            }
        }
        var tip: String {
            switch self {
            case .rect:   return "矩形（1）"
            case .arrow:  return "箭头（2）"
            case .text:   return "文字（3）"
            case .blur:   return "马赛克（4）"
            case .number: return "编号（5）"
            }
        }
    }

    struct Mark {
        var tool: Tool
        var rect: NSRect
        var text: String = ""
        var color: NSColor = .systemRed
        var lineWidth: CGFloat = 3
        /// 拖拽起点 / 终点：箭头方向必须跟着手走，不能从规范化后的 rect 推
        var start: NSPoint = .zero
        var end: NSPoint = .zero
    }

    static let shared = AnnotateOverlay()

    // MARK: 状态

    private var imagePanel: OverlayPanel?
    private var toolbarPanel: OverlayPanel?
    private var canvas: AnnotateCanvas?
    private var toolbar: AnnotateToolbar?
    private var fileURL: URL?
    private var finishCont: CheckedContinuation<Void, Never>?
    private var didSave = false

    private(set) var tool: Tool = .rect
    private(set) var color: NSColor = NSColor(calibratedRed: 0.98, green: 0.24, blue: 0.25, alpha: 1)
    private(set) var lineWidth: CGFloat = 3
    private(set) var marks: [Mark] = []
    private var redoStack: [Mark] = []
    private var counter = 1

    var canUndo: Bool { !marks.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func syncToolbar() {
        toolbar?.sync(tool: tool,
                      color: color,
                      width: lineWidth,
                      canUndo: canUndo,
                      canRedo: canRedo)
    }

    // MARK: 进入 / 退出

    /// 返回 true = 已保存覆盖原图；false = 取消
    func present(image: NSImage, at rect: NSRect, fileURL: URL) async -> Bool {
        // 已经在标注中就别再开一层
        guard imagePanel == nil else { return false }
        self.fileURL = fileURL
        marks = []
        redoStack = []
        counter = 1
        didSave = false
        tool = .rect

        buildPanels(image: image, rect: rect)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishCont = cont
        }
        return didSave
    }

    private func buildPanels(image: NSImage, rect: NSRect) {
        // 先把应用提到前台，浮层才能拿到键盘（Esc / ⌘Z / 直接打字）
        NSApp.activate(ignoringOtherApps: true)

        // —— 图片浮层：与截图区域完全重合
        let cv = AnnotateCanvas(frame: NSRect(origin: .zero, size: rect.size))
        cv.owner = self
        cv.setImage(image)
        canvas = cv

        let ip = OverlayPanel(contentRect: cv.bounds,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        ip.isOpaque = false
        ip.backgroundColor = .clear
        // 图片浮层贴着截图原位，系统投影会压在旁边的原画面上、显得「浮起来一层」，
        // 所以这里关掉；工具条是悬空的，保留投影。
        ip.hasShadow = false
        ip.level = .floating
        ip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ip.contentView = cv
        ip.setFrame(rect, display: false)
        ip.orderFrontRegardless()
        ip.makeKey()
        ip.makeFirstResponder(cv)

        // 黑色半透明描边 + 18pt 圆角（和选区放大镜同款圆角），告诉你「这块现在可编辑」。
        // 圆角要真的把图裁掉，否则边框圆了、图的直角还戳在外面。
        // 真正的 1 物理像素发丝线：1pt 在 Retina 上是 2 个像素，看着偏粗
        let hostScale = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY))
        }?.backingScaleFactor ?? 2

        cv.wantsLayer = true
        // ★ 关键：层的 contentsScale 不跟上屏幕缩放，整块内容会被按 1x 画再放大 → 看着糊
        cv.layer?.contentsScale = hostScale
        cv.layer?.cornerRadius = 12
        cv.layer?.cornerCurve = .continuous
        cv.layer?.masksToBounds = true
        cv.layer?.borderWidth = 1.0 / hostScale
        cv.layer?.borderColor = NSColor.black.withAlphaComponent(0.5).cgColor

        // —— 工具条：贴在图片正上方居中
        let tb = AnnotateToolbar()
        tb.owner = self
        tb.onTool = { [weak self] t in self?.setTool(t) }
        tb.onColor = { [weak self] c in self?.setColor(c) }
        tb.onWidth = { [weak self] w in self?.setWidth(w) }
        tb.onUndo = { [weak self] in self?.undo() }
        tb.onRedo = { [weak self] in self?.redo() }
        tb.onSave = { [weak self] in self?.save() }
        tb.onClose = { [weak self] in self?.cancel() }
        toolbar = tb

        let tw = AnnotateToolbar.totalWidth
        let th = AnnotateToolbar.height
        let tp = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: tw, height: th),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        tp.isOpaque = false
        tp.backgroundColor = .clear
        tp.hasShadow = true
        tp.level = .floating
        tp.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tp.contentView = tb
        tp.setFrameOrigin(toolbarOrigin(for: rect, size: NSSize(width: tw, height: th)))
        tp.keyEnabled = false      // 工具条不吃键盘焦点，Esc/⌘Z 始终给画布
        tp.orderFrontRegardless()
        toolbarPanel = tp

        syncToolbar()

        NSApp.activate(ignoringOtherApps: true)
        imagePanel = ip
    }

    /// 工具条位置：图片正上方 10pt 居中；上方没空间就落到图片下方
    private func toolbarOrigin(for rect: NSRect, size: NSSize) -> NSPoint {
        var x = rect.midX - size.width / 2
        var y = rect.maxY + 10
        let host = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY))
        } ?? NSScreen.main
        if let vis = host?.visibleFrame {
            x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
            if y + size.height > vis.maxY - 6 {
                y = rect.minY - size.height - 10     // 翻到图片下方
            }
            if y < vis.minY + 6 { y = vis.minY + 6 }
        }
        return NSPoint(x: x, y: y)
    }

    private func teardown() {
        imagePanel?.close()
        imagePanel = nil
        toolbarPanel?.close()
        toolbarPanel = nil
        canvas = nil
        toolbar = nil
        fileURL = nil
    }

    private func finish(saved: Bool) {
        didSave = saved
        teardown()
        if let c = finishCont {
            finishCont = nil
            c.resume()
        }
    }

    // MARK: 移动（截图 + 工具条一起走）

    private var moveAnchor: (mouse: NSPoint, image: NSPoint, toolbar: NSPoint)?

    /// 整块浮层（图 + 工具条）一起搬：按住空格拖画布，或直接拖工具条空白处
    func beginMove() {
        guard let ip = imagePanel, let tp = toolbarPanel else { return }
        moveAnchor = (NSEvent.mouseLocation, ip.frame.origin, tp.frame.origin)
    }

    func updateMove() {
        guard let a = moveAnchor, let ip = imagePanel, let tp = toolbarPanel else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - a.mouse.x
        let dy = m.y - a.mouse.y
        ip.setFrameOrigin(NSPoint(x: a.image.x + dx, y: a.image.y + dy))
        tp.setFrameOrigin(NSPoint(x: a.toolbar.x + dx, y: a.toolbar.y + dy))
    }

    func endMove() { moveAnchor = nil }

    // MARK: 移动区

    func cancel() { finish(saved: false) }

    // MARK: 工具 / 样式

    func setTool(_ t: Tool) {
        tool = t
        syncToolbar()
        canvas?.needsDisplay = true
    }

    func setColor(_ c: NSColor) {
        color = c
        syncToolbar()
    }

    func setWidth(_ w: CGFloat) {
        lineWidth = w
        syncToolbar()
    }

    // MARK: 画标注（画布回调）

    func newMark(tool t: Tool, at p: NSPoint) -> Mark {
        var m = Mark(tool: t, rect: NSRect(origin: p, size: .zero), color: color, lineWidth: lineWidth)
        m.start = p
        m.end = p
        if t == .number {
            m.text = "\(counter)"
            counter += 1
        }
        return m
    }

    func commit(_ m: Mark) {
        guard m.rect.width > 2 || m.rect.height > 2 || m.tool == .text || m.tool == .number else { return }
        marks.append(m)
        redoStack.removeAll()
        canvas?.marks = marks
        canvas?.needsDisplay = true
        syncToolbar()
    }

    func undo() {
        guard let last = marks.popLast() else { return }
        if last.tool == .number, let n = Int(last.text) {
            counter = max(1, n)
        }
        redoStack.append(last)
        canvas?.marks = marks
        canvas?.needsDisplay = true
        syncToolbar()
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        marks.append(last)
        canvas?.marks = marks
        canvas?.needsDisplay = true
        syncToolbar()
    }

    // MARK: 保存（覆盖原图）

    func save() {
        guard let url = fileURL, let canvas else { finish(saved: false); return }
        guard let rep = canvas.flatten() ,
              let data = rep.representation(using: .png, properties: [:]) else {
            finish(saved: false)
            return
        }
        do {
            try data.write(to: url)
        } catch {
            NSLog("[Yaya] 标注保存失败：%@", error.localizedDescription)
            finish(saved: false)
            return
        }
        // 剪贴板同步成带标注的版本
        if let img = NSImage(data: data) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
        }
        finish(saved: true)
    }
}

// MARK: - 可成为 key 的浮层

final class OverlayPanel: NSPanel {
    var keyEnabled = true
    /// 失去键盘焦点时回调：窗口选择器靠它实现「点别处 = 取消」
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { keyEnabled }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - 画布（图上直接画）

@MainActor
final class AnnotateCanvas: NSView {

    weak var owner: AnnotateOverlay?

    private var baseCG: CGImage?
    private var pixelated: CGImage?
    var marks: [AnnotateOverlay.Mark] = []

    private var dragStart: NSPoint?
    private var dragMark: AnnotateOverlay.Mark?
    private var textField: NSTextField?
    /// 空格按住 = 进入「搬动整块浮层」模式
    private var spaceDown = false
    private var moving = false

    override var acceptsFirstResponder: Bool { true }

    func setImage(_ image: NSImage) {
        // 取像素最多的那个 rep，别让 NSImage 按「点」尺寸降采样 —— 那样放上来就糊
        let best = image.representations
            .compactMap { ($0 as? NSBitmapImageRep)?.cgImage }
            .max { $0.width < $1.width }
        baseCG = best ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if let cg = baseCG { pixelated = Self.makePixelated(cg, blockPx: 18) }
        needsDisplay = true
    }

    /// 真像素化：把整图缩到 1/18 再放大回来，得到块状底图
    private static func makePixelated(_ cg: CGImage, blockPx: Int) -> CGImage? {
        let w = max(1, cg.width / blockPx)
        let h = max(1, cg.height / blockPx)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        render(into: ctx)
    }

    func render(into ctx: CGContext) {
        if let cg = baseCG {
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: bounds)
        }
        for m in marks { drawMark(m, ctx: ctx) }
        if let d = dragMark { drawMark(d, ctx: ctx) }
    }

    private func drawMark(_ m: AnnotateOverlay.Mark, ctx: CGContext) {
        switch m.tool {
        case .rect:
            ctx.setStrokeColor(m.color.cgColor)
            ctx.setLineWidth(m.lineWidth)
            ctx.stroke(m.rect)

        case .arrow:
            // 燕尾箭头：杆收腰（尾细头粗）+ 带凹口的倒钩头，尖端永远在松手那一端
            drawBarbedArrow(ctx, from: m.start, to: m.end, lw: m.lineWidth, color: m.color)

        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize(m.lineWidth), weight: .semibold),
                .foregroundColor: m.color,
            ]
            (m.text as NSString).draw(at: m.rect.origin, withAttributes: attrs)

        case .blur:
            guard let px = pixelated else { break }
            ctx.saveGState()
            ctx.clip(to: m.rect)
            ctx.interpolationQuality = .none
            ctx.draw(px, in: bounds)
            ctx.restoreGState()

        case .number:
            let r = badgeRect(at: m.rect.origin, lineWidth: m.lineWidth)
            ctx.setFillColor(m.color.cgColor)
            ctx.fillEllipse(in: r)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: r.height * 0.58),
                .foregroundColor: NSColor.white,
            ]
            let s = m.text as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
                   withAttributes: attrs)
        }
    }

    /// 燕尾箭头（参数按参考图实测校准：头长 33 / 头宽 21 / 凹口 1/3，杆尾收成 30%）
    private func drawBarbedArrow(_ ctx: CGContext, from a: NSPoint, to b: NSPoint,
                                 lw: CGFloat, color: NSColor) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 2 else { return }
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux

        let headL = min(22 + lw * 4.5, len * 0.6)
        let headW = 6.5 + lw * 1.7
        let notchDepth = headL * 0.36

        let back  = NSPoint(x: b.x - headL * ux, y: b.y - headL * uy)
        let notch = NSPoint(x: b.x - (headL - notchDepth) * ux, y: b.y - (headL - notchDepth) * uy)
        let barb1 = NSPoint(x: back.x + headW * nx, y: back.y + headW * ny)
        let barb2 = NSPoint(x: back.x - headW * nx, y: back.y - headW * ny)

        let wHead = lw * 2.8
        let wTail = max(1.0, wHead * 0.30)

        // 略微半透明：先用不透明色把形状画进一个透明图层，最后整层一次性上透明度。
        // 否则杆和头重叠的地方会二次叠加，出现一条更深的接缝。
        ctx.saveGState()
        ctx.setAlpha(0.92)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color.cgColor)

        // 杆：尾细 → 头粗的梯形，末端插进凹口
        ctx.beginPath()
        ctx.move(to: NSPoint(x: a.x + nx * wTail / 2, y: a.y + ny * wTail / 2))
        ctx.addLine(to: NSPoint(x: notch.x + nx * wHead / 2, y: notch.y + ny * wHead / 2))
        ctx.addLine(to: NSPoint(x: notch.x - nx * wHead / 2, y: notch.y - ny * wHead / 2))
        ctx.addLine(to: NSPoint(x: a.x - nx * wTail / 2, y: a.y - ny * wTail / 2))
        ctx.closePath()
        ctx.fillPath()
        // 尾巴圆头
        ctx.fillEllipse(in: CGRect(x: a.x - wTail / 2, y: a.y - wTail / 2,
                                   width: wTail, height: wTail))

        // 头：燕尾（tip → 倒钩 → 凹口 → 倒钩）
        ctx.beginPath()
        ctx.move(to: b)
        ctx.addLine(to: barb1)
        ctx.addLine(to: notch)
        ctx.addLine(to: barb2)
        ctx.closePath()
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func fontSize(_ w: CGFloat) -> CGFloat { 16 + w * 2 }
    private func badgeRect(at p: NSPoint, lineWidth: CGFloat) -> NSRect {
        let d = 22 + lineWidth * 2
        return NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitEditingText()
        guard let owner else { return }
        // 空格 + 拖动 = 搬动整块浮层（不画标注）
        if spaceDown {
            moving = true
            owner.beginMove()
            NSCursor.closedHand.push()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if owner.tool == .text {
            beginText(at: p)
            return
        }
        dragStart = p
        dragMark = owner.newMark(tool: owner.tool, at: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if moving { owner?.updateMove(); return }
        guard let s = dragStart, var m = dragMark else { return }
        let p = convert(event.locationInWindow, from: nil)
        m.rect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                        width: abs(p.x - s.x), height: abs(p.y - s.y))
        m.end = p
        dragMark = m
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if moving {
            moving = false
            owner?.endMove()
            NSCursor.pop()
            return
        }
        if let m = dragMark { owner?.commit(m) }
        dragMark = nil
        dragStart = nil
        needsDisplay = true
    }

    // MARK: 文字工具

    private func beginText(at p: NSPoint) {
        guard let owner else { return }
        let size = fontSize(owner.lineWidth)
        // 输入框别超出画布，也别掉出下边
        let availW = max(60, bounds.width - p.x - 8)
        let fieldW = min(availW, 320)
        let fieldH = size + 10
        let y = min(max(p.y - size, 0), max(0, bounds.height - fieldH))
        let tf = NSTextField(frame: NSRect(x: p.x, y: y, width: fieldW, height: fieldH))
        tf.font = .systemFont(ofSize: size, weight: .semibold)
        tf.textColor = owner.color
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = true
        tf.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        tf.focusRingType = .none
        tf.stringValue = ""
        tf.target = self
        tf.action = #selector(commitTextFromField(_:))
        addSubview(tf)
        textField = tf
        window?.makeFirstResponder(tf)

        NotificationCenter.default.addObserver(forName: NSControl.textDidEndEditingNotification,
                                               object: tf, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitEditingText() }
        }
    }

    @objc private func commitTextFromField(_ sender: NSTextField) {
        commitEditingText()
    }

    private func commitEditingText() {
        guard let tf = textField, let owner else { return }
        let value = tf.stringValue
        let origin = tf.frame.origin
        // 文字基线落点：文本框左下角对齐字形底部
        let p = NSPoint(x: origin.x + 2, y: origin.y + 1)
        tf.removeFromSuperview()
        textField = nil
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var m = AnnotateOverlay.Mark(tool: .text, rect: NSRect(origin: p, size: .zero),
                                     text: value, color: owner.color, lineWidth: owner.lineWidth)
        m.text = value
        owner.commit(m)
        needsDisplay = true
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        guard let owner else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 空格：按住拖动画布 → 搬动整块浮层
        if event.keyCode == 49 {
            if !spaceDown {
                spaceDown = true
                NSCursor.openHand.push()
            }
            return
        }

        if mods.contains(.command) {
            switch (event.charactersIgnoringModifiers ?? "").lowercased() {
            case "z":
                if mods.contains(.shift) { owner.redo() } else { owner.undo() }
                return
            case "s":
                owner.save()
                return
            default:
                break
            }
        }
        if event.keyCode == 53 { owner.cancel(); return }   // Esc

        if let ch = event.charactersIgnoringModifiers,
           let n = Int(ch), n >= 1, n <= 5,
           let t = AnnotateOverlay.Tool(rawValue: n - 1) {
            owner.setTool(t)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            if spaceDown {
                spaceDown = false
                NSCursor.pop()
            }
            return
        }
        super.keyUp(with: event)
    }

    // MARK: 导出

    /// 按原图像素尺寸合成，返回位图
    func flatten() -> NSBitmapImageRep? {
        guard let cg = baseCG, bounds.width > 1, bounds.height > 1 else { return nil }
        let pxW = cg.width
        let pxH = cg.height
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            let scale = CGFloat(pxW) / bounds.width
            ctx.scaleBy(x: scale, y: scale)
            render(into: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        // 让 PNG 带上正确的 DPI（= 像素/点 × 72），否则查看器会把 2x 图当 1x 放大显示 → 看着糊
        rep.size = NSSize(width: bounds.width, height: bounds.height)
        return rep
    }
}

// MARK: - 工具条

/// 轻量按钮：自己画高亮，选中时显示白色底片
@MainActor
final class MiniButton: NSView {

    enum Highlight { case background, ring }
    var highlight: Highlight = .background

    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    var isActive = true { didSet { needsDisplay = true } }
    var drawContent: ((NSRect) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected && highlight == .background {
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        if !isActive { NSGraphicsContext.current?.cgContext.setAlpha(0.3) }
        drawContent?(bounds)
        NSGraphicsContext.restoreGraphicsState()
        // 色块这类内容铺满按钮，选中态改用外圈白环，否则底片被盖住看不见
        if isSelected && highlight == .ring {
            NSColor(calibratedWhite: 0.98, alpha: 0.95).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
final class AnnotateToolbar: NSView {

    weak var owner: AnnotateOverlay?
    private var moving = false

    /// 拖工具条空白处 = 整块浮层（图 + 工具条）一起搬
    override func mouseDown(with event: NSEvent) {
        moving = true
        owner?.beginMove()
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        if moving { owner?.updateMove() }
    }
    override func mouseUp(with event: NSEvent) {
        if moving {
            moving = false
            owner?.endMove()
            NSCursor.pop()
        }
    }

    var onTool: ((AnnotateOverlay.Tool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    static let height: CGFloat = 40
    static let colors: [NSColor] = [
        NSColor(calibratedRed: 0.98, green: 0.24, blue: 0.25, alpha: 1),   // 红
        NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.04, alpha: 1),   // 橙
        NSColor(calibratedRed: 0.20, green: 0.51, blue: 1.00, alpha: 1),   // 蓝
        NSColor(calibratedWhite: 0.98, alpha: 1),                          // 白
    ]
    static let widths: [CGFloat] = [3, 5, 8]

    private enum L {
        static let pad: CGFloat = 8
        static let tool: CGFloat = 30
        static let toolGap: CGFloat = 2
        static let sepGap: CGFloat = 7
        static let color: CGFloat = 22
        static let colorGap: CGFloat = 3
        static let widthBtn: CGFloat = 24
        static let widthGap: CGFloat = 2
        static let action: CGFloat = 30
        static let actionGap: CGFloat = 2
        static let saveW: CGFloat = 54
        static let closeW: CGFloat = 26

        static var content: CGFloat {
            (5 * tool + 4 * toolGap)
            + (sepGap * 2 + 1)
            + (4 * color + 3 * colorGap)
            + (sepGap * 2 + 1)
            + (3 * widthBtn + 2 * widthGap)
            + (sepGap * 2 + 1)
            + (2 * action + actionGap)
            + sepGap
            + saveW + 6 + closeW
        }
        static var total: CGFloat { content + pad * 2 }
    }

    static var totalWidth: CGFloat { L.total }

    private var toolButtons: [MiniButton] = []
    private var colorButtons: [MiniButton] = []
    private var widthButtons: [MiniButton] = []
    private var undoBtn: MiniButton?
    private var redoBtn: MiniButton?

    private var selTool: AnnotateOverlay.Tool = .rect
    private var selColor: NSColor = AnnotateToolbar.colors[0]
    private var selWidth: CGFloat = 3
    private var canUndo = false
    private var canRedo = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: L.total, height: AnnotateToolbar.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 构建

    private static func symbolImage(_ name: String, point: CGFloat = 14,
                                    color: NSColor = NSColor(calibratedWhite: 0.96, alpha: 1)) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: point, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    private func centered(_ img: NSImage?, in rect: NSRect) {
        guard let img else { return }
        let s = img.size
        img.draw(in: NSRect(x: rect.midX - s.width / 2,
                            y: rect.midY - s.height / 2,
                            width: s.width, height: s.height))
    }

    private func add(_ v: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        v.frame = NSRect(x: x, y: y, width: w, height: h)
        addSubview(v)
    }

    private func build() {
        var x = L.pad
        let cy = (AnnotateToolbar.height - L.tool) / 2

        // 5 个工具
        for t in AnnotateOverlay.Tool.allCases {
            let b = MiniButton()
            let img = Self.symbolImage(t.symbol)
            b.drawContent = { [weak self] rect in self?.centered(img, in: rect) }
            b.onClick = { [weak self] in self?.onTool?(t) }
            b.toolTip = t.tip
            add(b, x: x, y: cy, w: L.tool, h: L.tool)
            toolButtons.append(b)
            x += L.tool + L.toolGap
        }
        x += L.sepGap - L.toolGap
        x = addSeparator(x: x)
        x += L.sepGap

        // 颜色
        let colorY = (AnnotateToolbar.height - L.color) / 2
        for c in AnnotateToolbar.colors {
            let b = MiniButton()
            b.highlight = .ring
            b.drawContent = { rect in
                let r = rect.insetBy(dx: 3.5, dy: 3.5)
                c.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            b.onClick = { [weak self] in self?.onColor?(c) }
            add(b, x: x, y: colorY, w: L.color, h: L.color)
            colorButtons.append(b)
            x += L.color + L.colorGap
        }
        x += L.sepGap - L.colorGap
        x = addSeparator(x: x)
        x += L.sepGap

        // 线宽
        for w in AnnotateToolbar.widths {
            let b = MiniButton()
            b.drawContent = { rect in
                let barH = w
                let r = NSRect(x: rect.minX + 4, y: rect.midY - barH / 2,
                               width: rect.width - 8, height: barH)
                NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
                NSBezierPath(roundedRect: r, xRadius: barH / 2, yRadius: barH / 2).fill()
            }
            b.onClick = { [weak self] in self?.onWidth?(w) }
            add(b, x: x, y: cy, w: L.widthBtn, h: L.tool)
            widthButtons.append(b)
            x += L.widthBtn + L.widthGap
        }
        x += L.sepGap - L.widthGap
        x = addSeparator(x: x)
        x += L.sepGap

        // 撤销 / 重做
        let undoImg = Self.symbolImage("arrow.uturn.backward")
        let redoImg = Self.symbolImage("arrow.uturn.forward")
        let ub = MiniButton()
        ub.drawContent = { [weak self] rect in self?.centered(undoImg, in: rect) }
        ub.onClick = { [weak self] in self?.onUndo?() }
        ub.toolTip = "撤销（⌘Z）"
        add(ub, x: x, y: cy, w: L.action, h: L.tool)
        undoBtn = ub
        x += L.action + L.actionGap

        let rb = MiniButton()
        rb.drawContent = { [weak self] rect in self?.centered(redoImg, in: rect) }
        rb.onClick = { [weak self] in self?.onRedo?() }
        rb.toolTip = "重做（⇧⌘Z）"
        add(rb, x: x, y: cy, w: L.action, h: L.tool)
        redoBtn = rb
        x += L.action + L.sepGap

        // 保存
        let save = MiniButton()
        save.drawContent = { rect in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.98, alpha: 1),
            ]
            let s = "保存" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: rect.midX - size.width / 2,
                               y: rect.midY - size.height / 2),
                   withAttributes: attrs)
        }
        save.onClick = { [weak self] in self?.onSave?() }
        save.toolTip = "保存并覆盖原图（⌘S）"
        let saveH: CGFloat = 28
        save.setFrameSize(NSSize(width: L.saveW, height: saveH))
        save.wantsLayer = true
        save.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        save.layer?.cornerRadius = saveH / 2
        save.layer?.cornerCurve = .continuous
        add(save, x: x, y: (AnnotateToolbar.height - saveH) / 2, w: L.saveW, h: saveH)
        x += L.saveW + 6

        // 关闭（=取消）
        let closeImg = Self.symbolImage("xmark", point: 12)
        let cb = MiniButton()
        cb.drawContent = { [weak self] rect in self?.centered(closeImg, in: rect) }
        cb.onClick = { [weak self] in self?.onClose?() }
        cb.toolTip = "取消（Esc）"
        add(cb, x: x, y: cy, w: L.closeW, h: L.tool)
    }

    private func addSeparator(x: CGFloat) -> CGFloat {
        let v = NSView(frame: NSRect(x: x, y: (AnnotateToolbar.height - 18) / 2, width: 1, height: 18))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        addSubview(v)
        return x + 1
    }

    // MARK: 状态同步

    func sync(tool: AnnotateOverlay.Tool, color: NSColor, width: CGFloat,
              canUndo: Bool, canRedo: Bool) {
        selTool = tool
        selColor = color
        selWidth = width
        self.canUndo = canUndo
        self.canRedo = canRedo
        for (i, b) in toolButtons.enumerated() {
            b.isSelected = (AnnotateOverlay.Tool(rawValue: i) == tool)
        }
        for (i, b) in colorButtons.enumerated() {
            b.isSelected = (AnnotateToolbar.colors[i] == color)
        }
        for (i, b) in widthButtons.enumerated() {
            b.isSelected = (AnnotateToolbar.widths[i] == width)
        }
        undoBtn?.isActive = canUndo
        redoBtn?.isActive = canRedo
    }
}
