import AppKit
import GrapherKit
import GrapherRender
import UniformTypeIdentifiers

/// Export entry points. Everything here re-samples the document at the export
/// resolution instead of upscaling the on-screen geometry, so a 4x PNG really
/// has 4x the detail in the curves themselves.
@MainActor
enum Exporter {

    static func exportPNG(state: AppState, scale: Double, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "graph@\(Int(scale))x.png"
        panel.title = L("Export PNG")
        present(panel, in: window) { url in
            let scene = state.buildForExport(scale: scale).scene
            let width = Int(state.exportViewport.widthPixels * scale)
            let height = Int(state.exportViewport.heightPixels * scale)
            guard width > 0, height > 0,
                  let context = MetalContext.shared,
                  let renderer = OffscreenRenderer2D(
                    context: context,
                    pixelWidth: width,
                    pixelHeight: height,
                    supersample: 1
                  )
            else {
                state.presentError(L("Export failed"), L("Could not initialize the renderer"))
                return
            }
            do {
                try renderer.writePNG(scene, to: url)
                state.statusMessage = String(format: L("Exported %@ (%ld×%ld)"), url.lastPathComponent, width, height)
            } catch {
                state.presentError(L("Export failed"), error.localizedDescription)
            }
        }
    }

    static func exportPDF(state: AppState, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "graph.pdf"
        panel.title = L("Export Vector PDF")
        present(panel, in: window) { url in
            let scene = state.buildForExport(scale: 1).scene
            let pointsPerPixel = max(state.backingScale, 1)
            let widthPoints = state.exportViewport.widthPixels / pointsPerPixel
            let heightPoints = state.exportViewport.heightPixels / pointsPerPixel
            do {
                try PDFExport.write(
                    scene: scene,
                    to: url,
                    widthPoints: widthPoints,
                    heightPoints: heightPoints,
                    pixelsPerPoint: pointsPerPixel
                )
                state.statusMessage = String(format: L("Exported vector %@"), url.lastPathComponent)
            } catch {
                state.presentError(L("Export failed"), error.localizedDescription)
            }
        }
    }

    static func exportCSV(state: AppState, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "points.csv"
        panel.title = L("Export Sample Points")
        present(panel, in: window) { url in
            do {
                try CSVExport.write(curves: state.buildForExport(scale: 1).probeCurves, to: url)
                state.statusMessage = String(format: L("Exported sample points %@"), url.lastPathComponent)
            } catch {
                state.presentError(L("Export failed"), error.localizedDescription)
            }
        }
    }

    private static func present(_ panel: NSSavePanel, in window: NSWindow?, then handle: @escaping (URL) -> Void) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            handle(url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}
