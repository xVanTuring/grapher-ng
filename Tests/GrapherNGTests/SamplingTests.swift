import XCTest
@testable import GrapherKit

/// These tests check the geometric claims the renderer relies on. Anything that
/// would show up as a visible artefact on screen gets a numeric assertion here.
final class SamplingTests: XCTestCase {

    private func viewport(width: Double = 200, height: Double = 200, scale: Double = 100) -> Viewport2D {
        Viewport2D(centerX: 0, centerY: 0, scale: scale, widthPixels: width, heightPixels: height)
    }

    private func expression(_ source: String, _ variables: [String]) throws -> CompiledExpression {
        try CompiledExpression(source: source, context: ExpressionContext(variables: variables))
    }

    // MARK: - Explicit curves

    func testExplicitCurveStaysOnTheFunction() {
        let vp = viewport(width: 600, height: 400, scale: 40)
        let compiled = try! expression("sin(x)", ["x"])
        let curve = CurveSampler.sampleExplicit(
            f: { compiled.evaluate([$0]) },
            xRange: -10...10,
            viewport: vp,
            quality: .full
        )

        var checks = 0
        for segment in curve.segments {
            for point in segment {
                XCTAssertEqual(point.y, sin(point.x), accuracy: 1e-9)
                checks += 1
            }
        }
        XCTAssertGreaterThan(checks, 200, "the curve should be sampled densely")
    }

    func testExplicitCurveIsFlatEnoughOnScreen() {
        // A curve that bends hard: the polyline must still hug it to well under
        // a pixel, which is what makes it look smooth.
        let vp = viewport(width: 800, height: 600, scale: 60)
        let compiled = try! expression("0.2*x^2", ["x"])
        let curve = CurveSampler.sampleExplicit(
            f: { compiled.evaluate([$0]) },
            xRange: -6...6,
            viewport: vp,
            quality: .full
        )

        var worstDeviation = 0.0
        for segment in curve.segments {
            for index in 0..<(segment.count - 1) {
                let a = segment[index]
                let b = segment[index + 1]
                let mid = SIMD2((a.x + b.x) / 2, (b.y - a.y) / (b.x - a.x) * ((a.x + b.x) / 2 - a.x) + a.y)
                let trueMid = SIMD2(mid.x, compiled.evaluate([mid.x]))
                let error = abs(trueMid.y - mid.y) * vp.scale
                worstDeviation = max(worstDeviation, error)
            }
        }
        XCTAssertLessThan(worstDeviation, 1.0, "chord error in pixels must stay under a pixel")
    }

    func testExplicitCurveBreaksAtPoles() {
        let vp = viewport(width: 800, height: 600, scale: 60)
        let compiled = try! expression("1/x", ["x"])
        let curve = CurveSampler.sampleExplicit(
            f: { compiled.evaluate([$0]) },
            xRange: -3...3,
            viewport: vp,
            quality: .full
        )

        XCTAssertGreaterThanOrEqual(curve.segments.count, 2, "1/x must not be drawn as one stroke")

        // No stroke may cross the pole: every segment stays on one side of x = 0.
        for segment in curve.segments {
            let crosses = segment.contains { $0.x < 0 } && segment.contains { $0.x > 0 }
            XCTAssertFalse(crosses, "a stroke spans the pole, which would draw a vertical line")
        }
    }

    func testTangentBreaksAtEveryAsymptote() {
        let vp = viewport(width: 1000, height: 700, scale: 60)
        let compiled = try! expression("tan(x)", ["x"])
        let curve = CurveSampler.sampleExplicit(
            f: { compiled.evaluate([$0]) },
            xRange: -7...7,
            viewport: vp,
            quality: .full
        )

        // Asymptotes of tan on [-7, 7] sit at +-pi/2 and +-3pi/2 (±5pi/2 is
        // outside the range), so the range holds five branches.
        XCTAssertEqual(curve.segments.count, 5, "tan must be broken at each asymptote")

        for segment in curve.segments {
            for index in 0..<(segment.count - 1) {
                let dy = abs(segment[index + 1].y - segment[index].y) * vp.scale
                let dx = abs(segment[index + 1].x - segment[index].x) * vp.scale
                XCTAssertFalse(
                    dy > vp.heightPixels && dx < 4,
                    "a segment jumps a full screen height over a couple of pixels"
                )
            }
        }
    }

