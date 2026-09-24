# 终端迁移：kterm → xterm.js（WebView 承载）+ WebView2 宿主模式改造

> 背景与根因分析见 `terminal-bugs-investigation.md`；kterm 与上游 1.5.5 的差异审计见
> `kterm-tui-compat-audit.md`。本文档只讲**这次改了什么、怎么验、怎么退**。

## 一、改了什么

### 1. WebView2 宿主模式（A 方案）

`windows/runner/main.cpp` 在任何 WebView2 初始化之前设置：

```cpp
::SetEnvironmentVariableW(L"COREWEBVIEW2_FORCED_HOSTING_MODE",
                          L"COREWEBVIEW2_HOSTING_MODE_WINDOW_TO_VISUAL");
```

原因：插件把嵌入式 WebView 走的是 **Visual(composition) 宿主**
（`in_app_webview_manager.cpp` 里 `createInAppWebViewEnv(hwnd, true, ...)`），
按微软文档，Visual 宿主下"鼠标/触摸/触控笔等空间输入必须由宿主转发给 WebView2"，
插件于是用 `sendScroll()` 把 Flutter 的逻辑像素增量乘一个可调倍率合成为
`WHEEL_DELTA` 事件，单位与刻度都不对，滚轮手感因此不可控；键盘/IME 焦点问题
也在同一条路径上。改成 Window-to-Visual 后输入由系统直接投递给 WebView2，内容
仍输出到 Visual，现有纹理捕获路径不变。

**排障开关**：`set SSHIVE_WEBVIEW_HOSTING=default` 再启动 → 退回插件默认宿主，
此时旧的滚轮倍率设置重新生效（用于 A/B 对比）。

### 2. 终端引擎：kterm → xterm.js 6.0.0

| 文件 | 状态 | 说明 |
|---|---|---|
| `assets/xterm/*` | 新增 | xterm.js 6.0.0 + addon-fit/webgl/unicode11/web-links（离线，MIT） |
| `tool/fetch_xterm_assets.mjs` | 新增 | 资产拉取脚本（固定版本 + sha256 核对） |
| `lib/services/xterm_page.dart` | 新增 | 宿主页模板：内联资产、注入配置、JS↔Dart 桥 |
| `lib/services/terminal_manager.dart` | 重写内部 | 会话改为"搬字节 + 转发事件"，公开 API 不变 |
| `lib/ui/terminal_tabs_page.dart` | 改造 | `TerminalView`(kterm) → `InAppWebView`；新增"复制选区"按钮 |
| `pubspec.yaml` | 改动 | 移除 `kterm` 依赖与 `dependency_overrides`，注册 `assets/xterm/` |
| `third_party/kterm/` | **保留未删** | 已不在依赖图里（`flutter pub get` 已确认），确认新终端可用后再 `git rm -r` 即可 |

`flutter pub get` 已执行，kterm 及其传递依赖（kitty_protocol / zmodem_lbp /
image / petitparser / xml / archive / posix）已从依赖图移除；
`dart analyze lib test` 无告警；`flutter build windows --debug` 通过。

### 3. 桥协议（JS ↔ Dart）

**JS → Dart**（`window.flutter_inappwebview.callHandler`，参数按顺序成为 `List<dynamic>`）

| handler | 参数 | 作用 |
|---|---|---|
| `sshiveReady` | 1 | 页面与 `window.__sshive` 就绪，Dart 开始喂字节 |
| `sshiveInput` | String | 用户输入（含 IME 组合结果）→ 写回 SSH（UTF-8） |
| `sshiveResize` | cols, rows | fit 后的真实尺寸 → `resizeTerminal()` |
| `sshiveTitle` | String | OSC 0/2 标题 → 标签名 |
| `sshiveBell` | - | 响铃 |
| `sshiveCopy` | String | 选区文本 → 系统剪贴板 |
| `sshiveSelection` | String | 选区变化（缓存最近值） |
| `sshiveOpenUrl` | String | 点击超链接 → 系统浏览器 |
| `sshiveError` / `sshiveLog` | String | 诊断 |

