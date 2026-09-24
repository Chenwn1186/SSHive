# kterm TUI Compatibility Audit — SSHive terminal engine

Scope: `third_party/kterm` (vendored fork, CHANGELOG latest `1.5.5 - 2026-08-06`) + app PTY layer.
Method: read all listed core files; every claim below is a `path:line` citation with the dispatch code quoted.
No file in the repo was modified by this audit.

Reference points: `handler.dart` is only the interface; the real implementation is `Terminal`
(`third_party/kterm/lib/src/terminal.dart`) and the dispatch tables are in
`third_party/kterm/lib/src/core/escape/parser.dart`.

---

## 1. Compatibility matrix

| # | Feature | Status | Evidence |
|---|---|---|---|
| 1 | Alt screen `?1049h/l` | ✅ supported | `parser.dart:1144-1152` `case 1049: if (enabled) { handler.saveCursor(); handler.clearAltBuffer(); handler.useAltBuffer(); } else { handler.useMainBuffer(); }` |
| 2 | Alt screen `?47h/l` | ✅ supported (no clear/save) | `parser.dart:1090-1095`; `terminal.dart:867-874` |
| 3 | Alt screen `?1047h/l` | ✅ supported (clears alt on exit) | `parser.dart:1130-1137` |
| 4 | Alt screen `?1048h/l` (cursor save/restore) | ✅ supported | `parser.dart:1138-1143` |
| 5 | Alt-screen exit restores cursor | ✅ supported via `?1049l` pair (`?1049h` saved it) | `parser.dart:1144-1151`; `buffer.dart:377-395`. ⚠️ `useMainBuffer()`/`useAltBuffer()` themselves never save/restore — an app using bare `?47h`+`?1049l` mixes them (`terminal.dart:867-874`) |
| 6 | Alt screen reflow on resize | ❌ missing (by design) | `buffer.dart:531` `if (terminal.reflowEnabled && !isAltBuffer)` — alt buffer takes the truncate path `buffer.dart:545` |
| 7 | `CSI s` / `CSI u` (SCOSC/SCORC) | ❌ missing — dropped entirely | grep `'s'.codeUnitAt|'u'.codeUnitAt` in `parser.dart` → only `u` appears at `parser.dart:218` for Kitty `CSI > u`; `_csiHandlers` (`parser.dart:338-368`) has no `s`/`u` entry → `unknownCSI` no-op (`terminal.dart:798`) |
| 8 | `ESC 7` / `ESC 8` (DECSC/DECRC) | ✅ supported | `parser.dart:96-101,122-133`; `buffer.dart:377-395` |
| 9 | DECSC covers attributes + charset | ✅ supported | `buffer.dart:380-382` (`_savedCursorStyle = cursor.copy()`, `charset.save()`) |
| 10 | DECSC covers origin mode | ❌ missing | `buffer.dart:377-383` saves only x/y/style/charset; `terminal.dart:837-839` (`_originMode`) is never saved |
| 11 | DECSTBM `CSI r` | ✅ supported | `parser.dart:349,751-766`; `terminal.dart:706-708`; `buffer.dart:399-405` |
| 12 | DECSTBM homes the cursor | ❌ missing | `parser.dart:765` calls only `handler.setMargins(top-1, bottom)`; `terminal.dart:706-708` does not touch the cursor (xterm homes to origin) |
| 13 | DECOM `?6h/l` | ✅ supported | `parser.dart:1077-1078`; `terminal.dart:836-839`; applied in `buffer.dart:356-366` |
| 14 | LF/IND respect bottom margin | ✅ supported | `buffer.dart:278-304` (`index()`), `buffer.dart:308-313` (`lineFeed()`) |
| 15 | RI (ESC M) respects top margin | ✅ supported | `buffer.dart:316-326` |
| 16 | IL/DL respect margins | ✅ supported | `buffer.dart:448-473`, `buffer.dart:478-497` (both bail on `!isInVerticalMargin`) |
| 17 | ED/EL respect margins | ❌ missing | `buffer.dart:189-218` erases `0 .. viewHeight` unconditionally; `buffer.dart:222-239` uses `viewWidth`/`0` as bounds |
| 18 | ICH `CSI @` | ✅ supported | `parser.dart:367,1046-1054`; `buffer.dart:442-444` |
| 19 | DCH `CSI P` | ✅ supported | `parser.dart:363,990-998`; `buffer.dart:418-422` |
| 20 | IL `CSI L` / DL `CSI M` | ✅ supported | `parser.dart:361-362,964-985` |
| 21 | ECH `CSI X` | ✅ supported | `parser.dart:366,1029-1037`; `buffer.dart:242-245` |
| 22 | IRM insert mode `CSI 4h/l` | ⚠️ stored only, **never applied** | stored `parser.dart:1058-1059` → `terminal.dart:805-807` `_insertMode = enabled`. grep `insertMode` across `lib/` returns only the setter/getter (`terminal.dart:149,230,805`), `state.dart:15`, `handler.dart:180`, `debugger.dart:351`. `buffer.dart:121-167` (`writeChar`) never consults it → chars overwrite, no cell insert |
| 23 | ED `CSI J` 0/1/2/3 | ✅ supported | `parser.dart:922-939`; `terminal.dart:722-740` (`3` → `clearScrollback`, `buffer.dart:425-431`) |
| 24 | EL `CSI K` 0/1/2 | ✅ supported | `parser.dart:944-959` |
| 25 | Selective erase DECSEL/DECSED (`CSI ?K`/`?J`) | ❌ missing | grep `selective|Selective|DECSEL|DECSED` in `lib/` → **no matches**. `_csiHandleEraseDisplay` (`parser.dart:922`) / `_csiHandleEraseLine` (`parser.dart:944`) ignore `_csi.prefix`; verified `_csi.prefix` is only read at `parser.dart:218,388,451` |
| 26 | SGR 0-9 | ✅ supported (1,2,3,4,5,7,8,9) | `parser.dart:479-517` |
| 27 | SGR 21 (double underline / bold-off) | ⚠️ mapped to `unsetCursorBold()` | `parser.dart:519-521` — double-underline (`4:2`) exists but `21` = bold-off is incomplete |
| 28 | SGR 22-29 | ❌ **22 only clears faint** | `parser.dart:522-524` `case 22: handler.unsetCursorFaint();` — does not clear bold. `parser.dart:525-542` covers 23,24,25,27,28,29 |
| 29 | SGR 30-37 / 40-47 | ✅ supported | `parser.dart:544-567`, `596-619` |
| 30 | SGR 90-97 / 100-107 | ✅ supported | `parser.dart:677-725` |
| 31 | SGR 39 / 49 | ✅ supported | `parser.dart:592-594`, `644-646` |
| 32 | SGR `38;5;n` / `48;5;n` (256-color) | ✅ supported | `parser.dart:581-588`, `633-640` |
| 33 | SGR `38;2;r;g;b` / `48;2;r;g;b` (truecolor) | ✅ supported (semicolon form) | `parser.dart:572-580`, `624-632` |
| 34 | Colon sub-params `38:2::r:g:b` | ✅ works (tested by hand-trace) | `parser.dart:307-313` treats `:` and `;` identically; empty colons become `0` because `hasParam` stays true → `params=[38,2,0,r,g,b]`, read at `parser.dart:577-578`. ⚠️ **but the same flattening breaks `4;n`** — see gap #3 |
| 35 | SGR 4:1..4:5 underline styles | ⚠️ implemented, but eats the next SGR | `cursor.dart:63-73` (`CursorStyle.setUnderlineStyle`), `parser.dart:491-504`; `4;31` (underline+red, extremely common) is misread as "style 31" → no underline, no red |
| 36 | SGR 58 / 59 underline color | ✅ supported | `parser.dart:649-674` |
| 37 | Strikethrough 9 / inverse 7 / conceal 8 | ✅ supported | `parser.dart:508-517`; `cursor.dart:51-61`; painted `painter.dart:552` (inverse) |
| 38 | Blink 5/25 | ⚠️ attribute stored, never animated | `cursor.dart:47-49`, `parser.dart:505-507,531-533`; grep `CellFlags.blink` in `lib/src/ui/` → no painting/animation use |
| 39 | DECTCEM `?25h/l` | ✅ supported | `parser.dart:1088-1089`; `terminal.dart:861-864`; honoured at `render.dart:381-383` |
| 40 | DECAWM `?7h/l` | ✅ supported | `parser.dart:1079-1080`; `terminal.dart:846-849`; used `buffer.dart:146,152` |
| 41 | Bracketed paste `?2004h/l` | ✅ supported | `parser.dart:1153-1154`; `terminal.dart:902-904`; emit `terminal.dart:441-469` → `emitter.dart:26-28` |
| 42 | Mouse 1000/1002/1003 | ✅ supported | `parser.dart:1098-1113` |
| 43 | Mouse 1005 (UTF-8) / 1006 (SGR) / 1015 (urxvt) | ✅ supported | `parser.dart:1116-1129` (`MouseReportMode.utf/sgr/urxvt`) |
| 44 | Mouse 9 / 1001 / 1007 | ✅ supported | `parser.dart:1081-1084,1102-1105,1124-1125` |
| 45 | Focus reporting `?1004h/l` | ⚠️ stored only, **never emitted** | `parser.dart:1114-1115` → `terminal.dart:886-889` `_reportFocusMode = enabled`. grep `reportFocusMode` in `lib/` → only declaration/getter/setter + `debugger.dart`; no `\x1b[I` / `\x1b[O` emission anywhere |
| 46 | Synchronized output `?2026h/l` | ❌ missing | grep `2026|synchroniz` in `lib/` → no mode handling; falls to `parser.dart:1155-1156` `setUnknownDecMode` → `terminal.dart:1367-1370` no-op |
| 47 | LNM `?20h/l` | ✅ supported | `parser.dart:1060-1061`; `terminal.dart:809-812`; `buffer.dart:308-313` |
| 48 | App cursor keys `?1h/l` | ✅ supported | `parser.dart:1069-1070`; `terminal.dart:821-824`; consumed `input/handler.dart:128`-area |
| 49 | App keypad DECKPAM/DECKPNM (`ESC =`/`ESC >`) | ✅ supported | `parser.dart:115-116,200-211`; `terminal.dart:881-884` |
| 50 | `?12`/`?13` cursor blink | ✅ supported | `parser.dart:1085-1087`; `terminal.dart:856-859` |
| 51 | `?3` DECCOLM 132-col + clear | ❌ no-op | `parser.dart:1073-1074` → `terminal.dart:841-844` `// no-op` |
| 52 | Wide/CJK storage (2-cell) | ✅ supported | `buffer.dart:135,158-166` (`setCell(..., cellWidth, ...)` then `writeChar(0)` as the filler); `line.dart:147-157` `setCell` stores `char \| (width << widthShift)` |
| 53 | Wide char wrap at right margin | ✅ supported | `buffer.dart:142-155` (`if (cellWidth == 2 && _cursorX >= viewWidth - 1) { index(); setCursorX(0); ... isWrapped = true; }`) |
| 54 | Wide char at margin edge — half-cell cleanup | ✅ supported | `buffer.dart:143-148`; `line.dart:197-212` (`eraseRange` resets the partner cell); `reflow.dart:97-99`, `reflow.dart:123-125` |
| 55 | Combining (zero-width) marks | ⚠️ zero-width marks are **dropped**, not composed | `buffer.dart:137-140` `if (codePoint != 0 && cellWidth <= 0) { return; }` → `e + U+0301` renders as `e`. `unicode_v11.dart:502-509` `wcwidth` returns 0 for `BMP_COMBINING` (`unicode_v11.dart:5-221`) |
| 56 | U+200D ZWJ / emoji sequences | ❌ ZWJ given width 1 | grep `0x200D` in `lib/` → **no matches**; `unicode_v11.dart:464-476` `buildTable()` fills combining ranges (`:470-472`, incl. VS16 `0xFE00-0xFE0F` at `unicode_v11.dart:216`) then wide ranges — `0x200D` is in neither → `table[0x200D] == 1` → ZWJ is stored as a real 1-cell glyph, breaking emoji/ZWJ clusters |
| 57 | Reflow on resize (main buffer) | ✅ supported | `buffer.dart:530-543` → `reflow.dart:163-197`; `reflow.dart:177-187` follows `isWrapped` runs |
| 58 | Reflow keeps cursor on logical position | ❌ missing | `Terminal.resize` (`terminal.dart:496-520`) reflows both buffers then only clamps: `buffer.dart:526-527` `_cursorX = _cursorX.clamp(0, newWidth - 1)`. The pre- and post-reflow cursor anchors are never mapped (`reflow.dart` performs anchor reparenting only, `reflow.dart:34-36,127-131`) |
| 59 | OSC 0 / 2 title + icon | ⚠️ parsed, app never listens | `parser.dart:1177-1187`; `terminal.dart:1526-1534`; grep `onTitleChange` in `lib/` (app) → **no matches** |
| 60 | OSC 1 icon name | ⚠️ same as above | `parser.dart:1182-1184`; `terminal.dart:1531-1534` |
| 61 | OSC 8 hyperlinks | ✅ supported | `parser.dart:1188-1203`; `terminal.dart:1555-1598`; stored per cell `line.dart:134-140` |
| 62 | OSC 52 clipboard | ⚠️ parsed, app never wires callbacks | `parser.dart:1204-1215`; `terminal.dart:1600-1614`; grep `onClipboardWrite|onClipboardRead` in `lib/` (app) → **no matches** |
| 63 | OSC 4 / 10 / 11 (palette/color get-set) | ❌ missing | `parser.dart:1162-1258` switch has cases `0,1,2,8,52,10,133,30001,30101,99,777` only; `4`,`11` fall to `unknownOSC` (`parser.dart:1255`) → `terminal.dart:1714-1717` → app callback unset |
| 64 | OSC 10 as a *font-size* query | ⚠️ wrong semantics, hardcoded reply | `parser.dart:1216-1221`; `terminal.dart:1636-1643` replies `\x1b]10;12\x1b\\` |
| 65 | OSC 133 shell integration | ⚠️ parsed, app never listens | `parser.dart:1222-1228`; `terminal.dart:1645-1649` → `onPrivateOSC?.call('133', ...)`; grep `onPrivateOSC` in `lib/` (app) → **no matches** |
| 66 | OSC 7 (cwd) | ❌ missing | no `case '7'` in `parser.dart:1177-1251` → `unknownOSC` |
| 67 | DCS `+q` remote control / DA responses | ✅ supported | `parser.dart:1262-1290`; `terminal.dart:1673-1708`. DA1 advertises `\x1b[?1;2c` (`emitter.dart:4-6`) = VT100 w/ AVO — **does not advertise 256-color or sixel** |
| 68 | Sixel | ❌ missing | `parser.dart:105` `// 'P'.charCode: _unsupportedHandler, // Sixel` (commented out) and `parser.dart:108` rebinds `P` to DCS. grep `sixel\|Sixel\|SIXEL` in `lib/` → only that comment |
| 69 | Kitty graphics (APC `_G`) | ✅ supported | `parser.dart:109-110,1294-1333`; `terminal.dart:949-1090` (PNG `f=100`, JPEG `f=98`, RGBA `f=32`, GIF `f=50`); `graphics_manager.dart` |
| 70 | iTerm2 inline images (OSC 1337) | ❌ missing | grep `1337\|iTerm2\|iterm` in `lib/` → **no matches**; `parser.dart:1177-1251` has no `1337` |
| 71 | DECSCUSR `CSI Ps SP q` cursor shape | ❌ missing | `_csiHandlers` (`parser.dart:338-368`) has no `q` final byte; grep `DECSCUSR\|cursorShape\|setCursorShape` in `lib/` → **no matches**. `ui/cursor_type.dart` is a 3-value enum (`block/underline/verticalBar`) set only from the widget: `lib/ui/terminal_tabs_page.dart:304` `cursorType: TerminalCursorType.block` |
| 72 | RIS `ESC c` (full reset) | ❌ missing | `parser.dart:96-117` `_escHandlers` has no `c`; `parser.dart:106` `// 'c'.charCode: _unsupportedHandler,` → `unknownEscape` no-op (`terminal.dart:627-630`) |
| 73 | DECALN `ESC # 8` | ❌ missing | `parser.dart:107` `// '#'.charCode: _unsupportedHandler,`; grep `DECALN` in `lib/` → **no matches** |
| 74 | Tab stops HTS/TBC | ⚠️ `CSI 3g` works only by accident of `default:` | `parser.dart:429-442` (`case 0:` else `default: clearAllTabStops`); `tabs.dart:52-56` `clearAll()` never re-seeds the default 8-column stops (`tabs.dart:14-19` is only called from the constructor and `reset()`), so **`ESC[3g` permanently kills all tab stops until RIS — which does not exist** |
| 75 | Back-tab `CSI Z` (CBT) | ❌ missing | `parser.dart:338-368` has no `Z` entry → `unknownCSI`; `keytab_default.dart:27-30` provides Backtab *input* records, but the emulator offers no tab-stop-aware reverse tab |
| 76 | 8-bit C1 controls (CSI `0x9B`, OSC `0x9D`) | ❌ missing | parser dispatches only on `char == Ascii.ESC` (`parser.dart:41`); grep `0x9b\|0x9d` in `lib/src/core/escape/` → no matches; `0x9B` has `wcwidth == 1` (`unicode_v11.dart:504`) → printed as garbage |
| 77 | Bell / notify / title events | ⚠️ callbacks exist, app wires none | grep `onBell|onIconChange|onNotification` in `lib/` (app) → **no matches** |
| 78 | Erase fills use the *current* SGR background (BCE) | ❌ missing | Every erase path passes a fresh default style instead of `terminal.cursor`: `buffer.dart:189-239` (`eraseRange(…, CursorStyle())`), plus default args at `buffer.dart:220` (`removeCells`) and `buffer.dart:254` (`insertCells`). xterm fills erased cells with the active background; TUIs that paint a colored panel then `EL`/`ED` get default-background holes |

