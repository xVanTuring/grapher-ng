# Grapher NG — Usage

**English** · [简体中文](usage.zh-CN.md)

## Let an AI draw graphs (MCP)

Grapher NG has a built-in [MCP](https://modelcontextprotocol.io) server. An AI assistant such as Claude Code can then
open documents, add curves, regions and surfaces, move the camera, and look at the result — all in the same windows you
are using. Whatever it adds is a normal edit: it shows in the layer list, you can undo it with ⌘Z, and the document is
marked as edited until you save.

### 1. Turn it on

Open **Grapher NG ▸ Settings…** (⌘,):

| Setting | Meaning |
|---|---|
| Enable MCP server | Starts or stops the server immediately. Off by default. |
| Port | Default `8776`. Changing it restarts the server. |
| Allow AI to modify graphs | Off by default. While off, the AI can only read documents and render images; every tool that changes something is refused with a clear message. |
| Access token | Every request must carry it. It is stored in the Keychain. Regenerate it any time to cut off old clients. |

The server listens on `127.0.0.1` only, so nothing outside this Mac can reach it.

### 2. Connect a client

The Settings window shows ready-to-copy snippets with your port and token filled in.

**Claude Code**

```bash
claude mcp add --transport http grapher-ng http://127.0.0.1:8776/mcp \
  --header "Authorization: Bearer <your token>"
```

**Other clients** (anything that speaks MCP over HTTP):

```json
{
  "mcpServers": {
    "grapher-ng": {
      "type": "http",
      "url": "http://127.0.0.1:8776/mcp",
      "headers": { "Authorization": "Bearer <your token>" }
    }
  }
}
```

Grapher NG has to be running. A quick check from a terminal:

```bash
curl -s -X POST http://127.0.0.1:8776/mcp \
  -H "Authorization: Bearer <your token>" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### 3. Ask for a graph

Some prompts that work well:

- "Draw a heart curve and a circle through its two lobes in Grapher NG."
- "Make a 3D graph of z = sin(x)·cos(y) and a sphere of radius 1 at the origin. Show me a picture."
- "Add a parameter `a` from 0 to 4 and plot `a*sin(x)/x`, so I can drag the slider."
- "Save it to ~/Desktop/heart.grapher and export a 2000×1200 PNG next to it."

The assistant should call `get_reference` first (formula syntax and which fields each plot kind needs), build the graph,
then `render_image` to check it. If a formula is wrong the call fails with the column of the mistake and nothing is
added, so the assistant can fix it and retry.

### Tools

Read tools always work:

| Tool | What it does |
|---|---|
| `get_state` | Open documents (id, title, 2D/3D, layer count) and whether writing is allowed. Start here. |
| `get_document` | Everything in one document: layers with ids, formulas, colours and errors; parameters; view; appearance. |
| `get_reference` | Plot kinds, formula syntax, functions and examples. |
| `render_image` | Renders the document as a PNG the assistant can look at. Defaults to 900×600, up to 2400×2400. |
| `relate` | 3D: how two points / straight lines / planes relate (relation code, distance, angle, foot of the perpendicular, intersection, common perpendicular, line of intersection) with coordinates. A line is a `spaceCurve` linear in `t`, a plane an `implicitSurface` / `surface` linear in x, y, z or a `tangentPlane`. |

Write tools need **Allow AI to modify graphs**:

| Tool | What it does |
|---|---|
| `create_document` | New empty window, 2D (`plane`) or 3D (`space`). |
| `open_document` / `save_document` | Open a `.grapher` file; save in place or to a path. |
| `add_layer` | Insert a graph: `kind`, `formula`, and as needed `secondary_formula`, `tertiary_formula`, `domain`, `domain2`, `domain_formulas`, `domain2_formulas`, `relation`, `extrude`, `color`, `line_width`, `dashed`, `name`. |
| `update_layer` / `remove_layer` | Change fields of a layer by id (its kind cannot change) or delete it. |
| `set_parameter` / `remove_parameter` | Create or change a named parameter with a slider range (`name`, `value`, `min`, `max`). |
| `set_view` | 2D: `center_x`, `center_y`, `scale`. 3D: `center`, `half_extent`, `azimuth`, `elevation` (degrees), `camera_zoom`. Also `fit` and `reset`. |
| `set_appearance` | `theme` (light/dark), grid, minor grid, axes, tick labels. |
| `export_png` | Write a PNG file at a given size. |
| `draw_relation` | Same as `relate`, and adds the helper objects (feet, intersection points, common perpendicular, line of intersection) as new layers. |

Every tool that targets a document takes an optional `document_id`. Leave it out and the frontmost graph window is used.

### Plot kinds at a glance

| Document | `kind` | Fields |
|---|---|---|
| 2D | `explicit` | `formula` = f(x) |
| 2D | `parametric` | `formula` = x(t), `secondary_formula` = y(t), `domain` |
| 2D | `polar` | `formula` = r(theta), `domain` |
| 2D | `implicit` | `formula` = F(x, y), drawn where F = 0 |
| 2D | `region` | `formula` = F(x, y), `relation` is one of `<` `<=` `>` `>=` |
| 3D | `surface` | `formula` = f(x, y) |
| 3D | `parametricSurface` | x(u,v), y(u,v), z(u,v) in the three formula fields, `domain` for u, `domain2` for v |
| 3D | `spaceCurve` | x(t), y(t), z(t) in the three formula fields, `domain` |
| 3D | `implicitSurface` | `formula` = F(x, y, z), drawn where F = 0 |
| 3D | `surfaceIntersection` | no formula: `source_a` and `source_b` are the ids of two surface layers (`surface`, `parametricSurface`, `implicitSurface`); draws the curve where they meet, even if the sources are hidden |
| 2D | `scatter` | `formula` = the data, one `x, y` point per line (commas, semicolons, spaces or tabs; header lines are skipped), `fit: true` draws the least-squares line (`get_document` then reports `slope`, `intercept`, `r`), `line_width` = point size |
| 2D / 3D | `text` | `formula` = the text to write (not compiled as a formula), `at` / `at2` (`at3` in 3D) = position in data coordinates, `font_size`, `color` |
| 2D | `tangent` | no formula: `source_a` = an `explicit` / `parametric` / `polar` layer, `at` = x (explicit), t (parametric) or theta (polar), a number or a formula with parameters such as `"p"`, `normal: true` draws the normal line instead |
| 3D | `tangentPlane` | no formula: `source_a` = a `surface` / `parametricSurface` layer, `at` + `at2` = the point's (x, y) or (u, v); shows a translucent patch, its normal and the point, and counts as a plane in the relations panel |
| 3D | `gradientField` | no formula: `source_a` = a `surface` layer z = f(x, y); arrows along the steepest ascent, longer and warmer where the slope is larger (none at peaks, pits, saddles). `density` = arrows per axis (2–40), `arrow_scale` (negative draws −∇f), `on_floor: true` draws ∇f flat on the floor of the box |
| 3D | `gradientFlow` | `source_a` = a `surface` layer; `formula` = the starting points, one `x, y` per line (each column a number or a formula with parameters, e.g. `3*cos(q), 3*sin(q)`); the path follows ∇f uphill (`arrow_scale` < 0: downhill), `on_floor` draws it flat on the floor; `secondary_formula` = the ball position along the path, 0 to 1, and may use a parameter (play that parameter to roll the ball) |
| 3D | `point` | `formula`, `secondary_formula`, `tertiary_formula` = x, y, z (numbers and parameters only); `line_width` is the size |
| 3D | `projection` | no formula: `source_a` = a `point` / `spaceCurve` / `surfaceIntersection` layer, `target` = `xy` / `yz` / `xz` (the plane z / x / y = `offset`) or `plane` (`source_b` = a plane layer), `projectors` draws the projecting lines, `direction` = [dx, dy, dz] makes it an oblique projection |
| 3D | `explicit`, `parametric`, `polar`, `implicit` | as in 2D; drawn on z = 0, or with `extrude: true` swept along z |

For implicit kinds write F without `= 0` (`x^2 + y^2 - 4`, not `x^2 + y^2 = 4`).

### Good to know

- **The window comes to the front** when the AI creates or opens a document; other edits do not steal focus.
- **Nothing is saved automatically.** Unsaved documents keep the usual "Edited" mark and the save prompt when closed.
- **3D graphs are clipped to the axis box** (±4 by default). If a shape is not visible, scale it down or call `set_view`.
- **Only 127.0.0.1.** There is no setting to listen on other interfaces; to reach it from another machine use an SSH tunnel.
- **If it will not start**, the Settings window shows the reason (usually the port is taken — pick another one).
- Moving the token: after you regenerate it, update the client config (`claude mcp remove grapher-ng`, then add it again).

### Examples to learn from

**File ▸ Open Example** (and the **Examples** card in the welcome window) lists ready-made graphs grouped by topic. Each one opens in a new window, so you can drag the sliders, change formulas and rotate freely without touching your own work.

- **2D**: curves and regions · parameter sliders · tangents and normals · data and fitting
- **3D**: surfaces and space curves · intersection curves · points, lines and planes · projections and tangent planes

Hover over an example in the menu for a one-line explanation.

### Animating with parameters

Every parameter in the left panel has a **play** button. Play makes the slider sweep its range by itself, so every graph that uses the parameter moves: a plane sliding through a surface (and its intersection curve with it), a wave changing phase, a gradient field following a hill that widens and narrows, a ball rolling along a gradient path (write the ball position as a parameter such as `p`). The gear next to **+** sets the speed (slow / medium / fast) and whether it goes back and forth or repeats. Several parameters can play at once; undo returns to the values before playing.

### Seeing the gradient

Put a `surface` layer z = f(x, y) in a 3D document and add a **Gradient field** layer on it: arrows point along the steepest ascent, longer and redder where the slope is larger (none at peaks, pits and saddle points), either on the surface or flat on the floor (the textbook ∇f). **Gradient flow lines** start paths at the points you list and follow ∇f uphill (or −∇f downhill); a ball sits on each path at the position you give (0 to 1), so writing it as a parameter and pressing play rolls the balls along. Tick **Color by slope** on the surface to turn it into a heat map of |∇f|. The **Gradients** group in the example catalog shows each of these.

**Drawing a curve gradually.** The ends of a parameter range (the range of `t`, `theta`, `u`, `v`, or an explicit function's domain) can be formulas as well as numbers, for example `p*2*pi`. Create a parameter `p` from 0 to 1, write `p*2*pi` as the upper end, and play `p`: the curve is drawn up to that point as `p` grows, and a parametric surface is swept out. Through MCP use `domain_formulas` (and `domain2_formulas`), e.g. `["0", "p*2*pi"]`; an empty string keeps that end's plain number.

**Sliding along a curve.** The same works for positions: the point of tangency of a tangent, normal or tangent plane, the position of a text label and the position of a projection plane can be written as formulas with parameters (`p`, `2*cos(q)`, …). Play the parameter and the tangent slides along the curve, the tangent plane travels round a surface, a text label follows. Through MCP pass a string for `at`, `at2`, `at3` or `offset`, e.g. `"at": "p"`.
