import CoreGraphics
import Foundation

/// Writes the 2D scene as a real vector PDF — paths, not pixels — so the result
/// stays sharp at any magnification.
public enum PDFExport {
    public enum ExportError: Error, LocalizedError {
        case contextCreationFailed

        public var errorDescription: String? {
            switch self {
            case .contextCreationFailed: return L("Could not create the PDF file")
            }
        }
    }

    /// - Parameters:
    ///   - scene: geometry in backing pixels, origin top-left.
    ///   - pixelsPerPoint: how many scene pixels make one PDF point.
    public static func write(
        scene: Scene2D,
        to url: URL,
        widthPoints: Double,
        heightPoints: Double,
        pixelsPerPoint: Double
    ) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: widthPoints, height: heightPoints)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExportError.contextCreationFailed
        }

        let ratio = pixelsPerPoint > 0 ? pixelsPerPoint : 1
        context.beginPDFPage(nil)

        // The scene's y axis points down; flip it so PDF's upward axis matches.
        context.translateBy(x: 0, y: heightPoints)
        context.scaleBy(x: 1 / ratio, y: -1 / ratio)

        context.setFillColor(color: scene.background, alphaScale: 1)
        context.fill(CGRect(x: 0, y: 0, width: widthPoints * ratio, height: heightPoints * ratio))

        context.setLineCap(.round)
        context.setLineJoin(.round)

        for command in scene.commands {
            switch command {
            case .rects(let batch):
                draw(rects: batch, in: context)
            case .polyline(let primitive):
                draw(polyline: primitive, in: context)
            case .markers(let batch):
                draw(markers: batch, in: context)
            }
        }

        context.endPDFPage()
        context.closePDF()
    }

    private static func draw(rects batch: RectPrimitiveBatch, in context: CGContext) {
        var currentCoverage: Float = -1
        for (index, geometry) in batch.geometry.enumerated() {
            let coverage = index < batch.coverage.count ? batch.coverage[index] : 1
            if coverage != currentCoverage {
                currentCoverage = coverage
                context.setFillColor(color: batch.color, alphaScale: Double(coverage))
            }
            let rect = CGRect(
                x: Double(geometry.x),
                y: Double(geometry.z),
                width: Double(geometry.y - geometry.x),
                height: Double(geometry.w - geometry.z)
            )
            context.fill(rect)
        }
    }

    private static func draw(polyline primitive: PolylinePrimitive, in context: CGContext) {
        guard primitive.points.count >= 2 else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: primitive.points[0].x, y: primitive.points[0].y))
        for point in primitive.points.dropFirst() {
            guard point.x.isFinite, point.y.isFinite else { return }
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        if primitive.isClosed { path.closeSubpath() }
        context.setStrokeColor(color: primitive.color, alphaScale: 1)
        context.setLineWidth(primitive.width)
        context.addPath(path)
        context.strokePath()
    }

    private static func draw(markers batch: MarkerPrimitiveBatch, in context: CGContext) {
        guard batch.radius > 0 else { return }
        context.setFillColor(color: batch.color, alphaScale: 1)
        for position in batch.positions where position.x.isFinite && position.y.isFinite {
            let rect = CGRect(
                x: position.x - batch.radius,
                y: position.y - batch.radius,
                width: batch.radius * 2,
                height: batch.radius * 2
            )
            context.fillEllipse(in: rect)
        }
    }
}

extension CGContext {
    fileprivate func setFillColor(color: RGBAColor, alphaScale: Double) {
        setFillColor(CGColor(
            srgbRed: color.r,
            green: color.g,
            blue: color.b,
            alpha: min(max(color.a * alphaScale, 0), 1)
        ))
    }

    fileprivate func setStrokeColor(color: RGBAColor, alphaScale: Double) {
        setStrokeColor(CGColor(
            srgbRed: color.r,
            green: color.g,
            blue: color.b,
            alpha: min(max(color.a * alphaScale, 0), 1)
        ))
    }
}
