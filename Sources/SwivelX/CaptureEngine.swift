import Foundation
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import CoreMedia
import AVFoundation
import ImageIO

extension Notification.Name {
    /// 录屏被系统侧停止（用户点了系统「停止共享」按钮）
    static let yayaRecordingExternallyStopped = Notification.Name("yayaRecordingExternallyStopped")
}

// MARK: - 采集引擎：截图 + 录屏（ScreenCaptureKit）
// 单一数据源：所有屏幕采集都走这里。截图输出 PNG，录屏输出 MP4（系统音频 + 麦克风）。
// CaptureEngine 运行在主 actor（由 AppDelegate 驱动）；ScreenRecorder 是独立线程安全对象（@unchecked Sendable）。

/// 区域截图的「只取图不落盘」结果，供 OCR 这类不想要文件的场景用
enum RegionShot {
    case cancelled
    case failed(String)
    case image(CGImage)
}

@MainActor
final class CaptureEngine {

    static let shared = CaptureEngine()

    enum CaptureMode: String, CaseIterable {
        case region   // 区域（拖拽框选）
        case window   // 窗口（点选）
        case full     // 全屏

        var title: String {
            switch self {
            case .region: return "区域截图"
            case .window: return "窗口截图"
            case .full:   return "全屏截图"
            }
        }
    }

    private var recorder: ScreenRecorder?
    /// 预热缓存的显示器对象，省掉每次采集前的 SCShareableContent 拉取
    private var cachedDisplay: SCDisplay?
    /// 最近一次区域截图的选区（屏幕坐标），标注浮层要靠它定位
    private(set) var lastRegion: NSRect?
    /// 最近一次采集用的像素比（写 PNG 的 DPI 要用，否则查看器会把 2x 图当 1x 放大显示）
    private(set) var lastPixelScale: CGFloat = 2
    /// 窗口选择面板（活着的期间由单例持有，关闭时清空）
    private var pickerPanel: OverlayPanel?

    var isRecording: Bool { recorder != nil }

    // MARK: 权限

    /// 请求屏幕录制权限（首次会弹系统授权框）
    func ensurePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // 主动请求（首次会弹框；若已弹过则静默返回 false）
        CGRequestScreenCaptureAccess()
        // 短轮询等待授权
        for _ in 0..<20 {  // 最多等 ~4 秒
            if CGPreflightScreenCaptureAccess() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // 仍未授权：直接打开系统「屏幕录制」设置页，引导用户手动开启
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: 输出目录

    /// 截图保存目录：桌面（与录屏输出位置一致）
    private func picturesDir() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }

    // MARK: 截图

