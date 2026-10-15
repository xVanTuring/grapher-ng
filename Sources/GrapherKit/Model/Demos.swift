import Foundation
import simd

/// 示例的分类：按功能划分，每类属于平面图或立体图。菜单与欢迎窗口按它分组。
public enum DemoCategory: String, CaseIterable, Sendable {
    // 平面图
    case curves
    case parameters
    case tangents
    case data
    // 立体图
    case surfaces
    case intersections
    case geometry
    case projections
    case gradients
    case lessons

    public var dimension: DocumentDimension {
        switch self {
        case .curves, .parameters, .tangents, .data: return .plane
        case .surfaces, .intersections, .geometry, .projections, .gradients, .lessons: return .space
        }
    }

    public var title: String {
        switch self {
        case .curves: return L("Curves and regions")
        case .parameters: return L("Parameter sliders")
        case .tangents: return L("Tangents and normals")
        case .data: return L("Data and fitting")
        case .surfaces: return L("Surfaces and space curves")
        case .intersections: return L("Intersection curves")
        case .geometry: return L("Points, lines and planes")
        case .projections: return L("Projections and tangent planes")
        case .gradients: return L("Gradients")
        case .lessons: return L("Step-by-step derivations")
        }
    }
}

/// 一个示例：打开就是一份完整的文档，带讲解文字。
public struct Demo: Identifiable, Sendable {
    public var id: String
    public var category: DemoCategory
    public var title: String
    /// 一两句话：这个示例演示什么、可以怎么动手试。
    public var summary: String
    public var make: @Sendable () -> GrapherDocument

    public var dimension: DocumentDimension { category.dimension }
}

public enum Demos {

    public static var all: [Demo] { plane + space }

    public static func demos(in category: DemoCategory) -> [Demo] {
        all.filter { $0.category == category }
    }

    public static func demo(id: String) -> Demo? {
        all.first { $0.id == id }
    }

    /// 某种文档的所有分类，按声明顺序。
    public static func categories(for dimension: DocumentDimension) -> [DemoCategory] {
        DemoCategory.allCases.filter { $0.dimension == dimension }
    }

    // MARK: - 平面图

