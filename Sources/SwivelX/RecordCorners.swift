import AppKit

// MARK: - 录制区域角标
// 只在选区四角画 L 形短角，画在选区**外侧**：屏幕合成里有，但选区裁剪后不会进视频。

@MainActor
final class RecordCorners {

    private var panel: NSPanel?

    func show(region: NSRect) {
        close()
        guard !region.isEmpty,
              let screen = NSScreen.screens.first(where: {
                  $0.frame.contains(NSPoint(x: region.midX, y: region.midY))
              }) ?? NSScreen.main else { return }

        let view = CornersView(frame: screen.frame)
        view.region = region

        let p = NSPanel(contentRect: screen.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        p.contentView = view
        p.setFrameOrigin(.zero)
        p.orderFrontRegardless()
        panel = p

        // 呼吸：缓慢一暗一亮，提示「正在录」
        startBreathing(on: view)
    }

    /// 录制期间四角呼吸：0.5s 由暗到亮 + 0.5s 由亮到暗，无限循环。
    /// 只动 layer 的 opacity，不重绘，几乎不耗性能。
    private func startBreathing(on view: NSView) {
        guard !MotionPreference.reduceMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.28
        anim.toValue = 1.0
        anim.duration = 0.5
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "breathe")
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

// MARK: - 绘制

private final class CornersView: NSView {

    var region: NSRect = .zero

    private let barLength: CGFloat = 22
    private let thickness: CGFloat = 1
    private let gap: CGFloat = 4

    override func draw(_ dirtyRect: NSRect) {
        guard region.width > 4, region.height > 4 else { return }

        let b = bounds

        // 贴着选区外侧；靠屏幕边缘没有空间时翻到内侧
        let leftOut = region.minX - gap - thickness >= b.minX
        let rightOut = region.maxX + gap + thickness <= b.maxX
        let bottomOut = region.minY - gap - thickness >= b.minY
        let topOut = region.maxY + gap + thickness <= b.maxY

        let outline = NSBezierPath()
        let body = NSBezierPath()

        func arm(_ r: NSRect) {
            body.appendRect(r)
            outline.appendRect(r.insetBy(dx: -0.8, dy: -0.8))
        }

        // 四个角：两臂从同一个角点出发，分别沿左右边、上下边延伸
        for isLeft in [true, false] {
            for isBottom in [true, false] {
                let cx: CGFloat = isLeft
                    ? (leftOut ? region.minX - gap : region.minX + gap)
                    : (rightOut ? region.maxX + gap : region.maxX - gap)
                let cy: CGFloat = isBottom
                    ? (bottomOut ? region.minY - gap : region.minY + gap)
                    : (topOut ? region.maxY + gap : region.maxY - gap)

                // 竖臂
                arm(NSRect(x: cx,
                           y: isBottom ? cy : cy - barLength,
                           width: thickness,
                           height: barLength))
                // 横臂
                arm(NSRect(x: isLeft ? cx : cx - barLength,
                           y: cy,
                           width: barLength,
                           height: thickness))
            }
        }

        // 与十字准星同一套：黑 55% 描边（外扩 0.8pt）+ 白 90% 本体
        NSColor.black.withAlphaComponent(0.55).setFill()
        outline.fill()
        NSColor.white.withAlphaComponent(0.90).setFill()
        body.fill()
    }
}
