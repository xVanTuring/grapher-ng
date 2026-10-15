import Foundation

extension GrapherText {

    /// 写法说明（英文，给 AI 读）：MCP 的 `get_text_reference` 返回它，UniReader 的笔记技能也引用它。
    /// 写法示例由 `examples` 拼在后面，测试保证每一个都能读、能画。
    public static var reference: String {
        let samples = examples.map { "# \($0.title)\n```grapher\n\($0.text)\n```" }.joined(separator: "\n\n")
        return referenceText + "\n\nEXAMPLES\n\n" + samples
    }

    private static let referenceText = """
    Grapher text format (a ```grapher block in a Markdown note)

    One thing per line. Blank lines and lines starting with # or // are ignored.
    A mistake in one line only skips that line (the rest still draws); the error names the line number.
    Formulas use the same syntax as get_reference (x, y, z, t, theta, u, v, pi, sin, cos, exp, sqrt, abs, ^ …).

    SETTINGS (all optional)
      plane | space           2D or 3D. Omitted: 3D when any 3D layer is present, else 2D.
      theme: light | dark     Omitted: follows the app's theme.
      aspect: 1.5             width / height of the block (or 16:9). Default 1.5.
      grid: off   axes: off   ticks: off   minor-grid: on
      view: …                 the camera (see below). It is what the "save view" button rewrites.
      param a = 1.5 [0, 3]    a slider named a: value, then [lower, upper]. Names cannot be x y z t u v r e pi theta or a function name.
                              Formulas can use a anywhere, including ranges and positions.

    VIEW
      3D:  view: azimuth=35 elevation=25 zoom=1 range=4 center=0,0,0
           angles in degrees; range = half the side of the axis box (data units); zoom enlarges the box on screen.
      2D:  view: center=0,0 width=12        width = how many x units are visible across the block.

    LAYERS
      <type> [name]: <formulas>; <options>
      Separate pieces with ';'. A name is optional but needed when another layer refers to it (no ',' '=' or ':' in names).
      Options are key=value (or just the key for yes/no ones: dash, hidden, normal, floor, slope, fit, extrude).
      Common options: color=#rrggbb or red|blue|green|orange|purple|teal|pink|gray|black  width=2  dash  hidden
      opacity=0.5 (surfaces, regions, tangent planes, extruded curves).

      2D types
        explicit    f(x)                     explicit: sin(x); x=-6..6        (y = f(x) also accepted)
        parametric  x(t); y(t)               parametric: cos(t); sin(t); t=0..2*pi
        polar       r(theta)                 polar: 1+cos(theta)
        implicit    F(x,y) or F(x,y)=G(x,y)  implicit: x^2+y^2=1; levels=1,2   (extra contour levels)
        region      inequality               region: x^2+y^2<=1               (< <= > >= ≤ ≥)
        tangent     of=<curve>; at=<x|t|theta>   tangent: of=C; at=1; normal   (normal = draw the normal line)
        text        "words"                  text: "A"; at=1, 2; size=14
        scatter     rows "x, y"              scatter: 1, 2.1; 2, 3.9; 3, 6.2; fit   (fit = least-squares line)
      3D types (also all 2D curve types, drawn on z=0, or extrude: explicit/parametric/polar/implicit as a vertical wall)
        surface            f(x,y)                       surface S: sin(x)*cos(y); slope   (slope = color by steepness)
        parametric-surface x(u,v); y(u,v); z(u,v)       u=0..2*pi; v=0..2*pi
        space-curve        x(t); y(t); z(t)             t=0..4*pi; arrow   (arrow = arrowhead at the end of t, for vectors)
        implicit-surface   F(x,y,z) or F=G              implicit-surface: x^2+y^2+z^2=4
        intersection       of=A, B                      two surface-like layers (surface, parametric-surface, implicit-surface)
        point              x; y; z                      point P: 1; 2; 3     (the name is drawn next to it; label=off hides it)
        projection         of=<point|space-curve|intersection>; onto=xy|yz|xz|<plane layer>; offset=0; direction=1,0,1; projectors=off
        tangent-plane      of=<surface|parametric-surface>; at=x, y     (or u, v for a parametric surface)
        gradient-field     of=<surface>; density=12; scale=1; floor     (arrows of the gradient; negative scale = descent)
        gradient-flow      of=<surface>; x0, y0; x1, y1; ball=0.5       (paths uphill; ball = position along the path, 0..1)

      Ranges: var=lower..upper, e.g. t=0..2*pi, x=-3..3, u=0..pi. Ends may be formulas with parameters (x=-3..3*p).
      Positions (at, offset, ball, text at=) may be numbers or formulas with parameters, so a slider can move a tangent point,
      a tangent plane, a ball or a label.
      Layers refer to each other by name (of=S). Put the referred layer anywhere in the block.

    LESSON (optional: explain a derivation step by step; the reader turns pages and the picture changes with them)
      step <title>: show=A, B; azimuth=30 elevation=20; a=1.2; play=a
      > The text of this step. Inline TeX $\\mathrm dS$, a formula on its own line $$S=\\iint_D f\\,\\mathrm d\\sigma$$, **bold**.
      > More '>' lines belong to the same step; an empty '>' line starts a new paragraph.
      show=A, B      the layers this step shows (by name). add=C / hide=A change the previous step's set.
                     Nothing given: same as the previous step (a first step without show= shows every layer).
                     Layers that no step names are always shown.
      Camera keys as in view: (3D azimuth elevation zoom range center; 2D center width), separated by ';'.
                     Omitted: the camera stays where the previous step left it.
      <param>=<number>   moves that slider (animated) when the step opens.   play=<param>   starts playing it.
      focus=<layer>  highlights that layer.
      The title may hold TeX too. The first plain ':' ends the title: use '：' or put ':' inside $…$.
      Steps play in the Grapher NG window and in render_text step=N. A block inside a note does not page through steps yet:
      it draws every layer that is not hidden, so mark helper layers hidden if the plain picture should stay clean.
      TeX supported: fractions (\\frac \\dfrac), roots, sub/superscripts, Greek, \\mathrm \\mathbf \\mathbb \\text,
      \\vec \\hat \\bar, \\left( \\right), \\int \\iint \\oint \\sum \\lim (with \\limits), common relations and arrows.

    TIPS
      - Check with render_text before writing it into the note; fix every reported line.
      - For a lesson, render_text with step=N shows that page with its text card.
      - Prefer a few well-chosen layers and 1–3 sliders; give surfaces opacity=0.5–0.85 when something sits inside or behind them.
      - 3D z range is the axis box: use range= (and center=) to frame the part that matters.
    """
}
