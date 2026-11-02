import AppKit
import CoreGraphics

// MARK: - OKLCH → sRGB（含色域钳制）
// OKLCH 感知均匀：L 等距 = 亮度等距，色相不随明暗漂移。整套配色建立在同一色阶上。

extension NSColor {
    convenience init(oklchL L: Double, chroma C: Double, hue H: Double, alpha: Double = 1) {
        let h = H * .pi / 180
        let a = C * cos(h)
        let b = C * sin(h)

        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        let lr =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        func enc(_ v: Double) -> CGFloat {
            let c = min(max(v, 0), 1)                       // 色域钳制
            return CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
        }
        self.init(srgbRed: enc(lr), green: enc(lg), blue: enc(lb), alpha: alpha)
    }
}

// MARK: - 配色（同一色阶：绿果冻宠物 + 同色系绿色选中态）

enum Palette {
    // 宠物（薄荷绿水晶果冻）
    static let petBody     = NSColor(oklchL: 0.88, chroma: 0.13, hue: 128)   // 顶部浅薄荷（略偏黄绿）
    static let petShade    = NSColor(oklchL: 0.70, chroma: 0.15, hue: 135)   // 底部深绿
    static let petGlow     = NSColor(oklchL: 0.95, chroma: 0.09, hue: 130, alpha: 0.45)  // 顶部内透光
    static let petEdge     = NSColor(oklchL: 0.52, chroma: 0.13, hue: 138, alpha: 0.70)  // 明显深绿描边
    static let petRim      = NSColor(oklchL: 0.92, chroma: 0.10, hue: 118, alpha: 0.35)  // 黄绿反光斑
    static let gloss       = NSColor(oklchL: 1.0, chroma: 0, hue: 0, alpha: 0.50)        // 大高光
    static let leaf        = NSColor(oklchL: 0.74, chroma: 0.19, hue: 120)   // 嫩芽叶（草绿）
    static let leafShade   = NSColor(oklchL: 0.56, chroma: 0.16, hue: 128)
    static let leafHi      = NSColor(oklchL: 0.90, chroma: 0.12, hue: 118, alpha: 0.85)
    static let eyeWhite    = NSColor(oklchL: 0.995, chroma: 0.003, hue: 150)
    static let iris        = NSColor(oklchL: 0.72, chroma: 0.17, hue: 105)   // 黄绿虹膜环
    static let eye         = NSColor(oklchL: 0.22, chroma: 0.06, hue: 135)   // 深墨绿瞳孔（近黑绿）/闭眼线
    static let mouth       = NSColor(oklchL: 0.36, chroma: 0.10, hue: 130)
    static let tongue      = NSColor(oklchL: 0.66, chroma: 0.17, hue: 20)
    static let sparkle     = NSColor(oklchL: 0.98, chroma: 0.02, hue: 90)

    // 仓鼠（奶油色卡通）
    static let hamBody     = NSColor(oklchL: 0.90, chroma: 0.06, hue: 85)    // 奶油米色
    static let hamCap      = NSColor(oklchL: 0.74, chroma: 0.08, hue: 75)    // 头顶浅棕
    static let hamCheek    = NSColor(oklchL: 0.96, chroma: 0.04, hue: 85)    // 腮帮奶黄
    static let hamBelly    = NSColor(oklchL: 0.985, chroma: 0.02, hue: 85)   // 肚皮近白
    static let hamInnerEar = NSColor(oklchL: 0.52, chroma: 0.09, hue: 55)    // 内耳深棕
    static let hamEye      = NSColor(oklchL: 0.16, chroma: 0.02, hue: 60)    // 眼睛深棕黑
    static let hamNose     = NSColor(oklchL: 0.45, chroma: 0.09, hue: 50)    // 鼻子深棕
    static let hamOutline  = NSColor(oklchL: 0.20, chroma: 0.03, hue: 55)    // 黑色粗描边
    static let hamTongue   = NSColor(oklchL: 0.66, chroma: 0.17, hue: 20)    // 舌头

    // 猫头（奶油灰）
    static let catFur      = NSColor(oklchL: 0.82, chroma: 0.04, hue: 70)    // 奶油灰主体
    static let catMuzzle   = NSColor(oklchL: 0.97, chroma: 0.02, hue: 75)    // 口鼻白区
    static let catInnerEar = NSColor(oklchL: 0.80, chroma: 0.09, hue: 25)    // 粉色内耳
    static let catEyeDark  = NSColor(oklchL: 0.28, chroma: 0.06, hue: 45)    // 虹膜上（深棕）
    static let catEyeLight = NSColor(oklchL: 0.55, chroma: 0.12, hue: 50)    // 虹膜下（焦糖棕）
    static let catNose     = NSColor(oklchL: 0.78, chroma: 0.10, hue: 22)    // 粉红鼻
    static let catLine     = NSColor(oklchL: 0.50, chroma: 0.10, hue: 25)    // ω嘴/眼线深红棕
    static let catBlush    = NSColor(oklchL: 0.82, chroma: 0.08, hue: 20, alpha: 0.55)  // 腮红

    // 扇环
    static let surface     = NSColor(oklchL: 0.99, chroma: 0.004, hue: 250)
    static let surfaceEdge = NSColor(oklchL: 0.30, chroma: 0.02, hue: 260, alpha: 0.08)
    static let divider     = NSColor(oklchL: 1.0, chroma: 0.0, hue: 0, alpha: 0.55)
    static let accent      = NSColor(oklchL: 0.62, chroma: 0.19, hue: 285)   // 紫色高亮（适配淡紫玻璃风）
    static let accentHi    = NSColor(oklchL: 0.74, chroma: 0.16, hue: 285)
    static let onSurface   = NSColor(oklchL: 0.28, chroma: 0.02, hue: 260)
    static let onSurfaceHi = NSColor(oklchL: 0.99, chroma: 0.0, hue: 0)
}

// MARK: - 阴影：三层叠加表达高度（描边表达结构/状态）

enum Elevation {
    /// level 1 = 贴地，2 = 浮起，3 = 选中/拖拽中
    static func shadow(ctx: CGContext, path: CGPath, level: Int) {
        let layers: [(offset: CGFloat, blur: CGFloat, alpha: CGFloat)] = {
            switch level {
            case 1: return [(1, 2, 0.06), (2, 6, 0.06), (4, 14, 0.10)]
            case 3: return [(3, 6, 0.10), (8, 20, 0.14), (18, 44, 0.18)]
            default: return [(2, 4, 0.08), (4, 12, 0.09), (10, 28, 0.12)]
            }
        }()

        for (i, layer) in layers.enumerated() {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -layer.offset),
                          blur: layer.blur,
                          color: NSColor(oklchL: 0.25, chroma: 0.02, hue: 260, alpha: layer.alpha).cgColor)
            // 用极淡的填充把阴影“打”出来，只保留阴影本身
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.002 + 0.001 * CGFloat(i)).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}
