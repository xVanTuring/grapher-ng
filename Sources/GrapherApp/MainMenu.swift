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
            menu.addItem(item(L("About Grapher NG"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
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
            menu.addItem(item(L("New"), #selector(DocumentWindowController.newDocument(_:)), key: "n"))
            menu.addItem(item(L("Open…"), #selector(DocumentWindowController.openDocumentAction(_:)), key: "o"))
            menu.addItem(.separator())
            menu.addItem(item(L("Save"), #selector(DocumentWindowController.saveDocumentAction(_:)), key: "s"))
            menu.addItem(item(L("Save As…"), #selector(DocumentWindowController.saveDocumentAsAction(_:)),
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
            menu.addItem(item(L("Zoom In"), #selector(DocumentWindowController.zoomIn(_:)), key: "="))
            menu.addItem(item(L("Zoom Out"), #selector(DocumentWindowController.zoomOut(_:)), key: "-"))
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
            menu.addItem(self.item(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        }
        NSApp.windowsMenu = item.submenu
        return item
    }
}