    static var plane: [Demo] {
        [
            Demo(id: "plane.explicit", category: .curves, title: L("Explicit functions"),
                 summary: L("y = f(x). The curve of 1/x is cut at the pole instead of being joined by a vertical line.")) {
                var b = DemoBuilder(.plane, scale: 36)
                b.add(.explicit, "y = sin x", "sin(x)")
                b.add(.explicit, "y = x²/4 − 2", "x^2/4 - 2")
                b.add(.explicit, "y = 1/x", "1/x")
                b.add(.explicit, "y = |x|·e^(−|x|/3)", "abs(x)*exp(-abs(x)/3)")
                return b.document
            },
            Demo(id: "plane.parametric", category: .curves, title: L("Parametric curves"),
                 summary: L("A Lissajous figure and a cycloid. The range of t is set per layer.")) {
                var b = DemoBuilder(.plane, centerX: 3, scale: 34)
                b.add(.parametric, "Lissajous", "3*sin(3*t)", "3*sin(2*t)", domain: 0...(2 * .pi))
                b.add(.parametric, "Cycloid", "t - sin(t)", "1 - cos(t)", domain: 0...(4 * .pi))
                return b.document
            },
            Demo(id: "plane.polar", category: .curves, title: L("Polar curves"),
                 summary: L("A three-petal rose, a cardioid and an Archimedean spiral.")) {
                var b = DemoBuilder(.plane, scale: 38)
                b.add(.polar, "r = 3cos 3θ", "3*cos(3*theta)", domain: 0...(2 * .pi))
                b.add(.polar, "r = 1 + cos θ", "1 + cos(theta)", domain: 0...(2 * .pi))
                b.add(.polar, "r = θ/4", "theta/4", domain: 0...(4 * .pi))
                return b.document
            },
            Demo(id: "plane.implicit", category: .curves, title: L("Implicit curves"),
                 summary: L("F(x, y) = 0: the folium of Descartes, an ellipse and a hyperbola.")) {
                var b = DemoBuilder(.plane, scale: 48)
                b.add(.implicit, "x³ + y³ = 3xy", "x^3 + y^3 - 3*x*y")
                b.add(.implicit, "x²/4 + y² = 1", "x^2/4 + y^2 - 1")
                b.add(.implicit, "x² − y² = 1", "x^2 - y^2 - 1")
                return b.document
            },
            Demo(id: "plane.regions", category: .curves, title: L("Inequality regions"),
                 summary: L("Shade where F(x, y) is less than, or greater than, zero. Regions overlap with transparency.")) {
                var b = DemoBuilder(.plane, scale: 50)
                b.add(.region, "x² + y² ≤ 4", "x^2 + y^2 - 4") { $0.relation = .lessOrEqual }
                b.add(.region, "y > x²/2 − 1", "y - (x^2/2 - 1)") { $0.relation = .greater }
                b.add(.region, "|x| + |y| ≤ 3", "abs(x) + abs(y) - 3") { $0.relation = .lessOrEqual }
                return b.document
            },

            Demo(id: "plane.wave", category: .parameters, title: L("Sine wave with sliders"),
                 summary: L("Drag the sliders a, b and c to change amplitude, frequency and phase; the curves follow live.")) {
                var b = DemoBuilder(.plane, scale: 40)
                b.document.parameters = [
                    ParameterDefinition(name: "a", value: 1.5, lowerBound: 0, upperBound: 3),
                    ParameterDefinition(name: "b", value: 2, lowerBound: 0.2, upperBound: 5),
                    ParameterDefinition(name: "c", value: 0.5, lowerBound: -3.2, upperBound: 3.2),
                ]
                b.add(.explicit, "y = a sin(bx + c)", "a*sin(b*x + c)")
                b.add(.explicit, "y = a cos(bx + c)", "a*cos(b*x + c)") { $0.lineStyle.isDashed = true }
                return b.document
            },
            Demo(id: "plane.draw-in", category: .parameters, title: L("A curve that draws itself"),
                 summary: L("The upper end of t is p·2π. Press play on p and the Lissajous figure and the cycloid are drawn as p grows.")) {
                var b = DemoBuilder(.plane, centerX: 3, scale: 34)
                b.document.parameters = [ParameterDefinition(name: "p", value: 0.6, lowerBound: 0, upperBound: 1)]
                b.add(.parametric, "Lissajous", "3*sin(3*t)", "3*sin(2*t)", domain: 0...(2 * .pi)) { $0.domainUpperFormula = "p*2*pi" }
                b.add(.parametric, "Cycloid", "t - sin(t)", "1 - cos(t)", domain: 0...(4 * .pi)) { $0.domainUpperFormula = "p*4*pi" }
                return b.document
            },
            Demo(id: "plane.conics", category: .parameters, title: L("Ellipse and hyperbola"),
                 summary: L("Change the semi-axes a and b to see how an ellipse and a hyperbola with the same a and b relate.")) {
                var b = DemoBuilder(.plane, scale: 42)
                b.document.parameters = [
                    ParameterDefinition(name: "a", value: 3, lowerBound: 0.5, upperBound: 5),
                    ParameterDefinition(name: "b", value: 2, lowerBound: 0.5, upperBound: 5),
                ]
                b.add(.implicit, "x²/a² + y²/b² = 1", "x^2/a^2 + y^2/b^2 - 1")
                b.add(.implicit, "x²/a² − y²/b² = 1", "x^2/a^2 - y^2/b^2 - 1")
                b.add(.explicit, "y = (b/a)x", "b/a*x") { $0.lineStyle.isDashed = true }
                b.add(.explicit, "y = −(b/a)x", "-b/a*x") { $0.lineStyle.isDashed = true }
                return b.document
            },

            Demo(id: "plane.tangent-cubic", category: .tangents, title: L("Tangent and normal of a cubic"),
                 summary: L("The tangent at x = 1.5 and the normal at x = −0.5 of y = x³ − 3x. Change the position in the inspector.")) {
                var b = DemoBuilder(.plane, scale: 44)
                let curve = b.add(.explicit, "y = x³ − 3x", "x^3 - 3*x")
                b.tangent("Tangent x = 1.5", of: curve, at: 1.5)
                b.tangent("Normal x = −0.5", of: curve, at: -0.5, normal: true)
                b.text(L("tangent at x = 1.5"), at: 1.7, -1.4)
                b.text(L("normal at x = −0.5"), at: -5.6, 2.8)
                return b.document
            },
            Demo(id: "plane.tangent-slide", category: .tangents, title: L("A tangent sliding along a curve"),
                 summary: L("The point of tangency is the parameter p. Press play on p: the tangent and the normal of the cubic slide along it and the slope changes with them.")) {
                var b = DemoBuilder(.plane, scale: 44)
                b.document.parameters = [ParameterDefinition(name: "p", value: -1.8, lowerBound: -2.5, upperBound: 2.5)]
                let curve = b.add(.explicit, "y = x³ − 3x", "x^3 - 3*x")
                b.tangent("Tangent at x = p", of: curve, at: 0, positionFormula: "p")
                b.tangent("Normal at x = p", of: curve, at: 0, normal: true, positionFormula: "p")
                return b.document
            },
            Demo(id: "plane.tangent-curves", category: .tangents, title: L("Tangents of a circle and a cardioid"),
                 summary: L("Tangents work on parametric (position = t) and polar curves (position = θ) too.")) {
                var b = DemoBuilder(.plane, scale: 36)
                let circle = b.add(.parametric, "Circle", "3*cos(t)", "3*sin(t)", domain: 0...(2 * .pi))
                let cardioid = b.add(.polar, "Cardioid", "2*(1 + cos(theta))", domain: 0...(2 * .pi))
                b.tangent("Circle, t = 0.7", of: circle, at: 0.7)
                b.tangent("Cardioid, θ = 1", of: cardioid, at: 1)
                return b.document
            },

            Demo(id: "plane.scatter", category: .data, title: L("Scatter plot with a fitted line"),
                 summary: L("Paste your own x, y lines into the data box. The least-squares line and its statistics update as you type.")) {
                var b = DemoBuilder(.plane, centerX: 5, centerY: 5, scale: 46)
                let data = "1, 2.3\n2, 2.9\n3, 4.4\n4, 4.1\n5, 5.8\n6, 6.1\n7, 7.9\n8, 7.4\n9, 9.2"
                b.add(.scatter, "Data", data) { $0.showsFit = true }
                if let fit = ScatterData.fit(ScatterData.parse(data)), let r = fit.correlation {
                    let sign = fit.intercept < 0 ? "−" : "+"
                    b.text(String(format: "y = %.3f x %@ %.3f   r = %.3f", fit.slope, sign, abs(fit.intercept), r), at: 0.8, 9.6)
                }
                return b.document
            },
        ]
    }

    // MARK: - 立体图

