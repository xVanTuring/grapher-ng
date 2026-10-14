# AGENTS.md — GrapherNG

macOS 上的公式绘图工具（输入公式画曲线、区域、曲面）。**纯 AppKit + Metal**，唯一的第三方包是自动更新用的 Sparkle
（只链接到 App target，见 `docs/release.md`），**别再加别的依赖**；xcodegen 管理工程
（`GrapherNG.xcodeproj` 由 `project.yml` 生成，不要手改），macOS 14+，Swift 5 语言模式；Debug 与发布用同一个证书（zqsd 的 Developer ID Application，只有它能公证），**不许用 ad-hoc**；发布签名在 `scripts/package.sh`。

文档分**平面图**与**立体图**两种（新建时定下，`GrapherDocument.dimension`）：平面图有 2D 全部图型（显函数 / 参数方程 /
极坐标 / 隐函数 / 不等式区域）；立体图有显式曲面、参数曲面、空间曲线、隐式曲面，平面曲线也能放进去（画在 z = 0 上或
「延伸到 3D」）。**曲面交线**（`.surfaceIntersection`）是引用另外两个曲面图层（`sourceA` / `sourceB`）的图层，没有公式：
`SceneBuilder3D` 先画完其它图层再处理它，两张来源曲面的网格（藏起来的现采）交给 `MeshIntersection` 逐对三角形求交、按端点拼成折线，
不分图型组合；精度就是网格精度。

**点 / 投影 / 位置关系**（立体图）：
- `.point` 图层三个公式只能含参数，画成小球（`PointMarker`，半径按盒内归一化坐标，随盒子缩放）。
- **直线、平面不是图型**，是从图层里认出来的（`SpaceGeometry.recognize`）：线性的空间曲线 = 直线，线性的隐式 / 显式曲面 = 平面。
  识别靠在几个点上验证线性（容差 1e-7），所以带参数 `a` 的直线 / 平面照样认得。关系计算（距离、夹角、垂足、交点、交线、公垂线）
  全在 `SpaceGeometry.relation`，纯逻辑；检查器里的「位置关系」面板（`RelationPaneViewController`）只是选两个对象、显示结果，
  「画出结果」用 `GeometryConstruction.makeLayer` 把辅助对象加成新图层（数值快照，不跟来源联动）。
- `.projection` 图层（`sourceA` 来源：点 / 空间曲线 / 交线；目标：三张坐标面 + `projectionOffset`，或 `sourceB` 指向的平面图层）
  是正投影，在 `SceneBuilder3D` 里和交线一样最后处理；投影线最多 24 根，半透明细线。
- 切线 / 法线（`.tangent`，平面图）和切平面（`.tangentPlane`，立体图）也是引用来源图层、没有公式的图层（`sourceA` + `anchorU/V`）。
  导数在 `Tangents` 里用中心差分求，来源是编译好的公式；切平面经 `SpaceGeometry.recognize(_:in:)`（要看得到来源图层）
  当平面用，所以能进位置关系面板、当投影目标。**认平面请用带 `in:` 的重载**，单参数那个认不出切平面。
- 投影图层的 `projectionDirection`（nil = 正投影）是斜投影方向，与平面平行时整层不画。
- 文字标注（`.text`，平面图 / 立体图都能放）：`formula` 是要写的字，不编译；位置 `anchorU/V/W`、字号 `fontSize`。`PlotKind.dimension` 是 `.plane`，立体图的类型列表里手动补上。
  文字由画布叠加层（2D `CanvasOverlayView`、3D `Canvas3DOverlayView`）和导出图片（`GraphSnapshot`）按 `TextAnnotations.all` 写，不进 Metal 场景。
- 散点图（`.scatter`，平面图）：`formula` 是数据文本（每行 `x, y`，`ScatterData.parse` 解析，不当公式编译），点画成 `Draw2D.markers`、每个点同时是一段零长度的探针曲线（悬停读数、适应内容、CSV 导出都靠它）；`showsFit` 画最小二乘直线，统计量在检查器里显示。数据用多行 `NSTextView` 编辑（`LayerEditorViewController` 的 `NSTextViewDelegate` 扩展，输入中实时更新、输完记一步撤销）。
- 以上几种新 `PlotKind` 都要同步：`SceneBuilder2D` 里两处 switch、`LayerEditorViewController`、`MCPFacade.variables`、`MCPTests`、两份用法文档。