---

## 2. Ranked top-8 gaps

### 1. IRM (insert mode, `CSI 4h`) is accepted and then ignored
- **Mechanism**: `parser.dart:1058-1059` routes `CSI 4h` to `setInsertMode`, which only records a bool (`terminal.dart:805-807`). `Buffer.writeChar` (`buffer.dart:121-167`) unconditionally calls `line.setCell(...)` — there is no ICH-style shift of existing cells. Any TUI that turns on insert mode (some editors, some line-edit libraries, `dialog` passthrough of user `ESC[4h`) then types over existing text instead of shifting it.
- **Evidence**: store `terminal.dart:805-807`; grep `insertMode` over `lib/` shows no consumer in `buffer.dart`/`line.dart`.
- **Fix direction**: in `buffer.dart:157`, when `terminal.insertMode` is true and `_cursorX < viewWidth`, call `line.insertCells(_cursorX, cellWidth, terminal.cursor)` before `line.setCell(...)` (or reuse the existing `insertBlankChars` path at `buffer.dart:442-444`).

### 2. The whole SGR parameter list is flattened, so `4;n` swallows the next attribute
- **Mechanism**: `_consumeCsi` pushes both `;` and `:` into one flat `params` list (`parser.dart:307-313`). SGR case `4` then greedily consumes the following value as an underline *style* whenever it is 0-5 (`parser.dart:491-501`). The very common sequences `CSI 4;3m` (underline+italic), `CSI 4;5m` (underline+blink), `CSI 4;31m` (underline+red) and `CSI 0;4;31m` are therefore misread: the second attribute is lost. Because `case 38/48` also advances `i` by fixed offsets (`parser.dart:568-591`, `620-643`), a mis-parsed underline can additionally shift color handling.
- **Evidence**: `parser.dart:307-313`, `parser.dart:491-504`. Hand-trace of `ESC[4;3m` → `setCursorUnderlineStyle(3)` (curly), *not* underline+italic.
- **Fix direction**: track separator kind per parameter (e.g. a parallel `bool isColon` list, or emit a sub-parameter list) and only treat `4` as an extended style when the next value came from a `:` separator. Minimal alternative: require colon for the style form (`parser.dart:494`), keeping `4;3` as underline+italic.

