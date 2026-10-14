# Embedding Grapher NG in another app

Grapher NG ships three frameworks that another macOS app can link to show **a graph written as a few lines of text**,
and to let the reader rotate it, change its sliders and save the view back into the text. UniReader uses this for the
` ```grapher ` blocks of its Markdown notes (see UniReader's `GRAPHER-BLOCK-PLAN.md`).

| Framework | Needs | What it gives |
|---|---|---|
| `GrapherKit` | Foundation | The math, the document model and **`GrapherText`**: text → document, errors by line number, `patch` to write view and parameter values back into the text |
| `GrapherRender` | Metal, Core Graphics | `GraphSnapshot.image(text:pixelWidth:theme:…)`: text → bitmap, without any UI |
| `GrapherEmbed` | AppKit | **`GrapherBlockView`**: a live view of one text block |

License: GPL-3.0-or-later. An AGPL-3.0 host (UniReader) may link them; the combined work is distributed under the AGPL.

## The text format

One line per thing; a wrong line only skips itself and is reported with its line number. The full description, with
examples, is `GrapherText.reference` (the MCP tool `get_text_reference` returns it; every example in it is parsed and
drawn by the tests).

```
space
param a = 1.5 [0, 3]
view: azimuth=35 elevation=25
surface S: a*sin(x)*cos(y); opacity=0.8
tangent-plane: of=S; at=0.5, 1
```

`render_text` (MCP) draws a block without opening any document, so an AI can check what it wrote before putting it in a note.

## `GrapherBlockView`

```swift
let view = GrapherBlockView(source: text)      // nil if Metal is unavailable
view.themeOverride = .dark                     // optional; default: the text's `theme:` line, then the system appearance
view.onSourceChange = { newText in … }         // "save view": the text with `view:` and `param` lines rewritten
view.onEditSource = { … }                      // optional; shows an "edit the text" button
view.setSource(text)                           // the text was edited elsewhere
view.height(forWidth: w)                       // from the text's `aspect:` (default 3:2)
```

- At rest it looks like a picture and ignores scroll and drag (the host's scrolling keeps working). A click makes it
  *active*: a border, a small toolbar (edit text, reset, save view, open in Grapher NG) and one slider per parameter with a
  play button. Dragging rotates (3D) or pans (2D), the wheel and pinch zoom, double-click returns to the written view.
  A click outside or Esc leaves the active state.
- It never stores anything itself. The text is the only truth.
- Labels are drawn by a layer-hosted overlay (`BlockLabelOverlay`). Do not copy `TextLayerPool`'s usual
  `contentsAreFlipped()` rule into a new overlay: inside some view trees (a text view inside a scroll view inside a SwiftUI
  hosting view) it puts the labels upside down. Host the layer yourself and set `isGeometryFlipped = true`.

## Linking (UniReader's way)

An XcodeGen project reference to the sibling checkout:

```yaml
projectReferences:
  GrapherNG:
    path: ../grapher-ng/GrapherNG.xcodeproj
targets:
  YourApp:
    dependencies:
      - target: GrapherNG/GrapherKit
      - target: GrapherNG/GrapherRender
      - target: GrapherNG/GrapherEmbed
```

Both repositories must sit in the same parent directory.
