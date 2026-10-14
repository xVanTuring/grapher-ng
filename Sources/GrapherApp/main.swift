import AppKit

// 无界面模式（--render / --benchmark）先跑：解析到就直接做完退出，不受单实例影响，
// 这样开着 App 的时候照样能导图、量性能。
HeadlessRunner.runIfRequested()

MainActor.assumeIsolated {
    // 单实例：已有 GrapherNG 在运行时把它调到前面，自己退出。必须在建窗口之前。
    // 单元测试以本应用为宿主运行，要能和正在用的实例共存，所以不检查。
    if !AppDelegate.isRunningTests, !SingleInstanceLock.acquire() {
        exit(0)
    }

    // delegate 要在 NSApp 启动前装好：文档控制器得在 `applicationWillFinishLaunching` 里抢先建出来。
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
