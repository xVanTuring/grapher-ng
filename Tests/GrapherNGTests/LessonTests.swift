import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrapherKit
@testable import GrapherRender

/// 讲解：步骤决定图层显示、旧文件兼容、讲解文字与 TeX 的解析、公式排版的尺寸。
final class LessonTests: XCTestCase {

    // MARK: - 步骤与图层显示

    private func document() -> (GrapherDocument, Layer, Layer, Layer) {
        var document = GrapherDocument(dimension: .space)
        let surface = Layer.makeDefault(kind: .surface, index: 0)
        let patch = Layer.makeDefault(kind: .parametricSurface, index: 1)
        var later = Layer.makeDefault(kind: .spaceCurve, index: 2)
        later.name = "later"
        document.layers = [surface, patch, later]
        document.lessonSteps = [
            LessonStep(title: "1", visibleLayers: [surface.id]),
            LessonStep(title: "2", visibleLayers: [surface.id, patch.id]),
        ]
        return (document, surface, patch, later)
    }

    func testStepDecidesVisibilityOfManagedLayersOnly() {
        let (document, surface, patch, later) = document()
        XCTAssertEqual(document.lessonManagedLayers, [surface.id, patch.id])
        let first = document.presenting(step: 0)
        XCTAssertEqual(first.layers.filter(\.isVisible).map(\.id), [surface.id, later.id], "没写进任何一步的图层照常显示")
        let second = document.presenting(step: 1)
        XCTAssertEqual(second.layers.filter(\.isVisible).map(\.id), [surface.id, patch.id, later.id])
        XCTAssertEqual(document.presenting(step: 7), document, "越界的步骤不改文档")
        XCTAssertTrue(document.isLayer(later, visibleInStep: 0))
        XCTAssertFalse(document.isLayer(patch, visibleInStep: 0))
    }

    func testHidingAnUnmanagedLayerInOneStepKeepsTheOtherSteps() {
        var (document, _, _, later) = document()
        document.setLayer(later.id, visible: false, inStep: 1)
        XCTAssertTrue(document.presenting(step: 0).layers[2].isVisible, "别的步骤看起来和原来一样")
        XCTAssertFalse(document.presenting(step: 1).layers[2].isVisible)
        document.setLayer(later.id, visible: true, inStep: 1)
        XCTAssertEqual(document.lessonSteps[1].visibleLayers.last, later.id, "按图层列表的顺序存")
        XCTAssertTrue(document.presenting(step: 1).layers[2].isVisible)
    }

    func testCapturedStepRecordsWhatIsOnScreen() {
        var (document, surface, patch, later) = document()
        document.parameters = [ParameterDefinition(name: "h", value: 0.5, lowerBound: 0, upperBound: 1)]
        document.view3D.azimuth = 1.1
        let step = document.capturedStep(presenting: 0, title: "t")
        XCTAssertEqual(step.visibleLayers, [surface.id, later.id])
        XCTAssertFalse(step.visibleLayers.contains(patch.id))
        XCTAssertEqual(step.parameters, ["h": 0.5])
        XCTAssertEqual(step.camera?.space?.azimuth, 1.1)
    }

