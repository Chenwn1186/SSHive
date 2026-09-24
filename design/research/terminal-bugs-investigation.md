# SSHive 终端问题调研报告

> 调研对象：`lib/services/terminal_manager.dart`、`lib/services/ssh_session.dart`、`lib/ui/terminal_tabs_page.dart`、
> `third_party/kterm`（fork），以及**你自己机器上真实运行留下的调试日志**。
> 结论级别标注：`【已证实】`= 有日志/字节/上游源码证据；`【高置信】`= 代码路径可推导；`【待验证】`= 需要你确认一句。

---

## 0. 结论速览（按修复价值排序）

| # | 结论 | 级别 | 影响 |
|---|---|---|---|
| **A** | Windows 上**无修饰键的字母/中文根本到不了 App**：中文 IME 吞掉按键，而 Flutter 的 TextInput(IME) 通道在本机**全程 0 次回调**，组合结果直接蒸发。你实际是靠 `Ctrl+V` 粘贴在用终端。 | 【已证实】 | "输入命令"这件事本身是坏的 |
| **B** | **Enter 键没问题**：实测发出的是 `0x0D`(CR)，正常。所以"回车不换行"不该怪 Enter。 | 【已证实】 | 排除一个错误方向 |
| **C** | kterm 1.5.5 的 `Terminal.write` 快速路径**会在解析器持有"半截转义序列"时把后续文本直接写进缓冲区** → 解析器失步 → 远端重绘/光标模型错乱。上游 1.5.8 已修（"desyncing the shell's cursor model, wrecking prompt redraws"）。 | 【已证实】 | "字符跑到别的行/同一行"的头号嫌疑 + TUI 花屏 |
| **D** | **PTY 尺寸从头到尾没同步**：开 shell 时硬编码 `80×24`，而首次 layout 的 resize 因为 `_sshSession == null` 被丢弃，之后再也不会补发 → 远端一直以为终端是 80×24。 | 【高置信】 | TUI 画在 80×24、换行/回显错位 |
| **E** | kterm 1.5.5 缺一批 TUI 依赖的特性：`?2026` 同步输出、DECSCUSR 光标形状、IRM 插入模式（空实现）、SGR 22 只清 faint、ED/EL 不遵守滚动区、Kitty KeyUp 未门控（1.5.6 已修）等。 | 【已证实】 | "对 CLI UI 支持很垃圾" |
| **F** | 应用层：终端输出用**严格 UTF-8** 解码（一个坏字节丢掉整块输出）、没设 `LANG`/`COLORTERM`、kterm 的 `onTitleChange/onBell/OSC52` 等回调**一个都没接**。 | 【高置信】 | 中文乱码、复制/标题/响铃失效 |

---

## 1. 证据来源

| 来源 | 内容 |
|---|---|
| `C:\Users\Administrator\AppData\Local\Temp\ssh_agent_term.log` | **你自己的运行日志**（47367 字节，2026-09-08 ~ 09-15，最后一笔 09-15 19:32）。由 `lib/services/term_debug.dart` 与 kterm 的 `_debugLog()` 写入，覆盖了每次按键、每次 `onOutput`、每次 TextInput 连接 |
| `pub.dev` 官方 `kterm 1.5.5` 源码 | 与 fork 逐文件对比：**fork 只改了 2 个文件**（`terminal_view.dart`、`custom_text_edit.dart`），`parser/buffer/render/painter/terminal/reflow` 全是官方原版；另对比了 1.5.6/1.5.7/1.5.8 的 CHANGELOG |
| `design/research/kterm-tui-compat-audit.md` | kterm 转义序列/模式支持矩阵（78 项，逐条 path:line 证据），本次调研的附录 |
| 字节级日志分析 | 把日志里每条 `[onOutput]` 的原始字节 dump 出来核对（见 §2.1） |