**Dart → JS**（`evaluateJavascript`，`window.__sshive`）

| 方法 | 说明 |
|---|---|
| `writeB64(b64)` | 远端字节（原始流，xterm.js 自己流式解码 UTF-8） |
| `pasteB64(b64)` | 粘贴：交给 xterm.js 的 `paste()`，由它按 bracketed paste 模式决定是否包 `ESC[200~` |
| `focus()` / `fit()` / `clear()` / `reset()` / `scrollToBottom()` / `scrollLines(n)` / `selection()` | 常规控制 |

**为什么走 base64**：插件的方法通道只传字符串，base64 是唯一稳定、无转义风险的
字节载体（+33% 体积）。Dart 侧按 8KB/32KB 批量 flush，积压超过 512KB 时
`pause()` SSH 流做背压，低于 64KB 恢复。

**能力提升（相对 kterm 1.5.5）**
- **DEC mode 2026 同步输出**（xterm.js 6.0.0 新增）→ tmux/btop/fzf 不再撕裂
- **流式 UTF-8 解码在 JS 侧** → 坏字节不再让 Dart 侧严格 `utf8.decoder` 丢掉整块输出
- **PTY 尺寸由真实像素反推**（fit → `sshiveResize` → `window-change`），
  建 shell 时也带当前尺寸，修掉"远端恒为 80×24"
- **制表/宽字符**：unicode11 宽度表 + 显式 Consolas/Cascadia + 中文回退字族
- **DECSCUSR / IRM / OSC 8 / 超链接 / WebGL 渲染**

**功能损失（务必确认你是否在用）**
- ❌ **Kitty Graphics Protocol**（kterm 支持内联图片）
- ❌ **zmodem（sz/rz 文件传输）**（kterm 支持）
- ❌ 内建搜索（xterm.js 有 `addon-search`，本次未内置）
- ⚠️ 标签切换后**没有 API 能编程聚焦 WebView**（插件未暴露 `requestFocus`），
  可能需要点一下终端区域才能键盘输入；底部按键栏不受影响（直接写 SSH）

## 二、验证清单（按顺序做，每步都能单独定位问题）

前置：`flutter pub get` 已完成；产物在
`build\windows\x64\runner\Debug\sshive.exe`（或用 `flutter run -d windows`）。

1. **A 是否生效**：打开 Web 标签页滚一页 → 之前"每次进去幅度特别大"是否消失。
   若仍然异常 → 用 `SSHIVE_WEBVIEW_HOSTING=default` 对比一次，确认是宿主模式在起作用。
2. **终端出画面**：连服务器 → 打开终端 → 应看到横幅与提示符。
   看不到 → 看应用内日志里有没有 `xterm.js 页面就绪`（说明桥通了、是 SSH→JS 段的问题）。
3. **输入**：敲 `echo hi` 回车；再试中文输入法直接输入中文。
   不能输入 → 先用鼠标点一下终端区域（焦点），仍未解决见"功能损失"里的焦点说明。
4. **PTY 尺寸**：`stty size` 或 `echo $COLUMNS $LINES` → 应接近窗口实际列行数
   （不再是固定 `24 80`）。
5. **TUI**：`vim` / `htop` / `tmux` 打开 → 边框是否对齐、画面是否撕裂；
   可跑 `printf '\e[?2026h'; for i in 1 2 3; do echo $i; sleep 0.2; done; printf '\e[?2026l'`
   看是否原子刷新。
6. **宽字符对齐**：`ls` 一个含中文名的目录、`echo 中文test` → 光标位置是否与文字对齐。
7. **滚轮回看**：终端里滚回看缓冲（TUI 里开鼠标上报时滚轮应转给应用，不是回看）。
8. **复制粘贴**：选中文本 → Ctrl+Shift+C 或工具栏复制按钮；工具栏粘贴按钮 →
   在 `cat > /tmp/t` 里粘贴，应看到 bracketed paste 行为（`^[[200~`）。
