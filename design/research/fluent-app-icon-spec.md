# Windows / Fluent 应用图标规范摘要

> 调研来源（均为微软官方文档，2026-09 抓取，原文快照见本目录 `*.txt`）：
> - App icons（总览）：<https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icons>
> - **Design guidelines for Windows app icons**（隐喻/形状/颜色/阴影）：<https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-design>
> - **Construct your Windows app's icon**（尺寸/资源/主题）：<https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction>
> - Iconography in Windows（图标分类/系统图标）：<https://learn.microsoft.com/en-us/windows/apps/design/iconography/>
> - Fluent 2 · Iconography（图标集合与授权）：<https://fluent2.microsoft.design/iconography>
> - Geometry / Elevation / Materials（**UI 控件**规范，非图标）：`.../signature-experiences/geometry`、`/layering`、`/materials`

---

## 一、App 图标设计规范（这是"微软风格"的本体）

### 1. 隐喻 Metaphor
- 一个图标讲**一个核心概念**，最多两个隐喻，能用单个就别用两个。
- **优先字面隐喻**（信封=邮件、放大镜=搜索）；只有在找不到字面隐喻时才用抽象隐喻。
- **图标里不要放文字或字母**——"Icons should not include typography as part of the design. Letters and words on your icon should be avoided"。理由：应用名会始终跟随图标一起出现，图标不需要重复它。
- 不要为了装饰加元素，装饰会稀释隐喻。

### 2. 形状 Shape
- **对齐 48×48 网格**设计（"Microsoft aligns its icons to a 48x48 grid initially"），保证剪影和其它图标并排时视觉重量平衡。
- **圆角极小**：外轮廓曲线用 **2px @48**，内轮廓曲线用 **1px @48**。
  （换算到 1024 画布 ≈ 42.7px / 21.3px。**不是** iOS 那种 20%+ 的大圆角 squircle。）
- 剪影要能缩放：**形状尽量少、角尽量少**，避免忽粗忽细的极端。
- 细节只加在**最突出的那一层**，保证小尺寸可读。

### 3. 颜色与渐变 Color & gradients
- 不要只靠颜色传达含义，要和形状/隐喻配合。
- **克制的渐变**："Gradients should be subtle for the most part… limit your gradient ramps to only one or two steps"，**默认渐变角度 120°**，避免过紧的过渡（会看起来像反光或立体）。
- 尽量减少"多层不同透明度的叠加、色调叠加"（"overlays of varying opacity, and tints of color should be kept to a minimum"）。
- 调色板两种做法：
  - **单色系**：同一色相取三个色（浅色提亮、深色降饱和），中间再插三档；大多数面积用主色道，白/黑 tints & shades 仅在需要对比时少量使用。
  - **类似色系**：三组色，垂直渐变，用第二/第三色代替黑白做 tint/shade。
- 单色渐变用来暗示**来自左上角的环境光**，只是给形状一点动感，**不是**当作直接光源。

### 4. 对比度 Contrast
- 用暗/中/亮三个区间的颜色值组合。
- **至少一半的图标面积**要在**亮色主题和暗色主题下都通过 3.0:1** 对比度。
- 允许（非必须）为任务栏/开始菜单等主题敏感区域单独提供亮/暗两套资源。
- Windows 11 **不再要求**高对比度专用图标资源。

### 5. 层叠与阴影 Layering & shadow
- 图标由**扁平物体分层**堆叠而成；层数尽量少。
- **用投影在层与层之间做区分**并把组件视觉上连接起来；"shadows cast from light onto dark shapes have the best result"（浅色物体投在深色形状上效果最好）。
- 内阴影只作用在图形符号上，**不能**投到周围背景。
- **所有阴影数值都以 48×48 为基准渲染**，再等比缩放，否则整个图标系统的阴影会不一致。
- **透视**：正向平视；不推荐透视，除非隐喻本身（如圆柱、3D 类应用）必须有另一个面才能读懂。

---

## 二、构造与交付规范

### 1. 尺寸（Windows 11 各 DPI 实际会用到）
| 出现位置 | 100% | 125% | 150% | 200% | 250% | 300% | 400% |
|---|---|---|---|---|---|---|---|
| 右键菜单 / 标题栏 / 系统托盘 | 16 | 20 | 24 | 32 | 40 | 48 | 64 |
| 任务栏 / 搜索 / 开始"所有应用" | 24 | 30 | 36 | 48 | 60 | 72 | 96 |
| 开始菜单固定 | 32 | 40 | 48 | 64 | 80 | 96 | 256 |

- **最低要求：16 / 24 / 32 / 48 / 256**。带 256 的作用是让 Windows 永远只做缩小、不做放大。
- Win32 **ICO** 用的是上表的一个子集。

### 2. 背景：透明优先
> "Icons look best with a transparent background. If your app's branding requires your icon be plated on a background, that's okay too."

即：**透明底是首选**，整块"镀板"（plated）只是可接受，且镀板要自己重新实现主题适配（提供亮/暗两套）。

### 3. 底板（plate）机制 —— 一个容易踩的坑
打包类应用必须提供 `AppList.targetsize-*_altform-unplated.png`（暗色主题）与 `_altform-lightunplated.png`（亮色主题）：

