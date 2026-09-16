# SSHive

轻量级 SSH 隧道客户端（Android + Windows）：记住密码一键连接，把远程端口转发到本地，
并在应用内直接使用远程 WebUI、文件管理器与终端。

纯 Dart 实现 SSH（[dartssh2](https://pub.dev/packages/dartssh2)），不依赖任何系统 SSH 程序。

## 功能

### 服务器与连接

- **多服务器管理**：名称 / 主机 / 端口 / 用户名 / 密码或私钥（PEM，支持口令）
- **ssh 命令自动导入**：粘贴形如
  `ssh -L 8080:localhost:80 -L 8443:localhost:443 -p 2222 user@example.com`
  的命令，自动解析出服务器 + 多条隧道 + SOCKS5（支持引号、IPv6、`-D`、`-o Port=`、`host:port` 等写法）
- **加密存储**：全部配置（含密码/私钥）经 flutter_secure_storage 存入系统加密存储，不落明文
- **主机密钥校验（TOFU）**：首次连接记录 `SHA256:` 指纹，之后比对，不匹配直接拒绝（防中间人）
- **keepalive**：内置定时心跳（间隔可配），防 NAT/防火墙断链
- **断线自动重连**：2s / 5s / 10s / 30s 退避重试，重连后自动恢复隧道
- **SOCKS5 动态代理**：可选，一个端口当全局代理用（`ssh -D` 等效）

### 端口转发（隧道）

- 一个服务器可建多条隧道，每条独立启停，支持「服务器连接后自动启动」
- 仅监听 `127.0.0.1`，不对外暴露
- 一键把隧道对应的本地地址打开为网页标签

### 网页（内嵌 WebView）

- **多标签浏览器式管理**：多开、Tab 切换、实时标题、Cookie 持久保存（登录态不丢）
- **页面保活**：切 Tab / 返回主页都不销毁，只有手动销毁或退出应用才结束
- 后退 / 前进 / 刷新 / 跳系统浏览器 / 清除 Cookie
- **Windows（WebView2）**：禁用 HTTP→HTTPS 自动升级（隧道是明文 http 服务，避免误升级导致加载失败）；
  滚轮幅度可调
- **Android 桌面版模式**：桌面 User-Agent + 强制桌面视口，网页按电脑布局渲染，
  **渲染宽度可自由调节（300~2560px）**

### 文件管理器

- **VS Code 风格文件树**：目录懒加载展开、层级缩进、选中高亮、精准刷新
- **文件预览**：代码/文本（语法高亮 100+ 语言、虚拟滚动）、Markdown（GFM + 表格内公式）、图片（可缩放）
- **文件操作**：下载到本地（保存路径可自定义并记忆）、重命名、删除、属性查看、在当前目录打开终端
- 支持在指定目录创建文件夹、按服务器切换

### 终端

- 多终端会话、独立标签、保活
- 完整 xterm 兼容（kterm），Ctrl 组合键快捷栏（Ctrl+C/D/L/Z/R 等）
- 与文件管理器联动：在任意目录一键打开终端

### 其他

- 环形日志面板（自由选择复制）、实时状态指示
- 深浅色主题跟随系统、全局中文字体优化
- Android 后台保活（前台服务 + 通知，可开关）

## 平台支持

| 平台 | 说明 |
|---|---|
| **Android** | 完整支持（WebView 网页、文件管理器、终端、前台服务保活），支持桌面版网页模式 |
| **Windows** | 完整支持（WebView2），含窗口版一键构建 + 绿色包打包脚本 |

## 构建

环境要求：Flutter 3.47+（Dart 3.13+）、Android SDK（`compileSdk 37`）、
Windows 端需 Visual Studio 2022（含 C++ 桌面开发）与 CMake。

```bash
flutter pub get
flutter analyze
flutter test

# Android
flutter build apk --release --target-platform android-arm64     # 单 ABI（推荐，约 25MB）
flutter build apk --release                                      # 含全部 ABI

# Windows
flutter build windows --release
```

Windows 一键构建 + 部署 + 打包绿色包：

```powershell
.\build_windows.ps1                  # 构建 → 部署到目标目录 → 打包 zip → 启动
.\build_windows.ps1 -SkipBuild       # 用上次构建产物直接部署 + 打包
.\build_windows.ps1 -NoStart         # 部署后不启动
.\build_windows.ps1 -SkipZip         # 跳过 zip 打包
```

## 代码结构

```
lib/
├── main.dart                       # 入口：初始化、设置加载、自动连接
├── models/
│   ├── server_config.dart          # 服务器配置（含主机指纹 / SOCKS5 端口）
│   └── tunnel_config.dart          # 隧道配置
├── services/
│   ├── app_state.dart              # 全局状态与连接编排
│   ├── ssh_session.dart            # SSH 连接生命周期（dartssh2 封装、重连、TOFU）
│   ├── ssh_command_parser.dart     # ssh 命令解析（-L / -D / -p / user@host）
│   ├── tunnel_runtime.dart         # 端口转发运行时（ServerSocket ↔ SSH 通道）
│   ├── secure_store.dart           # 加密持久化
│   ├── log_bus.dart                # 环形日志总线
│   ├── web_session_manager.dart    # 网页会话（多标签保活 / Cookie）
│   ├── web_scroll_settings.dart    # 网页滚轮幅度（Windows）
│   ├── web_desktop_mode.dart       # 桌面版网页模式 + 渲染宽度（Android）
│   ├── file_browser_controller.dart# 文件管理器与主页 Tab 通信
│   ├── terminal_manager.dart       # 终端会话管理
│   └── ...
└── ui/
    ├── home_page.dart              # 主页（服务器/隧道/网页/终端/文件/日志 六 Tab）
    ├── import_ssh_page.dart        # ssh 命令导入
    ├── server_edit_page.dart       # 服务器编辑 + 测试连接
    ├── tunnel_edit_page.dart       # 隧道编辑
    ├── web_tabs_page.dart          # 网页标签（多标签浏览器）
    ├── remote_file_tabs_page.dart  # 文件管理器（左树 + 右文件标签）
    ├── remote_text_viewer_page.dart# 代码/文本预览（re_editor）
    ├── remote_markdown_page.dart   # Markdown 渲染（markdown-it + texmath + KaTeX）
    └── terminal_tabs_page.dart     # 终端标签（kterm）
```

## 关键依赖

| 包 | 用途 |
|---|---|
| dartssh2 | 纯 Dart SSH：密码/私钥/kbd-interactive 认证、`forwardLocal` 转发、`forwardDynamic` SOCKS5、内置 keepalive |
| flutter_inappwebview | 内嵌网页（Android WebView / Windows WebView2） |
| flutter_secure_storage | 系统加密存储 |
| re_editor + re_highlight | 代码查看（虚拟滚动 + 语法高亮） |
| kterm | 终端模拟 |
| markdown-it + KaTeX（texmath） | Markdown 与数学公式渲染（本地资源、离线可用） |
| flutter_foreground_task | Android 前台服务保活 |

## 本地补丁（third_party/）

以下几个上游包带有本项目所需的小改动，通过 `dependency_overrides` 引用：

| 包 | 补丁内容 |
|---|---|
| `flutter_secure_storage_windows` | 去除对 VS ATL 组件（`atlstr.h`）的依赖，改用标准 Win32 API，避免构建机需安装 ATL |
| `kterm` | 修复 Windows 桌面 TextInput 连接依赖一次性 keyboard token 导致的按键丢失 |
| `flutter_inappwebview_windows` | 滚轮幅度支持运行时热更新（`sendScroll` 读动态成员 + 插件级静态通道），改设置即时生效且无需重建 WebView |
| `re_editor` | 暴露全局滚轮倍率 `CodeWheelScale.factor`（`applyPhysicsToUserOffset`），实现文本/代码查看器的滚动幅度可调 |

## 安全说明

- 密码 / 私钥以 JSON 形式存入系统加密存储（Android Keystore / Windows 凭据保护）
- 主机密钥采用 TOFU 策略，指纹变更会拒绝连接并在日志中告警
- 私钥支持口令加密（OpenSSH 格式）；私钥与口令均只存于加密存储
- 隧道只监听 `127.0.0.1`，仅本机可访问
- 应用内网页仅在 `127.0.0.1` 回环地址放行明文 HTTP（用于转发出来的 WebUI）

## 已知限制

- Android 后台保活依赖前台服务；若进程被系统回收，重开应用后会自动恢复连接与隧道
- 转发为单跳直连，暂不支持跳板机多跳（可用 SOCKS5 + 第三方工具实现）
- 表格单元格内的块级公式（`$$…$$`）与含竖线 `|` 的公式需写作 `\vert`（Markdown 表格语法限制）
