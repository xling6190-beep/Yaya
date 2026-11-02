import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem?
    private var petPanel: NSPanel?
    private var petView: PetView?
    private var orbitPanel: OrbitPanel?
    private var toastPanel: NSPanel?
    private var outsideClickMonitor: Any?
    private var recordingBar: RecordingBar?
    private var recordCorners: RecordCorners?
    private var recordedFileURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        showPet()
        // 全局快捷键：先把触发回调挂好，再按已保存的配置注册
        HotKeyCenter.shared.onTrigger = { [weak self] action in
            self?.runHotKey(action)
        }
        HotKeyCenter.shared.installIfNeeded()
        // 启动时主动请求录屏权限：把 Yaya 加入系统「屏幕录制」列表（否则不弹框）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = CGRequestScreenCaptureAccess()
        }
        // 静默系统通知：让「录屏已保存」也能出现在通知中心里（自绘浮层进不去）
        SystemNotifier.shared.start()
        // 监听系统侧停止录屏（用户点「停止共享」），复位并提示
        NotificationCenter.default.addObserver(forName: .yayaRecordingExternallyStopped,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.petView?.recording = false
                self.recordingBar?.close()
                self.recordingBar = nil
                self.recordCorners?.close()
                self.recordCorners = nil
                self.showResultToast("⏹ 录制已停止")
            }
        }
        // 后台预热 SF Symbol：把首次冷加载提前到启动，避免第一次点宠物弹圆环时卡顿
        Task.detached(priority: .background) {
            let names = WheelAction.allCases.map(\.icon)
            for n in names {
                _ = NSImage(systemSymbolName: n, variableValue: 1, accessibilityDescription: nil)
            }
        }
        // 预热采集：提前取好显示器对象，按下区域截图时能更快定格画面
        Task { await CaptureEngine.shared.warmUpCapture() }
    }

    // MARK: 菜单栏入口（应用本体不可见）

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let img = loadMenuBarImage() {
                img.isTemplate = false
                button.image = img
                button.imagePosition = .imageOnly
            } else {
                button.title = "🐱"
            }
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Yaya 1.0 — yaya很能干！", action: nil, keyEquivalent: "")

        let captureSub = NSMenu()
        let regionItem = NSMenuItem(title: "区域截图", action: #selector(menuCaptureRegion), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "窗口截图", action: #selector(menuCaptureWindow), keyEquivalent: "")
        let fullItem = NSMenuItem(title: "全屏截图", action: #selector(menuCaptureFull), keyEquivalent: "")
        captureSub.addItem(regionItem)
        captureSub.addItem(windowItem)
        captureSub.addItem(fullItem)

        let captureParent = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        captureParent.submenu = captureSub
        menu.addItem(captureParent)

        menu.addItem(withTitle: "录屏", action: #selector(menuRecord), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Yaya", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func loadMenuBarImage() -> NSImage? {
        guard let res = Bundle.main.resourceURL else { return nil }
        // ★ 必须手工把 1x / 2x 两个 rep 装进同一个 NSImage。
        //   NSImage(contentsOf:) 不会自动关联 menubar@2x.png，
        //   Retina 上就只能把 18px 拉成 36px —— 也就是图标发糊的原因。
        let image = NSImage(size: NSSize(width: 18, height: 18))
        var added = false
        for name in ["menubar.png", "menubar@2x.png"] {
            let url = res.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: 18, height: 18)   // 两个 rep 的逻辑尺寸都是 18pt
            image.addRepresentation(rep)
            added = true
        }
        return added ? image : nil
    }

    // MARK: 宠物

    private func showPet() {
        let pet = PetView(frame: NSRect(x: 0, y: 0, width: 84, height: 84))
        pet.onFiles = { [weak self] urls, flags, screenPoint in
            self?.showOrbit(urls: urls, flags: flags, at: screenPoint)
        }
        pet.onSingleClick = { [weak self] screenPoint in
            self?.showSnapzyOrbit(at: screenPoint)
        }

        let panel = NSPanel(contentRect: pet.bounds,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 关闭背景拖动：宠物位置改由 PetView 手写「按住拖动」控制，避免与「单击弹圆环」冲突
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.contentView = pet
        petView = pet

        var origin = NSPoint(x: (NSScreen.main?.frame.maxX ?? 1400) - 110,
                             y: (NSScreen.main?.frame.minY ?? 200) + 140)
        if let saved = UserDefaults.standard.object(forKey: "ballPosition") as? [String: CGFloat],
           let x = saved["x"], let y = saved["y"] {
            origin = NSPoint(x: x, y: y)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        petPanel = panel
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = petPanel?.frame else { return }
        UserDefaults.standard.set(["x": frame.minX, "y": frame.minY], forKey: "ballPosition")
    }

    // MARK: 功能泡泡环

    private func showOrbit(urls: [URL], flags: NSEvent.ModifierFlags, at screenPoint: NSPoint) {
        orbitPanel?.close()
        petView?.setProud(true)
        petView?.onTap = { [weak self] in self?.closeOrbit() }

        let size: CGFloat = 400
        let actions = WheelAction.set(for: flags)
        let view = OrbitMenuView(actions: actions, urls: urls,
                                 onConfirm: { [weak self] action, urls in
                                     self?.execute(action, on: urls)
                                     self?.closeOrbit()
                                 },
                                 onCancel: { [weak self] in
                                     self?.closeOrbit()
                                 })

        let panel = OrbitPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view

        // 以宠物为绝对圆心：窗口允许越出屏幕（内容是透明的），钳制会让环心和宠物错位
        panel.setFrameOrigin(NSPoint(x: screenPoint.x - size / 2, y: screenPoint.y - size / 2))
        panel.orderFrontRegardless()
        // 系统可能把面板「挤回屏幕内」，窗口一动圆心就离开宠物了 —— 用面板的真实位置反算圆心
        view.ringCenter = NSPoint(x: screenPoint.x - panel.frame.minX,
                                  y: screenPoint.y - panel.frame.minY)
        panel.makeKey()
        view.window?.makeFirstResponder(view)
        panel.onResignKey = { [weak self] in self?.closeOrbit() }
        startOutsideClickMonitor()
        orbitPanel = panel
    }

    /// 统一收起：关转轮 + 宠物回待机 + 清掉点按回调 + 停止空白点击监听
    private func closeOrbit() {
        stopOutsideClickMonitor()
        petView?.setProud(false)
        petView?.onTap = nil
        orbitPanel?.close()
        orbitPanel = nil
    }

    // MARK: 点击圆环外空白收起（全局鼠标监听）

    /// 圆环展开后开始监听：点击圆环窗口 frame 之外的任何地方 → 收起
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.orbitPanel else { return }
                let p = NSEvent.mouseLocation
                if !panel.frame.contains(p) {
                    self.closeOrbit()
                }
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    // MARK: Snapzy 功能圆环（单击宠物弹出）

    private func showSnapzyOrbit(at screenPoint: NSPoint) {
        orbitPanel?.close()
        petView?.setProud(true)
        petView?.onTap = { [weak self] in self?.closeOrbit() }
        // 用户大概率要点采集类功能，顺手刷新一次预热，按下时更快
        Task { await CaptureEngine.shared.warmUpCapture() }

        let size: CGFloat = 400
        let actions = WheelAction.snapzySet
        let view = OrbitMenuView(actions: actions, urls: [],
                                 onConfirm: { [weak self] action, _ in
                                     self?.execute(action, on: [])
                                     self?.closeOrbit()
                                 },
                                 onCancel: { [weak self] in
                                     self?.closeOrbit()
                                 })

        let panel = OrbitPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view

        panel.setFrameOrigin(NSPoint(x: screenPoint.x - size / 2, y: screenPoint.y - size / 2))
        panel.orderFrontRegardless()
        // 系统可能把面板「挤回屏幕内」，窗口一动圆心就离开宠物了 —— 用面板的真实位置反算圆心
        view.ringCenter = NSPoint(x: screenPoint.x - panel.frame.minX,
                                  y: screenPoint.y - panel.frame.minY)
        panel.makeKey()
        view.window?.makeFirstResponder(view)
        panel.onResignKey = { [weak self] in self?.closeOrbit() }
        startOutsideClickMonitor()
        orbitPanel = panel
    }

    // MARK: 执行 + 结果提示

    private func execute(_ action: WheelAction, on urls: [URL]) {
        // 屏幕采集类动作不依赖拖入的文件，直接触发
        switch action {
        case .captureRegion, .captureWindow, .captureFull:
            let mode: CaptureEngine.CaptureMode = action == .captureRegion ? .region
                : (action == .captureWindow ? .window : .full)
            closeOrbit()
            Task { [weak self] in
                let result = await CaptureEngine.shared.capture(mode: mode)
                self?.showResultToast(result.hasPrefix("⚠️") ? result : "已截图：\(URL(fileURLWithPath: result).lastPathComponent)")
            }
            return

        case .startRecord:
            closeOrbit()
            if CaptureEngine.shared.isRecording {
                Task { [weak self] in await self?.stopRecordingFlow() }
            } else {
                Task { [weak self] in await self?.startRecordingFlow() }
            }
            return

        case .ocr:
            // 有拖入的图片 → 直接识别；无文件（功能圆环）→ 先框选，再识别
            closeOrbit()
            if let url = urls.first {
                Task { [weak self] in await self?.runOCR(on: url) }
            } else {
                Task { [weak self] in await self?.runOCRFromScreen() }
            }
            return

        case .annotate:
            // 标注：区域截图（松手后可调整大小）→ 图片原地贴在选区位置 → 工具条 → 保存覆盖原图
            closeOrbit()
            Task { [weak self] in
                let result = await CaptureEngine.shared.capture(mode: .region, adjustable: true)
                if result == "已取消" { return }
                guard !result.hasPrefix("⚠️") else {
                    self?.showResultToast(result)
                    return
                }
                let url = URL(fileURLWithPath: result)
                guard let image = NSImage(contentsOf: url) else {
                    self?.showResultToast("⚠️ 无法载入截图")
                    return
                }
                let rect = CaptureEngine.shared.lastRegion
                    ?? NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
                let saved = await AnnotateOverlay.shared.present(image: image, at: rect, fileURL: url)
                self?.showResultToast(saved ? "已保存标注（已覆盖原图）" : "已退出标注")
            }
            return

        default:
            break
        }

        var results: [String] = []
        for url in urls {
            results.append(FileAction.run(action, on: url))
        }
        showResultToast("\(action.title)：\(results.joined(separator: "、"))")
    }

    @objc private func menuCaptureRegion() {
        Task { [weak self] in
            let result = await CaptureEngine.shared.capture(mode: .region)
            self?.showResultToast(result.hasPrefix("⚠️") ? result : "已截图")
        }
    }

    @objc private func menuCaptureWindow() {
        Task { [weak self] in
            let result = await CaptureEngine.shared.capture(mode: .window)
            self?.showResultToast(result.hasPrefix("⚠️") ? result : "已截图")
        }
    }

    @objc private func menuCaptureFull() {
        Task { [weak self] in
            let result = await CaptureEngine.shared.capture(mode: .full)
            self?.showResultToast(result.hasPrefix("⚠️") ? result : "已截图")
        }
    }

    // MARK: 「文字」识别

    /// 框选 → 后台识别 → 结果浮层（不落盘、不卡界面、可校对后再复制）
    private func runOCRFromScreen() async {
        switch await CaptureEngine.shared.captureRegionImage() {
        case .cancelled:
            return                                  // 取消就静默退出，不弹无意义提示
        case .failed(let message):
            showResultToast(message)
        case .image(let image):
            showResultToast("正在识别…")
            let text = await OCREngine.recognize(cgImage: image)
            toastPanel?.close()
            toastPanel = nil
            presentOCR(text)
        }
    }

    /// 识别拖进来的图片文件
    private func runOCR(on url: URL) async {
        showResultToast("正在识别…")
        let text = await OCREngine.recognize(imageAt: url)
        toastPanel?.close()
        toastPanel = nil
        presentOCR(text)
    }

    /// 有文字就弹结果浮层（同时写剪贴板），没有就如实提示
    private func presentOCR(_ text: String) {
        if OCREngine.isUsable(text) {
            OCRResultPanel.shared.show(text)
        } else {
            showResultToast(text)
        }
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    /// 快捷键动作 id → 圆环动作
    private static let hotKeyActions: [String: WheelAction] = [
        "region":   .captureRegion,
        "window":   .captureWindow,
        "full":     .captureFull,
        "record":   .startRecord,
        "ocr":      .ocr,
        "annotate": .annotate,
    ]

    private func runHotKey(_ id: String) {
        guard let action = Self.hotKeyActions[id] else { return }
        execute(action, on: [])
    }

    @objc private func menuRecord() {
        Task { [weak self] in
            if CaptureEngine.shared.isRecording {
                await self?.stopRecordingFlow()
            } else {
                await self?.startRecordingFlow()
            }
        }
    }

    // MARK: 录屏统一流程

    private func startRecordingFlow() async {
        guard !CaptureEngine.shared.isRecording else { return }
        closeOrbit()

        // 1) 选区：拖拽框选，单击不拖 = 整屏，Esc = 取消
        guard let picked = await RegionSelector.shared.pick(
            hint: "拖拽框选录制区域 · 松手后可调整 · 单击录整屏 · Esc 取消",
            clickMeansFullScreen: true,
            adjustable: true
        ) else { return }

        let host = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: picked.midX, y: picked.midY))
        } ?? NSScreen.main
        var isFull = true
        if let f = host?.frame {
            isFull = picked.width >= f.width - 2 && picked.height >= f.height - 2
        }

        // 2) 3-2-1 倒计时，数字落在选区中心
        await Countdown.run(seconds: 3, centerAt: NSPoint(x: picked.midX, y: picked.midY))

        // 3) 开录
        let result = await CaptureEngine.shared.startRecording(region: isFull ? nil : picked, screen: host)
        if result.hasPrefix("⚠️") {
            showResultToast(result)
            return
        }
        // 宠物进入录制状态 + 控制条挂在录制区域正上方（一条：先「开始录制」，随后计时 + 停止）
        petView?.recording = true
        let anchor = isFull ? (host?.frame ?? picked) : picked
        let bar = RecordingBar()
        bar.onStop = { [weak self] in
            Task { [weak self] in await self?.stopRecordingFlow() }
        }
        bar.show(above: anchor)
        recordingBar = bar
        // 区域录制时，在四角画角标，让你随时看得到边界（整屏录制不画）
        if !isFull {
            let corners = RecordCorners()
            corners.show(region: picked)
            recordCorners = corners
        }
    }

    private func stopRecordingFlow() async {
        // 恢复宠物 + 隐藏控制条与角标
        petView?.recording = false
        recordingBar?.close()
        recordingBar = nil
        recordCorners?.close()
        recordCorners = nil

        let result = await CaptureEngine.shared.stopRecording()
        if result.hasPrefix("⚠️") {
            showResultToast(result)
            return
        }
        // 录完：只投一条静默系统通知（进通知中心，点开定位文件）。
        // 自绘浮层先收起来 —— 想恢复就把下面这行注释打开。
        SystemNotifier.shared.notifyRecordingSaved(path: result)
        // showRecordDoneCard(filePath: result)
    }

    /// 录完提示卡：可点开，直接定位到桌面上的视频文件
    private func showRecordDoneCard(filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        // 先关掉上一张提示（否则新旧两张叠在一起会出现重影）
        toastPanel?.close()
        toastPanel = nil

        // 尺寸参考 macOS 通知条：只有两行文字，右侧一枚圆形图标按钮
        let w: CGFloat = 340
        let h: CGFloat = 68
        let padX: CGFloat = 20
        let iconSide: CGFloat = 32

        let card = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous

        let textW = w - padX * 2 - iconSide - 12

        // 标题
        let title = ToastText("录屏已保存",
                              font: .systemFont(ofSize: 13, weight: .semibold),
                              color: NSColor(calibratedWhite: 0.97, alpha: 1))
        title.frame = NSRect(x: padX, y: 36, width: textW, height: 17)
        card.addSubview(title)

        // 文件名（过长走中段截断，不会顶到边）
        let name = ToastText(url.lastPathComponent,
                             font: .systemFont(ofSize: 11.5),
                             color: NSColor(calibratedWhite: 1.0, alpha: 0.55))
        name.frame = NSRect(x: padX, y: 17, width: textW, height: 15)
        card.addSubview(name)

        // 右侧圆形按钮：圆里一枚放大镜，点开即在访达中定位文件
        let circle = NSView(frame: NSRect(x: w - padX - iconSide,
                                          y: (h - iconSide) / 2,
                                          width: iconSide, height: iconSide))
        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        circle.layer?.cornerRadius = iconSide / 2
        circle.layer?.cornerCurve = .continuous
        card.addSubview(circle)

        let glyph = NSImageView(frame: circle.bounds)
        glyph.imageScaling = .scaleProportionallyDown
        if let base = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "在访达中打开") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedWhite: 0.95, alpha: 1)]))
            glyph.image = base.withSymbolConfiguration(cfg) ?? base
        }
        glyph.contentTintColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        circle.addSubview(glyph)

        let openBtn = NSButton(frame: circle.frame)
        openBtn.title = ""
        openBtn.isBordered = false
        openBtn.target = self
        openBtn.action = #selector(openRecordedFile)
        card.addSubview(openBtn)

        // 用全局记录当前文件路径，供按钮回调使用
        recordedFileURL = url

        let p = NSPanel(contentRect: card.bounds,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = card
        if let vis = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vis.maxX - w - 20, y: vis.maxY - h - 20))
        }
        p.orderFrontRegardless()
        toastPanel = p

        // 3 秒后自动淡出，避免一直挂在屏幕上
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { [weak self, weak p] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                p?.animator().alphaValue = 0
            }, completionHandler: {
                p?.close()
                if self?.toastPanel === p {
                    self?.toastPanel = nil
                    self?.recordedFileURL = nil
                }
            })
        }
    }

    @objc private func openRecordedFile() {
        guard let url = recordedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        toastPanel?.close()
        toastPanel = nil
        recordedFileURL = nil
    }

    private func showResultToast(_ text: String) {
        toastPanel?.close()

        // 宽度跟着文字走：短消息不留大片空白，长文件名也不会贴边
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let probe = ToastText(text, font: font, color: .white, alignment: .center)
        let padX: CGFloat = 20
        let w = min(max(ceil(probe.textWidth) + padX * 2, 104), 560)
        let h: CGFloat = 38

        let view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous

        let label = ToastText(text, font: font, color: .white, alignment: .center)
        label.frame = NSRect(x: padX, y: 0, width: w - padX * 2, height: h)
        view.addSubview(label)

        let panel = NSPanel(contentRect: view.bounds,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view

        if let vis = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vis.midX - w / 2, y: vis.maxY - 64))
        }
        panel.orderFrontRegardless()
        toastPanel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self, weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                panel?.close()
                if self?.toastPanel === panel { self?.toastPanel = nil }
            })
        }
    }
}

/// 泡泡环容器：无边框、不激活应用、可接收键盘（Esc 取消）
/// 失去焦点（点击圆环外空白）时自动收起
@MainActor
final class OrbitPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onResignKey: (() -> Void)?

    /// 圆环必须正对宠物：默认的 constrainFrameRect 会把窗口「挤回屏幕内」，
    /// 结果圆心离开宠物（实测被向下推了 280pt）。这里直接放行，允许露出屏幕边缘。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