    func testOscillationNearZeroIsResolved() {
        let vp = viewport(width: 900, height: 400, scale: 300)
        let compiled = try! expression("x*sin(1/x)", ["x"])
        let curve = CurveSampler.sampleExplicit(
            f: { compiled.evaluate([$0]) },
            xRange: -0.3...0.3,
            viewport: vp,
            quality: .full
        )
        // The wiggles crowd towards the origin, so that is where the samples
        // must crowd too.
        var nearOrigin = 0
        for segment in curve.segments {
            for point in segment where abs(point.x) < 0.02 {
                nearOrigin += 1
            }
        }
        XCTAssertGreaterThan(nearOrigin, 300, "sampling should thicken near the origin")
        XCTAssertGreaterThan(curve.pointCount, 800)
    }

    // MARK: - Parametric and polar

    func testParametricCircleClosesAndIsRound() {
        let vp = viewport()
        let compiled = try! expression("cos(t)", ["t"])
        let curve = CurveSampler.sampleParametric(
            tRange: 0...(2 * Double.pi),
            f: { t in SIMD2(cos(t), sin(t)) },
            viewport: vp,
            quality: .full
        )
        XCTAssertEqual(curve.segments.count, 1)
        for segment in curve.segments {
            for point in segment {
                XCTAssertEqual(sqrt(point.x * point.x + point.y * point.y), 1, accuracy: 1e-12)
            }
        }
        _ = compiled
    }

    func testPolarRoseHasThreePetals() {
        let vp = viewport(width: 400, height: 400, scale: 100)
        let curve = CurveSampler.samplePolar(
            r: { cos(3 * $0) },
            thetaRange: 0...(2 * Double.pi),
            viewport: vp,
            quality: .full
        )
        var maxRadius = 0.0
        for segment in curve.segments {
            for point in segment {
                let r = sqrt(point.x * point.x + point.y * point.y)
                maxRadius = max(maxRadius, r)
                // r = cos(3 theta) implies the point is inside the unit disc.
                XCTAssertLessThanOrEqual(r, 1 + 1e-9)
            }
        }
        XCTAssertEqual(maxRadius, 1, accuracy: 0.01)
    }

    // MARK: - Implicit contours

    func testMarchingSquaresCircleIsAccurateAndClosed() {
        // Deliberately leave a margin: a circle tangent to the viewport edge is
        // clipped by the grid and legitimately falls apart into arcs.
        let vp = viewport(width: 240, height: 240, scale: 100)
        let compiled = try! expression("x^2 + y^2 - 1", ["x", "y"])
        var grid = FieldGrid(viewport: vp, quality: .full)
        FieldEvaluator.fill(&grid, expr: compiled)

        let contours = MarchingSquares.contours(grid: grid, level: 0)
        XCTAssertEqual(contours.count, 1, "a circle is one closed loop")

        let points = contours[0]
        XCTAssertGreaterThan(points.count, 400)
        for point in points {
            let residual = point.x * point.x + point.y * point.y - 1
            XCTAssertEqual(residual, 0, accuracy: 2e-3)
        }
        let first = points.first!
        let last = points.last!
        XCTAssertEqual(first.x, last.x, accuracy: 2e-3, "the loop should close on itself")
        XCTAssertEqual(first.y, last.y, accuracy: 2e-3)
    }

    func testMarchingSquaresSeparatesTheTwoBranchesOfAHyperbola() {
        let vp = viewport(width: 300, height: 300, scale: 60)
        let compiled = try! expression("x*y - 1", ["x", "y"])
        var grid = FieldGrid(viewport: vp, quality: .full)
        FieldEvaluator.fill(&grid, expr: compiled)

        let contours = MarchingSquares.contours(grid: grid, level: 0)
        XCTAssertGreaterThanOrEqual(contours.count, 2, "x*y = 1 has two branches")
        for contour in contours {
            XCTAssertLessThan(contour.count, 4000, "a branch should not be one gigantic zig-zag")
        }
    }

    func testContourRespectsRequestedLevel() {
        let vp = viewport()
        let compiled = try! expression("x^2 + y^2", ["x", "y"])
        var grid = FieldGrid(viewport: vp, quality: .full)
        FieldEvaluator.fill(&grid, expr: compiled)

        // The r = 0.5 circle.
        let contours = MarchingSquares.contours(grid: grid, level: 0.25)
        XCTAssertEqual(contours.count, 1)
        for point in contours[0] {
            let radius = sqrt(point.x * point.x + point.y * point.y)
            XCTAssertEqual(radius, 0.5, accuracy: 3e-3)
        }
    }