    func testOldFilesWithoutStepsStillOpenAndStepsSurviveSaving() throws {
        var (document, _, _, _) = document()
        document.lessonSteps[1].camera = LessonCamera(space: View3D(center: SIMD3(0, 0, 1), halfExtent: 3, azimuth: 0.4, elevation: 0.3))
        document.lessonSteps[1].parameters = ["h": 0.25]
        document.lessonSteps[1].plays = ["a"]
        document.lessonSteps[1].text = "由 $\\mathrm d\\sigma=|\\cos\\gamma|\\,\\mathrm dS$ 得"
        let restored = try DocumentStore.decode(DocumentStore.encode(document))
        XCTAssertEqual(restored, document)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: DocumentStore.encode(document)) as? [String: Any])
        json["lessonSteps"] = nil
        let old = try DocumentStore.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.lessonSteps.isEmpty)
    }

    func testTransitionTakesTheShortWayRound() {
        XCTAssertEqual(LessonTransition.mixAngle(0.1, 2 * .pi - 0.1, 0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(LessonTransition.ease(0), 0)
        XCTAssertEqual(LessonTransition.ease(1), 1)
        XCTAssertEqual(LessonTransition.ease(0.5), 0.5, accuracy: 1e-12)
        let a = View3D(center: .zero, halfExtent: 2, azimuth: 0, elevation: 0)
        let b = View3D(center: SIMD3(2, 0, 0), halfExtent: 8, azimuth: 1, elevation: 0.5)
        let mid = LessonTransition.view(from: a, to: b, progress: 0.5)
        XCTAssertEqual(mid.halfExtent, 4, accuracy: 1e-9, "缩放按对数插值")
        XCTAssertEqual(mid.center.x, 1, accuracy: 1e-12)
    }

    // MARK: - 文字格式里的步骤

    func testTextFormatReadsSteps() throws {
        let source = """
        space
        param h = 0.6 [0.1, 1]
        view: azimuth=30 elevation=20
        surface S: 3 - (x^2 + y^2)/2; opacity=0.5
        point P: 1; 0.5; 2
        space-curve n: 1 + t; 0.5 + 0.5*t; 2 + t; t=0..1; arrow
        step 曲面 $S$：$z=z(x,y)$: show=S
        > 第一段，$\\mathrm d\\sigma$。
        >
        > $$\\mathrm dS=\\sqrt{1+z_x^2+z_y^2}\\,\\mathrm d\\sigma$$
        step: add=P, n; azimuth=60; h=0.3; play=h; focus=n
        step Last: hide=S
        """
        let result = GrapherText.parse(source)
        XCTAssertTrue(result.isValid, "\(result.errors)")
        let document = result.document
        let ids = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.name, $0.id) })
        XCTAssertEqual(document.lessonSteps.count, 3)
        let first = document.lessonSteps[0]
        XCTAssertEqual(first.title, "曲面 $S$：$z=z(x,y)$")
        XCTAssertEqual(first.text, "第一段，$\\mathrm d\\sigma$。\n\n$$\\mathrm dS=\\sqrt{1+z_x^2+z_y^2}\\,\\mathrm d\\sigma$$")
        XCTAssertEqual(first.visibleLayers, [ids["S"]!])
        XCTAssertNil(first.camera, "没写相机就不动")
        let second = document.lessonSteps[1]
        XCTAssertEqual(second.title, "")
        XCTAssertEqual(second.visibleLayers, [ids["S"]!, ids["P"]!, ids["n"]!], "add 在上一步的基础上加，按图层顺序")
        XCTAssertEqual(second.parameters, ["h": 0.3])
        XCTAssertEqual(second.plays, ["h"])
        XCTAssertEqual(second.focus, ids["n"])
        let camera = try XCTUnwrap(second.camera?.space)
        XCTAssertEqual(camera.azimuth, 60 * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(camera.elevation, 20 * .pi / 180, accuracy: 1e-9, "没写的角度沿用 view:")
        XCTAssertEqual(document.lessonSteps[2].visibleLayers, [ids["P"]!, ids["n"]!])
        XCTAssertTrue(document.layers.first { $0.name == "n" }!.showsArrow)
    }

    func testTextFormatReportsStepMistakes() {
        let result = GrapherText.parse("""
        space
        surface S: x*y
        > 没有步骤的文字
        step A: show=S, Nope; zoom=abc; play=q; colour=red
        step B: oops
        """)
        let lines = result.errors.map(\.line)
        XCTAssertTrue(lines.contains(3), "\(result.errors)")
        XCTAssertEqual(lines.filter { $0 == 4 }.count, 4, "\(result.errors)")
        XCTAssertTrue(lines.contains(5))
        XCTAssertEqual(result.document.lessonSteps.count, 2, "写错的选项跳过，步骤照样有")
        XCTAssertEqual(result.document.lessonSteps[0].visibleLayers.count, 1)
    }

    func testTextExampleWithStepsRenders() throws {
        let example = try XCTUnwrap(GrapherText.examples.first { $0.id == "space-lesson" })
        let result = GrapherText.parse(example.text)
        XCTAssertTrue(result.isValid, "\(result.errors)")
        XCTAssertEqual(result.document.lessonSteps.count, 3)
        let image = try XCTUnwrap(GraphSnapshot.lessonImage(of: result.document, step: 2, pixelWidth: 900, pixelHeight: 700, pointScale: 1.5))
        XCTAssertGreaterThan(inkFraction(of: image), 0.01)
    }

    // MARK: - 讲解文字

    func testParagraphsSplitInlineAndDisplayMath() {
        let text = "设 $z=z(x,y)$，**得**\n$$\\mathrm dS=\\sqrt{1+z_x^2}\\,\\mathrm d\\sigma$$\n价格 \\$5\n\n末行"
        let paragraphs = LessonText.paragraphs(text)
        XCTAssertEqual(paragraphs, [
            .inline([.text("设 ", bold: false), .math("z=z(x,y)"), .text("，", bold: false), .text("得", bold: true)]),
            .display("\\mathrm dS=\\sqrt{1+z_x^2}\\,\\mathrm d\\sigma"),
            .inline([.text("价格 $5", bold: false)]),
            .inline([]),
            .inline([.text("末行", bold: false)]),
        ])
        XCTAssertEqual(LessonText.paragraphs("只有一个 $ 号"), [.inline([.text("只有一个 $ 号", bold: false)])])
        XCTAssertEqual(LessonText.paragraphs("\\(a\\) 与 \\[b\\]"), [.inline([.math("a"), .text(" 与 ", bold: false)]), .display("b")])
    }

    func testTeXParsesTheSurfaceElement() {
        let nodes = MathTeX.parse("\\mathrm dS=\\sqrt{1+z_x^2(x,y)+z_y^2(x,y)}\\,\\mathrm d\\sigma")
        XCTAssertEqual(nodes.first, .group([.symbol("d", .ord)], .ord), "\\mathrm 只吃一个记号")
        XCTAssertEqual(nodes[1], .symbol("𝑆", .ord))
        XCTAssertEqual(nodes[2], .symbol("=", .rel))
        guard case .radical(nil, let body) = nodes[3] else { return XCTFail("应当是根号：\(nodes[3])") }
        XCTAssertEqual(body[0], .symbol("1", .ord))
        XCTAssertEqual(body[1], .symbol("+", .bin))
        XCTAssertEqual(body[2], .scripts(base: .symbol("𝑧", .ord), sub: [.symbol("𝑥", .ord)], sup: [.symbol("2", .ord)]))
        XCTAssertEqual(nodes[4], .space(3.0 / 18))
        XCTAssertEqual(nodes.last, .symbol("𝜎", .ord))
    }

    func testTeXCommandsMapToUnicode() {
        XCTAssertEqual(MathTeX.parse("\\iint_S"), [.scripts(base: .largeOperator("∬", large: true, limits: .never, integral: true),
                                                             sub: [.symbol("𝑆", .ord)], sup: nil)])
        XCTAssertEqual(MathTeX.parse("\\mathbb R^3").first,
                       .scripts(base: .group([.symbol("ℝ", .ord)], .ord), sub: nil, sup: [.symbol("3", .ord)]))
        XCTAssertEqual(MathTeX.parse("|\\cos\\gamma|"), [.symbol("|", .ord), .symbol("cos", .op), .symbol("𝛾", .ord), .symbol("|", .ord)])
        XCTAssertEqual(MathTeX.parse("\\vec n"), [.accent(.vec, [.symbol("𝑛", .ord)])])
        XCTAssertEqual(MathTeX.parse("x^{10}"), [.scripts(base: .symbol("𝑥", .ord), sub: nil, sup: [.symbol("10", .ord)])])
        XCTAssertEqual(MathTeX.parse("f'"), [.symbol("𝑓", .ord), .symbol("′", .ord)])
        XCTAssertEqual(MathTeX.parse("\\lim\\limits_{h}"),
                       [.scripts(base: .largeOperator("lim", large: false, limits: .always, integral: false), sub: [.symbol("ℎ", .ord)], sup: nil)])
        XCTAssertEqual(MathTeX.parse("\\text{面积 } S").first, .text("面积 "))
        XCTAssertEqual(MathTeX.parse("面积"), [.text("面积")])
        XCTAssertEqual(MathTeX.parse("\\left(\\frac12\\right]"),
                       [.delimited(left: "(", body: [.fraction([.symbol("1", .ord)], [.symbol("2", .ord)], style: .auto, rule: true)], right: "]")])
        XCTAssertEqual(MathTeX.parse("\\foo"), [.symbol("\\foo", .ord)], "不认识的命令原样写出来")
        // 写坏了也不崩：多余的右括号、没写完的命令。
        XCTAssertFalse(MathTeX.parse("}{a^").isEmpty)
        _ = MathTeX.parse("\\frac{")
        _ = MathTeX.parse("\\left(")
        _ = MathTeX.parse("\\sqrt[")
    }

    // MARK: - 排版

    func testTypesetterSizes() {
        let plain = MathTypesetter.layout("x", fontSize: 20, display: false)
        let fraction = MathTypesetter.layout("\\dfrac{1}{\\sqrt{1+z_x^2+z_y^2}}", fontSize: 20, display: false)
        XCTAssertGreaterThan(fraction.ascent, plain.ascent * 1.5)
        XCTAssertGreaterThan(fraction.descent, 15, "分母在基线以下")
        let small = MathTypesetter.layout("\\frac{1}{2}", fontSize: 20, display: false)
        let large = MathTypesetter.layout("\\frac{1}{2}", fontSize: 20, display: true)
        XCTAssertGreaterThan(large.ascent + large.descent, small.ascent + small.descent, "行间分数更大")
        let root = MathTypesetter.layout("\\sqrt{x}", fontSize: 20, display: false)
        XCTAssertGreaterThan(root.width, plain.width + 8)
        XCTAssertGreaterThan(root.ascent, plain.ascent)
        let sup = MathTypesetter.layout("x^2", fontSize: 20, display: false)
        XCTAssertGreaterThan(sup.ascent, plain.ascent + 2, "上标高出字母")
        let spaced = MathTypesetter.layout("a=b", fontSize: 20, display: false)
        let tight = MathTypesetter.layout("ab", fontSize: 20, display: false)
        XCTAssertGreaterThan(spaced.width, tight.width + 2 * 20 * 5 / 18, "关系符号两边留粗空")
        let unary = MathTypesetter.layout("-a", fontSize: 20, display: false)
        let binary = MathTypesetter.layout("b-a", fontSize: 20, display: false)
        XCTAssertGreaterThan(binary.width - unary.width, 20 * 8 / 18 - 1, "开头的负号不留二元运算的空")
        let tall = MathTypesetter.layout("\\left(\\dfrac{1}{2}\\right)", fontSize: 20, display: false)
        XCTAssertGreaterThan(tall.ascent, 20, "括号随内容变高")
    }

    func testLayoutWrapsLongTextAndCentersDisplayMath() {
        let short = LessonTextLayout(text: "曲面面积", width: 400, fontSize: 15)
        let long = LessonTextLayout(text: String(repeating: "曲面面积微元 ", count: 30), width: 400, fontSize: 15)
        XCTAssertGreaterThan(long.height, short.height * 3)
        let display = LessonTextLayout(text: "$$\\mathrm dS=\\sqrt{1+z_x^2+z_y^2}\\,\\mathrm d\\sigma$$", width: 400, fontSize: 15)
        XCTAssertGreaterThan(display.height, 30)
    }

    /// 带讲解的示例：每一步都画得出东西、引用的图层都在；设了 `GRAPHER_LESSON_DIR` 时每一步存一张 PNG（带讲解卡片）。
    func testLessonDemosRenderEveryStep() throws {
        let directory = ProcessInfo.processInfo.environment["GRAPHER_LESSON_DIR"].map { URL(fileURLWithPath: $0) }
        let lessons = Demos.all.filter { !$0.make().lessonSteps.isEmpty }
        XCTAssertFalse(lessons.isEmpty)
        for demo in lessons {
            let document = demo.make()
            if let directory {
                // 顺便存一份文档，可以直接用 App 打开看讲解卡片。
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try DocumentStore.save(document, to: directory.appendingPathComponent("\(demo.id).grapher"))
            }
            let ids = Set(document.layers.map(\.id))
            for (index, step) in document.lessonSteps.enumerated() {
                XCTAssertFalse(step.visibleLayers.isEmpty, "\(demo.id) 第 \(index + 1) 步什么都不显示")
                XCTAssertTrue(Set(step.visibleLayers).isSubset(of: ids), "\(demo.id) 第 \(index + 1) 步引用了不存在的图层")
                for name in step.parameters.keys.map({ $0 }) + step.plays {
                    XCTAssertTrue(document.parameters.contains { $0.name == name }, "\(demo.id) 第 \(index + 1) 步的参数 \(name) 不存在")
                }
                let image = try XCTUnwrap(GraphSnapshot.lessonImage(
                    of: document, step: index, pixelWidth: 1280, pixelHeight: 900, pointScale: 1.6, quality: .full))
                XCTAssertGreaterThan(inkFraction(of: image), 0.01, "\(demo.id) 第 \(index + 1) 步画面几乎是空的")
                if let directory {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("\(demo.id)-\(index + 1).png")
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                }
            }
        }
    }

    /// 把几段讲解文字画成 PNG（设了 `GRAPHER_LESSON_DIR` 才存），肉眼核对公式排得对不对。
    func testRenderSamplesForVisualCheck() throws {
        let samples = [
            ("surface-element", "**曲面的面积**（第一型曲面积分 $\\iint_S\\mathrm dS$）. 曲面面积微元：设曲面由 $z=z(x,y)$ 给出，$z(x,y)$ 有连续偏导数，曲面上小片 $\\mathrm dS$ 在 $xOy$ 面上的投影为 $\\mathrm d\\sigma$，法向量与 $z$ 轴夹角为 $\\gamma$，由 $\\mathrm d\\sigma=|\\cos\\gamma|\\,\\mathrm dS$ 与 $|\\cos\\gamma|=\\dfrac{1}{\\sqrt{1+z_x^2+z_y^2}}$ 得\n$$\\mathrm dS=\\sqrt{1+z_x^2(x,y)+z_y^2(x,y)}\\,\\mathrm d\\sigma .$$"),
            ("assorted", "$$S=\\iint_D\\sqrt{1+\\left(\\frac{\\partial z}{\\partial x}\\right)^2+\\left(\\frac{\\partial z}{\\partial y}\\right)^2}\\,\\mathrm dx\\,\\mathrm dy$$\n$$\\sum_{k=1}^{n} \\Delta S_k \\approx \\lim_{\\lambda\\to 0}\\sum_{k=1}^n f(\\xi_k)\\Delta\\sigma_k,\\quad \\vec n=(-z_x,-z_y,1)$$\n$$\\int_0^{2\\pi}\\!\\!\\int_0^1 r\\,\\mathrm dr\\,\\mathrm d\\theta = \\pi,\\qquad \\sqrt[3]{x^2+y^2}\\le \\|\\mathbf a\\|,\\ \\hat x,\\ \\bar y,\\ \\dot{x},\\ \\tilde z$$\n行内：$f'(x_0)=\\lim\\limits_{h\\to0}\\frac{f(x_0+h)-f(x_0)}{h}$，以及 $\\mathbb R^3$、$\\{x\\mid x>0\\}$、$\\binom{n}{k}$、$e^{-x^2/2}$。"),
        ]
        guard let directory = ProcessInfo.processInfo.environment["GRAPHER_LESSON_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            // 没要求存图：照样排一遍，确认不崩。
            for (_, text) in samples { _ = LessonTextLayout(text: text, width: 520, fontSize: 15) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in samples {
            let scale: CGFloat = 2
            let layout = LessonTextLayout(text: text, width: 520, fontSize: 15)
            let width = Int((layout.width + 40) * scale), height = Int((layout.height + 40) * scale)
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            layout.draw(in: context, topLeft: CGPoint(x: 20, y: layout.height + 20), color: CGColor(gray: 0.1, alpha: 1))
            let image = try XCTUnwrap(context.makeImage())
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                directory.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
}
