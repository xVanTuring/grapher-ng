# AGENTS.md — GrapherNG

macOS 上的公式绘图工具（输入公式画曲线、区域、曲面）。**纯 AppKit + Metal，零第三方依赖**；xcodegen 管理工程
（`GrapherNG.xcodeproj` 由 `project.yml` 生成，不要手改），macOS 14+，Swift 5 语言模式，ad-hoc 签名。

当前覆盖 **2D 全部图型**（显函数 / 参数方程 / 极坐标 / 隐函数 / 不等式区域）。3D 与两曲面交线是下一期，架构上已留位置。

## 构建 / 测试 / 运行

```sh
xcodegen generate
bash scripts/build.sh    # xcodebuild … -derivedDataPath build/DerivedData build
bash scripts/test.sh     # 单元测试，以 App 为宿主
bash scripts/run.sh      # 构建并直接运行，日志输出到终端
```

产物在 `build/DerivedData/Build/Products/Debug/GrapherNG.app`。图标：`bash scripts/make-icon.sh`。

无界面模式（调试与造图用，不开窗口）：

```sh
<app>/Contents/MacOS/GrapherNG --render out.png [--doc d.json] [--width W] [--height H] [--quality full|high]
<app>/Contents/MacOS/GrapherNG --benchmark
```

## 结构与边界

```
Sources/GrapherKit/     纯逻辑（framework）—— Expr / Sampling / Model / IO
Sources/GrapherRender/  Metal 渲染（framework）
Sources/GrapherApp/     AppKit 界面、事件处理、命令行模式
Tests/GrapherNGTests/   单元测试
```

- **GrapherKit 不许 import 任何界面框架**。拆成三个 target 就是为了让编译器守住这条边界；它也是唯一有测试覆盖的层，全部 58 项测试都跑在它和 GrapherRender 上。
- 界面**不许用 SwiftUI**。`AppState` 用极简观察者回调广播变更（`observe(_:_:)`），不引入 Combine。
- `GrapherRender` 的着色器是**运行期**从 `ShaderSource.swift` 里的内嵌字符串编译的，没有 `.metal` 编译阶段——别去加 build phase。
- `GrapherKit` 在 Debug 下单独开 `-O` + `wholemodule`：这一层数值密集，`-Onone` 让网格求值慢 27 倍（1.2M vs 32M 点/秒）。界面层保持 `-Onone`。

## 关键设计（改动前先读）

- **抗锯齿靠解析式覆盖率，不是 MSAA**。线在屏幕空间展开成四边形、片元算像素中心到线段的精确距离；填充的边界逐像素算子像素覆盖率。**`MetalContext.sampleCount` 必须是 1**，开了 MSAA 会在覆盖率之上再叠一层，把边缘弄脏。
- **采样在 CPU 上用 `Double`**（Apple GPU 没有双精度）。拖动时降到约 1/3 分辨率、停手 200ms 后重算精细版；这套节流在 `AppState.requestInteractiveRebuild`。
- **求值是字节码栈式虚拟机**，必须**可重入且线程安全**（`evaluate` 内部用 `withUnsafeTemporaryAllocation` 在栈上开求值栈，无共享可变状态）。网格求值走 `evaluateBatch`，不要退化成逐点调 `evaluate`。
- **间断必须断开**：`1/x`、`tan(x)` 不能画出竖直连线。判定在 `CurveSampler.sampleExplicit`（跳变超过半屏高且横向跨度小于 4 像素即为极点）。
- 画质常数别随手调：弦高容差 0.14 像素、`tolerancePixels` 分档在 `CurveSampler.options(for:)`；屏幕坐标进 GPU 前在 `SceneBuilder2D.screenClamped` 夹到 ±1e7，否则极点会把 float32 变成 inf。

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
- **不要在 `layout()` 里改观察状态**。`ViewportViewController` 的视口尺寸通过 `DispatchQueue.main.async` 延后一拍再写；在布局里直接写会让窗口进入无限重排（实测卡死在 `_layoutSubtreeWithOldSize` 递归里）。
- **分栏/窗口的自动保存状态会被写坏**：`NSSplitView Subview Frames <name>` 里出现过侧栏和检查器 `isCollapsed = YES`、
  画布独占全宽的状态（怀疑是同时跑两个实例时互相覆盖）。遇到「面板莫名消失」先查这条，清掉即可：
  `defaults delete tech.xvanturing.GrapherNG "NSSplitView Subview Frames GrapherNGSplit"`。

## 待定

- **代码注释目前是英文**。Perch / FreeMind / UniReader 的约定是「代码注释用中文」，这个工程还没统一。要改的话是一次全量机械替换（约 8000 行），改之前先确认。