    static var space: [Demo] {
        [
            Demo(id: "space.explicit-surface", category: .surfaces, title: L("Explicit surfaces"),
                 summary: L("z = f(x, y). A ripple and a saddle; use the opacity slider to see through the saddle.")) {
                var b = DemoBuilder(.space, azimuth: 0.7, elevation: 0.5)
                b.add(.surface, "z = 2·sin r / (1 + 0.4r)", "2*sin(sqrt(x^2 + y^2))/(1 + 0.4*sqrt(x^2 + y^2))")
                b.add(.surface, "z = (x² − y²)/6 − 3", "(x^2 - y^2)/6 - 3") { $0.fillStyle.opacity = 0.55 }
                return b.document
            },
            Demo(id: "space.parametric-surface", category: .surfaces, title: L("Parametric surfaces"),
                 summary: L("A sphere inside a torus, each given by (x, y, z) = F(u, v). Rotate with the mouse.")) {
                var b = DemoBuilder(.space, azimuth: 0.6, elevation: 0.7)
                b.add(.parametricSurface, "Torus", "(2.5 + 0.9*cos(v))*cos(u)", "(2.5 + 0.9*cos(v))*sin(u)", "0.9*sin(v)",
                      domain: 0...(2 * .pi), domain2: 0...(2 * .pi)) { $0.fillStyle.opacity = 0.6 }
                b.add(.parametricSurface, "Sphere", "1.4*cos(u)*sin(v)", "1.4*sin(u)*sin(v)", "1.4*cos(v)",
                      domain: 0...(2 * .pi), domain2: 0...(.pi))
                return b.document
            },
            Demo(id: "space.draw-in", category: .surfaces, title: L("A knot and a torus that build themselves"),
                 summary: L("The ranges of t and u end at p·2π. Press play on p: the trefoil knot is traced and the torus is swept out around its axis.")) {
                var b = DemoBuilder(.space, azimuth: 0.6, elevation: 0.6)
                b.document.parameters = [ParameterDefinition(name: "p", value: 0.65, lowerBound: 0, upperBound: 1)]
                b.add(.spaceCurve, "Trefoil knot", "sin(t) + 2*sin(2*t)", "cos(t) - 2*cos(2*t)", "-sin(3*t) + 2.6",
                      domain: 0...(2 * .pi)) {
                    $0.domainUpperFormula = "p*2*pi"
                    $0.lineStyle.width = 3
                }
                b.add(.parametricSurface, "Torus", "(2.6 + 0.7*cos(v))*cos(u)", "(2.6 + 0.7*cos(v))*sin(u)",
                      "0.7*sin(v) - 2.4", domain: 0...(2 * .pi), domain2: 0...(2 * .pi)) {
                    $0.domainUpperFormula = "p*2*pi"
                    $0.fillStyle.opacity = 0.8
                }
                return b.document
            },
            Demo(id: "space.curves", category: .surfaces, title: L("Space curves"),
                 summary: L("A trefoil knot and a helix, both (x, y, z) = F(t).")) {
                var b = DemoBuilder(.space, azimuth: 0.4, elevation: 0.6)
                b.add(.spaceCurve, "Trefoil knot", "sin(t) + 2*sin(2*t)", "cos(t) - 2*cos(2*t)", "-sin(3*t)",
                      domain: 0...(2 * .pi)) { $0.lineStyle.width = 3 }
                b.add(.spaceCurve, "Helix", "3.5*cos(t)", "3.5*sin(t)", "t/5 - 3", domain: 0...(6 * .pi))
                return b.document
            },
            Demo(id: "space.implicit-surface", category: .surfaces, title: L("Implicit surfaces"),
                 summary: L("F(x, y, z) = 0: a torus and a translucent sphere around it, extracted with marching tetrahedra.")) {
                var b = DemoBuilder(.space, azimuth: 0.6, elevation: 0.55)
                b.add(.implicitSurface, "Torus", "(x^2 + y^2 + z^2 + 4 - 0.64)^2 - 16*(x^2 + y^2)")
                b.add(.implicitSurface, "Sphere r = 3.4", "x^2 + y^2 + z^2 - 11.56") { $0.fillStyle.opacity = 0.25 }
                return b.document
            },

            Demo(id: "space.sphere-plane", category: .intersections, title: L("Sphere cut by a plane"),
                 summary: L("The intersection of a sphere and the plane z = 1 is a circle. Hide the surfaces to keep only the curve.")) {
                var b = DemoBuilder(.space, azimuth: 0.6, elevation: 0.5)
                let sphere = b.add(.implicitSurface, "Sphere r = 2.8", "x^2 + y^2 + z^2 - 7.84") { $0.fillStyle.opacity = 0.35 }
                let plane = b.add(.surface, "z = 1", "1") { $0.fillStyle.opacity = 0.35 }
                b.intersection("Circle", sphere, plane, width: 3.2)
                return b.document
            },
            Demo(id: "space.steinmetz", category: .intersections, title: L("Two cylinders (Steinmetz)"),
                 summary: L("Two equal cylinders cross along two ellipses lying in the planes x = ±z.")) {
                var b = DemoBuilder(.space, azimuth: 0.5, elevation: 0.45)
                let first = b.add(.implicitSurface, "x² + y² = 2.2²", "x^2 + y^2 - 4.84") { $0.fillStyle.opacity = 0.3 }
                let second = b.add(.implicitSurface, "x² + z² = 2.2²", "x^2 + z^2 - 4.84") { $0.fillStyle.opacity = 0.3 }
                b.intersection("Intersection", first, second, width: 3.2)
                return b.document
            },
            Demo(id: "space.viviani", category: .intersections, title: L("Viviani's curve"),
                 summary: L("A sphere and a cylinder through its centre axis offset by the radius meet in a figure-eight curve.")) {
                var b = DemoBuilder(.space, azimuth: 0.9, elevation: 0.55)
                let sphere = b.add(.implicitSurface, "x² + y² + z² = 9", "x^2 + y^2 + z^2 - 9") { $0.fillStyle.opacity = 0.3 }
                let cylinder = b.add(.implicitSurface, "(x − 1.5)² + y² = 1.5²", "(x - 1.5)^2 + y^2 - 2.25") { $0.fillStyle.opacity = 0.3 }
                b.intersection("Viviani", sphere, cylinder, width: 3.2)
                return b.document
            },
            Demo(id: "space.conic-section", category: .intersections, title: L("Conic section of a cone"),
                 summary: L("A tilted plane cuts a cone in an ellipse. Make the slope of the plane 1 (a parabola) or larger (a hyperbola).")) {
                var b = DemoBuilder(.space, azimuth: 0.7, elevation: 0.35)
                let cone = b.add(.implicitSurface, "x² + y² = z²", "x^2 + y^2 - z^2") { $0.fillStyle.opacity = 0.35 }
                let plane = b.add(.surface, "z = 0.45x + 2", "0.45*x + 2") { $0.fillStyle.opacity = 0.35 }
                b.intersection("Ellipse", cone, plane, width: 3.2)
                return b.document
            },
            Demo(id: "space.paraboloid-plane", category: .intersections, title: L("Paraboloid and a plane"),
                 summary: L("The cut of z = (x² + y²)/3 − 2 by the plane z = x is an ellipse, its shadow on the floor a circle.")) {
                var b = DemoBuilder(.space, azimuth: 0.55, elevation: 0.5)
                let bowl = b.add(.surface, "z = (x² + y²)/3 − 2", "(x^2 + y^2)/3 - 2") { $0.fillStyle.opacity = 0.45 }
                let plane = b.add(.surface, "z = x", "x") { $0.fillStyle.opacity = 0.35 }
                let cut = b.intersection("Ellipse", bowl, plane, width: 3.2)
                b.projection("Shadow on z = −3.5", of: cut, target: .xy, offset: -3.5, projectors: true)
                return b.document
            },

            Demo(id: "space.point-plane", category: .geometry, title: L("Distance from a point to a plane"),
                 summary: L("Select the point and the plane in the Relations panel; “Draw Results” adds the foot of the perpendicular.")) {
                var b = DemoBuilder(.space, azimuth: 0.8, elevation: 0.45)
                let plane = b.add(.implicitSurface, "x + 2y + 2z = 6", "x + 2*y + 2*z - 6") { $0.fillStyle.opacity = 0.4 }
                let point = b.point("P", 2, 2, 2.5)
                b.construct(point, plane)
                return b.document
            },
            Demo(id: "space.skew-lines", category: .geometry, title: L("Skew lines and the common perpendicular"),
                 summary: L("Two lines that neither meet nor are parallel, their distance and the common perpendicular segment.")) {
                var b = DemoBuilder(.space, azimuth: 0.9, elevation: 0.5)
                let first = b.add(.spaceCurve, "Line a", "t", "t/2", "-1", domain: -3.5...3.5) { $0.lineStyle.color = RGBAColor.paletteColor(1) }
                let second = b.add(.spaceCurve, "Line b", "1.5", "-t", "1 + t/2", domain: -3.5...3.5) { $0.lineStyle.color = RGBAColor.paletteColor(2) }
                b.construct(first, second)
                return b.document
            },
            Demo(id: "space.dihedral", category: .geometry, title: L("Two planes and their line of intersection"),
                 summary: L("The dihedral angle and the line where two planes meet; try tilting one plane by editing its formula.")) {
                var b = DemoBuilder(.space, azimuth: 0.7, elevation: 0.45)
                let first = b.add(.implicitSurface, "x + y + z = 1", "x + y + z - 1") { $0.fillStyle.opacity = 0.4 }
                let second = b.add(.implicitSurface, "x − y + 2z = 0", "x - y + 2*z") { $0.fillStyle.opacity = 0.4 }
                b.construct(first, second)
                return b.document
            },
            Demo(id: "space.line-plane", category: .geometry, title: L("A line piercing a plane"),
                 summary: L("The intersection point and the angle between the line and the plane.")) {
                var b = DemoBuilder(.space, azimuth: 0.8, elevation: 0.4)
                let plane = b.add(.implicitSurface, "x + y − z = 1", "x + y - z - 1") { $0.fillStyle.opacity = 0.4 }
                let line = b.add(.spaceCurve, "Line", "-2 + t", "1 + t/2", "2 - t/2", domain: -1...6)
                b.construct(line, plane)
                return b.document
            },

            Demo(id: "space.three-views", category: .projections, title: L("Three views of a helix"),
                 summary: L("Orthogonal projections of a helix onto the three coordinate planes, like the top, front and side views.")) {
                var b = DemoBuilder(.space, azimuth: 0.7, elevation: 0.45)
                let helix = b.add(.spaceCurve, "Helix", "2*cos(t)", "2*sin(t)", "t/2.4", domain: -7...7) { $0.lineStyle.width = 3 }
                b.projection("Top view", of: helix, target: .xy, offset: -4, projectors: true)
                b.projection("Side view", of: helix, target: .yz, offset: -4, projectors: false)
                b.projection("Front view", of: helix, target: .xz, offset: 4, projectors: false)
                return b.document
            },
            Demo(id: "space.oblique", category: .projections, title: L("Oblique and orthogonal projection"),
                 summary: L("A tilted circle and its two shadows on the floor: straight down, and along a slanted direction.")) {
                var b = DemoBuilder(.space, azimuth: 0.6, elevation: 0.4)
                let ring = b.add(.spaceCurve, "Tilted circle", "2*cos(t)", "2*sin(t)", "1.2 + 1.2*cos(t)",
                                 domain: 0...(2 * .pi)) { $0.lineStyle.width = 3 }
                b.projection("Straight down", of: ring, target: .xy, offset: -3, projectors: true)
                b.projection("Along (1, 0.5, 1)", of: ring, target: .xy, offset: -3, projectors: true) {
                    $0.projectionDirection = SIMD3(1, 0.5, 1)
                }
                return b.document
            },
            Demo(id: "space.tangent-paraboloid", category: .projections, title: L("Tangent planes of a paraboloid"),
                 summary: L("Two tangent planes of z = (x² + y²)/4 − 2, each with its normal. Change the point of tangency in the inspector.")) {
                var b = DemoBuilder(.space, azimuth: 0.7, elevation: 0.5)
                let bowl = b.add(.surface, "z = (x² + y²)/4 − 2", "(x^2 + y^2)/4 - 2") { $0.fillStyle.opacity = 0.5 }
                b.tangentPlane("Tangent plane at (2, 1)", of: bowl, at: 2, 1)
                b.tangentPlane("Tangent plane at (−1.5, −2)", of: bowl, at: -1.5, -2)
                return b.document
            },
            Demo(id: "space.tangent-slide", category: .projections, title: L("A tangent plane circling a paraboloid"),
                 summary: L("The point of tangency is (2 cos q, 2 sin q). Press play on q: the tangent plane and its normal travel once round the bowl.")) {
                var b = DemoBuilder(.space, azimuth: 0.7, elevation: 0.55)
                b.document.parameters = [ParameterDefinition(name: "q", value: 0.8, lowerBound: 0, upperBound: 6.2832)]
                let bowl = b.add(.surface, "z = (x² + y²)/4 − 2", "(x^2 + y^2)/4 - 2") { $0.fillStyle.opacity = 0.5 }
                b.tangentPlane("Tangent plane", of: bowl, at: 0, 0, uFormula: "2*cos(q)", vFormula: "2*sin(q)")
                return b.document
            },
            Demo(id: "space.tangent-sphere", category: .projections, title: L("Tangent plane of a sphere"),
                 summary: L("A tangent plane of a parametric sphere; the normal points along the radius to the centre.")) {
                var b = DemoBuilder(.space, azimuth: 0.9, elevation: 0.5)
                let sphere = b.add(.parametricSurface, "Sphere", "2.6*cos(u)*sin(v)", "2.6*sin(u)*sin(v)", "2.6*cos(v)",
                                   domain: 0...(2 * .pi), domain2: 0...(.pi)) { $0.fillStyle.opacity = 0.45 }
                b.tangentPlane("Tangent plane", of: sphere, at: 0.8, 1.1)
                return b.document
            },

            Demo(id: "space.gradient-hill", category: .gradients, title: L("Gradient on a hill"),
                 summary: L("Arrows point uphill, longer and redder where the slope is steeper. The top and the flat foot have none.")) {
                var b = DemoBuilder(.space, azimuth: 0.8, elevation: 0.65)
                let hill = b.add(.surface, "z = 3e^(−(x²+y²)/6)", "3*exp(-(x^2 + y^2)/6)") { $0.fillStyle.opacity = 0.55 }
                b.gradient("∇f", of: hill, density: 14)
                return b.document
            },
            Demo(id: "space.gradient-floor", category: .gradients, title: L("Gradient field as a vector field"),
                 summary: L("The same idea as in the textbook: ∇f drawn flat on the floor, always pointing across the contours of the surface above.")) {
                var b = DemoBuilder(.space, azimuth: 0.7, elevation: 0.55)
                let waves = b.add(.surface, "z = 1.5 sin x cos y", "1.5*sin(x)*cos(y)") { $0.fillStyle.opacity = 0.6 }
                b.gradient("∇f on the floor", of: waves, density: 16, onFloor: true)
                return b.document
            },
            Demo(id: "space.gradient-saddle", category: .gradients, title: L("Uphill and downhill on a saddle"),
                 summary: L("Uphill arrows (warm) and downhill arrows (negative length) of a saddle; the saddle point in the middle has none.")) {
                var b = DemoBuilder(.space, azimuth: 0.9, elevation: 0.5)
                let saddle = b.add(.surface, "z = (x² − y²)/5", "(x^2 - y^2)/5") { $0.fillStyle.opacity = 0.5 }
                b.gradient("∇f", of: saddle, density: 12)
                b.gradient("−∇f", of: saddle, density: 12, scale: -1)
                return b.document
            },
            Demo(id: "space.gradient-slider", category: .gradients, title: L("A gradient field that changes with a slider"),
                 summary: L("Drag s to make the hill wider or narrower: the steepest ring moves and the arrows follow live.")) {
                var b = DemoBuilder(.space, azimuth: 0.8, elevation: 0.6)
                b.document.parameters = [ParameterDefinition(name: "s", value: 6, lowerBound: 1.5, upperBound: 14)]
                let hill = b.add(.surface, "z = 3e^(−(x²+y²)/s)", "3*exp(-(x^2 + y^2)/s)") {
                    $0.fillStyle.opacity = 0.75
                    $0.colorsBySlope = true
                }
                b.gradient("∇f", of: hill, density: 14, scale: 1.2)
                return b.document
            },
            Demo(id: "space.gradient-heat", category: .gradients, title: L("Steepness as a heat map"),
                 summary: L("The surface itself is coloured by slope, blue where it is flat and red where it is steep, with the gradient field on the floor below.")) {
                var b = DemoBuilder(.space, azimuth: 0.75, elevation: 0.7)
                let waves = b.add(.surface, "z = sin x · cos y + x/4", "sin(x)*cos(y) + x/4") { $0.colorsBySlope = true }
                b.gradient("∇f on the floor", of: waves, density: 15, scale: 0.9, onFloor: true)
                return b.document
            },
            Demo(id: "space.gradient-climb", category: .gradients, title: L("Climbing to two summits"),
                 summary: L("Paths that follow the gradient from different starting points end on different summits. Press play on p to roll the balls along.")) {
                var b = DemoBuilder(.space, azimuth: 0.8, elevation: 0.6)
                b.document.parameters = [ParameterDefinition(name: "p", value: 0.35, lowerBound: 0, upperBound: 1)]
                let hills = b.add(.surface, "Two hills", "2.5*exp(-((x - 1.5)^2 + (y - 1)^2)/3) + 1.6*exp(-((x + 1.8)^2 + (y + 1.2)^2)/2.5)") {
                    $0.fillStyle.opacity = 0.5
                }
                b.flow("Uphill paths", of: hills,
                       seeds: "0.2, 0.2\n3, -0.5\n1.5, 3\n-0.5, 1.2\n-3, -2.5\n-1.5, 0\n0, -3\n3, 3", progress: "p")
                return b.document
            },
            Demo(id: "space.gradient-basins", category: .gradients, title: L("Which summit does it reach?"),
                 summary: L("One starting point travels round a circle, (3 cos q, 3 sin q). Press play on q: the path jumps from one summit to the other where the basins meet.")) {
                var b = DemoBuilder(.space, azimuth: 0.8, elevation: 0.6)
                b.document.parameters = [ParameterDefinition(name: "q", value: 0.5, lowerBound: 0, upperBound: 6.2832)]
                let hills = b.add(.surface, "Two hills", "2.5*exp(-((x - 1.5)^2 + (y - 1)^2)/3) + 1.6*exp(-((x + 1.8)^2 + (y + 1.2)^2)/2.5)") {
                    $0.fillStyle.opacity = 0.5
                }
                b.flow("Path from the moving start", of: hills, seeds: "3*cos(q), 3*sin(q)", progress: "1")
                return b.document
            },
            Demo(id: "space.gradient-descent", category: .gradients, title: L("Gradient descent in a narrow valley"),
                 summary: L("Following −∇f downhill into the valley: the path first drops across the steep walls, then slides along the floor. Press play on p.")) {
                var b = DemoBuilder(.space, azimuth: 0.55, elevation: 0.55)
                b.document.parameters = [ParameterDefinition(name: "p", value: 0.5, lowerBound: 0, upperBound: 1)]
                let valley = b.add(.surface, "z = x²/8 + y²/1.5 − 2", "x^2/8 + y^2/1.5 - 2") { $0.fillStyle.opacity = 0.5 }
                b.flow("Downhill paths", of: valley, seeds: "-3.6, 2.4\n3.6, 2.4\n-3.6, -2.4\n3.6, -2.4\n0, 3\n-3.2, 0.4",
                       progress: "p", descent: true)
                b.gradient("−∇f", of: valley, density: 10, scale: -0.8, onFloor: true)
                return b.document
            },

            Demo(id: "space.lesson-surface-area", category: .lessons, title: L("The surface area element dS"),
                 summary: L("Why dS = √(1 + z_x² + z_y²) dσ, step by step: a small piece dσ, the piece dS above it, the tangent plane, the normal and the angle γ. Turn the pages with ← → or the buttons on the card.")) {
                surfaceAreaLesson()
            },
        ]
    }