**选中联动 / 半透明**（立体图）：
- 场景里每个 `Mesh3D` / `Polyline3D` 都带 `layerID`（`SceneBuilder3D.tag`，用 `defer` 在每个图层处理完后统一打；坐标盒线框不属于任何图层）。
  选中高亮靠它：`MetalView3D.highlight`（= `AppState.selection`）→ `Renderer3D.encode(highlight:)`。曲面往橙色偏，曲线先画一圈
  宽的半透明光晕（`lineBoost` + `tint`）再画本体；光晕用 `baseInstance` 只画该图层那一段线段实例（`PreparedScene3D.lineRanges`）。
- 点选在 CPU 上做（`ScenePicker3D`，纯逻辑）：射线对三角形求交 + 曲线按屏幕像素距离。曲线只被**不透明**曲面挡住，
  贴在曲面上的线（交线、投影）深度差在 `lineDepthSlack` 内算曲线在前。`Viewport3DViewController.handleMouseUp` 里累计拖动
  不到 3 点才当点击；点空白处取消选中。
- 悬停读数：`Viewport3DHostView` 的 tracking area → 鼠标停 80 毫秒后 `ScenePicker3D.hit`，状态栏显示「图层名 · x y z」
  （位数跟着屏幕精度）。命中测试扫全部三角形，**鼠标动着时不做**。点图层的名称（A、B、C…）由 `Canvas3DOverlayView` 每帧投影后摆字。
- 平面图的同类联动：选中图层的曲线在 chrome 层（画在曲线层底下）加一圈橙色光晕（`chromeWithSelectionHalo`，点取自
  `probeCurves`，按当前视口换成屏幕像素）；点击用现成的 `CurveProbe`（离曲线 8 点以内选中，空白处取消）。
- 半透明：曲面图层的 `fillStyle.opacity < 1`（与区域填充同一个字段）→ 网格颜色 alpha → `Mesh3D.isTranslucent`。渲染分三轮：
  不透明曲面（写深度）→ 半透明曲面（`glassPipeline`，只测深度、不写、两面都画，批之间不排序）→ 线。
- `Uniforms3D` / `MeshStyle3D` 改动要同步 `ShaderSource3D`，`Renderer3DTests` 里有偏移量断言守着。

测试里 MCP 令牌只放内存（`MCPSettings.token`），不碰真正的 Keychain，免得弄丢 / 改写正在用的令牌。

## 构建 / 测试 / 运行

```sh
xcodegen generate
bash scripts/build.sh    # xcodebuild … -derivedDataPath build/DerivedData build
bash scripts/test.sh     # 单元测试，以 App 为宿主
bash scripts/run.sh      # 构建并直接运行，日志输出到终端
scripts/package.sh       # Developer ID 签名 + 公证，出 build/dist 下的 zip / dmg（不发布）
scripts/release.sh <版本> --notes-file release-notes/v<版本>.md [--dry-run]   # 正式发布（公开），见 docs/release.md
```

产物在 `build/DerivedData/Build/Products/Debug/GrapherNG.app`。图标：`bash scripts/make-icon.sh`。
Sparkle 是 SPM 包，第一次编译前要先解析（`xcodebuild … -resolvePackageDependencies`，完整命令见 `docs/release.md`）。

无界面模式（调试与造图用，不开窗口）：

```sh
<app>/Contents/MacOS/GrapherNG --render out.png [--doc d.grapher] [--width W] [--height H] [--quality full|high]
<app>/Contents/MacOS/GrapherNG --benchmark
```

## 结构与边界

```
Sources/GrapherKit/     纯逻辑（framework）—— Expr / Sampling / Model / IO
Sources/GrapherRender/  Metal 渲染（framework）
Sources/GrapherApp/     AppKit 界面、事件处理、命令行模式
Tests/GrapherNGTests/   单元测试
```

- **GrapherKit 不许 import 任何界面框架**。拆成三个 target 就是为了让编译器守住这条边界；测试主要跑在它和 GrapherRender 上（全部共 164 项）。
- 界面**不许用 SwiftUI**。`AppState` 用极简观察者回调广播变更（`observe(_:_:)`），不引入 Combine。
- `GrapherRender` 的着色器是**运行期**从 `ShaderSource.swift` 里的内嵌字符串编译的，没有 `.metal` 编译阶段——别去加 build phase。
- `GrapherKit` 在 Debug 下单独开 `-O` + `wholemodule`：这一层数值密集，`-Onone` 让网格求值慢 27 倍（1.2M vs 32M 点/秒）。界面层保持 `-Onone`。

## 关键设计（改动前先读）

- **抗锯齿靠解析式覆盖率，不是 MSAA**。线在屏幕空间展开成四边形、片元算像素中心到线段的精确距离；填充的边界逐像素算子像素覆盖率。**`MetalContext.sampleCount` 必须是 1**，开了 MSAA 会在覆盖率之上再叠一层，把边缘弄脏。
  （这条只管 2D。3D 曲面的三角形边缘没法解析地算覆盖率，`Renderer3D.sampleCount` 是 4，两边互不相干。）
