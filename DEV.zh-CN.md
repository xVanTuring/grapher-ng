# Grapher NG — 开发

[English](DEV.md) · **简体中文**

## 构建与运行

```bash
xcodegen generate                          # 工程由 project.yml 生成，GrapherNG.xcodeproj 是生成物、不入库
xcodebuild -project GrapherNG.xcodeproj -scheme GrapherNG \
  -derivedDataPath build/DerivedData -resolvePackageDependencies   # 第一次编译前解析 Sparkle
bash scripts/build.sh                      # 等价于 xcodebuild … -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/GrapherNG.app

bash scripts/run.sh                        # 构建并直接跑，日志输出到终端
bash scripts/test.sh                       # 跑单元测试
```

需要 Xcode 和 `xcodegen`（`brew install xcodegen`）。工程管理方式与 Perch / FreeMind / UniReader 一致。
签名、公证、打包与发布见 [docs/release.md](docs/release.md)。

图标可以重新生成：`bash scripts/make-icon.sh`（需要带 Pillow 的 Python），产物是 `Sources/GrapherApp/Resources/Assets.xcassets/AppIcon.appiconset`。

## 无界面模式

调试和造图用得上：

```bash
# 渲染一张图，不打开窗口
build/DerivedData/Build/Products/Debug/GrapherNG.app/Contents/MacOS/GrapherNG \
  --render out.png --doc doc.grapher --width 1600 --height 1200 --quality high

# 渲染立体图示例（立体图文件用 --doc 指定即可），可以换个角度
build/DerivedData/Build/Products/Debug/GrapherNG.app/Contents/MacOS/GrapherNG \
  --render out.png --space --azimuth 1.2 --elevation 0.3

# 采样与求值的性能
build/DerivedData/Build/Products/Debug/GrapherNG.app/Contents/MacOS/GrapherNG --benchmark
```

## 代码结构

```
project.yml          xcodegen 工程定义（GrapherNG.xcodeproj 是生成物）
Sources/
  GrapherKit/        纯逻辑，不依赖界面框架（framework target）
    Expr/            词法 → 语法 → 字节码 → 栈式虚拟机求值
    Sampling/        自适应细分、marching squares、区域填充、探针、场景组装、坐标轴文字摆放；
                     3D 的曲面网格、marching tetrahedra、空间曲线、坐标盒线框
    Model/           文档、图层、视口变换（2D 视口、3D 坐标盒与相机）、刻度、画布手感
    IO/              PDF / CSV 导出
  GrapherRender/     Metal 渲染（framework target）：2D 描边与填充、3D 曲面与线、离屏导出、缩略图、MTKView 封装
  GrapherApp/        AppKit 界面与事件处理、文档模型、欢迎窗口、自动更新、命令行模式
    MCP/             内置 MCP 服务（见下文）：JSON-RPC 与 HTTP 解析、工具注册表、各工具、文档操作层、设置窗口
Extensions/
  QuickLook/         访达空格预览（可交互的只读画布）
  Thumbnail/         访达文件缩略图
Tests/
  GrapherNGTests/    表达式（含模糊测试与基准）、采样与几何、整条流水线、离屏渲染像素断言
```

分成三个 target 而不是全合进 App，是为了让编译器守住一条边界：**GrapherKit 不许 import AppKit**。整套单元测试主要跑在它上面。

`GrapherKit` 在 Debug 下单独开了 `-O` + 整模块优化：这一层是数值密集的，`-Onone` 会让网格求值慢 27 倍（实测 1.2M vs 32M 点/秒），拖动只剩 5 帧。界面层仍是 `-Onone`，照常单步。

界面全部是 AppKit：`NSSplitViewController` 三栏、`NSTableView` 图层列表、`NSStackView` 表单、`NSColorWell` 取色、`NSToolbar` 工具栏、手写 `NSMenu` 菜单栏。刻度数字和光标读数是一层 `NSView`，用 Core Graphics 和 Core Text 画在 Metal 画布之上。`AppState` 用一个极简的观察者回调广播变更，不依赖 Combine 或任何绑定框架——界面这一段没有任何声明式框架参与。