    // MARK: - 讲解

    /// 曲面面积元的推导：z = 3.6 − (x² + y²)/2（z_x = −x，z_y = −y），在 (a, b) 处取边长 h 的小方块 dσ。
    /// 坐标盒的底面就是 xOy 面（盒子 z 从 −0.05 起，底面上的东西不被裁掉）。
    static func surfaceAreaLesson() -> GrapherDocument {
        var b = DemoBuilder(.space)
        b.document.view3D = View3D(center: SIMD3(0, 0, 2.75), halfExtent: 2.8, azimuth: 35 * .pi / 180, elevation: 22 * .pi / 180)
        b.document.parameters = [
            ParameterDefinition(name: "a", value: 1, lowerBound: -1.8, upperBound: 1.2),
            ParameterDefinition(name: "b", value: 0.5, lowerBound: -1.8, upperBound: 1.2),
            ParameterDefinition(name: "h", value: 0.6, lowerBound: 0.08, upperBound: 1),
        ]
        let z = "3.6 - (x^2 + y^2)/2"
        let zP = "(3.6 - (a^2 + b^2)/2)"
        let ink = RGBAColor(0.15, 0.15, 0.2)
        let blue = RGBAColor(0.12, 0.42, 0.95)
        let orange = RGBAColor(0.92, 0.36, 0.1)
        let green = RGBAColor(0.13, 0.6, 0.3)
        let purple = RGBAColor(0.55, 0.22, 0.78)
        let amber = RGBAColor(0.93, 0.56, 0.05)
        func patch(_ layer: inout Layer) {
            layer.domainLowerFormula = "a"
            layer.domainUpperFormula = "a + h"
            layer.domain2LowerFormula = "b"
            layer.domain2UpperFormula = "b + h"
        }
        func paint(_ layer: inout Layer, _ color: RGBAColor, opacity: Double) {
            layer.lineStyle.color = color
            layer.fillStyle.color = color.withAlpha(0.22)
            layer.fillStyle.opacity = opacity
        }

        let surface = b.add(.surface, "S", z) { paint(&$0, RGBAColor(0.32, 0.56, 0.9), opacity: 0.42) }
        let slope = b.add(.surface, L("S coloured by slope"), z) {
            $0.colorsBySlope = true
            $0.fillStyle.opacity = 0.8
        }
        let region = b.add(.parametricSurface, "D", "u*cos(v)", "u*sin(v)", "0",
                           domain: 0...2.6833, domain2: 0...(2 * .pi)) { paint(&$0, RGBAColor(0.45, 0.47, 0.55), opacity: 0.2) }
        let dSigma = b.add(.parametricSurface, "dσ", "u", "v", "0.012", domain: 1...1.6, domain2: 0.5...1.1) {
            patch(&$0)
            paint(&$0, blue, opacity: 0.9)
        }
        let dS = b.add(.parametricSurface, "dS", "u", "v", "3.6 - (u^2 + v^2)/2 + 0.015", domain: 1...1.6, domain2: 0.5...1.1) {
            patch(&$0)
            paint(&$0, orange, opacity: 1)
        }
        // 以 dσ 的边界为准线、母线平行于 z 轴的柱面：u 绕边界一圈（0…4，每条边占 1），v 从 xOy 面升到曲面。
        let rimX = "(a + h*clamp(u, 0, 1) - h*clamp(u - 2, 0, 1))"
        let rimY = "(b + h*clamp(u - 1, 0, 1) - h*clamp(u - 3, 0, 1))"
        let walls = b.add(.parametricSurface, L("Cylinder over dσ"), rimX, rimY, "v*(3.6 - (\(rimX)^2 + \(rimY)^2)/2)",
                          domain: 0...4, domain2: 0...1) { paint(&$0, RGBAColor(0.42, 0.44, 0.5), opacity: 0.2) }
        let dA = b.add(.parametricSurface, "dA", "u", "v", "\(zP) - a*(u - a) - b*(v - b) + 0.03",
                       domain: 1...1.6, domain2: 0.5...1.1) {
            patch(&$0)
            paint(&$0, green, opacity: 0.72)
        }
        let point = b.add(.point, "P", "a", "b", zP) {
            $0.lineStyle.color = ink
            $0.lineStyle.width = 2.6
        }
        // 法向量 n = (−z_x, −z_y, 1) = (a, b, 1)，画成长 1.6 的箭头。
        let normal = b.add(.spaceCurve, "n", "a + a*t", "b + b*t", "\(zP) + t", domain: 0...1) {
            $0.domainUpperFormula = "1.6/sqrt(1 + a^2 + b^2)"
            $0.showsArrow = true
            $0.lineStyle.color = purple
            $0.lineStyle.width = 3
        }
        let up = b.add(.spaceCurve, "k", "a", "b", "\(zP) + t", domain: 0...1.6) {
            $0.showsArrow = true
            $0.lineStyle.color = RGBAColor(0.35, 0.36, 0.42)
            $0.lineStyle.width = 2.4
        }
        // n 与 k 的夹角 γ：在 k、n 张成的竖直平面里画一段半径 0.7 的圆弧，tan γ = √(a² + b²)。
        let g = "sqrt(a^2 + b^2)"
        let angle = b.add(.spaceCurve, "γ", "a + 0.7*sin(t)*a/\(g)", "b + 0.7*sin(t)*b/\(g)", "\(zP) + 0.7*cos(t)",
                          domain: 0...1) {
            $0.domainUpperFormula = "atan(\(g))"
            $0.lineStyle.color = amber
            $0.lineStyle.width = 2.6
        }

        // 小片的名字：dσ、dS 写在 +y 一侧（多数步骤里是画面右边），dA 写在 −y 一侧，免得和 dS 叠在一起。
        let labelS = b.text("S", x: "-1.3", y: "1.5", z: "1.9", color: RGBAColor(0.2, 0.4, 0.75))
        let labelD = b.text("D", x: "2.0", y: "-1.0", z: "0.05", color: RGBAColor(0.35, 0.37, 0.45))
        let labelSigma = b.text("dσ", x: "a + h/2", y: "b + h + 0.15", z: "0.03", color: blue)
        let labelDS = b.text("dS", x: "a + h/2", y: "b + h + 0.15", z: "3.6 - ((a + h/2)^2 + (b + h)^2)/2 + 0.12", color: orange)
        let labelDA = b.text("dA", x: "a + h/2", y: "b - 0.35", z: "\(zP) - a*h/2 + 0.35*b + 0.1", color: green)
        let s = "1.6/sqrt(1 + a^2 + b^2)"
        let labelN = b.text("n", x: "a + a*\(s) + 0.08", y: "b + b*\(s)", z: "\(zP) + \(s) + 0.08", color: purple)
        let labelK = b.text("k", x: "a + 0.1", y: "b", z: "\(zP) + 1.62", color: RGBAColor(0.35, 0.36, 0.42))
        let half = "atan(\(g))/2"
        let labelGamma = b.text("γ", x: "a + 0.95*sin(\(half))*a/\(g)", y: "b + 0.95*sin(\(half))*b/\(g)",
                                z: "\(zP) + 0.95*cos(\(half))", color: amber)

        b.step(L("The surface S: $z=z(x,y)$"),
               L("We want the area of the surface $S$: $z=z(x,y)$, whose projection onto the $xOy$ plane is the region $D$; $z(x,y)$ has continuous partial derivatives. Here $z=3.6-\\dfrac{x^2+y^2}{2}$, so $z_x=-x$ and $z_y=-y$."),
               show: [surface, region, labelS, labelD], azimuth: 35, elevation: 22, zoom: 1,
               parameters: ["a": 1, "b": 0.5, "h": 0.6])
        b.step(L("Take a small piece $\\mathrm d\\sigma$ of $D$"),
               L("Cut $D$ into many small pieces and take any one of them, $\\mathrm d\\sigma$: here a small square with one corner at $(x,y)$ and sides $\\mathrm dx=\\mathrm dy=h$. Its area is also written $\\mathrm d\\sigma$."),
               show: [surface, region, dSigma, labelS, labelD, labelSigma], azimuth: 30, elevation: 30, zoom: 1.15)
        b.step(L("The piece $\\mathrm dS$ above $\\mathrm d\\sigma$"),
               L("The cylinder whose base is the boundary of $\\mathrm d\\sigma$ and whose rulings are parallel to the $z$-axis cuts a small piece out of $S$; call it $\\mathrm dS$. Its projection onto the $xOy$ plane is exactly $\\mathrm d\\sigma$. Where the surface is steeper, $\\mathrm dS$ is larger than $\\mathrm d\\sigma$."),
               show: [surface, dSigma, walls, dS, labelSigma, labelDS], azimuth: 24, elevation: 26, zoom: 1.35)
        b.step(L("Replace $\\mathrm dS$ by a piece of the tangent plane"),
               L("Take the tangent plane of $S$ at $P(x,y,z(x,y))$. The same cylinder cuts a parallelogram $\\mathrm dA$ out of it. When $\\mathrm d\\sigma$ is small, $\\mathrm dS\\approx\\mathrm dA$, with an error of higher order than $\\mathrm d\\sigma$."),
               show: [surface, dSigma, walls, dS, dA, point, labelSigma, labelDS, labelDA], azimuth: 14, elevation: 22, zoom: 1.5)
        b.step(L("The normal vector and the angle $\\gamma$"),
               L("A normal vector of the tangent plane is $\\vec n=(-z_x,-z_y,1)$. Let $\\gamma$ be the angle between $\\vec n$ and the positive $z$-axis $\\vec k$: $$\\cos\\gamma=\\frac{\\vec n\\cdot\\vec k}{|\\vec n|}=\\frac{1}{\\sqrt{1+z_x^2+z_y^2}}.$$"),
               show: [surface, dSigma, walls, dA, point, normal, up, angle, labelSigma, labelDA, labelN, labelK, labelGamma],
               azimuth: -30, elevation: 16, zoom: 1.5)
        b.step(L("Projection multiplies area by $|\\cos\\gamma|$"),
               L("Projecting a plane figure onto another plane multiplies its area by the cosine of the angle between the planes. The angle between the tangent plane and the $xOy$ plane equals the angle $\\gamma$ between their normals $\\vec n$ and $\\vec k$, and the projection of $\\mathrm dA$ is $\\mathrm d\\sigma$, so $$\\mathrm d\\sigma=|\\cos\\gamma|\\,\\mathrm dA\\approx|\\cos\\gamma|\\,\\mathrm dS.$$"),
               show: [dSigma, walls, dA, point, normal, up, angle, labelSigma, labelDA, labelN, labelK, labelGamma],
               azimuth: -50, elevation: 12, zoom: 1.6)
        b.step(L("The area element"),
               L("From $\\mathrm d\\sigma=|\\cos\\gamma|\\,\\mathrm dS$ and $|\\cos\\gamma|=\\dfrac{1}{\\sqrt{1+z_x^2+z_y^2}}$: $$\\mathrm dS=\\sqrt{1+z_x^2(x,y)+z_y^2(x,y)}\\,\\mathrm d\\sigma.$$ As $h$ shrinks (it is playing now), $\\mathrm dS$ and $\\mathrm dA$ fit closer and closer."),
               show: [surface, dSigma, walls, dS, dA, point, labelSigma, labelDS, labelDA],
               azimuth: 28, elevation: 26, zoom: 1.4, plays: ["h"])
        b.step(L("Add up the pieces: the area of $S$"),
               L("Summing over all the pieces gives $$S=\\iint_D\\sqrt{1+z_x^2+z_y^2}\\,\\mathrm d\\sigma.$$ The surface is now coloured by slope: where it is steeper (red), $\\sqrt{1+z_x^2+z_y^2}$ is larger and the same $\\mathrm d\\sigma$ carries a larger $\\mathrm dS$. Drag $a$ and $b$ to move the piece around."),
               show: [slope, region, dSigma, walls, dS, labelD, labelSigma, labelDS],
               azimuth: 35, elevation: 34, zoom: 1, parameters: ["h": 0.6])
        // 结束讲解后图层按自己的开关显示：和最后一步一样，不把所有辅助图层一起摊出来。
        if let last = b.document.lessonSteps.last {
            for index in b.document.layers.indices {
                b.document.layers[index].isVisible = last.visibleLayers.contains(b.document.layers[index].id)
            }
        }
        return b.document
    }
}