- **采样在 CPU 上用 `Double`**（Apple GPU 没有双精度）。拖动时降到约 1/3 分辨率、停手 200ms 后重算精细版；这套节流在 `AppState.requestInteractiveRebuild`。
  网格求值（`FieldEvaluator.fill`）按块摊到所有核上并行，单屏全精度从约 50ms 降到约 5ms。
- **求值是字节码栈式虚拟机**，必须**可重入且线程安全**（`evaluate` 内部用 `withUnsafeTemporaryAllocation` 在栈上开求值栈，无共享可变状态）。网格求值走 `evaluateBatch`，不要退化成逐点调 `evaluate`。
- **间断必须断开**：`1/x`、`tan(x)` 不能画出竖直连线。判定在 `CurveSampler.sampleExplicit`（跳变超过半屏高且横向跨度小于 4 像素即为极点）。
- 画质常数别随手调：弦高容差 0.14 像素、`tolerancePixels` 分档在 `CurveSampler.options(for:)`；屏幕坐标进 GPU 前在 `SceneBuilder2D.screenClamped` 夹到 ±1e7，否则极点会把 float32 变成 inf。

## MCP（让 AI 插入图形）

`Sources/GrapherApp/MCP/`：手写 JSON-RPC over HTTP（`Network.framework`，不依赖 MCP SDK，与 Perch / UniReader 同构），
只监听 127.0.0.1，默认关闭，设置在「Grapher NG ▸ 设置…」。用户文档 `docs/usage.md` / `docs/usage.zh-CN.md`，实现说明见 `DEV.md`。

- **改文档只许经 `MCPFacade`，且一律走 `AppState.mutate`**（和界面同一条路径），这样 AI 的改动能撤销、会标成已编辑。不要绕过它直接改 `document`。
- **写权限闸门只在 `MCPCatalog.call` 一处**：新工具注册时标 `.read` / `.write`，别在各 handler 里自己判断。
- **公式先编译再插入**（`MCPFacade.validate`）：有错就什么都不改，错误信息带列号，模型据此重试。
- 新增 / 改动工具要同步：`MCPTests`、两份用法文档、设置窗口新增文字的两份 `Localizable.strings`。

## 文档模型（NSDocument）

- 每扇窗口一份 `GraphDocument`（`NSDocument` 子类），持有该窗口的 `AppState`。新建、打开、保存、另存为、窗口标题与代理图标、
  关闭按钮里的小圆点、关窗 / 退出时的「是否保存」提示，全走 AppKit 的标准流程——**不要再手写打开 / 保存面板或窗口标题**。
- **文件是 `.grapher`**（内容是 `DocumentStore` 写的 JSON）：project.yml 导出类型 `tech.xvanturing.grapherng.graph`
  （`UTExportedTypeDeclarations`），`CFBundleDocumentTypes` 里登记为 Editor，双击就用本 App 打开。
  类型只遵从 `public.data` / `public.content`，**故意不遵从 `public.json`**：系统自带 JSON / 文本的缩略图与预览，
  遵从了它就可能和下面的 Quick Look 扩展抢（FreeMind 的 .fmind 同样不遵从文本类型）。
  `LSHandlerRank` 取构建设置 `GRAPHER_HANDLER_RANK`：**Debug 为 Alternate、Release 为 Owner**（同 FreeMind），
  装了正式版时双击不会被开发用的 Debug 版抢走；没装正式版时 Debug 版照样能打开。
- 早先存的 `.json` 登记为 `public.json` 的 **Viewer**（Alternate，不抢 .json 的默认程序）：能打开，⌘S 弹存储面板另存成
  `.grapher`，不会写回 JSON（`writableTypes` 只有 `.grapher`）。
- `autosavesInPlace = false`：改过的文档关窗、退出都弹标准的保存提示，不悄悄写回文件。
  代价是系统不再给标题加「已编辑」（那是自动保存文档才有的），所以 `DocumentWindowController.setDocumentEdited`
  自己把窗口**子标题**（`window.subtitle`）设成「已编辑」，存过就清掉。
- **改动计数**：撤销栈用 NSDocument 自己的 `undoManager`，撤销 / 重做自动增减计数；另外 `AppState.markEdited` 经 `onEdit`
  调 `updateChangeCount(.changeDone)`——拖滑块、输入公式要等一串结束才记一步撤销，中途就得先标成已修改。
  新的改文档路径要么走 `mutate`，要么调 `markEdited`，否则关窗时不会提示保存。平移、缩放视口不算改动。
