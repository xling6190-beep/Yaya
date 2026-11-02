import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - 动作定义

enum WheelAction: CaseIterable {
    case toPNG
    case toJPEG
    case toHEIC
    case compress
    case halfSize
    case rotate90
    case copyPath
    case revealInFinder

    // 新增：屏幕采集（截图/录屏）+ OCR
    case captureRegion
    case captureWindow
    case captureFull
    case startRecord
    case ocr
    case annotate

    var title: String {
        switch self {
        case .toPNG: return "转 PNG"
        case .toJPEG: return "转 JPEG"
        case .toHEIC: return "转 HEIC"
        case .compress: return "压缩"
        case .halfSize: return "缩小一半"
        case .rotate90: return "旋转 90°"
        case .copyPath: return "复制路径"
        case .revealInFinder: return "访达中显示"
        case .captureRegion: return "区域截图"
        case .captureWindow: return "窗口截图"
        case .captureFull: return "全屏截图"
        case .startRecord: return "录屏"
        case .ocr: return "识别文字"
        case .annotate: return "标注"
        }
    }

    var symbol: String {
        switch self {
        case .toPNG: return "PNG"
        case .toJPEG: return "JPG"
        case .toHEIC: return "HEIC"
        case .compress: return "⇣"
        case .halfSize: return "½"
        case .rotate90: return "⟳"
        case .copyPath: return "⌘C"
        case .revealInFinder: return "⌘R"
        case .captureRegion: return "▭"
        case .captureWindow: return "▢"
        case .captureFull: return "▣"
        case .startRecord: return "●"
        case .ocr: return "字"
        case .annotate: return "✎"
        }
    }

    /// 泡泡上的短标签
    var short: String {
        switch self {
        case .toPNG: return "PNG"
        case .toJPEG: return "JPG"
        case .toHEIC: return "HEIC"
        case .compress: return "压缩"
        case .halfSize: return "缩半"
        case .rotate90: return "旋转"
        case .copyPath: return "路径"
        case .revealInFinder: return "访达"
        case .captureRegion: return "区域"
        case .captureWindow: return "窗口"
        case .captureFull: return "全屏"
        case .startRecord: return "录屏"
        case .ocr: return "文字"
        case .annotate: return "标注"
        }
    }

    /// 泡泡里的 SF Symbol 图标
    var icon: String {
        switch self {
        case .toPNG: return "photo"
        case .toJPEG: return "photo.fill"
        case .toHEIC: return "photo.on.rectangle"
        case .compress: return "rectangle.compress.vertical"
        case .halfSize: return "aspectratio"
        case .rotate90: return "rotate.right"
        case .copyPath: return "link"
        case .revealInFinder: return "folder"
        case .captureRegion: return "crop"
        case .captureWindow: return "macwindow"
        case .captureFull: return "rectangle.inset.filled"
        case .startRecord: return "record.circle"
        case .ocr: return "text.viewfinder"
        case .annotate: return "pencil.tip.crop.circle"
        }
    }

    /// 修饰键决定轮盘内容
    /// - 无修饰（直接拖文件）：图片格式转换（保持原体验不变）
    /// - Shift：图片格式转换（同上）
    /// - Command：工具/动作
    static func set(for flags: NSEvent.ModifierFlags) -> [WheelAction] {
        if flags.contains(.command) {
            return [.compress, .halfSize, .rotate90, .copyPath, .revealInFinder, .toPNG]
        }
        return [.toPNG, .toJPEG, .toHEIC, .compress, .halfSize, .rotate90]
    }

    /// 单击宠物弹出的 Snapzy 功能圆环（截图/录屏/OCR/标注）
    static var snapzySet: [WheelAction] {
        return [.captureRegion, .captureWindow, .captureFull, .startRecord, .ocr, .annotate]
    }
}

// MARK: - 图片处理

enum FileAction {
    /// 统一的执行入口，返回结果说明
    static func run(_ action: WheelAction, on url: URL) -> String {
        switch action {
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
            return "路径已复制"

        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "已在访达中显示"

        case .toPNG:  return convert(url, to: .png)
        case .toJPEG: return convert(url, to: .jpeg, quality: 0.9)
        case .toHEIC: return convert(url, to: .heic)
        case .compress:
            return isImage(url) ? convert(url, to: .jpeg, quality: 0.6, suffix: "-compressed") : "不是图片"
        case .halfSize:
            return isImage(url) ? rescale(url, factor: 0.5) : "不是图片"
        case .rotate90:
            return isImage(url) ? rotate(url, degrees: 90) : "不是图片"

        // 屏幕采集 / OCR 类不经过 FileAction（在 AppDelegate 直接处理）
        case .captureRegion, .captureWindow, .captureFull, .startRecord, .ocr, .annotate:
            return "已处理"
        }
    }

    // MARK: 内部实现

    private static func isImage(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { return false }
        return UTType(type as String)?.conforms(to: .image) ?? false
    }

    private static func outputURL(for url: URL, ext: String, suffix: String? = nil) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let s = suffix ?? ""
        let name = "\(base)\(s).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func convert(_ url: URL, to type: UTType, quality: Double = 1.0, suffix: String? = nil) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "读取失败" }
        let ext = type.preferredFilenameExtension ?? "png"
        let dest = outputURL(for: url, ext: ext, suffix: suffix)
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else {
            return "无法创建目标文件"
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImageFromSource(dst, src, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return "写入失败" }
        return dest.lastPathComponent
    }

    private static func rescale(_ url: URL, factor: CGFloat) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "读取失败" }
        let w = max(1, Int(CGFloat(cg.width) * factor))
        let h = max(1, Int(CGFloat(cg.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "绘制失败" }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return "绘制失败" }
        let dest = outputURL(for: url, ext: "png", suffix: "-half")
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return "无法创建目标文件"
        }
        CGImageDestinationAddImage(dst, out, nil)
        guard CGImageDestinationFinalize(dst) else { return "写入失败" }
        return dest.lastPathComponent
    }

    private static func rotate(_ url: URL, degrees: CGFloat) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "读取失败" }
        let swapped = Int(degrees).magnitude % 180 == 90
        let w = swapped ? cg.height : cg.width
        let h = swapped ? cg.width : cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "绘制失败" }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -degrees * .pi / 180)
        ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2,
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard let out = ctx.makeImage() else { return "绘制失败" }
        let dest = outputURL(for: url, ext: "png", suffix: "-rot90")
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return "无法创建目标文件"
        }
        CGImageDestinationAddImage(dst, out, nil)
        guard CGImageDestinationFinalize(dst) else { return "写入失败" }
        return dest.lastPathComponent
    }
}