// MARK: - 搭建示例的小工具

/// 把示例里反复出现的「建图层、设范围、配视图」收拢起来。
struct DemoBuilder {
    var document: GrapherDocument

    init(_ dimension: DocumentDimension, centerX: Double = 0, centerY: Double = 0, scale: Double = 40,
         azimuth: Double = 0.55, elevation: Double = 0.45) {
        document = GrapherDocument(dimension: dimension)
        if dimension == .plane {
            document.viewport.centerX = centerX
            document.viewport.centerY = centerY
            document.viewport.scale = scale
        } else {
            document.view3D = View3D(center: .zero, halfExtent: 4, azimuth: azimuth, elevation: elevation)
        }
    }

    @discardableResult
    mutating func add(
        _ kind: PlotKind, _ name: String, _ formula: String = "", _ secondary: String = "", _ tertiary: String = "",
        domain: ClosedRange<Double>? = nil, domain2: ClosedRange<Double>? = nil,
        _ configure: ((inout Layer) -> Void)? = nil
    ) -> Layer {
        var layer = Layer.makeDefault(kind: kind, index: document.layers.count)
        layer.name = name
        layer.formula = formula
        layer.secondaryFormula = secondary
        layer.tertiaryFormula = tertiary
        if let domain {
            layer.domainLower = domain.lowerBound
            layer.domainUpper = domain.upperBound
            layer.usesExplicitDomain = true
        }
        if let domain2 {
            layer.domain2Lower = domain2.lowerBound
            layer.domain2Upper = domain2.upperBound
        }
        configure?(&layer)
        document.layers.append(layer)
        return layer
    }

