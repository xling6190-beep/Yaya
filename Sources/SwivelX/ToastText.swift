import AppKit
import CoreText

// MARK: - 自绘文字视图
// NSTextField 的 label 是从框顶开始画字，框高不合适就会整体偏上。
// 这里按「字形实际墨迹范围」来对齐：水平居中时左右留白真正相等，垂直也真正居中。
// 长文本走中段截断，不会顶到容器边缘。

@MainActor
final class ToastText: NSView {

    private var content: String
    private let font: NSFont
    private var color: NSColor
    private let alignment: NSTextAlignment
    private let lineBreaks: NSLineBreakMode

    init(_ text: String,
         font: NSFont,
         color: NSColor,
         alignment: NSTextAlignment = .left,
         lineBreaks: NSLineBreakMode = .byTruncatingMiddle) {
        self.content = text
        self.font = font
        self.color = color
        self.alignment = alignment
        self.lineBreaks = lineBreaks
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 改文字（用于倒计时这类需要刷新的场景）
    var text: String {
        get { content }
        set {
            guard newValue != content else { return }
            content = newValue
            needsDisplay = true
        }
    }

    /// 改颜色（用于「已复制」这类短暂反馈）
    var textColor: NSColor {
        get { color }
        set {
            color = newValue
            needsDisplay = true
        }
    }

    private var attributed: NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lineBreaks
        return NSAttributedString(string: content, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    /// 单行文本的排版宽度，供外层算容器宽度
    var textWidth: CGFloat {
        attributed.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin]).width
    }

    override func draw(_ dirty: CGRect) {
        guard bounds.width > 1, bounds.height > 1,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        let string = attributed
        let line = CTLineCreateWithAttributedString(string)
        // 一行的排版宽度超过可用宽度时，退回普通绘制（自动中段截断）
        let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
        if advance > Double(bounds.width) + 0.5 {
            let measured = string.boundingRect(
                with: NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let y = (bounds.height - measured.height) / 2
            string.draw(with: NSRect(x: 0, y: y, width: bounds.width, height: measured.height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }

        // 墨迹范围：用 .useOpticalBounds 拿到贴合字形的矩形。
        // 不要用 CTLineGetImageBounds —— 它依赖上下文、会改动文本矩阵，
        // 同一图层里后续文字会被带着一起偏移（表现为后面的字整体右移、被裁掉）。
        let ink = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let x: CGFloat
        if alignment == .center {
            x = (bounds.width - ink.width) / 2 - ink.minX
        } else {
            x = -ink.minX
        }
        let y = (bounds.height - ink.height) / 2 - ink.minY

        ctx.saveGState()
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
