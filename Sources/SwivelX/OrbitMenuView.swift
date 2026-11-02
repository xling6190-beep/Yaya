import AppKit

/// 功能扇形环 v4：围绕宠物的一圈玻璃扇区；点宠物/空白 = 收回取消
/// 样式遵循：ease-out 240ms 展开、140ms 可打断的选中过渡、三层叠加阴影、OKLCH 统一色阶
@MainActor
final class OrbitMenuView: NSView {

    private let actions: [WheelAction]
    private let urls: [URL]
    private let onConfirm: (WheelAction, [URL]) -> Void
    private let onCancelAction: () -> Void

    private var selectedIndex: Int? = nil
    private var closing = false
    private var renderTask: Task<Void, Never>?

    /// 圆环中心（本视图坐标）。默认是视图正中；
    /// 面板被系统「挤回屏幕内」而挪动时，由外层传入宠物的真实位置，保证圆心永远压在宠物身上。
    var ringCenter: CGPoint? {
        didSet { needsDisplay = true }
    }

    private let holeRadius: CGFloat = 54       // 宠物所在区
    private let outerRadius: CGFloat = 152     // 扇环外缘

    // 可打断的过渡
    /// 弹出节奏：从 0.88 起手（先淡入，不是凭空爆开）→ 1.12 → 0.975 → 1.00，共 0.32s
    /// 三段都用 easeInOut：每个转折点的速度正好是 0，接缝处不会有「速度突变」的机械感
    private let bloom = Keyframe(0)
    private var pops: [Anim] = []
    /// 动画还在跑的时候跳过阴影绘制（模糊极耗性能），停下来再补一次完整重绘
    private var animating = false
    /// 淡入起点：头 80ms 从透明浮出来
    private var appearAt = Date()

    private static let openKeys: [Keyframe.Key] = [
        Keyframe.Key(0.00, 0.880, Ease.inOut),
        Keyframe.Key(0.13, 1.120, Ease.inOut),
        Keyframe.Key(0.23, 0.975, Ease.inOut),
        Keyframe.Key(0.32, 1.000, Ease.inOut),
    ]
    private static let fadeDuration: TimeInterval = 0.08