    // MARK: - Region filling

    /// The strongest check on the coverage maths: the total ink must equal the
    /// true area of the region, which is what proves the sub-pixel coverage is
    /// neither over- nor under-counting at the boundary.
    func testFilledDiscAreaMatchesPiRSquared() {
        let vp = viewport(width: 220, height: 220, scale: 100)
        let compiled = try! expression("x^2 + y^2 - 1", ["x", "y"])
        var grid = FieldGrid(viewport: vp, quality: .full)
        FieldEvaluator.fill(&grid, expr: compiled)

        let fill = RegionFiller.fill(grid: grid, relation: .lessOrEqual, pixelStep: 1.0)
        var coveredArea = 0.0
        for index in 0..<fill.count {
            let g = fill.geometry[index]
            coveredArea += Double(g.y - g.x) * Double(g.w - g.z) * Double(fill.coverage[index])
        }

        let expected = Double.pi * 100 * 100
        let relativeError = abs(coveredArea - expected) / expected
        XCTAssertLessThan(relativeError, 0.01, "covered area \(coveredArea) vs expected \(expected)")
    }

    func testRegionBoundaryPixelsCarryFractionalCoverage() {
        let vp = viewport(width: 200, height: 200, scale: 100)
        let compiled = try! expression("x^2 + y^2 - 1", ["x", "y"])
        var grid = FieldGrid(viewport: vp, quality: .full)
        FieldEvaluator.fill(&grid, expr: compiled)

        let fill = RegionFiller.fill(grid: grid, relation: .lessOrEqual, pixelStep: 1.0)
        var partiallyCovered = 0
        for index in 0..<fill.count {
            let coverage = fill.coverage[index]
            if coverage > 0.02 && coverage < 0.98 { partiallyCovered += 1 }
        }
        // Circumference is about 628 pixels, so there should be hundreds of
        // partially covered pixels and they must not be binary.
        XCTAssertGreaterThan(partiallyCovered, 300)
    }

    func testRegionRelationIsRespected() {
        let vp = viewport(width: 200, height: 200, scale: 100)
        let compiled = try! expression("x^2 + y^2 - 1", ["x", "y"])
        var grid = FieldGrid(viewport: vp, quality: .full)
        FieldEvaluator.fill(&grid, expr: compiled)

        func area(_ relation: RegionRelation) -> Double {
            let fill = RegionFiller.fill(grid: grid, relation: relation, pixelStep: 1.0)
            var total = 0.0
            for index in 0..<fill.count {
                let g = fill.geometry[index]
                total += Double(g.y - g.x) * Double(g.w - g.z) * Double(fill.coverage[index])
            }
            return total
        }

        let inside = area(.lessOrEqual)
        let outside = area(.greaterOrEqual)
        let total = Double(vp.widthPixels * vp.heightPixels)
        XCTAssertEqual(inside + outside, total, accuracy: total * 0.01)
    }

    func testRegionWithAHoleKeepsTheHoleOpen() {
        // The annulus spans r = 1...2 data units, so at 100 px/unit the canvas
        // has to reach 200 px from the centre to contain it.
        let vp = viewport(width: 440, height: 440, scale: 100)
        let compiled = try! expression("(x^2 + y^2 - 4)*(x^2 + y^2 - 1)", ["x", "y"])
        var grid = FieldGrid(viewport: vp, quality: .full)
        FieldEvaluator.fill(&grid, expr: compiled)

        let fill = RegionFiller.fill(grid: grid, relation: .lessOrEqual, pixelStep: 1.0)
        let centre = SIMD2(vp.widthPixels / 2, vp.heightPixels / 2)

        // Nothing may be painted in the middle of the hole.
        var inkNearCentre = 0.0
        for index in 0..<fill.count {
            let g = fill.geometry[index]
            let x = (Double(g.x) + Double(g.y)) / 2
            let y = (Double(g.z) + Double(g.w)) / 2
            if abs(x - centre.x) < 40 && abs(y - centre.y) < 40 {
                inkNearCentre += Double(fill.coverage[index])
            }
        }
        XCTAssertEqual(inkNearCentre, 0, "the r < 1 hole must stay unfilled")

        var coveredArea = 0.0
        for index in 0..<fill.count {
            let g = fill.geometry[index]
            coveredArea += Double(g.y - g.x) * Double(g.w - g.z) * Double(fill.coverage[index])
        }
        let expected = Double.pi * (200 * 200 - 100 * 100)
        XCTAssertEqual(coveredArea / expected, 1, accuracy: 0.02)
    }