> ⚠️ **本机 Flutter/Dart 工具链在我的沙箱里完全卡死**（`flutter test` 10 分钟无输出、`dart --version` 45 秒超时），所以我**没有跑起来实测**，也没有跑成 `test/terminal_core_probe_test.dart`。所有结论均来自代码路径 + 你的真实日志。

---

## 2. 输入链路：为什么"敲命令"本身就不工作 【已证实】

### 2.1 日志铁证

统计整个日志（跨 4 次运行会话）：

| 计数项 | 次数 | 含义 |
|---|---|---|
| `updateEditingValue` | **0** | Flutter 的 TextInput/IME 通道**从未回调过一次** |
| `_onInsert`（IME 文本插入） | **0** | 经由 IME 的文本一个字都没进来 |
| `PATCH textInput` | 2 | fork 打的补丁只在 2 次击键上生效（都是字符 `1`） |
| `_openInputConnection ATTACHED` | 23 | 连接倒是每次都建了（补丁起作用了） |

日志里出现过的**全部**按键（`logical` / `char`）：

```
KeyDownEvent Enter        char=null   ×12
KeyDownEvent Arrow Up/Down char=null  ×17
KeyDownEvent Backspace    char=null   ×5
KeyDownEvent Control Left char=null   ×8
KeyDownEvent V            char=null   ×4   ← 带 Ctrl（Ctrl+V）
KeyDownEvent C            char=null   ×2   ← 带 Ctrl（Ctrl+C）
KeyDownEvent 1            char="1"    ×2   ← 唯一的"能打字"的证据
```

**结论：整个日志里没有任何一个"无修饰键的字母"按键事件。** 而 `Ctrl+字母` 是有的。
这正是中文输入法的指纹：**无修饰键的字母被 IME 抓去做拼音组合**（因此 Flutter 连 `KeyDownEvent` 都收不到，日志里干脆没有），而 `Ctrl+字母` 绕过 IME 直达应用。数字不触发组合，所以 `1` 能过。

字节级核对（`[onOutput]` 的实际 payload）：

```
1B 5B 41 / 1B 5B 42   → 方向键 ESC[A / ESC[B]
31                    → "1"
7F                    → 退格 (DEL，正确)
0D                    → Enter (CR，正确 ✅)
03                    → Ctrl+C
1B 5B 32 30 30 7E ... → Ctrl+V 粘贴走了 bracketed paste: ESC[200~
```

也就是说：**你在终端里几乎没有"打"过字，全都是粘贴进去的**（日志里两条 `echo 'ssh-ed25519 ...'`、`dsh plugin --profile web add dshmarket` 都是 `ESC[200~` 包起来的）。

### 2.2 机制

```
中文 IME(微软拼音) ──吞掉──> 字母 KeyDown（Flutter 收不到）
        └─ 组合结果本应走 TextInput 通道 ──> updateEditingValue()
                                             ↑
                                     本机 0 次回调（通道失效）
                                             ↓
                                       文字彻底丢失
```

`third_party/kterm/lib/src/terminal_view.dart:700-715` 的补丁想绕过这条死通道（用 `event.character` 补发），但它**只能救那些"到达 Flutter 且带字符"的按键**——字母连事件都没有，补丁无从下手。

### 2.3 相关代码

| 位置 | 说明 |
|---|---|
| `third_party/kterm/lib/src/ui/custom_text_edit.dart:179-183`、`:160-162` | 丢掉上游的 keyboard-token 仲裁，改成"只要有焦点就建连接、每次按键还补建一次"，并注释说"字母数字按键全部丢失" |
| `third_party/kterm/lib/src/terminal_view.dart:700-715` | 字符补丁；注释说"TextInput 通道整体失效"——**这两个补丁的假设互相矛盾**（一个说通道死了所以绕开，一个说把它强行拉活）。一旦哪天 Flutter 把 `updateEditingValue` 修好，同一次击键会被**发送两次**（补丁发一遍 + `_onInsert` 再发一遍） |
| `third_party/kterm/lib/src/terminal.dart:429-432` | `textInput()` 只调 `onOutput`，**不写本地缓冲区** → 没有本地回显/预测；键丢了屏幕上就什么都没有，无法自证 |