9. **按键栏 / 清屏**：Ctrl+L 按钮、底部 Ctrl+C/Tab/方向键。
10. **多标签与联动**：开 3 个终端来回切；文件管理器"在此打开终端"应自动 `cd` 到该目录。

## 三、如果 A 不生效怎么办（回退与后续）

1. 先确认不是"设置里滚轮倍率残留"：退回默认宿主时，`WebScrollSettings` 的
   倍率重新生效，而当前默认值与本机手感不匹配（你的实测是"几十偏慢、80 偏大"）。
   最小改动是把倍率调到你觉得合适的位置即可，不必动代码。
2. 若宿主模式无法改（例如插件以后升级后 composition 路径变了），还有两条独立于
   宿主模式的做法：
   - **JS 侧滚动**：Flutter 拦下 `PointerSignal`，经桥调 `term.scrollLines(n)`，
     完全绕开 `WHEEL_DELTA` 语义（但会与 TUI 的鼠标上报冲突，需要按模式分流）；
   - **修 C++ 换算**：`in_app_webview.cpp` 的 `sendScroll()` 里按
     `scaleFactor_` 把逻辑像素换算成物理像素再除以"每格像素"得到格数，
     乘 120 后送入，并对单事件做 `clamp`（顺带消掉 `static_cast<short>` 溢出）。

## 四、已知未做的事

- 终端搜索（`addon-search` 未内置，需要时再加一个资产即可）
- Kitty Graphics / zmodem（见"功能损失"）
- 标签激活时的编程聚焦（依赖插件的焦点问题修复，或自建 HWND 宿主）
- `COLORTERM=truecolor` 未下发（需要服务器 `AcceptEnv` 允许，贸然下发会在
  不接受的服务器上抛 `SSHChannelRequestError` 直接把终端打断，故未做）
- `third_party/kterm` 目录尚未删除

## 五、Windows 黑屏根因与插件补丁（2026-09-18，已修复待验证）

### 现象

终端页面加载成功、桥也通了（`xterm.js 页面就绪`），但屏幕全黑、输入无反应。日志里出现
自相矛盾的两行：

```
[INFO] Terminal 终端 1: 写入 xterm 58 字节（第 1 批）      ← Dart 认为写成功
[INFO] Terminal 终端 1: [diag] {... "rxChunks":0,"rxBytes":0 ...}  ← JS 一次都没收到
```

`[diag]` 同时证明页面侧一切正常：`container=1266x514`、`cols=174`、`rows=29`、
`hasElement=true`、`core=ok`，`resize -> 284x51` 说明 fit 与 `sshiveResize` 也工作。
**唯一坏掉的是 Dart→JS 方向。**

### 根因

`third_party/flutter_inappwebview_windows` 的 `InAppWebView::evaluateJavascript()` 是把脚本
交给 **CDP `Runtime.evaluate`** 执行的（`in_app_webview.cpp`，`CallDevToolsProtocolMethod`）。
实测该调用会"成功返回"但脚本没有生效：CDP 只把失败记成 console message，Dart 侧既没有
异常也没有结果，于是**静默失效**。而插件把三条 Dart→JS 路径全部压在这一个原语上：

1. `InAppWebViewController.evaluateJavascript()`（我们搬字节用的就是它）
2. `callHandler` 的 Promise 回值（`evaluateJavascript(...resolve...)`）
3. `postWebMessage`（也是用 `evaluateJavascript` 派发 `message` 事件）

所以不是 xterm.js 的问题，也不是资产/尺寸/字体的问题——是宿主插件这一层。

### 修复

对 fork 打补丁：`evaluateJavascript()` 的**页面主世界**分支改用 WebView2 原生
`ICoreWebView2::ExecuteScript`（不经过 DevTools 协议），非 page 的 content world 仍走
原来的 CDP 隔离世界路径，行为不变。补丁位置与说明见 `pubspec.yaml` 的本地补丁清单。

### 同时加入的排查设施（保留）

- **eval 自检**：页面就绪后 Dart 执行 `1+1`，日志应出现
  `eval 自检返回 2（期望 2）`——这是"这条方向是否通"的一句话判据。
