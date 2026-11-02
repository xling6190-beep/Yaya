import AppKit
import UserNotifications

// MARK: - 静默系统通知
//
// 自绘浮层负责「好看、可控」，但它不进系统通知中心（那只是我们自己的一块窗口）。
// 这里额外投递一条 **passive 级** 的系统通知：
//   · 不弹横幅、不响铃、不亮屏（interruptionLevel = .passive）
//   · 只出现在「通知中心」的列表里，事后能翻到、点一下直接定位到文件
//
// ⚠️ 需要通知权限，而我们是自签应用，授权有可能被系统拒绝。
//    拿不到授权时这里安静地退化 —— 浮层照旧，其它功能完全不受影响。

@MainActor
final class SystemNotifier: NSObject, @preconcurrency UNUserNotificationCenterDelegate {

    static let shared = SystemNotifier()

    private static let fileKey = "yaya.file"

    /// 启动时调一次：设 delegate + 申请授权
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { granted, error in
            if let error {
                NSLog("[Yaya] 通知授权失败（不影响其它功能）：%@", error.localizedDescription)
                UserDefaults.standard.set("失败：\(error.localizedDescription)", forKey: "notifAuth")
            } else {
                NSLog("[Yaya] 通知授权：%@", granted ? "已允许" : "被拒绝")
                UserDefaults.standard.set(granted ? "已允许" : "被拒绝", forKey: "notifAuth")
            }
        }
    }

    /// 录屏完成：投一条静默通知，点开定位到文件
    func notifyRecordingSaved(path: String) {
        post(title: "录屏已保存",
             body: (path as NSString).lastPathComponent,
             path: path)
    }

    /// 截图保存：同上（默认不开，想用把这里接上即可）
    func notifyScreenshotSaved(path: String) {
        post(title: "截图已保存",
             body: (path as NSString).lastPathComponent,
             path: path)
    }

    private func post(title: String, body: String, path: String) {
        // 自签应用没有通知权限时，add 会报错，这里全部吞掉，绝不打扰主流程
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.fileKey: path]
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .passive      // 安静投递：只进通知中心
        }
        content.sound = nil

        let req = UNNotificationRequest(identifier: "yaya.\(UUID().uuidString)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                NSLog("[Yaya] 通知投递失败：%@", error.localizedDescription)
                UserDefaults.standard.set("投递失败：\(error.localizedDescription)", forKey: "notifPost")
            } else {
                UserDefaults.standard.set("已投递 \(Date())", forKey: "notifPost")
            }
        }
    }

    // MARK: 前台也只用列表呈现，不弹横幅

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler:
                               @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 11.0, *) {
            completionHandler([.list])          // 只进列表，不打扰
        } else {
            completionHandler([])
        }
    }

    /// 点通知 → 在访达里定位文件
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let path = info[Self.fileKey] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        completionHandler()
    }
}