    @discardableResult
    mutating func point(_ name: String, _ x: Double, _ y: Double, _ z: Double) -> Layer {
        add(.point, name, "\(x)", "\(y)", "\(z)")
    }

    @discardableResult
    mutating func text(_ content: String, at x: Double, _ y: Double, _ z: Double = 0) -> Layer {
        add(.text, content, content) {
            $0.anchorU = x
            $0.anchorV = y
            $0.anchorW = z
        }
    }

    /// 位置写成含参数的公式的文字（跟着参数动）。
    @discardableResult
    mutating func text(_ content: String, x: String, y: String, z: String, color: RGBAColor, size: Double = 16) -> Layer {
        add(.text, content, content) {
            $0.anchorUFormula = x
            $0.anchorVFormula = y
            $0.anchorWFormula = z
            $0.fontSize = size
            $0.lineStyle.color = color
        }
    }

    /// 讲解的一步：显示 `show` 里的图层；给了角度（度）、缩放就转相机，`parameters` 是进这一步时参数要变成的值。
    mutating func step(
        _ title: String, _ text: String, show: [Layer],
        azimuth: Double? = nil, elevation: Double? = nil, zoom: Double? = nil,
        parameters: [String: Double] = [:], plays: [String] = []
    ) {
        var camera: LessonCamera?
        if azimuth != nil || elevation != nil || zoom != nil {
            var view = document.view3D
            if let azimuth { view.azimuth = azimuth * .pi / 180 }
            if let elevation { view.elevation = elevation * .pi / 180 }
            if let zoom { view.cameraZoom = zoom }
            camera = LessonCamera(space: view)
        }
        document.lessonSteps.append(LessonStep(
            title: title, text: text, visibleLayers: show.map(\.id), camera: camera,
            parameters: parameters, plays: plays))
    }