- **`onConsoleMessage` 接到 LogBus**：页面 JS 异常（含 CDP 抛错）不再无声无息。
- **页面自检快照 `[diag]`**：容器/视口尺寸、`cols/rows`、`rxChunks/rxBytes`、渲染器名。
- **WebGL 渲染器默认关闭**（`XtermPageConfig.webgl`）：先保证一定能出画面。
- **fit 兜底**：`document.fonts.ready` 后重排 + `cols/rows` 异常时退避重试 5 次。

### 验证方法

打开终端后，日志应同时出现：

1. `eval 自检返回 2（期望 2）`
2. `写入 xterm N 字节（第 M 批）`
3. `[diag] ... "rxChunks":1,"rxBytes":N ...`（rxBytes 与写入总量一致）

三行齐全 = Dart→JS 已通、字节已进 xterm.js。若只有 1、2 没有 3，说明补丁没生效
（检查部署目录里 `flutter_inappwebview_windows_plugin.dll` 的时间戳）。

## 六、日志与诊断设施升级（2026-09-18）

排查过程暴露了日志系统的短板：只有 800 条内存环形缓冲、没有级别/标签过滤、
不能导出、**也不记录跨语言调用的返回值**——于是"`1+1` 能跑但 `writeB64` 没跑"
这种问题无从下手。已升级：

### LogBus（`lib/services/log_bus.dart`）
- 新增 `LogLevel.trace` + `verbose`（"诊断模式"）：每批写入、每次 JS 调用返回值这类
  高频日志默认只计数不记录（`droppedTrace` 会提示"另有 N 条未记录"），打开后全量保留。
- 环形缓冲 800 → 4000 条；时间戳精确到毫秒（跨语言调用靠它对时序）。
- **合并刷新**：120ms 内的多条日志只触发一次 UI 重建，避免日志页拖慢主线程。
- `exportText()` / `environmentHeader()`：一键导出可粘贴文本，头部自动带上
  平台、Dart 版本、诊断模式状态、**WebView2 宿主模式**——贴日志给人排查时不再缺上下文。
- `tags`：供 UI 按标签过滤。

### 日志 Tab（`lib/ui/home_page.dart`）
级别过滤（全部/DEBUG+/INFO+/WARN+/ERROR）、标签过滤、诊断模式开关、
"复制当前过滤结果"、"保存到文件"（写到应用支持目录并回显路径）、
跟随最新/锁定切换、`筛选数/总数`计数。

### 终端探针（`xterm_page.dart` + `terminal_manager.dart`）
- **JS 侧所有入口都返回 `ok...` / `err:<原因>`**，Dart 侧的 `_evalJs()` 与每批写入
  **必定把返回值写进日志**。返回 `null`/空 = 脚本没有执行；`err:` = 执行时抛错。
  这是"到底跑没跑"的唯一判据，取代了原来那些空 `catch`。
- 新增 `ping(tag)` 端到端探针：必须能访问 `window.__sshive` 才可能返回 `ok`，
  比 `1+1` 更能区分"ExecuteScript 通了"与"页面对象可见"。
- `onConsoleMessage` 接到日志：页面 JS 异常（含插件内部 CDP 抛错）不再无声无息。

### 顺带修的疑点：推送要等文档 load
`sshiveReady` 在 `readyState=loading` 时发出，而 WebView2 在导航未完成时执行脚本
不可靠——日志里"第 1 批写入的 await 拖到 400ms 后才返回、脚本却没生效"就是征兆。
现在新增 `sshiveLoaded`（load 事件后发送），Dart 侧等它再开始推送，并有 2 秒超时兜底。

## 七、Dart→JS 通道重做（2026-09-18 深夜，黑屏真因）

升级后的日志一次就定位了问题：

```
[WARN] ping → (无返回，脚本可能未执行)  [window.__sshive.ping("ready")]
[INFO] [diag] ... "hasSshive":true ...      ← 页面自己看得见 __sshive
```