    /// 冻结画面用的全屏快照（区域选择时当底图，也是放大镜的数据源）
    /// 为了缩短「按下快捷键 → 画面定格」的时差，SCDisplay 会缓存预热，
    /// 避免每次都要先拉一遍 SCShareableContent（那一步通常要 100ms 以上）。
    func snapshotFullScreen() async -> CGImage? {
        if cachedDisplay == nil {
            await warmUpCapture()
        }
        guard let display = cachedDisplay else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // ★ SCDisplay.width 返回的是「点」，不是像素；要乘屏幕的 backingScaleFactor 才是真实像素，
        //   否则 Retina 上抓到的是一半分辨率（放大后发虚）。
        let scale = Self.pixelScale(for: Self.screen(matching: display))
        lastPixelScale = scale
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = false
        config.capturesAudio = false
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: config)
        } catch {
            NSLog("[Yaya] 冻结快照失败：%@", error.localizedDescription)
            cachedDisplay = nil
            return nil
        }
    }

    /// 预热：提前取好显示器对象，供快照/录屏直接使用
    func warmUpCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedDisplay = content.displays.first
        } catch {
            NSLog("[Yaya] 采集预热失败：%@", error.localizedDescription)
        }
    }

    /// 异步抓取一张截图（全屏 / 指定窗口 / 指定区域），返回保存路径
    func capture(mode: CaptureMode, adjustable: Bool = false) async -> String {
        // 全屏：直接用「定格快照」，保证截到的就是点下去那一瞬的画面
        if mode == .full {
            if let frozen = await snapshotFullScreen() { return saveImage(frozen) }
            return "⚠️ 截图失败：拿不到屏幕内容"
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            let filter: SCContentFilter
            var region: CGRect? = nil
            var window: SCWindow? = nil

            switch mode {
            case .full:
                filter = SCContentFilter(display: content.displays[0],
                                         excludingWindows: [])
            case .window:
                guard let w = await pickWindow(from: content) else { return "已取消" }
                window = w
                filter = SCContentFilter(desktopIndependentWindow: w)
            case .region:
                let r = await RegionSelector.shared.pick(adjustable: adjustable)
                guard let r else { return "已取消" }
                lastRegion = r
                region = r
                // 只排除「刚刚那个覆盖全屏的选框浮层」，不要排除 Yaya 的全部窗口：
                // 提示条、录完卡片、宠物都是用户可能想截的内容，排掉就截不到了。
                let selectorID = RegionSelector.shared.lastPanelWindowID
                let own = selectorID.map { id in
                    content.windows.filter { $0.windowID == id }
                } ?? []
                filter = SCContentFilter(display: content.displays[0],
                                         excludingWindows: own)
            }

            let config = SCStreamConfiguration()
            let display = content.displays[0]
            // ★ 像素比必须取屏幕的 backingScaleFactor。
            //   原来用 display.width / screen.frame.width —— SCDisplay 给的是点，这个比值恒为 1，
            //   结果整张图按 1x 输出，Retina 上放大后就是糊的。
            let hostScreen = region.flatMap { Self.screen(containing: $0) } ?? Self.screen(matching: display) ?? NSScreen.main
            let pxScale = Self.pixelScale(for: hostScreen)
            lastPixelScale = pxScale
            // 选区同样要换算成显示器左上角原点（y 向下），并按像素比放大
            if let r = region, let s = hostScreen {
                config.sourceRect = Self.displayLocalRect(r, on: s)
                config.width = Int((r.width * pxScale).rounded())
                config.height = Int((r.height * pxScale).rounded())
            } else if let w = window {
                config.width = Int((w.frame.width * pxScale).rounded())
                config.height = Int((w.frame.height * pxScale).rounded())
            } else {
                config.width = Int((CGFloat(display.width) * pxScale).rounded())
                config.height = Int((CGFloat(display.height) * pxScale).rounded())
            }
            config.showsCursor = true
            config.capturesAudio = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                     configuration: config)
            return saveImage(cgImage)

        } catch {
            let ns = error as NSError
            // 权限错误码（-3821 系统停止 / -3805 连接中断 / 未授权）
            if ns.code == -3821 || ns.code == -3805 || ns.domain.contains("ScreenCaptureKit") {
                return "⚠️ 未获得屏幕录制权限，请到 系统设置 → 隐私与安全性 → 录屏与系统录音 开启 Yaya"
            }
            return "⚠️ 截图失败：\(error.localizedDescription)"
        }
    }

    /// 区域截图，但只把图交回去：不写桌面、不动剪贴板。
    /// 「文字」识别用这条——原来复用 `capture(.region)` 会在桌面留下一张截图。
    func captureRegionImage() async -> RegionShot {
        guard let r = await RegionSelector.shared.pick() else { return .cancelled }
        lastRegion = r

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return .failed("⚠️ 未找到显示器") }
            // 只排除刚关掉的选框浮层（详见 capture(.region) 的说明）
            let selectorID = RegionSelector.shared.lastPanelWindowID
            let own = selectorID.map { id in
                content.windows.filter { $0.windowID == id }
            } ?? []
            let filter = SCContentFilter(display: display, excludingWindows: own)

            let config = SCStreamConfiguration()
            let hostScreen = Self.screen(containing: r) ?? Self.screen(matching: display) ?? NSScreen.main
            let pxScale = Self.pixelScale(for: hostScreen)
            lastPixelScale = pxScale
            if let s = hostScreen {
                config.sourceRect = Self.displayLocalRect(r, on: s)
                config.width = Int((r.width * pxScale).rounded())
                config.height = Int((r.height * pxScale).rounded())
            }
            config.showsCursor = false
            config.capturesAudio = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: config)
            return .image(image)
        } catch {
            let ns = error as NSError
            if ns.code == -3821 || ns.code == -3805 || ns.domain.contains("ScreenCaptureKit") {
                return .failed("⚠️ 未获得屏幕录制权限，请到 系统设置 → 隐私与安全性 → 录屏与系统录音 开启 Yaya")
            }
            return .failed("⚠️ 截图失败：\(error.localizedDescription)")
        }
    }

    /// 写 PNG 到桌面 + 复制到剪贴板，返回文件路径
    func saveImage(_ cgImage: CGImage) -> String {
        let dir = picturesDir()
        let name = "截图 \(timestamp()).png"
        let dest = dir.appendingPathComponent(name)
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL,
                                                        UTType.png.identifier as CFString,
                                                        1, nil) else {
            return "⚠️ 无法创建文件"
        }
        // ★ 必须写 DPI：不写的话查看器按「1 像素 = 1 点」显示，
        //   Retina 上会被再放大一倍 → 明明图是 2x 的，看着却糊。
        let scale = lastPixelScale
        let dpi = 72.0 * Double(scale)
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dst, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return "⚠️ 写入失败" }

        // 复制到剪贴板，方便直接粘贴（逻辑尺寸按点算，粘到别处不会变成 2 倍大）
        let pb = NSPasteboard.general
        pb.clearContents()
        let nsImage = NSImage(cgImage: cgImage,
                              size: NSSize(width: CGFloat(cgImage.width) / scale,
                                           height: CGFloat(cgImage.height) / scale))
        pb.writeObjects([nsImage])

        return dest.path
    }

    /// 弹出一个窗口选择器（黑透列表），用户点选；Esc / 取消按钮退出
    private func pickWindow(from content: SCShareableContent) async -> SCWindow? {
        // 过滤掉自己 + 太小的窗口（菜单、状态项、无边框弹层）
        let windows = content.windows.filter { w in
            guard let app = w.owningApplication else { return false }
            return app.applicationName != "Yaya" && w.frame.width > 60 && w.frame.height > 60
        }
        guard !windows.isEmpty else { return nil }

        NSApp.activate(ignoringOtherApps: true)

        var resumed = false
        let pickedID: CGWindowID? = await withCheckedContinuation { cont in
            // 收尾统一走这里：先关面板（避免自己的界面留在屏幕上），再放行等待方。
            // resumed 闸门保证「点选」和「取消」不会双发。
            let finish: (CGWindowID?) -> Void = { id in
                guard !resumed else { return }
                resumed = true
                self.pickerPanel?.orderOut(nil)
                self.pickerPanel = nil
                cont.resume(returning: id)
            }

            let picker = WindowPickerView(windows: windows)
            let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: picker.frame.size),
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = picker
            self.pickerPanel = panel

            picker.onSelect = { w in finish(w.windowID) }
            picker.onCancel = { finish(nil) }
            // 点面板外面（切到别的应用）= 取消
            panel.onResignKey = { finish(nil) }

            // 居中到「鼠标所在那块屏」，而不是固定主屏
            let mouse = NSEvent.mouseLocation
            let host = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let area = host?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2,
                                         y: area.midY - panel.frame.height / 2))
            NSApp.activate(ignoringOtherApps: true)   // 先激活，点别处才会 resignKey
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(picker)
        }
        return windows.first { $0.windowID == pickedID }
    }

    // MARK: 录屏

    // MARK: 屏幕与像素比

    /// 真实像素比。SCDisplay.width / SCWindow.frame 都是「点」，不是像素；
    /// 直接相除得到的永远是 1，必须用屏幕的 backingScaleFactor。
    static func pixelScale(for screen: NSScreen?) -> CGFloat {
        max(1, screen?.backingScaleFactor ?? 2)
    }

    /// 某个全局坐标点落在哪块屏
    static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
            ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
    }

    /// SCDisplay 对应的 NSScreen（尺寸一致即可）
    static func screen(matching display: SCDisplay) -> NSScreen? {
        let w = CGFloat(display.width), h = CGFloat(display.height)
        return NSScreen.screens.first {
            abs($0.frame.width - w) < 1 && abs($0.frame.height - h) < 1
        } ?? NSScreen.main
    }

    /// 把屏幕全局坐标（左下原点、y 向上）的选区，换算成 ScreenCaptureKit
    /// 需要的「显示器左上角为原点、y 向下」的点坐标
    static func displayLocalRect(_ r: NSRect, on screen: NSScreen) -> CGRect {        let f = screen.frame
        return CGRect(x: r.minX - f.minX,
                      y: f.height - (r.maxY - f.minY),
                      width: r.width,
                      height: r.height)
    }

    /// 开始录屏。region 为 nil 时录整块屏幕；否则只录该选区（屏幕全局坐标）。
    func startRecording(region: NSRect? = nil, screen: NSScreen? = nil) async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return "⚠️ 未找到显示器" }
            let host = screen ?? NSScreen.main

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()

            // 选区 → 裁剪。宽高按屏幕的真实像素比换算（Retina 2x），并强制偶数（H.264 要求）
            let scale = Self.pixelScale(for: host ?? Self.screen(matching: display))
            var pixelW = Int((CGFloat(display.width) * scale).rounded())
            var pixelH = Int((CGFloat(display.height) * scale).rounded())
            if let r = region, let s = host, r.width >= 8, r.height >= 8 {
                config.sourceRect = Self.displayLocalRect(r, on: s)
                pixelW = Int((r.width * scale).rounded())
                pixelH = Int((r.height * scale).rounded())
            }
            pixelW = max(2, pixelW - pixelW % 2)
            pixelH = max(2, pixelH - pixelH % 2)
            config.width = pixelW
            config.height = pixelH
            config.scalesToFit = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2

            let rec = ScreenRecorder()
            rec.onExternallyStopped = { [weak self] in
                NSLog("[Yaya] onExternallyStopped 触发")
                Task { @MainActor [weak self] in
                    // 系统侧停止（用户点了「停止共享」）：复位状态 + 提示
                    if self?.recorder === rec { self?.recorder = nil }
                    NotificationCenter.default.post(name: .yayaRecordingExternallyStopped, object: nil)
                }
            }
            try await rec.start(filter: filter, config: config)
            recorder = rec
            NSLog("[Yaya] 录屏已开始")
            return "🔴 开始录制"
        } catch {
            let ns = error as NSError
            if ns.code == -3821 || ns.code == -3805 || ns.domain.contains("ScreenCaptureKit") {
                return "⚠️ 未获得屏幕录制权限，请到 系统设置 → 隐私与安全性 → 录屏与系统录音 开启 Yaya"
            }
            return "⚠️ 录制失败：\(error.localizedDescription)"
        }
    }

    func stopRecording() async -> String {
        guard let rec = recorder else { return "当前没有录制" }
        recorder = nil
        return await rec.stop()
    }
}