    @discardableResult
    mutating func flow(
        _ name: String, of source: Layer, seeds: String, progress: String = "1", descent: Bool = false, onFloor: Bool = false
    ) -> Layer {
        add(.gradientFlow, name, seeds, progress) {
            $0.sourceA = source.id
            $0.arrowScale = descent ? -1 : 1
            $0.gradientOnFloor = onFloor
            $0.lineStyle.width = 2.6
        }
    }

    @discardableResult
    mutating func gradient(
        _ name: String, of source: Layer, density: Int, scale: Double = 1, onFloor: Bool = false
    ) -> Layer {
        add(.gradientField, name) {
            $0.sourceA = source.id
            $0.gridDensity = density
            $0.arrowScale = scale
            $0.gradientOnFloor = onFloor
            $0.lineStyle.width = 2.2
        }
    }

    @discardableResult
    mutating func tangent(
        _ name: String, of source: Layer, at position: Double, normal: Bool = false, positionFormula: String = ""
    ) -> Layer {
        add(.tangent, name) {
            $0.sourceA = source.id
            $0.anchorU = position
            $0.anchorUFormula = positionFormula
            $0.drawsNormal = normal
        }
    }

    @discardableResult
    mutating func tangentPlane(
        _ name: String, of source: Layer, at u: Double, _ v: Double, uFormula: String = "", vFormula: String = ""
    ) -> Layer {
        add(.tangentPlane, name) {
            $0.sourceA = source.id
            $0.anchorU = u
            $0.anchorV = v
            $0.anchorUFormula = uFormula
            $0.anchorVFormula = vFormula
        }
    }