`1+1` 能返回、任何碰页面全局对象的脚本都返回不了 ⇒ **从 Dart 发起的脚本执行看不到
页面主世界的全局对象**。而插件把三条 Dart→JS 路径全压在 `evaluateJavascript` 上：

1. `InAppWebViewController.evaluateJavascript()`
2. `callHandler` 的 Promise 回值（内部用 `evaluateJavascript` 去 resolve）
3. `postWebMessage`（拼一段 JS 再用 `evaluateJavascript` 派发 message 事件）

所以三条全废。**修复思路：不再用"执行脚本"做数据通道。**

### 插件补丁（`third_party/flutter_inappwebview_windows`）
- `evaluateJavascript()` 页面主世界改用原生 `ICoreWebView2::ExecuteScript`。
- **`postWebMessage()` 改用原生 `ICoreWebView2::PostWebMessageAsJson`**：由 WebView2 直接
  把消息投递到文档，完全不经过脚本执行（数组缓冲类型仍走原路径）。

### 传输层重写（Dart ↔ JS）
- **Dart→JS**：`controller.postWebMessage(WebMessage(data: <JSON 信封>))`
  - `{"t":"d","v":"<base64 字节>"}` 终端输出
  - `{"t":"p","v":"<base64 文本>"}` 粘贴（交给 xterm.js 的 `paste()`）
  - `{"t":"c","v":"focus|fit|clear|reset|scrollBottom|ping|diag"}` 命令
  - JS 侧由 `window.chrome.webview.addEventListener('message', ...)` 接收并解析
- **JS→Dart**：仍用 `callHandler`（这条方向一直可用），每个入口返回 `ok.../err:...`
- **结构化确认**：每批数据 JS 回 `sshiveAck(chunk, bytes, total)`；Dart 侧分开统计
  "已投递批次"与"JS 已确认批次"，3 秒内没收到任何确认就直接给出结论：
  `已投递 N 批但 JS 一次未确认（web message 通道可能不通）`
- 终端路径里**不再有任何 `evaluateJavascript` 调用**；复制改用 JS 在
  `onSelectionChange` 时推上来的选区文本，不再向 JS 索取。

### 判据（新版日志）
| 日志 | 含义 |
|---|---|
| `[diag] ... "webMessage":"ok"` | 页面能看到 WebView2 消息通道 |
| `[diag] pong {...}` | Dart→JS→Dart 整条环路通 |
| `已投递 xterm N 字节（第 1 批），等待 JS 确认` | Dart 已发出 |
| `JS 已确认第 1 批（本批 58 字节，累计 58）` | **数据真的进了 xterm.js** |
| `已投递 N 批但 JS 一次未确认` | 通道仍不通，问题在插件/宿主层 |

## 八、焦点模型（2026-09-19）

### 问题
在终端页做任何 Flutter 侧操作（工具栏按钮、底部按键栏、标签切换、关闭对话框）
之后，终端就收不到键盘输入了。原因：**插件里没有任何 `MoveFocus` 调用**，
键盘焦点必须在 WebView2 的输入窗口上；点终端区域能用，是因为点击被转发给
WebView2、由它自己抢焦点；而点 Flutter 按钮会把 Win32 焦点交给 Flutter 窗口，
页面再也拿不回来（页面里 `term.focus()` 只能改 DOM 焦点，无法把窗口焦点要回来）。

### 修法
1. **插件补丁**：JS 桥新增保留名 `__focus`——由**收到该消息的那个 WebView 实例**
   执行 `ICoreWebView2Controller::MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC)`。
   放在 `InAppWebView::onCallJsHandler()` 里，所以不需要任何 id 分发，天然"谁请求谁获焦"。
2. **JS**：`requestNativeFocus()`（`callHandler('__focus')`）+ `focus` 命令同时设置
   DOM 焦点；新增 `blur` 命令（`term.blur()`）。
