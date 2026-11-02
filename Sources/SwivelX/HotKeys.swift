import AppKit
import Carbon.HIToolbox

// MARK: - 快捷键模型

struct Shortcut: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32          // Carbon 修饰键位

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + KeyName.of(keyCode)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

enum KeyName {
    static let table: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
        50: "`", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    static func of(_ code: UInt32) -> String { table[code] ?? "Key\(code)" }
    static func isFunctionKey(_ code: UInt32) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(code)
    }
}

// MARK: - 全局热键中心（Carbon RegisterEventHotKey，不需要辅助功能授权）

@MainActor
final class HotKeyCenter {

    static let shared = HotKeyCenter()
    private init() {}

    /// 设置面板里的动作清单（顺序即显示顺序）
    static let actions: [(id: String, title: String)] = [
        ("region",   "区域截图"),
        ("window",   "窗口截图"),
        ("full",     "全屏截图"),
        ("record",   "录屏"),
        ("ocr",      "OCR 识别"),
        ("annotate", "标注"),
    ]

    private struct Registration {
        let ref: EventHotKeyRef
        let action: String
    }

    private var registrations: [UInt32: Registration] = [:]
    private var idByAction: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private(set) var shortcuts: [String: Shortcut] = [:]
    var onTrigger: ((String) -> Void)?

    private let storeKey = "yaya.hotkeys"

    func installIfNeeded() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), yayaHotKeyHandler, 1, &spec, nil, nil)
        installed = true
        load()
    }

    func handle(id: UInt32) {
        guard let reg = registrations[id] else { return }
        onTrigger?(reg.action)
    }

    /// 设置/清除某动作的快捷键，立即生效；返回是否注册成功
    @discardableResult
    func set(_ shortcut: Shortcut?, for action: String) -> Bool {
        unregister(action: action)
        guard let sc = shortcut else {
            shortcuts[action] = nil
            save()
            return true
        }

        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x59415941), id: id)   // 'YAYA'
        let status = RegisterEventHotKey(sc.keyCode, sc.modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("[Yaya] 快捷键注册失败 action=%@ status=%d", action, status)
            shortcuts[action] = nil
            save()
            return false
        }
        registrations[id] = Registration(ref: ref, action: action)
        idByAction[action] = id
        shortcuts[action] = sc
        save()
        return true
    }

    func unregister(action: String) {
        guard let id = idByAction.removeValue(forKey: action),
              let reg = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(reg.ref)
    }

    func clearAll() {
        for (_, reg) in registrations { UnregisterEventHotKey(reg.ref) }
        registrations.removeAll()
        idByAction.removeAll()
        shortcuts.removeAll()
        save()
    }

    func load() {
        let raw = UserDefaults.standard.dictionary(forKey: storeKey) ?? [:]
        for (action, value) in raw {
            guard let d = value as? [String: Any],
                  let kc = (d["key"] as? NSNumber)?.uint32Value,
                  let md = (d["mods"] as? NSNumber)?.uint32Value else { continue }
            _ = set(Shortcut(keyCode: kc, modifiers: md), for: action)
        }
    }

    private func save() {
        var out: [String: [String: UInt32]] = [:]
        for (a, sc) in shortcuts {
            out[a] = ["key": sc.keyCode, "mods": sc.modifiers]
        }
        UserDefaults.standard.set(out, forKey: storeKey)
    }
}

// MARK: - Carbon 回调（C 函数指针，不能捕获上下文）

private func yayaHotKeyHandler(_ callRef: EventHandlerCallRef?,
                               _ event: EventRef?,
                               _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hkID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hkID)
    guard status == noErr else { return status }
    // Carbon 应用级事件处理器运行在主线程
    MainActor.assumeIsolated {
        HotKeyCenter.shared.handle(id: hkID.id)
    }
    return noErr
}
