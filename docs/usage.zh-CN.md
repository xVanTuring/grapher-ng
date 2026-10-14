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
| 端口 | 默认 `8775`。改动后服务会自动重启。 |
| 允许 AI 修改图形 | 默认关闭。关闭时 AI 只能读取文档、生成图片；所有会改动内容的工具都会被拒绝，并给出明确的提示。 |
| 访问令牌 | 每个请求都必须带上它，存放在钥匙串里。随时可以重新生成，旧客户端立即失效。 |

服务只监听 `127.0.0.1`，这台 Mac 之外的设备无法访问。

### 2. 连接客户端

设置窗口里有填好端口和令牌的现成片段，直接复制即可。

**Claude Code**

```bash
claude mcp add --transport http grapher-ng http://127.0.0.1:8775/mcp \
  --header "Authorization: Bearer <你的令牌>"
```

**其他客户端**（任何支持 HTTP 方式 MCP 的）：

```json
{
  "mcpServers": {
    "grapher-ng": {
      "type": "http",
      "url": "http://127.0.0.1:8775/mcp",
      "headers": { "Authorization": "Bearer <你的令牌>" }
    }
  }
}
```

需要 Grapher NG 正在运行。在终端里快速验证：

```bash
curl -s -X POST http://127.0.0.1:8775/mcp \
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
| `render_image` | 把文档画成 PNG 给助手看。默认 900×600，最大 2400×2400。 |

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
| 立体 | `spaceCurve` | 三个公式栏依次是 x(t)、y(t)、z(t)，`domain` |
| 立体 | `implicitSurface` | `formula` = F(x, y, z)，画 F = 0 |
| 立体 | `explicit`、`parametric`、`polar`、`implicit` | 同平面；默认画在 z = 0 上，`extrude: true` 则沿 z 拉成竖直曲面 |

隐式图型的 F 不要写 `= 0`（写 `x^2 + y^2 - 4`，不要写 `x^2 + y^2 = 4`）。

### 需要知道的

- **新建或打开文档时窗口会被调到最前**；其他改动不会抢走你的焦点。
- **不会自动保存。** 没保存的文档照常显示「已编辑」，关窗时照常弹出保存提示。
- **立体图会被裁在坐标盒里**（默认 ±4）。图形看不见时，把它缩小，或者调用 `set_view`。
- **只监听 127.0.0.1**，没有监听其他网卡的选项；要从别的机器访问，请用 SSH 隧道。
- **启动不了时**，设置窗口会显示原因（多半是端口被占用，换一个端口即可）。
- 重新生成令牌后，要更新客户端配置（`claude mcp remove grapher-ng`，再重新添加）。
