import AppKit
import Sparkle

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
            menu.addItem(item(L("About Grapher NG"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
            menu.addItem(item(L("Check for Updates…"), #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                              target: UpdaterService.controller))
            menu.addItem(.separator())
            menu.addItem(item(L("Settings…"), #selector(AppDelegate.showSettings(_:)), key: ","))
            menu.addItem(.separator())
            menu.addItem(item(L("Hide Grapher NG"), #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
            let hideOthers = item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                                  modifiers: [.command, .option], target: NSApp)
            menu.addItem(hideOthers)
            menu.addItem(item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
            menu.addItem(.separator())
            menu.addItem(item(L("Quit Grapher NG"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        }
    }

    private static func fileMenu() -> NSMenuItem {
        submenu(L("File")) { menu in
            // 新建、打开落到响应链末端的 NSDocumentController，保存、另存为落到窗口的 NSDocument。
            menu.addItem(item(L("New 2D Graph"), #selector(NSDocumentController.newDocument(_:)), key: "n"))
            menu.addItem(item(L("New 3D Graph"), #selector(AppDelegate.newSpaceDocument(_:)), key: "n",
                              modifiers: [.command, .shift]))
            menu.addItem(item(L("Open…"), #selector(NSDocumentController.openDocument(_:)), key: "o"))
            // 示例目录：按功能分类的一组示例，各在新窗口里打开，拿来学习。
            let examples = NSMenuItem(title: L("Open Example"), action: nil, keyEquivalent: "")
            examples.submenu = ExamplesMenu.make(target: NSApp.delegate)
            menu.addItem(examples)
            menu.addItem(item(L("Load Example"), #selector(DocumentWindowController.loadExample(_:))))
            menu.addItem(.separator())
            menu.addItem(item(L("Save"), #selector(NSDocument.save(_:)), key: "s"))
            menu.addItem(item(L("Save As…"), #selector(NSDocument.saveAs(_:)),
                              key: "s", modifiers: [.command, .shift]))
            menu.addItem(.separator())
            menu.addItem(item(L("Export PNG 1×"), #selector(DocumentWindowController.exportPNG1x(_:))))
            menu.addItem(item(L("Export PNG 2×"), #selector(DocumentWindowController.exportPNG2x(_:))))
            menu.addItem(item(L("Export PNG 4×"), #selector(DocumentWindowController.exportPNG4x(_:))))
            menu.addItem(item(L("Export Vector PDF…"), #selector(DocumentWindowController.exportPDFAction(_:))))
            menu.addItem(item(L("Export Sample Points as CSV…"), #selector(DocumentWindowController.exportCSVAction(_:))))
            menu.addItem(.separator())
            menu.addItem(item(L("Close Window"), #selector(NSWindow.performClose(_:)), key: "w"))
        }
    }

    private static func editMenu() -> NSMenuItem {
        submenu(L("Edit")) { menu in
            menu.addItem(item(L("Undo"), Selector(("undo:")), key: "z"))
            menu.addItem(item(L("Redo"), Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
            menu.addItem(.separator())
            menu.addItem(item(L("Cut"), #selector(NSText.cut(_:)), key: "x"))
            menu.addItem(item(L("Copy"), #selector(NSText.copy(_:)), key: "c"))
            menu.addItem(item(L("Paste"), #selector(NSText.paste(_:)), key: "v"))
            menu.addItem(item(L("Select All"), #selector(NSText.selectAll(_:)), key: "a"))
        }
    }

    private static func viewMenu() -> NSMenuItem {
        submenu(L("View")) { menu in
            menu.addItem(item(L("Fit Content"), #selector(DocumentWindowController.fitToContent(_:)), key: "f",
                              modifiers: []))
            menu.addItem(item(L("Reset View"), #selector(DocumentWindowController.resetView(_:)), key: "r",
                              modifiers: []))
            menu.addItem(.separator())
            // 立体图的平面视图（正交投影）：数字键 1 2 3 对应沿 x、y、z 轴看，P 切换透视 / 正交。
            menu.addItem(item(L("View Along X (YZ Plane)"), #selector(DocumentWindowController.lookAlongX(_:)), key: "1",
                              modifiers: []))
            menu.addItem(item(L("View Along Y (XZ Plane)"), #selector(DocumentWindowController.lookAlongY(_:)), key: "2",
                              modifiers: []))
            menu.addItem(item(L("View Along Z (XY Plane)"), #selector(DocumentWindowController.lookAlongZ(_:)), key: "3",
                              modifiers: []))
            menu.addItem(item(L("Orthographic Projection"), #selector(DocumentWindowController.toggleOrthographic(_:)),
                              key: "p", modifiers: []))
            menu.addItem(.separator())
            menu.addItem(item(L("Zoom In"), #selector(DocumentWindowController.zoomIn(_:)), key: "="))
            menu.addItem(item(L("Zoom Out"), #selector(DocumentWindowController.zoomOut(_:)), key: "-"))
            menu.addItem(.separator())
            // 讲解：一步一步看推导。画布上还可以用 ← → / 空格翻页、Esc 结束。
            menu.addItem(item(L("Start Lesson"), #selector(DocumentWindowController.toggleLesson(_:)), key: "l",
                              modifiers: [.command, .option]))
            menu.addItem(item(L("Next Step"), #selector(DocumentWindowController.nextLessonStep(_:)), key: "]"))
            menu.addItem(item(L("Previous Step"), #selector(DocumentWindowController.previousLessonStep(_:)), key: "["))
            menu.addItem(item(L("Add Step from Current View"), #selector(DocumentWindowController.addLessonStep(_:))))
            menu.addItem(.separator())
            menu.addItem(item(L("Show/Hide Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), key: "s",
                              modifiers: [.command, .control]))
            menu.addItem(item(L("Show/Hide Inspector"), #selector(DocumentWindowController.toggleInspector(_:)), key: "i",
                              modifiers: [.command, .option]))
        }
    }

    private static func windowMenu() -> NSMenuItem {
        let item = submenu(L("Window")) { menu in
            menu.addItem(self.item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m"))
            menu.addItem(self.item(L("Zoom"), #selector(NSWindow.performZoom(_:))))
            menu.addItem(.separator())
            menu.addItem(self.item(L("Welcome to Grapher NG"), #selector(AppDelegate.showWelcome(_:)), key: "1",
                                   modifiers: [.command, .shift]))
            menu.addItem(.separator())
            menu.addItem(self.item(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        }
        NSApp.windowsMenu = item.submenu
        return item
    }
}
