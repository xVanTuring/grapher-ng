import AppKit

/// The menu bar, built in code. Items with a nil target travel the responder
/// chain, so the actions land on whichever window is frontmost.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenu())
        mainMenu.addItem(fileMenu())
        mainMenu.addItem(editMenu())
        mainMenu.addItem(viewMenu())
        mainMenu.addItem(windowMenu())
        return mainMenu
    }

    private static func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        menuItem.target = target
        return menuItem
    }

    // MARK: - Menus

    private static func applicationMenu() -> NSMenuItem {
        submenu("Grapher NG") { menu in
            menu.addItem(item("关于 Grapher NG", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
            menu.addItem(.separator())
            menu.addItem(item("隐藏 Grapher NG", #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
            let hideOthers = item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                                  modifiers: [.command, .option], target: NSApp)
            menu.addItem(hideOthers)
            menu.addItem(item("全部显示", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
            menu.addItem(.separator())
            menu.addItem(item("退出 Grapher NG", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        }
    }

    private static func fileMenu() -> NSMenuItem {
        submenu("文件") { menu in
            menu.addItem(item("新建", #selector(DocumentWindowController.newDocument(_:)), key: "n"))
            menu.addItem(item("打开…", #selector(DocumentWindowController.openDocumentAction(_:)), key: "o"))
            menu.addItem(.separator())
            menu.addItem(item("保存", #selector(DocumentWindowController.saveDocumentAction(_:)), key: "s"))
            menu.addItem(item("另存为…", #selector(DocumentWindowController.saveDocumentAsAction(_:)),
                              key: "s", modifiers: [.command, .shift]))
            menu.addItem(.separator())
            menu.addItem(item("导出 PNG 1×", #selector(DocumentWindowController.exportPNG1x(_:))))
            menu.addItem(item("导出 PNG 2×", #selector(DocumentWindowController.exportPNG2x(_:))))
            menu.addItem(item("导出 PNG 4×", #selector(DocumentWindowController.exportPNG4x(_:))))
            menu.addItem(item("导出矢量 PDF…", #selector(DocumentWindowController.exportPDFAction(_:))))
            menu.addItem(item("导出采样点 CSV…", #selector(DocumentWindowController.exportCSVAction(_:))))
            menu.addItem(.separator())
            menu.addItem(item("关闭窗口", #selector(NSWindow.performClose(_:)), key: "w"))
        }
    }

    private static func editMenu() -> NSMenuItem {
        submenu("编辑") { menu in
            menu.addItem(item("撤销", Selector(("undo:")), key: "z"))
            menu.addItem(item("重做", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
            menu.addItem(.separator())
            menu.addItem(item("剪切", #selector(NSText.cut(_:)), key: "x"))
            menu.addItem(item("拷贝", #selector(NSText.copy(_:)), key: "c"))
            menu.addItem(item("粘贴", #selector(NSText.paste(_:)), key: "v"))
            menu.addItem(item("全选", #selector(NSText.selectAll(_:)), key: "a"))
        }
    }

    private static func viewMenu() -> NSMenuItem {
        submenu("视图") { menu in
            menu.addItem(item("适应内容", #selector(DocumentWindowController.fitToContent(_:)), key: "f",
                              modifiers: []))
            menu.addItem(item("重置视图", #selector(DocumentWindowController.resetView(_:)), key: "r",
                              modifiers: []))
            menu.addItem(.separator())
            menu.addItem(item("放大", #selector(DocumentWindowController.zoomIn(_:)), key: "="))
            menu.addItem(item("缩小", #selector(DocumentWindowController.zoomOut(_:)), key: "-"))
            menu.addItem(.separator())
            menu.addItem(item("显示/隐藏侧栏", #selector(NSSplitViewController.toggleSidebar(_:)), key: "s",
                              modifiers: [.command, .control]))
            menu.addItem(item("显示/隐藏检查器", #selector(DocumentWindowController.toggleInspector(_:)), key: "i",
                              modifiers: [.command, .option]))
        }
    }

    private static func windowMenu() -> NSMenuItem {
        let item = submenu("窗口") { menu in
            menu.addItem(self.item("最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
            menu.addItem(self.item("缩放", #selector(NSWindow.performZoom(_:))))
            menu.addItem(.separator())
            menu.addItem(self.item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        }
        NSApp.windowsMenu = item.submenu
        return item
    }
}