### 2.4 立刻可验证 / 可用的两条路

1. **一分钟验证**：把 Windows 输入法切到英文（或关掉微软拼音）再敲 `ls`。如果字母能出来了 → 机制 100% 确认。
2. **正确的修法**（而不是继续往 kterm 里打补丁）：桌面端把 `TerminalView(hardwareKeyboardOnly: true)`。
   此时 kterm **不建立 TextInput 连接**，Windows IME 不会接管键盘，字母以普通 `KeyEvent` 到达；
   `third_party/kterm/lib/src/ui/keyboard_listener.dart:26-38` 的 `CustomKeyboardListener` 本来就实现了"把 `event.character` 当输入插入"的逻辑（和那个补丁等价，但走的是正确的路径）。
   移动端保持 `false`（软键盘需要 IME），建议按平台区分：`hardwareKeyboardOnly: !isDesktop`。

> 附带一个隐私/性能问题：`lib/services/term_debug.dart` + kterm 的 `_debugLog()` 在**每次按键、每次输入**都同步 `writeAsStringSync` 写 `%TEMP%\ssh_agent_term.log`。你敲进 `sudo`/`ssh` 的密码会明文落在这个文件里，而且是在 UI 线程上做同步文件 IO。查完这轮建议关掉。

---

## 3. "回车后新字符还显示在同一行"：三个候选机制

先排除最容易误判的：**Enter 发出的确实是 `0x0D`**（§2.1 字节证据），kterm 内核的 `CR` = 光标回列 0、`LF` = 下移一行（`buffer.dart:308-313`、`terminal.dart:565-567`）逻辑也是对的。所以问题不在"Enter 送错了"。

### H1（首选，已证实代码存在）：解析器失步 —— fork 停在 1.5.5，缺 1.5.8 的关键修复

`third_party/kterm/lib/src/terminal.dart:310-333`：

```dart
void write(String data) {
  if (!data.contains('\x1b') && !_hasC0Control(data)) {
    _buffer.write(data);          // ← 直接当普通文本写进缓冲区
    _scheduleNotify();
    return;
  }
  _parser.write(data);            // ← 解析器（状态跨 chunk 保留）
}
```

SSH 数据是一包一包到的，转义序列**会被拆包**。如果上一包结尾是 `...\x1b[3`，下一包是 `1mHello`（不含 ESC、不含 C0），就走进快速路径：`1mHello` 被当成**普通文字打印**，而解析器仍停在 CSI 中间等待后续 → **整个重绘流从此错位**：后面的光标定位/清行序列被当文字打出来，远端（readline、TUI）的"光标模型"和屏幕真实状态永久分叉。

- 上游 **1.5.8** 的 CHANGELOG 原文就是修这个：*"Split escape sequences no longer leak as text"*，并且明确写了后果 *"desyncing the shell's cursor model, wrecking prompt redraws"*。
- fork 里 `hasPending` 这个保护**完全没有**（`grep hasPending` = 0 命中）。
- 触发概率：TUI 场景下转义字节占比很高，包边界落在序列中间是常态，不是偶发。

→ 这正好同时解释"新字符被画到上一行/同一行"和"TUI 一渲染就烂"。

### H2（高置信，一分钟可证伪）：远端 PTY 一直是 80×24，而屏幕早就是 120+ 列

- `lib/services/terminal_manager.dart:87`：`ssh.shell(cols: 80, rows: 24)` —— **硬编码**。
- `lib/services/terminal_manager.dart:44`：`onResize: (w,h,pw,ph) => _sshSession?.resizeTerminal(...)`。
  而 `open()` 是先 `notifyListeners()`（下一帧就 layout → 触发首次 resize），**之后**才 `await session.connect()`。
  首次 resize 发生在 `_sshSession == null` 时 → **被静默丢弃**。