## MCP 服务

在 `Network.framework` 上手写 JSON-RPC 2.0 over HTTP，不依赖 MCP SDK，设计与 Perch、UniReader 一致。面向用户的用法见
[docs/usage.zh-CN.md](docs/usage.zh-CN.md)。

- `MCPServer` 在 App 进程内监听 127.0.0.1（默认关闭；设置项在 `MCPSettings`，访问令牌在钥匙串）。每个连接只处理
  一个请求，只接受 `POST /mcp`，带了 `Origin` 就校验。
- `MCPProtocol` / `MCPHTTP` 是不碰网络的纯逻辑，直接做单元测试。只实现了 `tools/*`。
- `MCPCatalog` 是写权限开关唯一的检查点：工具注册时标明 `.read` 还是 `.write`。
- `MCPFacade` 是唯一碰文档的代码。所有改动都走 `AppState.mutate`——和界面同一条路径，所以 MCP 的改动能撤销、
  会把文档标成已编辑。插入之前先用 `LayerCompiler` 编译公式；公式有错则什么都不改，错误信息带列号。
- 文档用 `GraphDocument.mcpID` 指代；不传 `document_id` 就用最前面的图形窗口。
- 新增工具：在 `MCPTools` 里注册，文档逻辑放进 `MCPFacade`，在 `MCPTests` 里补测试，并把工具写进两份用法文档
  （`docs/usage.md`、`docs/usage.zh-CN.md`）。设置窗口的界面文字要同步补两份 `Localizable.strings`。

App 运行且已开启 MCP 时，手动验证：

```bash
curl -s -X POST http://127.0.0.1:8775/mcp -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_state","arguments":{}}}'
```

## 画质是怎么保证的

「曲线要光滑」是这个项目的硬指标，不是靠调 MSAA 级别实现的：

- **线**在线段级别展开成屏幕空间的四边形，片元着色器计算像素中心到线段的精确距离，按距离给出覆盖率。所以边缘是精确的 1 像素灰阶过渡，线宽在任何缩放下恒定，端点是圆头、拐角是圆角。
- **填充区域**的边界逐像素计算子像素覆盖率（对网格的双线性插值做 8×8 子采样），和描边是同一档质量。
- **曲线采样**做曲率自适应细分，弦高误差超过 0.14 像素就二分，参数方程还会额外检查转角。
- 隐函数用 marching squares 求等值线，并把散落的格子线段拼接成连续折线，避免用一堆短线段去画一条曲线。
- 采样在 CPU 上用 `Double` 完成（Apple GPU 没有双精度），拖动时降到约 1/3 分辨率、停手 200 毫秒后自动重算精细版本。

回归证据在测试里：`Renderer2DTests` 直接断言导出的像素值（45° 边缘的覆盖率、线宽在缩放下的稳定性、通道序、图层顺序、圆头端点），`SamplingTests` 断言填充区域的墨量等于 πr²、1/x 不会画出竖直连线之类。

立体图的曲面边缘靠 4× MSAA（三角形边缘没法解析地算覆盖率），空间曲线与坐标盒的线照旧按像素距离算覆盖率；盒外的部分用
六个裁剪平面在 GPU 上精确裁掉。`Sampling3DTests` 断言隐式球面的顶点都落在球面上、拼出的面积等于 4πr²，`Renderer3DTests`
断言盒外的面一个像素都不画、近处的面挡住远处的面。

## 还没做的

- 曲面交线目前只到网格精度（见 `MeshIntersection`）；没做牛顿迭代投影回真曲面，也不支持「延伸到 3D」的竖直曲面当来源。
- 立体图：悬停读数、矢量导出；多张半透明曲面之间没有按深度排序。

- 散点图以外的统计图表（直方图、箱线图、非线性拟合）。
