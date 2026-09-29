# assets/xterm —— 离线终端引擎资产

这个目录是 **xterm.js** 及其官方 addon 的离线副本，由
`tool/fetch_xterm_assets.mjs` 从 npm 镜像拉取（不依赖 CDN，终端必须离线可用）。

重新拉取 / 升级版本：

```bash
node tool/fetch_xterm_assets.mjs
```

脚本里的 `VERSIONS` 是唯一需要改的地方；升级后请核对输出里的 sha256 与文件大小。

## 落地文件与来源

| 文件 | 来源 | 许可 |
|---|---|---|
| `xterm.js` | `@xterm/xterm@6.0.0`（`package/lib/xterm.js`，UMD） | MIT（见 `LICENSE.xterm`） |
| `xterm.css` | `@xterm/xterm@6.0.0`（`package/css/xterm.css`） | MIT |
| `addon-fit.js` | `@xterm/addon-fit@0.11.0` | MIT（见 `LICENSE.addon-fit`） |
| `addon-webgl.js` | `@xterm/addon-webgl@0.19.0` | MIT |
| `addon-unicode11.js` | `@xterm/addon-unicode11@0.9.0` | MIT |
| `addon-web-links.js` | `@xterm/addon-web-links@0.12.0` | MIT |

## 为什么是这几个 addon

- **addon-fit**：按真实像素算出 `cols × rows`，回传给 SSH 做 `window-change`。
  这修掉了旧 kterm 实现"远端 PTY 一直按 80×24 工作"的错位问题。
- **addon-webgl**：GPU 渲染，TUI 全屏重绘时明显更稳；加载失败或
  WebGL 上下文丢失时会自动退回 DOM 渲染器（见 `xterm_page.dart` 里
  `onContextLoss` 的处理），不会让终端不可用。
- **addon-unicode11**：宽字符（CJK/emoji）宽度按 Unicode 11 计算，中文对齐更准。
- **addon-web-links**：终端里的 URL 可点击，点击后经桥交给系统浏览器打开。

## 注意

- 页面由 `lib/services/xterm_page.dart` 把以上文件**内联**进一个自包含 HTML，
  再通过 `loadData` 加载（与 `assets/md_viewer/` 的做法一致）。因此这些文件
  不能改名或挪位置，`XtermPage` 里的文件名是硬编码的。
- UMD 版 addon 把整个模块挂在全局上，所以取类时要写
  `window.FitAddon.FitAddon`（`xterm_page.dart` 里用 `ctor()` 做了兼容）。
- xterm.js 6.0.0 起支持 DEC mode 2026（同步输出），这是 tmux/btop/fzf
  这类 TUI 不撕裂的关键，也是选 6.0.0 而不是 5.5.0 的原因。