    @discardableResult
    mutating func intersection(_ name: String, _ first: Layer, _ second: Layer, width: Double = 2.4) -> Layer {
        add(.surfaceIntersection, name) {
            $0.sourceA = first.id
            $0.sourceB = second.id
            $0.lineStyle.width = width
            $0.lineStyle.color = RGBAColor(0.86, 0.15, 0.15)
        }
    }

    @discardableResult
    mutating func projection(
        _ name: String, of source: Layer, target: ProjectionTarget, offset: Double, projectors: Bool,
        _ configure: ((inout Layer) -> Void)? = nil
    ) -> Layer {
        add(.projection, name) {
            $0.sourceA = source.id
            $0.projectionTarget = target
            $0.projectionOffset = offset
            $0.showsProjectors = projectors
            $0.lineStyle.width = 2.6
            configure?(&$0)
        }
    }

    /// 把两个对象的位置关系里能画出来的辅助对象（垂足、交点、公垂线、交线）加成图层，
    /// 并把距离 / 夹角写成一行字摆在盒子角上。
    mutating func construct(_ first: Layer, _ second: Layer) {
        let compiled = LayerCompiler().compile(document)
        guard let a = compiled.first(where: { $0.layer.id == first.id }).flatMap({ SpaceGeometry.recognize($0, in: compiled) }),
              let b = compiled.first(where: { $0.layer.id == second.id }).flatMap({ SpaceGeometry.recognize($0, in: compiled) })
        else { return }
        let relation = SpaceGeometry.relation(a, b)
        for construction in relation.constructions {
            var layer = construction.makeLayer(index: document.layers.count, lineExtent: 12)
            layer.lineStyle.color = RGBAColor(0.86, 0.15, 0.15)
            if case .line = construction { layer.lineStyle.width = 2.8 }
            document.layers.append(layer)
        }
        let measures = relation.measures.map { measure in
            measure.isAngle ? String(format: "%@ %.1f°", measure.name, measure.value)
                            : String(format: "%@ %.3f", measure.name, measure.value)
        }
        // 只有一个辅助点（垂足 / 交点）时写出它的名字；两个垂足之类写出来太挤，留给用户在检查器里打开。
        let points = relation.constructions.filter { if case .point = $0 { return true } else { return false } }
        if points.count > 1 {
            for index in document.layers.indices where document.layers[index].kind == .point
                && document.layers[index].showsLabel && points.contains(where: { $0.name == document.layers[index].name }) {
                document.layers[index].showsLabel = false
            }
        }
        text(([relation.summary] + measures).joined(separator: "  ·  "), at: -3.9, -3.9, 3.9)
    }
}