3. **Dart/UI**：
   - 终端页所有 Flutter 交互控件（工具栏、按键栏、标签条）用
     `Focus(canRequestFocus: false, descendantsAreFocusable: false)` 包裹，点击不夺焦；
   - 每次交互后 post-frame 调 `focusTerminal()`（双保险，覆盖对话框等场景）；
   - 切换终端标签 → 重新聚焦并 refit；
   - **离开终端页**（HomePage 的 Tab 变化）→ `blurTerminal()` + Flutter `unfocus()`；
     回到终端页 → 自动聚焦。

### 期望行为
- 终端页内任何操作（含点按钮、切终端标签、开关对话框）后，**直接打字即可**，无需再点终端。
- 只有离开终端页（切到服务器/隧道/网页/文件/日志）时终端才让出键盘焦点。

## 九、滚轮刻度与系统设置（2026-09-19，网页仍偏大的真因）

### 现象
终端滚轮手感正常，**网页仍然滚得太多**——而两者走同一份宿主事件、同一个倍率。

### 真因：换算里硬编码了"一格 = 100 物理 px"
Flutter 引擎把一格滚轮换算成的像素量与系统设置联动：

```
每格物理像素 = WheelScrollLines × 100 / 3        （Windows 默认 3 行 → 100 px）
```

本机注册表实测 `HKCU\Control Panel\Desktop\WheelScrollLines = 6` → **引擎每格给 200 px**，
而换算里写死了除以 100，于是**每次滚轮都发了两格的量**（`mouseData = 240` 而非 120）。

为什么只有网页明显：
- 网页（Chromium）把两格如实换算成像素并做平滑滚动 → 一眼看出"多滚一倍"；
- xterm.js 把同一事件换算成**行**并累积进回看缓冲，2× 的偏差在这里恰好读作"手感正常"。

### 修法（已部署）
宿主换算改为读同一个系统设置：

```cpp
UINT lines = 3;
::SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
pxPerNotch = lines * (100.0 / 3.0);   // 与 Flutter 引擎同源
```

于是"一格进 → 一格出"对任何设置都成立（3 行/6 行/10 行都对；`0 = 一次滚一屏`
按默认 3 行处理）。该值首次滚动时读一次（Flutter 引擎同样只在启动时读），
改系统设置后需重启应用。

### 预期与后续
- 网页：与原生浏览器一致（本机 6 行/格）。
- 终端：量减半（此前确实收到 2 格）。若嫌慢，用设置里的倍率调（1 = 标准，最大 4）；
  若两者手感需求长期不同，下一步把"网页倍率"与"终端倍率"拆成两个独立设置。

## 十、滚轮倍率拆分：网页 / 终端各一套（2026-09-19，已完成）

### 目标
网页与终端手感需求不同（同一个格数在 Chromium 里是"像素+平滑滚动"，在 xterm.js 里
是"行"），因此给它们各自一个倍率，并且**改完对已打开的视图立即生效**。

### 实现
1. **插件 fork 新增每视图方法**：
   - C++：每视图 channel 新增 `setScrollMultiplier`（调用已有的
     `InAppWebView::setScrollMultiplier`）；
   - Dart：`WindowsInAppWebViewController.setScrollMultiplier(int)`。
   顶层静态通道的 `setMultiplierAll` 保留但 app 不再使用（它会把所有视图一起改，
   正是"分不开"的原因）。
2. **`WebScrollSettings` 持有两个值**：
   - `webMultiplier` 默认 **1**（= 原生浏览器手感）；
   - `terminalMultiplier` 默认 **2**（= 修好刻度前那个"用起来没问题"的终端量）；
   - 各自持久化（终端用新键 `sshagent_terminal_scroll_multiplier`）；
     旧量纲（≥8）与越界值自动迁移到默认值。
3. **三个创建点各取自己的值**：终端 → `terminalMultiplier`；
   网页标签 / Markdown 预览 → `webMultiplier`。
4. **设置对话框拆成两个滑杆**（主页设置菜单 →「滚轮倍率（网页/终端）…」），
   点"应用"后通过每视图通道对**已打开**的网页标签与终端立即生效，无需重开。
   失败只记 DEBUG 日志，不影响功能（新开的视图仍会带上正确值）。