- `GraphDocumentController` 必须在 `applicationWillFinishLaunching` 里最先建出来才会成为 `shared`。它只补两件事：
  新建立体图 / 示例（`newDocument(dimension:example:)`，示例不算改动、标题写明是哪个示例）；只开着一扇没动过的空白窗口时
  打开文件，文件接替这扇窗口（同「文本编辑」）。接替时**先显示新窗口再关空白的**，反过来的话那一刻一扇窗口都没有，
  `applicationShouldTerminateAfterLastWindowClosed` 会让程序直接退出。
- 新窗口默认是空白文档。「文件 → 加载示例」和图层列表空白时的按钮走 `AppState.loadExample`：图层、参数、视角换成示例，
  主题与网格不动，可撤销。示例本身仍是 `GrapherDocument.sample()` / `sample3D()`，无界面渲染也用它们。

## 欢迎窗口（照 FreeMind 的做，界面用 AppKit）

- 启动时没有文件要打开、点 Dock 图标时一扇窗口都没有、又启动了一次（单实例转过来）：都走
  `AppDelegate.applicationOpenUntitledFile` → 欢迎窗口；欢迎窗口里取消了「启动时显示」（UserDefaults `showWelcomeOnLaunch`）
  的，直接新建空白平面图。测试宿主里 `applicationShouldOpenUntitledFile` 返回 false，什么都不开。⇧⌘1（窗口菜单）随时打开。
- 左栏：新建平面图 / 新建立体图 / 打开 / 示例（弹菜单选平面或立体示例，各开一扇新窗口）。右栏：最近打开的文档，
  列表来自 `NSDocumentController.recentDocumentURLs`（打开、保存时系统自动登记），右键可在访达中显示、移除、清空。
- **缩略图**（`RecentGraphs.thumbnail`）：后台读文件、按文档存下时的视口重新采样并离屏渲染（平面图取没被侧栏盖住的那块铺满、
  立体图取当时视角；不画刻度文字），按路径 + 修改时间缓存。
- 任何文档的窗口**显示出来之后**才关欢迎窗口（`GraphDocument.showWindows`）：在 `addDocument` 里就关的话，新窗口还没出来，
  那一刻一扇窗口都没有，程序会直接退出。没有文档时关掉欢迎窗口，程序同样会退出（最后一扇窗口关了就退出，这是既有约定）。
- 卡片（`WelcomeCardView`）整块是点击区：`hitTest` 返回自己，子视图不接鼠标；`mouseDownCanMoveWindow = false`，
  否则窗口「拖背景移动」会把点击吃掉。颜色都在 `draw` 里取动态色，深浅色外观切换时自动跟上。
- **Debug 版曾经每重新编一次，最近列表就清空一次**：系统按 App 的签名记这份列表，ad-hoc 签名每次构建都变。
  现在 Debug 用固定开发证书，不再发生；要是又出现，先查签名是不是被改回了 `-`。
- `read(from:ofType:)` 在 SDK 里是 nonisolated；没开并发读（`canConcurrentlyReadDocuments` 默认 false），AppKit 在主线程调它，
  所以里面用 `MainActor.assumeIsolated` 把内容交给 `AppState`。

## Quick Look 扩展（访达空格预览 / 文件缩略图，同 FreeMind）

- `GrapherNGQuickLook`（空格预览）和 `GrapherNGThumbnail`（缩略图）两个 app-extension，源码在 `Extensions/`，
  只链接 GrapherKit 与 GrapherRender，用 App 里那份（`embed: false`，rpath 指到 `../../../../Frameworks`），开沙盒。
  两个框架因此开了 `APPLICATION_EXTENSION_API_ONLY`：**别在 GrapherKit / GrapherRender 里用扩展不能用的 API**（如 `NSApplication`）。
  另有两个界面文件与 App 共用、两边都编译：`TextLayerPool.swift`、`CanvasInput+AppKit.swift`（见 project.yml）。
- **空格预览是可交互的只读画布**（视图型预览，`QLIsDataBasedPreview: false`）：`PreviewViewController` 里用 App 同款
  `MetalView2D` / `MetalView3D` 与刻度文字图层，`PreviewSession` 按 App 的节奏后台采样（单通道、交互画质、停手补精）。
  打开时是文档存下时的取景，双击复位；没有编辑、没有读数。实测访达的预览窗口会把拖动、滚动、捏合都交给扩展。
- **手感只有一份 `CanvasInput`**（GrapherKit）：App 的 2D / 3D 画布与预览都按它把滚轮、捏合、拖动换成动作，
  按键习惯改这里就两边一起改。**双指滚动永远是平移**，不当缩放（`CanvasInputTests` 守着）。
