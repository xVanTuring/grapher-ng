import AppKit
import GrapherKit

/// 「示例」菜单：先分平面图 / 立体图，再按功能分类，最底下是一个个示例。菜单项的提示文字是这个示例的讲解。
/// 文件菜单与欢迎窗口共用；点开的示例都在新窗口里打开（`AppDelegate.openDemo`）。
@MainActor
enum ExamplesMenu {

    static func make(target: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: L("Examples"))
        for dimension in [DocumentDimension.plane, .space] {
            let header = NSMenuItem(title: dimension == .plane ? L("2D Graphs") : L("3D Graphs"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for category in Demos.categories(for: dimension) {
                let item = NSMenuItem(title: category.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: category.title)
                for demo in Demos.demos(in: category) {
                    let entry = NSMenuItem(title: demo.title, action: #selector(AppDelegate.openDemo(_:)), keyEquivalent: "")
                    entry.target = target
                    entry.representedObject = demo.id
                    entry.toolTip = demo.summary
                    submenu.addItem(entry)
                }
                item.submenu = submenu
                menu.addItem(item)
            }
            if dimension == .plane { menu.addItem(.separator()) }
        }
        return menu
    }
}
