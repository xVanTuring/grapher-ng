import Foundation

extension GrapherText {

    public struct Example: Sendable {
        public var id: String
        public var title: String
        public var text: String
    }

    /// 写法示例：`get_reference` 里给 AI 看，测试逐个检查能读、能画。
    public static let examples: [Example] = [
        Example(id: "plane-wave", title: "A curve with a slider", text: """
        param a = 1.5 [0, 3]
        view: center=0,0 width=14
        explicit f: a*sin(x); x=-6..6; color=#2563eb; width=2.4
        """),
        Example(id: "plane-tangent", title: "A tangent line sliding along a parabola", text: """
        param p = 1 [-2, 2]
        view: center=0,1.5 width=8
        explicit C: x^2/2 - 1; color=#2563eb; width=2.4
        tangent T: of=C; at=p; color=#dc2626
        text: "tangent line"; at=p, 2.4; size=13; color=#dc2626
        """),
        Example(id: "plane-region", title: "An inequality region and its boundary", text: """
        view: center=0,0 width=7
        region: x^2 + y^2 <= 4; color=#16a34a; opacity=0.35
        implicit: x^2 + y^2 = 4; color=#16a34a
        explicit: y = x; dash
        """),
        Example(id: "plane-scatter", title: "Scatter data with a least-squares line", text: """
        view: center=3,5 width=9
        scatter: 1, 2.1; 2, 3.9; 3, 6.2; 4, 7.8; 5, 10.1; fit
        """),
        Example(id: "space-surface", title: "A surface with a slider", text: """
        space
        param a = 1.5 [0, 3]
        view: azimuth=35 elevation=28
        surface S: a*sin(x)*cos(y); opacity=0.85; slope
        """),
        Example(id: "space-tangent-plane", title: "A tangent plane on a surface", text: """
        space
        param s = 0.8 [-2, 2]
        view: azimuth=30 elevation=30
        surface S: (x^2 + y^2)/4; opacity=0.6
        point P: s; 0.5; (s^2 + 0.25)/4
        tangent-plane: of=S; at=s, 0.5; opacity=0.5; color=orange
        """),
        Example(id: "space-intersection", title: "A sphere cut by a plane", text: """
        space
        view: azimuth=40 elevation=25 range=2.5
        implicit-surface Ball: x^2 + y^2 + z^2 = 4; opacity=0.35
        surface Cut: 0.5*x + 0.3*y; opacity=0.35; color=orange
        intersection: of=Ball, Cut; color=red; width=3
        """),
        Example(id: "space-gradient", title: "A ball rolling uphill along the gradient", text: """
        space
        param q = 0.5 [0, 1]
        view: azimuth=35 elevation=35 center=0,0,1 range=3.5
        surface S: 2*exp(-((x-1)^2+(y-1)^2)/2) + 1.5*exp(-((x+1.5)^2+(y+1)^2)/1.5); opacity=0.85; slope
        gradient-flow: of=S; 2, 2; -2.5, 0; 0, -2; ball=q; color=#111827
        """),
    ]
}