- 缩略图的画法 `GraphSnapshot`（GrapherRender，只用 Core Graphics / Core Text / Metal，不碰 AppKit）：缩略图、
  欢迎窗口的最近文档、立体图导出 PNG 共用，预览的初始取景（`planeViewport` / `spaceView`）也取自它。
  取景是文档存下时没被侧栏盖住的那块（立体图是当时的视角）；缩略图不画刻度文字。
- 平面图坐标轴文字的位置只有一份 `PlaneLabels`（GrapherKit）：画布叠加层与预览共用，字体由画的一方按角色挑。
- 缩略图回调里交来的 `CGContext` 是**像素**口径（Retina 下是 `contextSize` 的两倍），按点画只占左下四分之一；
  要铺满 `context.boundingBoxOfClipPath`。
- 验证缩略图：`qlmanage -x -t -s 200 -f 2 -o <目录> 某个.grapher`（**一定带 `-f 2`**：访达要的是 2 倍图，
  不带的话是 1 倍，上面那个四分之一的问题看不出来）；渲染本身由 `SnapshotTests` 覆盖。
  **实测遇到过：重新编译、`lsregister -f` 重新登记之后，常驻的 `com.apple.quicklook.ThumbnailsAgent` 仍用旧记录**
  （日志里是 "Unable to find this application extension record"），继续出系统的文本缩略图。要重启它：
  `kill -9 $(pgrep -f com.apple.quicklook.ThumbnailsAgent); qlmanage -r cache; killall Finder`。
  这几种都**不管用**：`killall`（进程名超过 16 个字符，匹配不上）、`pkill -f`（它不理会普通的结束信号）、
  `launchctl kickstart -k`（系统完整性保护拦下）、`qlmanage -r`（只重置 quicklookd，不是这个服务）。
  空格预览只能在访达里按空格验证（FreeMind 的记录：`qlmanage -p` 调预览扩展会崩在 qlmanage 自己身上）；
  预览服务也可能沿用旧版扩展，重启办法：`kill -9 $(pgrep -f QuickLookUIService); killall Finder`。

## 无限画布（照 UniReader 的画板抄的）

中心画布是无限可平移缩放的，视口模型是 `Viewport2D`（视口中心 + 像素/单位的等比缩放）。四条纪律：

1. **不要给 `MTKView` 套 `NSScrollView` + `magnification`**。UniReader 把这个取舍跑过两遍：位图内容
   （PDF 页图、图片）用滚动视图 + `allowsMagnification`，整体拉伸正合期望；**矢量/自绘内容**（他们的画板、
   我们的 Metal 画布）自己管视口。套进滚动视图只会把 Metal 画布放成一张模糊的位图，`drawableSize` 也不跟着变。
2. **所有改视口的路径都过 `AppState.mutateViewport`**（拖动、滚轮、捏合、工具栏按钮、F/R），
   软边界与锚点代数都只写一遍。锚点换算只在 `Viewport2D.zoom(by:anchorPixel:)` 里，别在调用处再抄一遍。
3. **软边界**（`ViewportBounds`，抄 `ScratchBounds`）：可见区必须与「内容包围盒外扩 `slackScreens = 1.5`
   个视口」相交，越界拉回；内容为空时退化成围着原点的一块。包围盒在建场景时算一次存进
   `BuiltScene.contentBounds`——**不要放在拖动路径上现算**（那条路径每帧都走）。
4. **输入**：普通滚动 = 平移，`⌘`+滚动 = 缩放，捏合 = 缩放。缩放只在 `momentumPhase == []` 时消费，
   否则触控板一甩会连着放大好几档；有级滚轮（`hasPreciseScrollingDeltas == false`）的 delta 要 ×10。
   这些规则都写在 `CanvasInput`（GrapherKit），App 画布与 Quick Look 预览共用，别在调用处再写一遍。

### 拖动跟手：画面不等后台采样

视口一变，**同一帧里**画面就要跟上（UniReader 画板 `viewportChanged` 的思路：平移只挪图层，不重画笔迹）：

- **曲线层**：后台算好的几何留在它自己的像素空间（`BuiltScene.viewport`），上传一次显存
  （`Renderer2D.prepare` → `PreparedScene2D`）；之后每帧只传一个 `ScreenTransform2D`
  （`Viewport2D.screenTransform(from:)`，等比缩放 + 平移），着色器里套上。线宽、标记半径不跟着缩放。
- **网格与坐标轴**不进后台场景，每次视口变化按当前视口现画（`SceneBuilder2D.chromeScene`，
  `AppState.chrome()` 带缓存）；叠加层的刻度数字也用这一份，所以数字和网格线永远对得上。
  读数圈按 `ProbeHit.dataPoint` 和当前视口现算位置，拖动时跟着曲线走。