// MARK: - 录屏实现（ScreenCaptureKit 官方录制输出，macOS 15+）
// 不再手工管 AVAssetWriter：编码、音轨、封装全部交给 SCRecordingOutput。

final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var completion: CheckedContinuation<String, Never>?
    private var finished = false
    /// 已经落定的结果（正常完成或失败）；再次 stop 时直接返回它
    private var terminalResult: String?
    private let lock = NSLock()

    /// 系统侧停止（用户点系统「停止共享」按钮）时回调，通知引擎复位状态
    var onExternallyStopped: (() -> Void)?

    func start(filter: sending SCContentFilter, config: sending SCStreamConfiguration) async throws {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("录屏 \(f.string(from: Date())).mp4")
        outputURL = url

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mp4
        recConfig.videoCodecType = .h264

        let output = SCRecordingOutput(configuration: recConfig, delegate: self)
        recordingOutput = output

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addRecordingOutput(output)
        stream = s
        try await s.startCapture()
        NSLog("[Yaya] 录制输出已启动 → %@", url.lastPathComponent)
    }

    func stop() async -> String {
        guard stream != nil else { return "⚠️ 没有在录" }
        return await withCheckedContinuation { cont in
            lock.lock()
            if finished {
                let r = terminalResult ?? "⚠️ 已结束"
                lock.unlock()
                cont.resume(returning: r)
                return
            }
            completion = cont
            lock.unlock()

            // 停止采集；文件收尾由 recordingOutputDidFinishRecording 回调告知
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.stream?.stopCapture()
                    NSLog("[Yaya] stopCapture 完成，等待录制输出收尾")
                } catch {
                    NSLog("[Yaya] stopCapture 出错：%@", error.localizedDescription)
                    self.finish(with: "⚠️ 停止失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func finish(with result: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        terminalResult = result
        let c = completion
        completion = nil
        lock.unlock()
        c?.resume(returning: result)
    }

    // MARK: - SCRecordingOutputDelegate

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        NSLog("[Yaya] 录制输出已开始写入")
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let e = error as NSError
        NSLog("[Yaya] 录制输出失败 domain=%@ code=%d desc=%@",
              e.domain, e.code, e.localizedDescription)
        finish(with: "⚠️ 录制失败：\(e.localizedDescription)")
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let path = outputURL?.path ?? ""
        NSLog("[Yaya] 录制输出完成 → %@", path)
        finish(with: path.isEmpty ? "⚠️ 没有生成文件" : path)
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let e = error as NSError
        NSLog("[Yaya] didStopWithError code=%d desc=%@", e.code, e.localizedDescription)
        onExternallyStopped?()
    }
}