> "If you do not include the targetsize-*-altform-unplated assets above your icon will scale to a smaller size and will get an **undesirable backplate behind the icon** on Taskbar and Start."

也就是**不提供 unplated 资源，Windows 会自己给你的图标垫一块底板**，并且图标被缩小。三种主题变体（默认/亮/暗）即使图一样也必须各自提供文件。

### 4. Fluent 2 的图标集合与授权
- 三套：**system**（UI 内部用）、**product launch**（微软自家 app 的启动图标）、**file type**。
- **System icons 是 MIT 许可**，可以合法使用。
- `product launch icons` 代表微软自家应用，"**Never change the color of product launch icons**"——不是给第三方用的素材。
- System icons 两个主题：Regular（寻路/识别可用动作）与 Filled（选中态、小尺寸需要更大重量）。
- 加修饰符（modifier）时：**必须用 filled 主题，且固定在右下角**。
- 系统图标要加色就**只加一种颜色**；"Adding color to an icon may disrupt its visual balance"。
- 命名按**形状/物体**而非功能（举例：叫 *Shield*，不叫 *security*）。
- 缩放：小于 48px 要**简化细节**；大于 48px 用全保真并**按 4 的倍数**缩放（48/64/96…）；要用具体尺寸而不是无脑缩放。

---

## 三、必须区分开：这些是 **UI 控件**规范，不是图标规范

我第一轮把这些当成了图标规范，是错的。它们管的是窗口、控件、弹出层：

| 项 | 官方值 | 适用范围 |
|---|---|---|
| 圆角 | 顶层容器（窗口/浮出/对话框）**8px**；页内控件（Button/ListView…）**4px**；条状元素 **4px** | UI 控件，**非图标** |
| 全局资源 | `ControlCornerRadius`=4、`OverlayCornerRadius`=8 | UI 控件 |
| 层叠 | 两层：base（菜单/命令/导航）+ content | app 布局 |
| Elevation | Window/Dialog 128、Flyout 32、Tooltip 16、Card 8、Control 2、Layer 1；**描边宽度一律 1** | UI 表面 |
| 材质 | **Mica**（不透明、随桌面壁纸着色、有激活/非激活态）、**Acrylic**（毛玻璃，仅用于 flyout/右键菜单这类瞬态表面）、**Smoke**（模态遮罩，恒为半透明黑） | 窗口/表面 |

**关键结论**：官方图标规范里**没有**"顶部柔光条 + 内沿 1px 高光 + 大圆角 tile"这一套。那是我从系统 App 的成品观感倒推的，不是微软的图标语言。

---

## 四、对照检查：我第一轮那 8 稿哪里违规

| 我的做法 | 官方规范 | 结论 |
|---|---|---|
| 圆角 232/1024（≈22.7%） | 外轮廓 **2px@48** ≈ 1024 上 42.7px | ❌ 我凭空编的，超标 5 倍以上 |
| 顶部柔光条 + 内沿高光 + 底部压暗 | 无此规范；且"多层透明度叠加要尽量少" | ❌ 系统成品观感，不是设计语言 |
| 三段 135° 对角渐变 | 渐变 **1~2 段**，默认 **120°** | ❌ 段数超了、角度不合 |
| 方案 G「S」字母 monogram | **图标里不要放字母/文字** | ❌ 直接违规 |
| 全部方案**零投影** | 分层靠**投影**区分，且以 48×48 为基准 | ❌ 缺了官方最主要的层次手段 |
| 整块渐变 tile 当默认 | **透明底优先**，镀板只是可以 | ⚠️ 方向偏了 |
| 没做对比度校验 | 至少一半面积在亮/暗主题过 **3.0:1** | ⚠️ 缺验收项 |
| 尺寸取 16/24/32/48/64/128/256 | 官方集合 16/20/24/30/32/36/40/48/60/64/72/80/96/256，最低 16/24/32/48/256 | ⚠️ 需按官方集合重取 |

---

## 五、按规范重做的硬约束（可直接当验收清单）

1. 在 **48×48 网格**上构图，缩放到 1024 出稿；剪影在 16px 可辨。
2. 形状圆角：外轮廓 **2px@48**、内轮廓 **1px@48**（即 1024 上的 42.7 / 21.3）。
3. **不用字母、不用文字**。
4. 隐喻 ≤2 个，且能不加标签就认出来。
5. 扁平分层 ≤3 层，层间用**投影**区分，阴影值以 48×48 为基准定义。
6. 渐变 ≤2 段、默认 120°；不用"柔光条/内沿高光"这类叠加。
7. **透明底**为默认方案（需要时可另出镀板版）。
8. 亮/暗背景下**各至少一半面积过 3.0:1** 对比度。
9. 交付尺寸：16/24/32/48/256 为必出，另按官方集合补 20/30/36/40/60/64/72/80/96。
10. Fluent **system icons（MIT）**可作字形基座；微软 product launch icons 不可改色、不可当作素材。

> 待补：官方文档里的**阴影具体数值**是以配图（Figma 模板/图片）给出的，纯文本抓不到，需要从官方设计工具包中取。
