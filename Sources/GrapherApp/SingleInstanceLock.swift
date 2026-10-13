import AppKit
import Foundation

/// 单实例守卫（同 FreeMind / Perch，先开的留下）：进程启动最早期抢一把文件锁，抢不到说明已有
/// GrapherNG 在运行，通知它把窗口调到前面，自己直接退出。
///
/// 为什么用 `flock` 而不是枚举 `NSRunningApplication`：
/// - 文件锁是内核级原子操作，挡得住两个进程几乎同时启动的情况；枚举在「查的时候没有、启动后
///   却撞上」之间有空档。
/// - 持锁进程崩溃或被强制结束时内核自动释放，不会留下需要清理的旧锁。
///
/// 两个实例同时开着会争同一份 UserDefaults——实测把分栏的自动保存状态写坏过：侧栏和检查器都被
/// 写成 `isCollapsed = YES`，两个面板一起消失。
enum SingleInstanceLock {
    /// 持锁的 fd，进程结束前不关（关了就解锁）。
    private static var lockFD: Int32 = -1

    /// 第二个实例退出前发这个通知，已在运行的实例收到后调到前面。
    static let secondLaunchNotification = Notification.Name("tech.xvanturing.GrapherNG.secondInstanceLaunched")

    /// 抢锁：成功（可以正常启动）返回 true，已有实例占着锁返回 false。
    /// 第一次没抢到就马上通知已在运行的实例调到前面，用户不用干等；之后再重试 2 秒：
    /// 如果占锁的是正在退出、还在收尾的旧进程，等它放了锁照常启动。
    static func acquire() -> Bool {
        let url = AppDirectories.support.appendingPathComponent("instance.lock")
        if let fd = lock(url, retryFor: 0) {
            lockFD = fd
            return true
        }
        notifyExistingInstance()
        guard let fd = lock(url, retryFor: 2) else { return false }
        lockFD = fd
        return true
    }

    /// 在 url 上抢独占文件锁，成功返回持锁的 fd。锁文件打不开时不挡启动（返回 -1 当作成功）。
    static func lock(_ url: URL, retryFor seconds: TimeInterval) -> Int32? {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return -1 }
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            usleep(100_000)
        } while Date() < deadline
        close(fd)
        return nil
    }

    /// 告诉已在运行的实例：用户又打开了一次 GrapherNG，把它调到前面。
    static func notifyExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            secondLaunchNotification, object: nil, userInfo: nil, deliverImmediately: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != me }
        _ = existing?.activate(options: [])
    }
}