// MARK: - 窗口选择器

/// 黑透列表式窗口选择器：标题栏（选择窗口 / 取消）+ 可滚动窗口列表。
/// 点行即截，Esc 或「取消」退出——两条路径都会回到 CaptureEngine 的 finish 闸门。
@MainActor
final class WindowPickerView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    var onSelect: ((SCWindow) -> Void)?
    var onCancel: (() -> Void)?

    private let windows: [SCWindow]
    private let tableView = NSTableView()

    private let headerH: CGFloat = 42
    private let rowH: CGFloat = 44
    private let panelW: CGFloat = 360

    /// 翻转坐标：y 从顶往下数，布局好算
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: 拖动（按住标题栏拖走整块面板）

    private var dragMouse: NSPoint?
    private var dragFrame: NSPoint?

    override func mouseDown(with event: NSEvent) {
        // 只有标题栏区域可拖，列表区域留给表格自己处理
        let p = convert(event.locationInWindow, from: nil)
        guard p.y <= headerH else { return super.mouseDown(with: event) }
        dragMouse = NSEvent.mouseLocation
        dragFrame = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragMouse, let origin = dragFrame, let win = window else {
            return super.mouseDragged(with: event)
        }
        // 用屏幕坐标算位移：窗口一动，locationInWindow 就变了，会漂
        let now = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: origin.x + (now.x - start.x),
                                   y: origin.y + (now.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        dragMouse = nil
        dragFrame = nil
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: headerH),
                      cursor: .openHand)
    }

    init(windows: [SCWindow]) {
        self.windows = windows
        // 高度按行数自适应：标题栏 + 每行 44，夹在 190~470 之间，超了滚动
        let rows = CGFloat(windows.count)
        let h = min(max(headerH + rows * rowH + 8, 190), 470)
        super.init(frame: NSRect(x: 0, y: 0, width: panelW, height: h))

        // 与 Yaya 其它浮层同一套：黑 75% 底 + 12pt 连续圆角
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        buildHeader()
        buildList(height: h)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildHeader() {
        let title = NSTextField(labelWithString: "选择窗口")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        title.frame = NSRect(x: 16, y: 13, width: 180, height: 17)
        addSubview(title)

        let cancel = NSButton(title: "", target: self, action: #selector(cancelTapped))
        cancel.isBordered = false
        cancel.attributedTitle = NSAttributedString(string: "取消", attributes: [
            .foregroundColor: NSColor(calibratedWhite: 0.70, alpha: 1),
            .font: NSFont.systemFont(ofSize: 12.5)
        ])
        cancel.frame = NSRect(x: bounds.width - 62, y: 11, width: 48, height: 20)
        cancel.autoresizingMask = [.minXMargin]
        addSubview(cancel)

        // 标题栏下的 1 物理像素分隔线
        let hair = NSView(frame: NSRect(x: 0, y: headerH - 0.5,
                                        width: bounds.width, height: 0.5))
        hair.wantsLayer = true
        hair.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        hair.autoresizingMask = [.width]
        addSubview(hair)
    }

    private func buildList(height h: CGFloat) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: headerH,
                                                width: bottomWidth,
                                                height: h - headerH))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("win"))
        col.resizingMask = .autoresizingMask
        col.width = bottomWidth
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = rowH
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        // 单击即选（action 在 mouseUp 触发，比 selectionDidChange 更可靠）
        tableView.target = self
        tableView.action = #selector(rowClicked)

        // 关键：给表格真实尺寸再 reloadData，否则 documentView 是 0×0，一行都不显示
        tableView.frame = NSRect(x: 0, y: 0,
                                 width: bottomWidth,
                                 height: CGFloat(windows.count) * rowH)
        scroll.documentView = tableView
        tableView.reloadData()
    }

    private var bottomWidth: CGFloat {
        bounds.width > 0 ? bounds.width : panelW
    }

    // MARK: 交互

    @objc private func cancelTapped() { onCancel?() }

    @objc private func rowClicked() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < windows.count else { return }
        onSelect?(windows[row])
    }

    /// Esc：表格在响应链上会把这个动作递上来
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }

    // MARK: 数据源

    func numberOfRows(in tableView: NSTableView) -> Int { windows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PickerRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("WindowRowCell")
        let cell: WindowRowCell
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? WindowRowCell {
            cell = reused
        } else {
            cell = WindowRowCell(frame: .zero)
            cell.identifier = id
        }

        let w = windows[row]
        let app = w.owningApplication
        cell.iconView.image = Self.appIcon(pid: app?.processID)
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        let rawTitle = (w.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        cell.titleLabel.stringValue = rawTitle.isEmpty ? "（无标题窗口）" : rawTitle
        cell.appLabel.stringValue = app?.applicationName ?? "未知"
        return cell
    }

    /// 应用图标：拿不到就返回 nil，由 cell 用 SF Symbol 兜底
    private static func appIcon(pid: pid_t?) -> NSImage? {
        guard let pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }
}

// MARK: - 列表行

/// 一行：应用图标 + 窗口标题 + 应用名（两行文字，标题优先）
@MainActor
final class WindowRowCell: NSTableCellView {

    override var isFlipped: Bool { true }

    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let appLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        appLabel.font = .systemFont(ofSize: 11)
        appLabel.textColor = NSColor(calibratedWhite: 0.56, alpha: 1)
        appLabel.lineBreakMode = .byTruncatingTail
        addSubview(appLabel)

        imageView = iconView
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 尺寸在 layout 里算，不靠 autoresizing 猜比例（旧版就是这里把文字挤没的）
    override func layout() {
        super.layout()
        let w = bounds.width
        let textX: CGFloat = 44
        iconView.frame = NSRect(x: 14, y: (bounds.height - 20) / 2, width: 20, height: 20)
        titleLabel.frame = NSRect(x: textX, y: 6, width: max(0, w - textX - 14), height: 16)
        appLabel.frame = NSRect(x: textX, y: 23, width: max(0, w - textX - 14), height: 13)
    }
}

/// 行高亮：系统蓝在黑底上太跳，换成白色 12% 的圆角块
final class PickerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let r = bounds.insetBy(dx: 6, dy: 3)
        NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
    }
}