- kterm 只在**尺寸变化**时才通知（`third_party/kterm/lib/src/ui/render.dart:342-368` 的 `_viewportSize != viewportSize` 判断），所以除非你手动缩放窗口，**这个尺寸永远不会补发**。
- 结果：远端 shell/readline/vim/htop/tmux 全都按 80×24 计算换行与重绘，而 App 按真实宽度绘制。

**证伪方法（1 分钟）**：打开终端后，**手动拖一下窗口大小**（触发一次 window-change）再看是否恢复正常。如果好了 → 就是它。
**修法（3 行）**：`connect()` 里 `_sshSession = s;` 之后立刻 `s.resizeTerminal(terminal.viewWidth, terminal.viewHeight)`，并把初始 `cols/rows` 用当前值。

### H3（中等）：Kitty 键盘协议的 KeyUp 未门控（fork 缺 1.5.6 修复）

`third_party/kterm/lib/src/terminal_view.dart:565-577`：Kitty 模式开启时，**只要按着修饰键，松开任何键都会往远端发 CSI-u 序列**。上游 1.5.6 修的就是这个，CHANGELOG 写的后果是 *"cursor jumping in the remote shell"*。
你的日志里 `Ctrl` 按下/松开反复出现，而你最近跑的正是 `dsh`（这类现代 CLI 会开启 Kitty 协议 / `?2026` 同步输出）。一个"凭空多出来的按键"足以让它的输入行重绘错位。
**证伪**：给 `kittyMode` 加一行日志（或临时把 Kitty 分支短路），看现象是否消失。

---

## 4. "对 CLI UI 的支持很垃圾"的其他原因

完整矩阵见 `design/research/kterm-tui-compat-audit.md`（78 项，逐条 path:line）。挑对 TUI 影响最大的：

| 缺失项 | 证据 | 后果 |
|---|---|---|
| **`?2026` 同步输出**（完全没实现） | `parser.dart` 里 `2026`/`synchroniz` 零命中，落到 `setUnknownDecMode` 空实现 | tmux / btop / fzf / dsh 类 UI 每帧撕裂、画面抖 |
| **IRM 插入模式是死变量** | `parser.dart:1058-1059` → `terminal.dart:805-807`；`buffer.dart:157` 永远覆盖写 | `CSI 4h` 下插入字符直接覆盖后面的内容 |
| **SGR `;` 与 `:` 被压平** | `parser.dart:307-313` + `case 4` 贪婪（`parser.dart:491-501`） | `ESC[4;31m` 变成"波浪下划线"，红色丢了 |
| **SGR 22 只清 faint，不清 bold** | `parser.dart:522-524` | 提示符/高亮样式残留 |
| **ED/EL 不遵守 DECSTBM** | `buffer.dart:189-239`（但 SU/SD 是对的） | 分屏类 UI 清屏范围错 |
| **没有 DECSCUSR（`CSI Ps SP q`）** | `parser.dart:338-368` 无 `q`；App 还硬编码 `TerminalCursorType.block`（`lib/ui/terminal_tabs_page.dart:304`） | 光标形状永远是方块，vim/插入模式无法切换 |
| **没有 RIS `ESC c` / DECALN**；`ESC[3g` 是单向陷阱 | `parser.dart:106-107`；`tabs.dart:52-67` | 程序"复位终端"后制表位再也不恢复 |
| **组合字符被丢弃**（不是叠加） | `buffer.dart:137-140` | 拼音声调、emoji 变体、泰米尔语等会掉字符 |
| **`?1004` 焦点上报只存不发**；OSC 52/133/标题从未接通 | `grep reportFocusMode` 只有存取；App 侧 `onTitleChange/onBell/onClipboardWrite` **0 处使用** | 复制到系统剪贴板、标题、shell 集成全废 |
| **TERM 声明过头** | `lib/services/ssh_session.dart:228-236` 写死 `xterm-256color`，但上面这些它并不支持；DA1 还回 `ESC[?1;2c` | 程序按 xterm 能力发序列 → 踩空 |