- **重绘跟屏幕刷新走，不跟事件走**：状态一变只调 `MetalView2D.requestFrame()`，真正的更新
  （网格、曲线视口、叠加层）在显示链接回调 `onFrame` 里做，每次刷新最多一帧。按事件画的话，
  鼠标事件比屏幕刷新快（120Hz 鼠标配 60Hz 外接屏）时多出的帧在显示队列里排队，画面落后光标两三帧。
  `presentsWithTransaction = true`：Metal 这一帧与叠加层图层同一个事务上屏，数字与网格线不会错开一帧。
- **叠加层是一堆小图层**（`CanvasOverlayView`）：每串文字只渲染一次存成位图，之后只挪位置。
  不要改回整块 `draw(_:)`——那是每帧一张整窗大小的透明位图，WindowServer 每帧都得重新上传合成。
- 新曲线几何的显存上传在后台队列做（`MetalView2D.setContent`），换上之前继续画旧的那份——
  每份几何带着自己的视口，照样摆得对。
- **外扩采样**：交互画布四周各多采 `AppState.overscan = 0.25` 个视口，拖动、缩小时露出来的边上已经有图。
  外扩量取整像素，停稳时变换只差整数平移，区域填充的逐像素矩形不会被插值糊掉。
  导出、离屏渲染保持 `overscan = 0` 且带网格（`SceneBuildRequest` 的默认值）。
- **后台采样单通道**：同一时刻只跑一份，跑着时来的请求只记「还要再算、什么画质」，跑完按**那一刻**的
  文档和视口再起一份；结果一律收下（变换会把它摆到当前位置）。**不要**改回「每个事件取消上一份、
  只收最新一代」：一次采样比两次鼠标事件的间隔长，拖动全程一份都收不到，曲线只在停手后才跳过去，
  被取消的任务还照样算完、占满 CPU。
- `.errors` 只在错误集合真变了时才广播：图层列表和检查器收到它会整个刷新。

## 沉浸式侧栏（同 UniReader 阅读区）

画布这一格伸到左侧毛玻璃侧栏底下，透过侧栏能看到曲线；侧栏一开内容被推到右边没被盖住的那块里居中，
一收又回来，动画全程逐帧跟随。

- 开关是画布分栏项的 `automaticallyAdjustsSafeAreaInsets = true`（macOS 26+，`#available` 包着）。
  检查器是普通分栏项，不受影响，仍然真的占宽度。
- 被盖住的四边记在 `Viewport2D.insetLeft/Top/Right/Bottom`（像素）：`centerX/Y` 落在没被盖住那块的
  中心（`focusX/Y`），`xRange/yRange` 仍覆盖整块画布（毛玻璃底下也要有图）。遮挡宽度是窗口状态，
  `CodingKeys` 不含它，不进文档；换文档 / 撤销时沿用当前值（`AppState.adoptCanvasMetrics`）。
- 「适应内容」装进没被盖住的那块；导出、检查器里的 X/Y 范围、「视图范围」按钮都用 `Viewport2D.unobscured`。
- 叠加层的文字、读数框、状态条都让开遮挡区；叠加层用视口里记的遮挡宽度，不读自己的 `safeAreaInsets`（原因见下一节）。

## 立体图（3D）

- **坐标盒**：`View3D` 存盒心 `center` 与半边长 `halfExtent`（三轴同一个，图形不变形）、相机方位角 / 仰角。
  一切几何先换成**盒内归一化坐标** `n = (p − center) / halfExtent`（盒子 = [-1, 1]³），GPU 用 Float。
  相机绕盒心转、z 轴朝上、离盒心固定距离透视投影。两种缩放：**⌘+滚轮 / 捏合缩放图形**，改 `halfExtent`，
  盒子在屏幕上大小不变（同 Desmos 3D，也与平面图的 ⌘+滚轮一致）；**⌥+滚轮 / ⌥+捏合放大盒子**，改 `cameraZoom`
  （投影焦距的倍数），数据范围不变、不重采。按键是用户定的：⌘ 留给缩放图形，盒子用 ⌥。
- **重采的边界**：只转相机不重采（`orbit` 只换投影矩阵）；平移、缩放改了盒子才重采，期间旧几何经
  `View3D.boxTransform(from:)` 换到新盒子里照画。画布尺寸、遮挡变了也只改投影。
- **裁剪**：盒外的部分在顶点着色器里用 6 个 `clip_distance` 裁掉（真几何裁剪，边缘有 MSAA）；盒子自己的棱线、
  盒壁网格不裁（`Renderer3D.Pass.clipToBox`）。
