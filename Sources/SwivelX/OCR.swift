import Foundation
import AppKit
import Vision
import ImageIO

// MARK: - OCR 引擎（Vision 本地识别，不联网）

/// 识别一律在后台队列跑：Vision 的 `perform` 是同步阻塞的，
/// 放在主线程会让整个 App 卡住（实测一张全屏截图要 2 秒以上，
/// 期间界面完全无响应，看起来就像「点了没反应」）。
enum OCREngine {

    // MARK: 入口

    /// 文件路径 → 文本（拖入的图片走这里）
    static func recognize(imageAt url: URL) async -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return "⚠️ 无法读取图片"
        }
        return await recognize(cgImage: cg)
    }

    /// 内存里的图像 → 文本（框选截图走这里，不落盘）
    static func recognize(cgImage: CGImage) async -> String {
        let box = ImageBox(cgImage)
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run(box.cgImage))
            }
        }
    }

    /// 识别后把整段文本写进剪贴板
    @MainActor
    static func copyToPasteboard(_ text: String) {
        guard isUsable(text) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 是不是一段「可以复制」的结果
    static func isUsable(_ text: String) -> Bool {
        !text.hasPrefix("⚠️") && text != "（未识别到文字）" && !text.isEmpty
    }

    // MARK: 实现

    /// CGImage 不是 Sendable，包一层带进后台队列
    private struct ImageBox: @unchecked Sendable {
        let cgImage: CGImage
        init(_ image: CGImage) { self.cgImage = image }
    }

    /// 同步识别（只在后台队列调用）
    nonisolated private static func run(_ cg: CGImage) -> String {
        var lines: [String] = []
        var failure: String?

        let request = VNRecognizeTextRequest { req, err in
            if let err {
                failure = "⚠️ 识别失败：\(err.localizedDescription)"
                return
            }
            guard let observations = req.results as? [VNRecognizedTextObservation] else {
                failure = "⚠️ 识别失败"
                return
            }
            // Vision 的 y 轴是「从下往上」，按 midY 从大到小排 = 从上到下
            lines = observations
                .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            return "⚠️ 识别失败：\(error.localizedDescription)"
        }
        if let failure { return failure }
        return lines.isEmpty ? "（未识别到文字）" : lines.joined(separator: "\n")
    }
}
