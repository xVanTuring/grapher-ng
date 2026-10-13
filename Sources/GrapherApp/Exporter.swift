import AppKit
import GrapherKit
import GrapherRender
import ImageIO
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
            if state.document.dimension == .space {
                exportPNG3D(state: state, scale: scale, to: url)
                return
            }
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

    /// 立体图导出 PNG：眼前没被遮住的那块，按目标倍率重新采样、4× MSAA 渲染，
    /// 再用 Core Text 把坐标盒的刻度数字与轴名画上去，和屏幕上看到的一致。
    private static func exportPNG3D(state: AppState, scale: Double, to url: URL) {
        guard let image = renderImage3D(state: state, scale: scale) else {
            state.presentError(L("Export failed"), L("Could not initialize the renderer"))
            return
        }
        let width = image.width
        let height = image.height
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            state.presentError(L("Export failed"), L("Could not initialize the renderer"))
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            state.statusMessage = String(format: L("Exported %@ (%ld×%ld)"), url.lastPathComponent, width, height)
        } else {
            state.presentError(L("Export failed"), url.lastPathComponent)
        }
    }

    /// 立体图渲染成图片（含刻度文字），导出与测试共用。
    static func renderImage3D(state: AppState, scale: Double) -> CGImage? {
        let pixelScale = state.backingScale * scale
        let view = state.exportView3D(scale: scale)
        let width = Int(view.widthPixels)
        let height = Int(view.heightPixels)
        let built = state.buildForExport3D(view: view, pixelScale: pixelScale)
        let chrome = Chrome3D.make(view: view, document: state.document, backingScale: pixelScale)
        guard width > 0, height > 0,
              let context = MetalContext.shared,
              let renderer = OffscreenRenderer3D(context: context, pixelWidth: width, pixelHeight: height),
              let rendered = renderer.makeImage(content: built.scene, contentView: built.view, chrome: chrome.scene,
                                                view: view, background: state.document.theme.background)
        else { return nil }
        return drawLabels(chrome.labels, onto: rendered, view: view, pointScale: pixelScale,
                          color: ControlFactory.nsColor(state.document.theme.label))
    }

    /// 在渲染好的图上画刻度文字。图是像素口径，字号按 `pointScale`（像素 / 点）放大。
    private static func drawLabels(
        _ labels: [AxisLabel3D],
        onto image: CGImage,
        view: View3D,
        pointScale: Double,
        color: NSColor
    ) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5 * pointScale, weight: .regular)
        let nameFont = NSFont.systemFont(ofSize: 12 * pointScale, weight: .semibold)
        for label in labels {
            guard let screen = view.project(label.position) else { continue }
            let text: String
            let font: NSFont
            switch label.kind {
            case .tick(let value, let decimals):
                text = AxisLabelFormat.tick(value, decimals: decimals)
                font = tickFont
            case .axisName(let name):
                text = name
                font = nameFont
            }
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let size = string.size()
            // 投影给的是左上角原点的像素坐标；位图上下文是左下角原点。
            string.draw(at: CGPoint(x: screen.x - size.width / 2, y: height - screen.y - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
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
