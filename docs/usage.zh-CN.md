# Grapher NG — 用法

[English](usage.md) · **简体中文**

## 让 AI 画图（MCP）

Grapher NG 内置了一个 [MCP](https://modelcontextprotocol.io) 服务。Claude Code 这类 AI 助手接上之后，可以新建文档、
添加曲线、区域和曲面、调整视角，还能自己看一眼画出来的结果——都发生在你正在用的这些窗口里。它加的内容就是普通的编辑：
出现在图层列表里，可以用 ⌘Z 撤销，保存之前文档一直标为「已编辑」。

### 1. 打开服务

打开 **Grapher NG ▸ 设置…**（⌘,）：

| 设置项 | 说明 |
|---|---|
| 启用 MCP 服务 | 立即启动或停止。默认关闭。 |
| 端口 | 默认 `8776`。改动后服务会自动重启。 |
| 允许 AI 修改图形 | 默认关闭。关闭时 AI 只能读取文档、生成图片；所有会改动内容的工具都会被拒绝，并给出明确的提示。 |
| 访问令牌 | 每个请求都必须带上它，存放在钥匙串里。随时可以重新生成，旧客户端立即失效。 |

服务只监听 `127.0.0.1`，这台 Mac 之外的设备无法访问。

### 2. 连接客户端

设置窗口里有填好端口和令牌的现成片段，直接复制即可。

**Claude Code**

```bash
claude mcp add --transport http grapher-ng http://127.0.0.1:8776/mcp \
  --header "Authorization: Bearer <你的令牌>"
```

**其他客户端**（任何支持 HTTP 方式 MCP 的）：

```json
{
  "mcpServers": {
    "grapher-ng": {
      "type": "http",
      "url": "http://127.0.0.1:8776/mcp",
      "headers": { "Authorization": "Bearer <你的令牌>" }
    }
  }
}
```

需要 Grapher NG 正在运行。在终端里快速验证：

```bash
curl -s -X POST http://127.0.0.1:8776/mcp \
  -H "Authorization: Bearer <你的令牌>" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### 3. 让它画图

下面这些说法都可以：

- 「在 Grapher NG 里画一条心形线，再画一个穿过两个心瓣的圆。」
- 「做一个立体图：z = sin(x)·cos(y)，再在原点放一个半径 1 的球，画完给我看图。」
- 「加一个 0 到 4 的参数 `a`，画 `a*sin(x)/x`，我想拖滑块看变化。」
- 「保存到 ~/Desktop/heart.grapher，再在旁边导出一张 2000×1200 的 PNG。」

助手应当先调 `get_reference`（公式语法，以及每种图型要填哪些栏），画完用 `render_image` 检查。公式写错时调用会失败，
并指出出错的列号，图形不会被加进去，助手改完重试即可。

### 工具

读取类工具随时可用：

| 工具 | 作用 |
|---|---|
| `get_state` | 已打开的文档（id、标题、平面 / 立体、图层数），以及是否允许修改。从这里开始。 |
| `get_document` | 一份文档的全部内容：图层（含 id、公式、颜色、错误）、参数、视角、外观。 |
| `get_reference` | 图型、公式语法、函数与示例。 |
| `render_image` | 把文档画成 PNG 给助手看。默认 900×600，最大 2400×2400。带讲解的文档加 `step`（从 1 数）画那一步：图层、视角、参数按那一步，底部带讲解卡片。 |
| `get_text_reference` | Markdown 笔记里图形块（```` ```grapher ```` 代码块，如 UniReader）的文字格式说明：一行一个图层、滑块、视角、示例。 |
| `render_text` | 把一段文字描述画成 PNG，错误按行号列出，不碰任何打开着的文档。往笔记里放图形块之前先用它检查。文字里写了讲解步骤时，加 `step` 画那一步。 |
| `relate`（只读） | 立体图：两个点 / 直线 / 平面的位置关系（关系代码、距离、夹角、垂足、交点、公垂线、交线），带坐标。直线是对 `t` 线性的 `spaceCurve`，平面是对 x、y、z 线性的 `implicitSurface` / `surface` 或 `tangentPlane`。 |

修改类工具需要打开「允许 AI 修改图形」：

| 工具 | 作用 |
|---|---|
| `create_document` | 新建空白窗口：平面图 `plane` 或立体图 `space`。 |
| `open_document` / `save_document` | 打开 `.grapher` 文件；原地保存或存到指定路径。 |
| `add_layer` | 添加图形：`kind`、`formula`，按需再填 `secondary_formula`、`tertiary_formula`、`domain`、`domain2`、`relation`、`extrude`、`color`、`line_width`、`dashed`、`name`。 |
| `update_layer` / `remove_layer` | 按 id 修改图层的字段（图型不能改），或删除。 |
| `set_parameter` / `remove_parameter` | 新建或修改命名参数及滑块范围（`name`、`value`、`min`、`max`）。 |
| `set_view` | 平面图：`center_x`、`center_y`、`scale`。立体图：`center`、`half_extent`、`azimuth`、`elevation`（度）、`camera_zoom`。另有 `fit`、`reset`。 |
| `set_appearance` | `theme`（light / dark）、网格、次网格、坐标轴、刻度数字。 |
| `export_png` | 按指定尺寸写出 PNG 文件。 |
| `draw_relation` | 同 `relate`，并把垂足、交点、公垂线、交线这些辅助对象加成新图层。 |
| `set_lesson` | 把文档做成分步讲解：整份换掉步骤。每一步有 `title`、`text`（可夹 TeX）、`show`（这一步显示的图层名）、相机（立体图 `azimuth` `elevation` `zoom` `range` `center`，平面图 `center` `width`）、`parameters`（参数名 → 值）、`play`（要播放的参数）。空数组去掉讲解。能撤销。 |
| `go_to_step` | 在窗口里翻到讲解的第几步（从 1 数），或 `end: true` 结束讲解。 |

所有针对文档的工具都有可选的 `document_id`；不填就用最前面的图形窗口。

### 图型速查

| 文档 | `kind` | 要填的栏 |
|---|---|---|
| 平面 | `explicit` | `formula` = f(x) |
| 平面 | `parametric` | `formula` = x(t)，`secondary_formula` = y(t)，`domain` |
| 平面 | `polar` | `formula` = r(theta)，`domain` |
| 平面 | `implicit` | `formula` = F(x, y)，画 F = 0 |
| 平面 | `region` | `formula` = F(x, y)，`relation` 取 `<` `<=` `>` `>=` |
| 立体 | `surface` | `formula` = f(x, y) |
| 立体 | `parametricSurface` | 三个公式栏依次是 x(u,v)、y(u,v)、z(u,v)，`domain` 是 u 的范围，`domain2` 是 v 的范围 |
| 立体 | `spaceCurve` | 三个公式栏依次是 x(t)、y(t)、z(t)，`domain`；`arrow: true` 在 t 的终点画箭头（画向量） |
| 立体 | `implicitSurface` | `formula` = F(x, y, z)，画 F = 0 |
| 立体 | `surfaceIntersection` | 没有公式：`source_a`、`source_b` 是两个曲面图层（`surface`、`parametricSurface`、`implicitSurface`）的 id，画它们的交线；来源图层隐藏了也照画 |
| 平面 | `scatter` | `formula` 是数据，每行一个 `x, y` 点（逗号、分号、空格或制表符分隔，表头行会跳过），`fit: true` 画最小二乘直线（`get_document` 会给出 `slope`、`intercept`、`r`），`line_width` 是点的大小 |
| 平面 / 立体 | `text` | `formula` 是要写的文字（不当公式编译），`at` / `at2`（立体图再加 `at3`）是数据坐标里的位置，`font_size` 字号，`color` 颜色 |
| 平面 | `tangent` | 没有公式：`source_a` 是 `explicit` / `parametric` / `polar` 图层，`at` 是切点位置（显函数的 x、参数方程的 t、极坐标的 theta），`normal: true` 画法线而不是切线 |
| 立体 | `tangentPlane` | 没有公式：`source_a` 是 `surface` / `parametricSurface` 图层，`at` + `at2` 是切点的 (x, y) 或 (u, v)；画一块半透明方片、法线和切点，在位置关系面板里当平面用 |
| 立体 | `gradientField` | 没有公式：`source_a` 是 `surface` 图层 z = f(x, y)；箭头沿最陡上升方向，坡越陡越长越暖（峰顶、谷底、鞍点没有箭头）。`density` 是每个方向的箭头数（2–40），`arrow_scale` 取负数画 −∇f，`on_floor: true` 把 ∇f 平放在坐标盒底面 |
| 立体 | `gradientFlow` | `source_a` 是 `surface` 图层；`formula` 是起点，每行一个 `x, y`（每一栏可以是数或含参数的公式，如 `3*cos(q), 3*sin(q)`）；路径沿 ∇f 上坡走（`arrow_scale` 取负数下坡），`on_floor` 平放在地面；`secondary_formula` 是小球在路径上的位置（0 到 1），可以写参数——播放这个参数小球就滚起来 |
| 立体 | `point` | `formula`、`secondary_formula`、`tertiary_formula` 依次是 x、y、z（只能写数和参数）；`line_width` 是点的大小 |
| 立体 | `projection` | 没有公式：`source_a` 是 `point` / `spaceCurve` / `surfaceIntersection` 图层，`target` 取 `xy` / `yz` / `xz`（投到 z / x / y = `offset` 的平面）或 `plane`（`source_b` 是一个平面图层），`projectors` 控制是否画投影线，`direction` = [dx, dy, dz] 改成沿该方向的斜投影 |
| 立体 | `explicit`、`parametric`、`polar`、`implicit` | 同平面；默认画在 z = 0 上，`extrude: true` 则沿 z 拉成竖直曲面 |

隐式图型的 F 不要写 `= 0`（写 `x^2 + y^2 - 4`，不要写 `x^2 + y^2 = 4`）。

### 需要知道的

- **新建或打开文档时窗口会被调到最前**；其他改动不会抢走你的焦点。
- **不会自动保存。** 没保存的文档照常显示「已编辑」，关窗时照常弹出保存提示。
- **立体图会被裁在坐标盒里**（默认 ±4）。图形看不见时，把它缩小，或者调用 `set_view`。
- **只监听 127.0.0.1**，没有监听其他网卡的选项；要从别的机器访问，请用 SSH 隧道。
- **启动不了时**，设置窗口会显示原因（多半是端口被占用，换一个端口即可）。
- 重新生成令牌后，要更新客户端配置（`claude mcp remove grapher-ng`，再重新添加）。

### 拿来学习的示例

**文件 ▸ 打开示例**（以及欢迎窗口里的「示例」卡片）按功能分类列出一组现成的图。每个示例都在新窗口里打开，可以放心拖滑块、改公式、旋转，不会动到你自己的图。

- **平面图**：曲线与区域 · 参数滑块 · 切线与法线 · 数据与拟合
- **立体图**：曲面与空间曲线 · 曲面交线 · 点、线、面 · 投影与切平面 · 梯度 · 分步推导

鼠标停在菜单里的示例上，会显示一句话说明。

### 分步讲解

把一份图拆成几步，一步一步讲推导（比如曲面面积元 dS 是怎么来的）。每一步有标题和一段讲解，讲解里可以夹 TeX 公式：
行内写 `$…$`，单独一行写 `$$…$$`，加粗写 `**…**`。每一步还规定显示哪些图层、相机转到哪、参数取什么值（进这一步时
平滑地变过去），以及要不要自动播放某个参数。

- **看讲解**：打开带讲解的文档（如 **文件 ▸ 打开示例 ▸ 分步推导 ▸ 曲面面积元 dS**）会直接从第一步讲起。讲解卡片在画布底部，
  图形自动摆在卡片上方。翻页用卡片上的 ‹ ›，或在画布上按 ← → / 空格 / PageUp PageDown；点卡片左上角的「2 / 8」可以跳到
  任意一步；Esc 或 ✕ 结束讲解。菜单里也有 **显示 ▸ 下一步（⌘]）/ 上一步（⌘[）**。讲解中照样可以拖动旋转、拖滑块。
- **看讲解不改文档**：每一步只影响画出来的样子，图层自己的显示开关不变；结束讲解时参数回到进讲解之前的值，存盘存的也是这些值。
- **做讲解**：点工具栏的讲解按钮（学士帽），或 **显示 ▸ 开始讲解（⌥⌘L）**。还没有步骤时，它用眼前的样子建第一步并打开编辑。
  点卡片上的铅笔进入编辑：
  - 图层列表里的眼睛改的是**这一步**显示哪些图层；
  - 摆好视角、拖好滑块，点「记下视角和参数」存进这一步；
  - 标题和讲解原文直接在卡片里改；「在后面加一步」、↑ ↓ 挪位置、「删除这一步」。所有改动都能撤销。
- 没在任何一步里出现过的图层不归讲解管，按它自己的显示开关；所以写好讲解之后再加的图层照常显示。
- 往后翻一页只用这一步自己写的相机和参数（没写就不动，手动转过的视角留着）；跳页、往回翻则恢复成「一路讲到这一步」的样子。
- **画向量**：讲解里常要画法向量、切向量。空间曲线在检查器里勾选「末端画箭头」，就在参数终点画一个箭头。

让 AI 做讲解：先用 `add_layer` 画好所有图层（辅助图层也一起），再用 `set_lesson` 分步，用 `render_image` 加 `step` 逐步检查。
文字格式（```` ```grapher ```` 块）也能写讲解：`step 标题: show=S, P; azimuth=30; h=0.3; play=h`，紧跟着以 `>` 开头的行是
这一步的讲解文字（写法见 `get_text_reference`）。

### 用参数做动画

左侧面板里每个参数都有**播放**按钮。播放后滑块自己在范围里来回走，所有用到这个参数的图形跟着动：平面扫过曲面（交线跟着移动）、正弦波相位滚动、山丘变宽变窄时梯度场跟着变、小球沿梯度路径滚动（把小球位置写成参数，如 `p`）。**+** 旁边的齿轮设置速度（慢 / 中 / 快）以及往返还是循环。可以同时播放几个参数；撤销会回到播放之前的值。

### 看梯度

在立体图里放一个 `surface` 图层 z = f(x, y)，再在它上面加「梯度场」图层：箭头指向最陡的上升方向，坡越陡越长越红（峰顶、谷底、鞍点没有箭头），可以画在曲面上，也可以平放在地面上（课本上的 ∇f）。「梯度流线」从你列出的起点出发，沿 ∇f 上坡（或 −∇f 下坡）走；每条路径上有一个小球，位置由你给（0 到 1），把它写成参数、按播放，小球就沿路径滚动。曲面上勾选「按坡度上色」，整张曲面变成 |∇f| 的热力图。示例目录里的「梯度」分组把这些都演示了一遍。

**让曲线逐渐画出来。** 参数范围的端点（`t`、`theta`、`u`、`v` 的范围，或显函数的定义域）除了数，也可以写公式，如 `p*2*pi`。建一个 0 到 1 的参数 `p`，把上限写成 `p*2*pi`，播放 `p`：曲线随 `p` 变大画到相应的位置，参数曲面则一圈圈扫出来。通过 MCP 用 `domain_formulas`（以及 `domain2_formulas`），例如 `["0", "p*2*pi"]`；空字符串表示这一端仍用原来的数。

**沿曲线滑动。** 位置也一样：切线、法线、切平面的切点，文字标注的位置，投影平面的位置，都可以写成含参数的公式（`p`、`2*cos(q)`……）。播放参数，切线就沿曲线滑动，切平面绕着曲面转，文字跟着走。通过 MCP 给 `at`、`at2`、`at3` 或 `offset` 传字符串即可，例如 `"at": "p"`。