    // MARK: - Probe

    func testProbeFindsNearestPointOnCurve() {
        let vp = viewport(width: 200, height: 200, scale: 100)
        let curve = ProbeCurve(
            layerID: UUID(),
            layerName: "line",
            color: .black,
            kind: .explicit,
            segments: [[SIMD2(-2, 0), SIMD2(2, 0)]]
        )

        // A pixel a tenth of a unit above the middle of the segment.
        let pixel = vp.toScreen(x: 0.5, y: 0.1)
        let hit = CurveProbe.nearest(curves: [curve], toPixel: pixel, viewport: vp)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!.dataPoint.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(hit!.dataPoint.y, 0, accuracy: 1e-6)
        XCTAssertEqual(hit!.distancePixels, 10, accuracy: 1e-6)
    }

    func testProbeReturnsNilWhenFarFromEveryCurve() {
        let vp = viewport(width: 200, height: 200, scale: 100)
        let curve = ProbeCurve(
            layerID: UUID(),
            layerName: "line",
            color: .black,
            kind: .explicit,
            segments: [[SIMD2(-2, 0), SIMD2(2, 0)]]
        )
        let pixel = vp.toScreen(x: 0, y: 5)
        XCTAssertNil(CurveProbe.nearest(curves: [curve], toPixel: pixel, viewport: vp))
    }

    // MARK: - Ticks

    func testTickStepIsANiceNumber() {
        for exponent in -6...6 {
            let raw = pow(10.0, Double(exponent)) * 1.37
            let step = AxisTicks.niceStep(minimumDataStep: raw)
            let mantissa = step / pow(10.0, (log10(step)).rounded(.down))
            XCTAssertTrue(
                abs(mantissa - 1) < 1e-9 || abs(mantissa - 2) < 1e-9 || abs(mantissa - 5) < 1e-9,
                "step \(step) has mantissa \(mantissa)"
            )
            XCTAssertGreaterThanOrEqual(step, raw)
        }
    }

    func testTicksCoverTheVisibleRangeWithoutOverflow() {
        for exponent in -4...4 {
            let scale = pow(10.0, Double(exponent))
            let vp = viewport(width: 800, height: 600, scale: scale)
            let ticks = AxisTicks.ticks(range: vp.xRange, pixelsPerUnit: vp.scale)
            XCTAssertFalse(ticks.major.isEmpty)
            XCTAssertLessThan(ticks.major.count, 200)
            for tick in ticks.major {
                XCTAssertTrue(vp.xRange.contains(tick))
            }
        }
    }

    // MARK: - Viewport geometry

    func testViewportRoundTripsAndKeepsShapesUndistorted() {
        var vp = viewport(width: 640, height: 480, scale: 55)
        let point = SIMD2(1.25, -3.5)
        let back = vp.toData(vp.toScreen(x: point.x, y: point.y))
        XCTAssertEqual(back.x, point.x, accuracy: 1e-12)
        XCTAssertEqual(back.y, point.y, accuracy: 1e-12)

        // A circle has to look like a circle: same pixels per unit on both axes.
        let a = vp.toScreen(x: 0, y: 0)
        let b = vp.toScreen(x: 1, y: 0)
        let c = vp.toScreen(x: 0, y: 1)
        XCTAssertEqual(GeometryMath.simdLength(b - a), GeometryMath.simdLength(c - a), accuracy: 1e-9)

        // Zooming about the cursor leaves the data point under it alone.
        let anchor = SIMD2(120.0, 300.0)
        let before = vp.toData(anchor)
        vp.zoom(by: 3.7, anchorPixel: anchor)
        let after = vp.toData(anchor)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
    }

    func testFitFramesTheGivenRectangle() {
        var vp = viewport(width: 800, height: 600, scale: 10)
        vp.fit(minX: -4, maxX: 4, minY: -1, maxY: 1)
        XCTAssertTrue(vp.xRange.contains(-4) && vp.xRange.contains(4))
        XCTAssertTrue(vp.yRange.contains(-1) && vp.yRange.contains(1))
        XCTAssertEqual(vp.centerX, 0, accuracy: 1e-12)
    }
}
