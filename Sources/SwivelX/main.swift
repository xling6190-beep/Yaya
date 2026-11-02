import AppKit

// Yaya — 桌面宠物 + 截图/录屏/OCR/标注 + 拖文件转换（Intel / Apple Silicon 通用）
// 交互：拖入文件 → 按住修饰键 → 光标处弹出转轮 → 移动选区 → 松手执行

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
