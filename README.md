<p align="center">
  <img src="Sources/GrapherApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Grapher NG icon">
</p>

<h1 align="center">Grapher NG</h1>

<p align="center">
  A native macOS graphing app: type a formula, get curves, regions and surfaces.<br>
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a>
</p>

![2D graph](docs/screenshot.png)

![3D graph](docs/screenshot-3d.png)

## Features

- **2D graphs**: explicit functions `y = f(x)`, parametric curves, polar curves, implicit curves `F(x, y) = 0` and
  inequality regions.
- **3D graphs**: explicit surfaces, parametric surfaces, space curves and implicit surfaces; 2D curves can be placed in
  3D too. Rotate, pan and zoom freely.
- **Parameter sliders**: define a parameter such as `a`, use it in any formula, and drag the slider to see the graph change live.
- **Readable formulas**: implicit multiplication (`2x`, `3sin(x)`), common math functions and constants, piecewise
  functions with `if(...)`, and clear error messages that point at the mistake.
- **Smooth rendering**: Metal-drawn curves with crisp edges and constant line width at any zoom.
- **Hover read-out**: move the pointer over a 2D curve to see the nearest point, its coordinates and slope.
- **Files and export**: save as `.grapher` documents, export PNG (re-sampled at 1×/2×/4×), vector PDF and CSV of sample points.
- **Finder integration**: file icons show the graph; press Space for an interactive Quick Look preview.
- **AI can draw for you**: a built-in MCP server lets Claude Code and other assistants create documents and insert
  curves, regions and surfaces, then look at the result. Off by default; see [docs/usage.md](docs/usage.md).
- **Language**: English and Chinese, following the system language.

## Download

Download `GrapherNG-<version>.dmg` from [GitHub Releases](https://github.com/xVanTuring/grapher-ng/releases), open it and
drag Grapher NG into Applications. The app is signed with a Developer ID and notarized by Apple, and requires macOS 14 or later.
Once installed it checks for updates once a day; you can also check manually with Grapher NG ▸ Check for Updates….

## Quick start

| Kind | Example |
|---|---|
| Explicit function | `a*sin(x)/x` |
| Polar curve | `1 + cos(theta)` |
| Implicit curve | `x^3 + y^3 - 3*x*y` |
| Inequality region | `x^2 + y^2 - 1` with `≤` |
| 3D implicit surface (sphere) | `x^2 + y^2 + z^2 - 4` |

`File ▸ Load Example` loads ready-made 2D and 3D examples. Common shortcuts: drag to pan (rotate in 3D), `⌘`-scroll or
pinch to zoom, `F` to fit content, `R` to reset the view, `⌘Z` / `⇧⌘Z` to undo / redo, `⇧⌘N` for a new 3D graph.

## Development

See [DEV.md](DEV.md) for building, code layout and rendering notes. Release process: [docs/release.md](docs/release.md).

## License

Released under the [GNU General Public License v3.0 or later](LICENSE) (GPL-3.0-or-later).