### 3. No synchronized output (`?2026h/l`) → TUI redraw tearing
- **Mechanism**: DECSET 2026 is not in `_setDecMode` (`parser.dart:1067-1157`), so it lands in `setUnknownDecMode` (`parser.dart:1155-1156`) → no-op (`terminal.dart:1367-1370`). Modern TUIs (and tmux with `sync`, Claude Code / dsh-class UIs, `btop`, `fzf`) wrap each frame in `?2026h … ?2026l` and rely on the terminal to buffer the frame. Here every partial write is painted; combined with the coalescing microtask (`terminal.dart:298-305`) the user sees torn/partially-drawn frames.
- **Evidence**: grep `2026|synchroniz` over `lib/` → no mode handling at all.
- **Fix direction**: add `case 2026:` in `_setDecMode` setting a new `TerminalState.synchronizedOutput` bool, and in `Terminal._scheduleNotify` (`terminal.dart:298-305`) suppress `notifyListeners()` while it is set, flushing on reset/`?2026l`.

### 4. Initial PTY is 80×24 and a resize before the shell opens is dropped
- **Mechanism**: `TerminalSession.connect` calls `ssh.shell(cols: 80, rows: 24)` (`lib/services/terminal_manager.dart:87`) with literals, and the SSH layer echoes that into `SSHPtyConfig` (`lib/services/ssh_session.dart:228-236`). But the kterm sizing callback only reaches the PTY *after* `_sshSession` exists: `terminal_manager.dart:44` `onResize: (w, h, pw, ph) => _sshSession?.resizeTerminal(w, h, pw, ph)` — `_sshSession` is still null during the first `performLayout` (`third_party/kterm/lib/src/ui/render.dart:222-227,359-368`), so that resize is discarded. The remote PTY therefore stays 80×24 until the user manually resizes the window, while the local emulator is already at the real width/height.
- **Evidence**: `terminal_manager.dart:44,87`; `ssh_session.dart:218-237`; `render.dart:342-368`.
- **Fix direction**: pass the live size — `TerminalSession.connect` should read `terminal.viewWidth/viewHeight` (or the controller's viewport) into `ssh.shell(cols: …, rows: …)`, and re-issue `resizeTerminal` immediately after `_sshSession = s`.

### 5. ED/EL/SU/SD ignore the scrolling region and `IL`/`DL` move the cursor to column 0
- **Mechanism**: `eraseDisplay`, `eraseDisplayFromCursor`, `eraseDisplayToCursor` erase across the full viewport (`buffer.dart:189-218`), and `eraseLineFromCursor/ToCursor/eraseLine` span `0..viewWidth` (`buffer.dart:222-239`). `scrollUp`/`scrollDown` use `absoluteMargin*` correctly (`buffer.dart:249-269`), but the erase paths do not. Separately, `insertLines`/`deleteLines` call `setCursorX(0)` (`buffer.dart:453`, `buffer.dart:483`) — the cursor column must be preserved. `CSI r` also fails to home the cursor (`parser.dart:765`). TUIs that split the screen with DECSTBM and then repaint a pane (tmux panes, `screen`, vim `:split`, `htop` setup) get over-erasure outside the pane.
- **Evidence**: `buffer.dart:189-239,453,483`; `parser.dart:751-766`.
- **Fix direction**: clamp erase ranges to `[absoluteMarginTop, absoluteMarginBottom]` (matching the already-correct `scrollUp/scrollDown`), drop the two `setCursorX(0)` calls, and home the cursor in `terminal.setMargins` (`terminal.dart:706-708`).

### 6. SGR 22 does not clear bold — a very common "undo emphasis" bug
- **Mechanism**: `parser.dart:522-524` maps `case 22` to `unsetCursorFaint()` only. The only route to `unsetCursorBold()` is `parser.dart:520` (case `21`), which real applications rarely send; the standard reset `22` does not touch bold (`cursor.dart:87-89` defines `unsetBold` but `parser.dart:523` calls `unsetCursorFaint`). So `\x1b[1m…\x1b[22m` leaves the text bold, and any app that uses `1m`/`22m` for emphasis (git pager, `man`, dialog titles, fzf match highlighting) over-emphasises the rest of the line/screen.
- **Evidence**: `parser.dart:519-524`; `cursor.dart:87-93`.
- **Fix direction**: `case 22: handler.unsetCursorBold(); handler.unsetCursorFaint();` (keep `case 21` as double-underline, or route it to `setCursorUnderlineStyle(2)`).

### 7. Focus reporting is stored but never emitted; OSC 4/7/10/11/52/133 have no consumer
- **Mechanism**: `?1004h` sets `_reportFocusMode` (`parser.dart:1114-1115`, `terminal.dart:886-889`) and nothing in `lib/` ever emits `CSI I` / `CSI O`; the app does not attach a `FocusNode`-driven callback. In parallel, the app wires **no** terminal callbacks — grep `onTitleChange|onBell|onClipboardWrite|onClipboardRead|onPrivateOSC|onIconChange|onNotification` in `lib/` returns no matches outside `web_tabs_page.dart:403` (a WebView, not the terminal). Consequences: OSC 52 copy from a remote app silently does nothing (`terminal.dart:1600-1614`), OSC 133 shell-integration markers never reach the UI (`terminal.dart:1645-1649`), window title never tracks the remote host, and OSC 4/10/11 palette queries are answered with nothing (`parser.dart:1255`).
- **Evidence**: grep results above; `parser.dart:1162-1258`; `terminal.dart:1526-1568,1600-1649,1714-1717`.
- **Fix direction**: emit focus reports from `TerminalView`'s focus listener when `terminal.reportFocusMode` is true; wire `onTitleChange`/`onClipboardWrite`/`onPrivateOSC` in `lib/services/terminal_manager.dart:35-45` and implement OSC 4/10/11 as palette get/set on `TerminalThemes`.

### 8. No DECSCUSR, no RIS, no DECALN, no 8-bit C1 — and `ESC[3g` is a one-way trap
- **Mechanism**: `CSI Ps SP q` has no handler (no `q` final byte in `parser.dart:338-368`), so vim/neovim/tmux mode-dependent cursor shapes (bar in insert mode, block in normal) never appear; the widget hardcodes block (`lib/ui/terminal_tabs_page.dart:304`). `ESC c` (RIS) is commented out (`parser.dart:106`) and `unknownEscape` is a no-op (`terminal.dart:627-630`), so a remote `reset` or an app's panic-reset cannot clear modes, margins, tab stops or the alt buffer. `ESC # 8` (DECALN) is likewise commented out (`parser.dart:107`). `CSI 3g` clears *all* tab stops and nothing ever re-seeds them, because `TabStops.reset()` (`tabs.dart:64-67`) is unreachable and RIS does not exist — after one `ESC[3g`, tab stops are dead for the session. 8-bit C1 `CSI`/`OSC` (`0x9B`/`0x9D`) are not recognised (`parser.dart:41` only dispatches on `ESC`) and have width 1 (`unicode_v11.dart:504`), so they render as garbage.
- **Evidence**: `parser.dart:106-107,338-368`; `tabs.dart:14-19,52-56,64-67`; `terminal.dart:627-630`; `lib/ui/terminal_tabs_page.dart:304`.
- **Fix direction**: add a `q`-final CSI handler for DECSCUSR (with an optional `SP` intermediate) feeding a cursor-shape state that `TerminalView` honours; implement `ESC c` as a full `Terminal.reset()` (modes, margins, tab stops re-seeded, both buffers cleared); add `ESC # 8`; treat byte `0x9B` as `ESC [` and `0x9D` as `ESC ]` in `EscapeParser._processChar`.

### Honorable mentions (not in top 8)
- **Combining marks are dropped, not composed** (`buffer.dart:137-140`) — accented Latin/Devanagari text from a TUI renders without diacritics.
- **ZWJ has width 1** (`unicode_v11.dart:464-476`; no `0x200D` anywhere) — emoji clusters and ZWJ-joined sequences occupy extra cells.
- **Reflow never remaps the cursor** (`terminal.dart:496-520`, `buffer.dart:526-527`).
- **DA1 claims only VT100** (`emitter.dart:4-6` `\x1b[?1;2c`) — features cannot be discovered, but it also means no app will *expect* sixel.
- **OSC 10 mis-implemented as a font-size query** with a hardcoded `\x1b]10;12\x1b\\` reply (`parser.dart:1216-1221`, `terminal.dart:1636-1643`).
- **Blink is stored but never animated** (`cursor.dart:47-49`; no `CellFlags.blink` use in `lib/src/ui/`).
- **VT52 (DECANM) is claimed in CHANGELOG 1.5.5 but has no VT52 behaviour**: `setAnsiMode` only stores a bool (`terminal.dart:827-829`); the VT52 input records are matched (`input/handler.dart:128`, `keytab.dart:36,91`) but the *output* side never switches to VT52 escape semantics, and `escape/parser.dart:1071-1072` merely updates the flag.

---

## 3. TERM / environment findings (app layer)

**What is actually sent**, from `lib/services/ssh_session.dart:218-237`:

```dart
return c.shell(
  pty: SSHPtyConfig(
    type: 'xterm-256color',
    width: cols, height: rows,
    pixelWidth: pixelWidth, pixelHeight: pixelHeight,
  ),
);
```

- **TERM = `xterm-256color`**, hardcoded (`ssh_session.dart:231`), applied as the PTY `term` field. Note the call site passes literals 80×24 (`lib/services/terminal_manager.dart:87`), and `pixelWidth/Height` default to `800×600` (`ssh_session.dart:221-222`) and are never populated with the real cell-pixel size.
- **COLORTERM is never set.** dartssh2's `shell()` accepts an `environment` map that it sends via SSH `env` requests (`dartssh2-2.22.5/lib/src/ssh_client.dart:516-532`, `:449-465`), but the call site passes none. So no `COLORTERM=truecolor` (and no `TERM_PROGRAM`, `LANG`, `LC_ALL`). Grep for `TERM|COLORTERM|LANG|LC_|environment` across `lib/` returns **no env-setting call**.
- **Locale is not set by the client** — any `LANG`/`LC_*` comes from the server's own login profile, which the client cannot influence here.
- **Does the emulator live up to the TERM claim?** Mostly yes for the 256-color part, with two caveats:
  - 256-color SGR **is** implemented correctly (`parser.dart:581-588` and `parser.dart:633-640`), so `TERM=xterm-256color` is honest for indexed color.
  - Truecolor SGR `38;2/48;2` also works for the plain semicolon form (`parser.dart:572-580`, `624-632`) and for the empty-field colon form, so the emulator is *more* capable than the advertised TERM. Advertising `COLORTERM=truecolor` would be safe.
  - But `TERM=xterm-256color` also promises xterm behaviours this fork does not have: **no `CSI Ps SP q` (DECSCUSR)**, **no synchronized output**, **no OSC 4/10/11**, **no RIS**, and **no focus reporting**. Applications are entitled to rely on those under that TERM string. The most user-visible of these for xterm-256color-class apps are DECSCUSR (cursor shape never changes) and the absent `?2026` frame sync.
- **Nothing in the app advertises capabilities back**: DA1 replies `\x1b[?1;2c` (`emitter.dart:4-6`), i.e. VT100-with-AVO, so apps cannot discover truecolor/Kitty graphics/mouse-extension support either way (Kitty graphics *does* work, but only for apps that send it unconditionally).
- **Title/bell/clipboard are dropped at the app boundary**: `Terminal` exposes `onTitleChange` (`terminal.dart:46`), `onBell` (`terminal.dart:42`), `onClipboardWrite/Read` (`terminal.dart:84,91`), `onPrivateOSC` (`terminal.dart:71`) and `onNotification` (`terminal.dart:1634`), but `lib/services/terminal_manager.dart:35-45` constructs the `Terminal` with only `onOutput` and `onResize`. Grep confirms no other wiring in `lib/`.

---

### Grep patterns used for the "absent" verdicts
`grep -rn "sixel|Sixel|SIXEL|iTerm2|iterm|1337|DECSCUSR|DECALN|2026|synchronizedOutput"` →
only `parser.dart:105` (commented Sixel) · `grep "selective|DECSEL|DECSED"` → 0 · `grep "insertMode"` →
6 hits, all declaration/setter (no `buffer.dart`) · `grep "reportFocusMode"` → setter/getter only, no emitter ·
`grep "0x200D|ZWJ|0x9b|0x9d"` → 0 · `grep "onTitleChange|onBell|onClipboardWrite|onClipboardRead|onPrivateOSC|onIconChange|onNotification"` in `lib/` → 0 ·
`grep "TERM|COLORTERM|LANG|LC_|environment"` in `lib/` → 0 env-setting calls.