- **渲染次序**：先画所有曲面（不透明、写深度），再画所有线（半透明、只测深度、深度往相机偏一点）——曲线能被曲面挡住，
  贴在曲面上的线也不被吃掉。曲面两面打光，背面压暗。
- **采样**（`SceneBuilder3D`）：显式曲面在盒子 xy 范围上铺网格；参数曲面在 u、v 范围上铺网格（法向按面积加权，
  极点处的退化三角形整个丢掉）；隐式曲面用体网格 + marching tetrahedra（Kuhn 剖分，法向取梯度）；
  空间曲线在归一化坐标里自适应细分。一条边超过 4 个归一化单位的三角形当断开处（1/x 两侧不连竖墙）。
- **平面曲线进立体图**（Desmos 3D 的做法）：`PlotKind.canExtrude` 的四种可以放进立体图，图层的 `extrudesInSpace`
  决定画在 z = 0 上还是沿 z 拉成贯穿盒子的竖直曲面。采样直接复用 2D 采样器，给它一个铺满盒子 xy 范围的虚拟视口。
- **坐标盒线框与刻度**（`Chrome3D`）：12 条棱、背向相机三面墙上的网格、过原点的坐标轴；刻度数字标在盒底朝向相机的棱
  和屏幕最左的竖棱上，盒角上的不标。每帧按当前视角重算，叠加层投影后摆文字（`Canvas3DOverlayView`）。
- **新字段都要兼容旧文件**：`Layer` 的 `tertiaryFormula` / `domain2Lower` / `domain2Upper` / `extrudesInSpace`、
  文档的 `dimension` / `view3D` 都用 `decodeIfPresent` 读，2D 时代的文件照样能开（`View3DTests` 里有用例）。
- 无界面渲染立体图：`--render out.png --space`（或 `--doc` 指定立体图文件），`--azimuth` / `--elevation` 换角度。

## 多语言（en + zh-Hans）

- 界面文字一律 `L("英文原文")`，不在界面代码里写中文字面量。带参数的用
  `String(format: L("Opened %@"), name)`，整数用 `%ld`。
- 两套表：App 的在 `Sources/GrapherApp/Resources/<语言>.lproj/Localizable.strings`；GrapherKit
  自己的文字（图型名、公式错误提示、示例文档图层名）在 `Sources/GrapherKit/Resources/` 下，
  Kit 里的 `L()` 查的是本 framework 的 bundle。新增文字两种语言都要补。
- 开发语言是 en（`project.yml` 的 `developmentLanguage`），缺翻译时退回英文原文。
- **测试固定用简体中文跑**（scheme 的 `test.language: zh-Hans`）：`ExprTests` 按中文原文断言错误提示。
  `LocalizationTests` 核对两个 bundle 里 en / zh-Hans 的 key 一致、占位符个数一致。
- `--render` / `--benchmark` 的命令行输出是调试用的，没有走本地化。
- 想在英文系统上看中文界面：系统设置 → 通用 → 语言与地区 → 应用程序里给 Grapher NG 选简体中文，
  或命令行加 `-AppleLanguages "(zh-Hans)"`。

## 已踩过的坑

- **窗口要「三件齐备」才是现代侧栏**（Finder/Mail 那样侧栏一路顶到窗口最上沿、工具栏浮在它上面）：
  ① styleMask 里必须有 `.fullSizeContentView`；② 侧栏用 `NSSplitViewItem(sidebarWithViewController:)`；
  ③ 工具栏里必须有 `.sidebarTrackingSeparator`。缺第①条，内容区从标题栏下方才开始、侧栏被切在标题栏之下；
  缺第③条，**侧栏开关会被当成普通 item 排到右边去**（实测最右墨迹从 940/948 掉到 669/948）。
- **但那三件只管到「侧栏 ↔ 内容区」**。工具栏右侧的 `.inspectorTrackingSeparator` 这个工程**故意不用**：
  它会把检查器的宽度从工具栏里切出去交给检查器区，而那个区里只有一枚小开关，结果右边三分之一看着是空的、
  其余 item 全挤在左边。FreeMind / UniReader 需要它是因为那边有搜索框这种弹性宽度的 item，会铺到检查器上方；
  本工程没有这类 item，所以去掉它右侧就贴边了。
- **`.flexibleSpace` 只在「侧栏分隔符 → 检查器分隔符」这一段里撑开**，不会撑到检查器区里去。想让 item 靠右，
  靠的就是这一个空白；要分组用 `.space` 断开。
