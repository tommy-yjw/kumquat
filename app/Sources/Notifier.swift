import AppKit
import UserNotifications

/// 系统通知(UNUserNotificationCenter):
/// - 完成通知点击后在 Finder 中显示输出文件;
/// - 应用在前台也显示横幅;
/// - 授权推迟到第一次真正要发通知时才请求(避免启动即弹窗);
/// - 用户拒绝授权时静默跳过,绝不阻塞转换流程。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var requested = false
    private var granted = false
    private var pending: [(title: String, body: String, reveal: URL?)] = []

    /// 必须在 application 启动早期调用(delegate 要赶在首次通知前就位)。
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String, reveal: URL? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.postOnMain(title: title, body: body, reveal: reveal)
        }
    }

    private func postOnMain(title: String, body: String, reveal: URL?) {
        if granted {
            enqueue(title: title, body: body, reveal: reveal)
            return
        }
        guard !requested else { return } // 已拒绝或等待授权中:静默跳过
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.granted = granted
                guard granted else { return }
                self.pending.forEach { self.enqueue(title: $0.title, body: $0.body, reveal: $0.reveal) }
                self.pending.removeAll()
            }
        }
        pending.append((title, body, reveal)) // 授权通过后补发首条
    }

    private func enqueue(title: String, body: String, reveal: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let reveal {
            content.userInfo["revealPath"] = reveal.path
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["revealPath"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
