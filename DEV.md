# Grapher NG — Development

**English** · [简体中文](DEV.zh-CN.md)

## Build and run

```bash
xcodegen generate                          # the project is generated from project.yml; GrapherNG.xcodeproj is not checked in
xcodebuild -project GrapherNG.xcodeproj -scheme GrapherNG \
  -derivedDataPath build/DerivedData -resolvePackageDependencies   # resolve Sparkle before the first build
bash scripts/build.sh                      # same as xcodebuild … -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/GrapherNG.app

bash scripts/run.sh                        # build and run, with logs in the terminal
bash scripts/test.sh                       # run the unit tests
```

Requires Xcode and `xcodegen` (`brew install xcodegen`). The project is managed the same way as Perch, FreeMind and UniReader.
Signing, notarization, packaging and releases are described in [docs/release.md](docs/release.md) (in Chinese).

The icon can be regenerated with `bash scripts/make-icon.sh` (needs Python with Pillow); it writes
`Sources/GrapherApp/Resources/Assets.xcassets/AppIcon.appiconset`.

## Headless mode

Handy for debugging and making images:

```bash
# Render an image without opening a window
build/DerivedData/Build/Products/Debug/GrapherNG.app/Contents/MacOS/GrapherNG \
  --render out.png --doc doc.grapher --width 1600 --height 1200 --quality high

# Render the 3D example (pass a 3D file with --doc), from another angle
build/DerivedData/Build/Products/Debug/GrapherNG.app/Contents/MacOS/GrapherNG \
  --render out.png --space --azimuth 1.2 --elevation 0.3

# Sampling and evaluation performance
build/DerivedData/Build/Products/Debug/GrapherNG.app/Contents/MacOS/GrapherNG --benchmark
```

## Code layout

```
project.yml          xcodegen project definition (GrapherNG.xcodeproj is generated)
Sources/
  GrapherKit/        pure logic with no UI framework (framework target)
    Expr/            lexer → parser → bytecode → stack VM evaluator
    Sampling/        adaptive subdivision, marching squares, region fill, probes, scene assembly, axis label layout;
                     3D surface meshes, marching tetrahedra, space curves, box wireframe
    Model/           documents, layers, view transforms (2D viewport, 3D box and camera), ticks, canvas input rules
    IO/              PDF / CSV export
  GrapherRender/     Metal rendering (framework target): 2D strokes and fills, 3D surfaces and lines,
                     offscreen export, thumbnails, MTKView wrappers
  GrapherApp/        AppKit UI and event handling, document model, welcome window, updates, command-line mode
    MCP/             built-in MCP server (see below): JSON-RPC and HTTP parsing, tool catalog, tools, document facade, settings window
Extensions/
  QuickLook/         Finder Quick Look preview (an interactive, read-only canvas)
  Thumbnail/         Finder file thumbnails
Tests/
  GrapherNGTests/    expressions (with fuzzing and benchmarks), sampling and geometry, the full pipeline,
                     pixel assertions on offscreen renders
```

The code is split into three targets rather than one app so that the compiler enforces a boundary: **GrapherKit may not
import AppKit**. Most of the unit tests run against it.

In Debug, `GrapherKit` alone is built with `-O` and whole-module optimization: this layer is numerically heavy, and `-Onone`
makes grid evaluation 27 times slower (1.2M vs 32M points per second measured), leaving 5 frames per second while dragging.
The UI layer stays at `-Onone` for normal debugging.

The UI is all AppKit: a three-pane `NSSplitViewController`, an `NSTableView` layer list, `NSStackView` forms, `NSColorWell`
colour pickers, an `NSToolbar` and a hand-built `NSMenu` menu bar. Tick labels and the pointer read-out sit in a layer above
the Metal canvas, drawn with Core Graphics and Core Text. `AppState` broadcasts changes through a minimal observer callback
with no Combine or binding framework; no declarative UI framework is involved anywhere.

## MCP server

Hand-rolled JSON-RPC 2.0 over HTTP on `Network.framework`, no MCP SDK — the same design as Perch and UniReader. User-facing
usage is in [docs/usage.md](docs/usage.md).

- `MCPServer` listens on 127.0.0.1 inside the app process (off by default; settings live in `MCPSettings`, the bearer
  token in the Keychain). One request per connection, `POST /mcp` only, `Origin` checked when present.
- `MCPProtocol` / `MCPHTTP` are pure logic with no networking and are unit-tested directly. Only `tools/*` is implemented.
- `MCPCatalog` is the single place that enforces the write switch: tools are registered as `.read` or `.write`.
- `MCPFacade` is the only code that touches documents. Every change goes through `AppState.mutate`, the same path the UI
  uses, so MCP edits are undoable and mark the document edited. Formulas are compiled with `LayerCompiler` before anything
  is inserted; a bad formula changes nothing and the error carries the column.
- Documents are addressed by `GraphDocument.mcpID`; without `document_id` the frontmost graph window is used.
- To add a tool: register it in `MCPTools`, put any document logic in `MCPFacade`, add a test in `MCPTests`, and add the
  tool to both usage docs (`docs/usage.md`, `docs/usage.zh-CN.md`). UI strings in the settings window go in both
  `Localizable.strings` files.

Quick manual check with the app running and MCP enabled:

```bash
curl -s -X POST http://127.0.0.1:8775/mcp -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_state","arguments":{}}}'
```

## How the rendering stays smooth

"Curves must be smooth" is a hard requirement of this project, and it is not met by turning up MSAA:

- **Lines** are expanded per segment into screen-space quads, and the fragment shader computes the exact distance from the
  pixel centre to the segment and turns it into coverage. Edges get an exact one-pixel grey ramp, line width stays constant
  at any zoom, and ends and joins are round.
- **Filled regions** compute sub-pixel coverage along their boundaries pixel by pixel (8×8 sub-sampling of the grid's
  bilinear interpolation), at the same quality as the strokes.
- **Curve sampling** subdivides adaptively by curvature: a segment is split whenever its chord error exceeds 0.14 pixels,
  and parametric curves also check the turning angle.
- Implicit curves are traced with marching squares, and the scattered cell segments are stitched into continuous polylines
  instead of drawing one curve as a pile of short segments.
- Sampling runs on the CPU in `Double` (Apple GPUs have no double precision). While dragging it drops to about 1/3
  resolution and re-samples at full quality 200 ms after you stop.

The evidence lives in the tests: `Renderer2DTests` asserts exported pixel values directly (coverage along a 45° edge, line
width stability under zoom, channel order, layer order, round caps), and `SamplingTests` asserts that a filled region's ink
equals πr², that 1/x never draws a vertical connector, and so on.

3D surface edges rely on 4× MSAA (triangle edges cannot have analytic coverage), while space curves and the box lines still
get per-pixel distance coverage; everything outside the box is clipped exactly on the GPU by six clip planes.
`Sampling3DTests` asserts that an implicit sphere's vertices lie on the sphere and its area equals 4πr²; `Renderer3DTests`
asserts that not a single pixel is drawn outside the box and that nearer faces hide farther ones.

## Not done yet

- Surface intersection curves are refined only to mesh accuracy (see `MeshIntersection`); Newton projection onto the true
  surfaces, and curves between a surface and a 2D-extruded wall, are not done.
- 3D: hover read-out, vector export; translucent surfaces are not depth-sorted against each other.

- Statistical charts other than scatter plots (histograms, box plots, non-linear fits).