- **画布是全出血的**（`.fullSizeContentView` 的副作用）：笔和网格画到工具栏底下，但**文字必须让开**——
  `CanvasOverlayView` 用 `safeAreaInsets` 夹住刻度与读数框，别让标签被工具栏压住。
- **工具栏按 AppKit 标准做法**：每枚按钮一个独立 item、`isBordered = true`，相邻图标 item 由系统合并成玻璃胶囊，
  分组靠 `.space` 断开；**不要**手动给符号指定 pointSize（系统自己管字号），也**不要**用 `NSToolbarItemGroup`
  做常规分组（它在「自定工具栏…」里拆不开）。检查器开关用 `toolbarImmovableItemIdentifiers` 钉住。
  改了 `toolbarDefaultItemIdentifiers` 的清单后，把 `NSToolbar(identifier:)` 升一版（`.v3` → `.v4`），
  否则 `autosavesConfiguration` 存下来的老清单里没有新 item。
- **`Array.move(fromOffsets:toOffset:)` 是 SwiftUI 的扩展**，去掉 SwiftUI 后链接会断在 `AppState.moveLayers`。自己实现的 `moveElements(fromOffsets:toOffset:)` 在 `AppState.swift` 末尾。
- **`NSResponder` 已有 `mouseMoved` / `mouseDown` 等同名方法**，控制器的处理方法必须改名（现在是 `handleMouseMoved` 等），否则会被当成重写。
- **侧栏收起时 `safeAreaInsets` 不逐帧变**：展开动画里它逐帧变，收起动画里它停在原值、动画结束才一下跳到 0，
  内容就等侧栏收完再猛跳一下（实测）。按安全区参考线约束出来的 frame 两个方向都逐帧变，所以画布用
  `SafeAreaProbeView`（钉在宿主 `safeAreaLayoutGuide` 上的透明视图）量遮挡宽度，frame 一变就对一次视口。
- **不要在 `layout()` 里改观察状态**。`ViewportViewController` 的视口尺寸通过 `DispatchQueue.main.async` 延后一拍再写；在布局里直接写会让窗口进入无限重排（实测卡死在 `_layoutSubtreeWithOldSize` 递归里）。
- **分栏/窗口的自动保存状态会被写坏**：`NSSplitView Subview Frames <name>` 里出现过侧栏和检查器 `isCollapsed = YES`、
  画布独占全宽的状态（怀疑是同时跑两个实例时互相覆盖）。遇到「面板莫名消失」先查这条，清掉即可：
  `defaults delete tech.xvanturing.GrapherNG "NSSplitView Subview Frames GrapherNGSplit"`。

## 待定

- **代码注释目前是英文**。Perch / FreeMind / UniReader 的约定是「代码注释用中文」，这个工程还没统一。要改的话是一次全量机械替换（约 8000 行），改之前先确认。

## 示例目录与 Agent 测试

- **示例目录**（`GrapherKit/Model/Demos.swift`）：`Demo`（id、分类、标题、一两句讲解、`make()` 出一份完整文档）按 `DemoCategory`
  分类——平面图：曲线与区域 / 参数滑块 / 切线与法线 / 数据与拟合；立体图：曲面与空间曲线 / 曲面交线 / 点线面 / 投影与切平面。
  搭示例用 `DemoBuilder`（`add` / `point` / `tangent` / `intersection` / `projection` / `construct` …）；`construct` 直接调
  `SpaceGeometry.relation`，把垂足、公垂线、交线、距离文字算出来写进文档，所以示例里的数字不会和内核不一致。
  菜单入口 `ExamplesMenu`（文件 ▸ 打开示例、欢迎窗口的「示例」共用），点开在**新窗口**里（`GraphDocumentController.newDocument(demo:)`），
  不改用户正在编辑的图。**新加示例**：在 `Demos.plane` / `Demos.space` 里加一项，标题与讲解补两种语言（`GrapherKit/Resources`）。
- **`DemoTests`** 守着每个示例：id 不重复、每类有示例、公式没错、引用的图层都在、存取不变、真的画得出东西、渲染出来的图有内容、
  中文都翻了。想肉眼过一遍：`TEST_RUNNER_GRAPHER_DEMO_DIR=<目录> bash scripts/test.sh`，每个示例会存成 PNG。
- **`AgentScenarioTests`** 把 AI 当用户，走真实的 MCP 工具目录 + JSON-RPC 画图：交线 + 投影、维维亚尼曲线、位置关系
  （`relate` / `draw_relation`）、切线 + 散点 + 文字、参数、出错不留半成品、只读权限。测试宿主里最后一扇窗口关掉会让 App 退出，
  所以测试里留一扇「哨兵」窗口不关。新加 MCP 工具 / 图型时，在这里加一个场景。