    init(actions: [WheelAction], urls: [URL],
         onConfirm: @escaping (WheelAction, [URL]) -> Void,
         onCancel: @escaping () -> Void) {
        self.actions = actions
        self.urls = urls
        self.onConfirm = onConfirm
        self.onCancelAction = onCancel
        super.init(frame: .zero)
        pops = actions.map { _ in Anim(0, duration: Timing.selection) }
        start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    deinit { renderTask?.cancel() }

    private var center: CGPoint {
        ringCenter ?? CGPoint(x: bounds.midX, y: bounds.midY)
    }

    // MARK: 展开与重绘循环

    private func start() {
        if MotionPreference.reduceMotion {
            bloom.jump(to: 1)
            needsDisplay = true
            return
        }
        bloom.run(Self.openKeys)
        appearAt = Date()
        animating = true
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var dirty = self.bloom.tick()
                for pop in self.pops { dirty = pop.tick() || dirty }
                // 关键帧跑完的那一帧补一次完整重绘，把阴影画上
                if !dirty && self.animating {
                    self.animating = false
                    self.needsDisplay = true
                }
                if dirty { self.needsDisplay = true }
                if self.closing, self.bloom.value < 0.02 {
                    self.onCancelAction()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func retract() {
        guard !closing else { return }
        closing = true
        selectedIndex = nil
        if MotionPreference.reduceMotion {
            onCancelAction()
            return
        }
        // 收起：从当前值直接淡出，不弹
        bloom.run([
            Keyframe.Key(0.00, bloom.value, Ease.out),
            Keyframe.Key(0.18, 0.00, Ease.out),
        ])
        animating = true
    }

    // MARK: 事件（命中区 ≥ 44pt：环厚 98pt，内缘角宽 56pt）

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .assumeInside],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !closing else { return }
        let p = convert(event.locationInWindow, from: nil)
        let d = hypot(p.x - center.x, p.y - center.y)

        var newSel: Int? = nil
        if d > holeRadius && d < outerRadius + 14 {
            var angle = atan2(p.y - center.y, p.x - center.x) + .pi / 2
            if angle < 0 { angle += 2 * .pi }
            let slot = 2 * .pi / CGFloat(max(1, actions.count))
            newSel = Int(angle / slot) % actions.count
        }
        if newSel != selectedIndex {
            selectedIndex = newSel
            for (i, pop) in pops.enumerated() { pop.to(i == newSel ? 1 : 0) }
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !closing else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - center.x, p.y - center.y) <= holeRadius { retract() }
    }

    override func mouseUp(with event: NSEvent) {
        guard !closing else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - center.x, p.y - center.y) <= holeRadius { return }
        if let sel = selection { onConfirm(sel, urls) } else { retract() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { retract(); return }
        super.keyDown(with: event)
    }

    private var selection: WheelAction? {
        guard let i = selectedIndex, actions.indices.contains(i) else { return nil }
        return actions[i]
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard !actions.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 淡入：头 80ms 从透明浮出来，避免第一帧「凭空爆开」
        if !MotionPreference.reduceMotion {
            let fade = min(1, max(0, Date().timeIntervalSince(appearAt) / Self.fadeDuration))
            if fade < 1 { ctx.setAlpha(CGFloat(fade)) }
        }

        let count = actions.count
        let slot = 2 * .pi / CGFloat(count)
        let startOffset: CGFloat = -.pi / 2
        let b = bloom.value
        guard b > 0.02 else { return }

        let innerR = holeRadius
        let outerR = holeRadius + (outerRadius - holeRadius) * b

        // 动画期间跳过阴影绘制（模糊投影极耗性能，是卡顿主因），跑完再画
        let animated = animating

        // 整环投影（一次成形，避免扇区之间互相叠脏）
        if !animated {
            let ringPath = CGMutablePath()
            ringPath.addArc(center: center, radius: outerR, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            ringPath.addArc(center: center, radius: innerR, startAngle: 2 * .pi, endAngle: 0, clockwise: true)
            ringPath.closeSubpath()
            Elevation.shadow(ctx: ctx, path: ringPath, level: 2)
        }

        // 扇区
        for (i, action) in actions.enumerated() {
            let start = startOffset + CGFloat(i) * slot
            let pop = pops[i].value
            let outer = outerR + pop * 10

            let path = CGMutablePath()
            path.addArc(center: center, radius: outer, startAngle: start, endAngle: start + slot, clockwise: false)
            path.addArc(center: center, radius: innerR, startAngle: start + slot, endAngle: start, clockwise: true)
            path.closeSubpath()

            ctx.saveGState()
            if pop > 0.01 {
                if !animated { Elevation.shadow(ctx: ctx, path: path, level: 3) }
                // 选中扇区：黑透 0.75 平涂。alpha 跟着 pop 淡入，避免出现「硬切」
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.75 * Double(min(1, pop))).cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            } else {
                ctx.addPath(path)
                // 半透明扇区：透出背景，但保留玻璃质感（提到 0.62，浅色壁纸上也能看清）
                ctx.setFillColor(Palette.surface.withAlphaComponent(0.62 * Double(min(1, b))).cgColor)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }

        // 图标 + 标签（光学对齐：图标略上移，标签下沉）
        for (i, action) in actions.enumerated() {
            let pop = pops[i].value
            let mid = startOffset + CGFloat(i) * slot + slot / 2
            let labelR = (innerR + outerR) / 2
            let baseX = center.x + labelR * cos(mid)
            let baseY = center.y + labelR * sin(mid)
            let tint: NSColor = (pop > 0.5 ? Palette.onSurfaceHi : Palette.onSurface)
                .withAlphaComponent(0.78 + 0.22 * Double(min(1, b)))
            draw(symbol: action.icon,
                 in: CGRect(x: baseX - 11, y: baseY + 1, width: 22, height: 20), tint: tint)
            draw(text: action.short, at: CGPoint(x: baseX, y: baseY - 15),
                 font: .systemFont(ofSize: 10.5, weight: .medium), color: tint)
        }
    }

    // SF Symbol 缓存：symbol 名 → 已着色的最终图（避免每帧重新光栅化导致卡顿）
    private static var symbolCache: [String: NSImage] = [:]

    private func draw(symbol name: String, in rect: CGRect, tint: NSColor) {
        // tint 在展开动画中 alpha 变化极小，直接用「不透明」的稳态色缓存，展开时只做位图拷贝
        let solidTint = tint.withAlphaComponent(1.0)
        // ★ key 必须带颜色：只按图标名缓存的话，先画了未选中的深色版，
        //   选中时的白色版会直接复用这张深色图 → 图标变成黑乎乎一片
        let cacheKey = Self.cacheKey(name: name, tint: solidTint)
        let img: NSImage
        if let cached = Self.symbolCache[cacheKey] {
            img = cached
        } else {
            guard let base = NSImage(systemSymbolName: name, variableValue: 1, accessibilityDescription: nil) else { return }
            let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [solidTint]))
            guard let rendered = base.withSymbolConfiguration(config) else { return }
            Self.symbolCache[cacheKey] = rendered
            img = rendered
        }
        // 动画中的透明度变化，用绘制时的 alpha 体现
        let size = img.size
        img.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height),
                 from: .zero, operation: .sourceOver,
                 fraction: tint.alphaComponent)
    }

    private static func cacheKey(name: String, tint: NSColor) -> String {
        let c = tint.usingColorSpace(.sRGB) ?? tint
        return String(format: "%@|%.3f/%.3f/%.3f", name,
                      c.redComponent, c.greenComponent, c.blueComponent)
    }

    private func draw(text: String, at point: CGPoint, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attrs)
    }
}