### 应用层另外三处

1. **严格 UTF-8 解码会整块吞输出**：`lib/services/terminal_manager.dart:91-110` 用 `utf8.decoder`（`allowMalformed: false`）。远端一旦吐出一个非 UTF-8 字节（服务器 locale 没设，`ls` 出 GBK 文件名很常见），该 chunk 抛 `FormatException` → 这一包剩下的内容全部丢失。应改 `utf8.decoder` 的宽松模式或自建解码器（仓库里 `lib/services/text_decoder.dart` 已有 UTF-8/GBK 智能解码，终端链路没用上）。
2. **没有设 `LANG`/`COLORTERM`**：`ssh_client.dart:513-532` 的 `shell(environment: ...)` 支持传环境变量，App 一个都没传（`lib/services/ssh_session.dart:218-237`）。远端没有 `LANG` → 中文输出乱码（你日志里粘贴的中文注释就是 UTF-8/GBK 混乱的现场）；没有 `COLORTERM=truecolor` → 程序退回 256 色。
3. **初始 pixelWidth/Height 写死 800×600**（`ssh_session.dart:221-222`），少数按像素排版的应用会算错。

---

## 5. 建议的修复顺序

| 优先级 | 动作 | 落点 |
|---|---|---|
| **P0** | shell 建好后立刻同步真实尺寸（并把初始 cols/rows 传真实值） | `lib/services/terminal_manager.dart:84-135` |
| **P0** | 桌面端 `hardwareKeyboardOnly: true`，让字母键绕过失效的 IME 通道真正到达 | `lib/ui/terminal_tabs_page.dart:299-318` |
| **P1** | kterm 升到 1.5.8（或至少把 `_parser.hasPending` 门控 + 1.5.6 的 KeyUp 门控 + RIS/HTS 修复挑回来） | `third_party/kterm` |
| **P1** | 补 `?2026` 同步输出（在 `Terminal._scheduleNotify` 里按模式门控） | `third_party/kterm/lib/src/terminal.dart:298-305` |
| **P2** | 终端输出改宽松解码，别再整块丢 | `lib/services/terminal_manager.dart:91-110` |
| **P2** | 传 `LANG`/`LC_ALL`/`COLORTERM=truecolor`/`TERM_PROGRAM` | `lib/services/ssh_session.dart:228-236` |
| **P2** | 接上 `onTitleChange`（标签页标题）、`onBell`、OSC 52（复制到系统剪贴板） | `lib/services/terminal_manager.dart:35-45` |
| **P3** | SGR 22/`4:n`、IRM、ED/EL 视界、DECSCUSR | kterm 核心 |
| **P3** | 关掉/收窄 `%TEMP%\ssh_agent_term.log`（含密码、UI 线程同步 IO） | `lib/services/term_debug.dart`、kterm `_debugLog` |

---

## 6. 我需要你确认的一点 / 我没做到的

- **待确认**：按回车后，具体是"**提示符没换行，新内容接着上一行**"，还是"**换行了，但新出现的字符位置错乱/叠在旧字上**"？
  前者指向 H1/H2，后者更指向 H1 的渲染错位。有张截图最好。
- **我做不了的**：本沙箱里 `flutter test` / `dart --version` 全部超时（工具链卡死），所以：
  - `test/terminal_core_probe_test.dart`（我写的内核探针，覆盖 CR/LF、环绕、宽字符、备用屏、DSR、reflow 等 12 个场景）**没能跑起来**，你在本机 `flutter test test/terminal_core_probe_test.dart` 一跑就知道"内核状态机是否干净"——如果它是干净的，那 H1/H2 的锅就全在 UI/连接层。
  - 也因此我无法实测 `KeyEvent.character` 对 Enter 的取值（不过字节证据已经证明 Enter 发的是 CR）。
