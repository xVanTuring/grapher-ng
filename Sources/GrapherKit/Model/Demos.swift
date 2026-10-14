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

    public var dimension: DocumentDimension {
        switch self {
        case .curves, .parameters, .tangents, .data: return .plane
        case .surfaces, .intersections, .geometry, .projections, .gradients: return .space
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
        ]
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
    mutating func tangent(_ name: String, of source: Layer, at position: Double, normal: Bool = false) -> Layer {
        add(.tangent, name) {
            $0.sourceA = source.id
            $0.anchorU = position
            $0.drawsNormal = normal
        }
    }

    @discardableResult
    mutating func tangentPlane(_ name: String, of source: Layer, at u: Double, _ v: Double) -> Layer {
        add(.tangentPlane, name) {
            $0.sourceA = source.id
            $0.anchorU = u
            $0.anchorV = v
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
