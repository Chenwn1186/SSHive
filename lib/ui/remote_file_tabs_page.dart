import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:re_editor/re_editor.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_state.dart';
import '../services/file_browser_controller.dart';
import '../services/font_config.dart';
import '../services/log_bus.dart';
import '../services/secure_store.dart';
import '../services/ssh_session.dart';
import '../services/terminal_manager.dart';
import '../services/text_decoder.dart';
import 'remote_markdown_page.dart';
import 'remote_text_viewer_page.dart';

/// 主页"文件"Tab：IDE 式远程文件管理器。
///
/// 布局：左侧为文件管理器（服务器切换 + 目录浏览 + 文件操作），
/// 右侧为已打开文件的标签页（多标签切换/关闭/刷新/字体切换）。
/// 打开的文件内容缓存在内存，标签跨服务器共享（按 serverId 归属）。
class RemoteFileTabsTab extends StatefulWidget {
  const RemoteFileTabsTab({super.key});

  @override
  State<RemoteFileTabsTab> createState() => _RemoteFileTabsTabState();
}

/// 已打开文件标签的内容类型。
enum _TabKind { text, markdown, image }

/// 已打开的文件标签。
class _FileTab {
  _FileTab({
    required this.serverId,
    required this.serverName,
    required this.path,
    required this.name,
    required this.kind,
    this.text = '',
    this.imageBytes,
  });

  final String serverId;
  final String serverName;
  final String path;
  final String name;
  final _TabKind kind;

  /// 文本/markdown 内容
  String text;

  /// 图片字节
  Uint8List? imageBytes;

  /// 内容版本号：刷新后 +1，用于强制重建视图（重新读取/解码）
  int revision = 0;
}

/// 文件树节点（VS Code 风格树形文件管理器）。
///
/// 目录节点懒加载：首次展开时通过 SFTP listdir 拉取子项，
/// 子项只含名称/路径/是否目录/属性，内容打开时才读取。
class _TreeNode {
  _TreeNode(this.name, this.path, this.isDir, {this.attr});

  final String name;
  final String path;
  final bool isDir;
  final SftpName? attr;

  final List<_TreeNode> children = [];
  bool expanded = false;
  bool loading = false;
  bool loaded = false;
  String? error;
}

class _RemoteFileTabsTabState extends State<RemoteFileTabsTab> {
  String? _serverId;
  SftpClient? _sftp;

  // ---- VS Code 风格文件树状态 ----
  String _path = '/'; // 当前活动路径（最近点击的目录/文件所在目录）
  String _rootPath = '/'; // 树根路径
  _TreeNode? _root; // 树根节点
  String? _selectedPath; // 树中高亮的节点路径
  final Map<String, _TreeNode> _dirNodeCache = {}; // path→已加载节点缓存

  bool _loading = true;
  bool _busy = false;
  int _progressBytes = 0;
  int _progressTotal = 0;
  String _progressLabel = '';
  String? _error;

  final List<_FileTab> _tabs = [];
  int _activeTab = -1;

  bool _showLeft = true;
  ViewerFontPref _fontPref = ViewerFontPref.mono;

  SshSession? get _session => _serverId == null
      ? null
      : AppState.instance.sessionOf(_serverId!);

  String _join(String base, String name) =>
      base == '/' ? '/$name' : '$base/$name';

  String get _displayPath => _path == '/' ? '/' : _path;

  // ---------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    SecureStore.instance.loadViewerFontPref().then((key) {
      if (!mounted) return;
      setState(() => _fontPref = ViewerFontPref.fromKey(key));
    });
    FileBrowserController.instance.addListener(_onFileBrowser);
    AppState.instance.addListener(_onAppState);
    // 消费外部"请选中服务器"请求（如服务器卡片"文件"按钮）
    _onFileBrowser();
  }

  @override
  void dispose() {
    FileBrowserController.instance.removeListener(_onFileBrowser);
    AppState.instance.removeListener(_onAppState);
    super.dispose();
  }

  void _onFileBrowser() {
    final pending = FileBrowserController.instance.takePendingServerId();
    if (pending != null && mounted) {
      _selectServer(pending);
    } else if (_serverId == null && mounted) {
      // 首次进入：沿用之前的选中，否则选第一个已连接服务器
      final saved = FileBrowserController.instance.serverId;
      final first = AppState.instance.servers
          .where((s) =>
              AppState.instance.sessionOf(s.id)?.isConnected ?? false)
          .firstOrNull;
      if (saved != null &&
          AppState.instance.servers.any((s) => s.id == saved)) {
        _selectServer(saved);
      } else if (first != null) {
        _selectServer(first.id);
      } else {
        setState(() {
          _serverId = null;
          _loading = false;
          _error = '没有已连接的服务器';
        });
      }
    }
  }

  void _onAppState() {
    final app = AppState.instance;
    // 当前服务器被删除：清空并尝试自动选择
    if (_serverId != null && !app.servers.any((s) => s.id == _serverId)) {
      _serverId = null;
      _sftp = null;
      _root = null;
      final first = app.servers
          .where((s) => app.sessionOf(s.id)?.isConnected ?? false)
          .firstOrNull;
      if (first != null) {
        _selectServer(first.id);
      } else if (mounted) {
        setState(() {
          _loading = false;
          _error = '没有已连接的服务器';
        });
      }
      return;
    }
    if (_serverId == null || !mounted) return;
    final session = _session;
    if (session == null || !session.isConnected) {
      // 断开：标记失效（内容标签保留，仍可查看缓存）
      if (_sftp != null) {
        setState(() {
          _sftp = null;
          _root = null;
          _error = '连接已断开，等待重连…';
        });
      }
      return;
    }
    // 重连成功且尚未建立 SFTP：自动重新打开
    if (_sftp == null) _open();
  }

  // ---------------------------------------------------------------------
  // 服务器与目录
  // ---------------------------------------------------------------------

  void _selectServer(String id) {
    if (_serverId == id) return;
    setState(() {
      _serverId = id;
      _path = '/';
      _rootPath = '/';
      _root = null;
      _selectedPath = null;
      _dirNodeCache.clear();
      _sftp = null;
      _loading = true;
      _error = null;
    });
    FileBrowserController.instance.selectServer(id);
    _open();
  }

  Future<void> _open() async {
    final sid = _serverId;
    if (sid == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final session = AppState.instance.sessionOf(sid);
    if (session == null || !session.isConnected) {
      setState(() {
        _loading = false;
        _error = session?.status == SshStatus.connecting
            ? '服务器连接中…'
            : '服务器未连接，请先在"服务器"Tab 连接';
      });
      return;
    }
    try {
      _sftp = await session.sftp();
      // 默认进入当前登录用户的 home 目录（SFTP 工作目录即 home）
      try {
        final home = await _sftp!.absolute('.');
        if (home.isNotEmpty) {
          _path = (home.length > 1 && home.endsWith('/'))
              ? home.substring(0, home.length - 1)
              : home;
          LogBus.instance.info('SFTP', 'home 目录: $_path');
        }
      } catch (e) {
        LogBus.instance.debug('SFTP', '获取 home 目录失败，回退到 /: $e');
        _path = '/';
      }
      // 初始化文件树根（home 目录）
      _rootPath = _path;
      _root = _TreeNode(
        _rootPath == '/' ? '/' : _rootPath.split('/').last,
        _rootPath,
        true,
      );
      await _loadChildren(_root!);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  // ---------------------------------------------------------------------
  // 文件树（VS Code 风格：懒加载展开、精准刷新）
  // ---------------------------------------------------------------------

  String _parentOf(String path) {
    if (path == '/') return '/';
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }

  /// 加载节点子项（懒加载；目录首次展开时调用）。
  Future<void> _loadChildren(_TreeNode node) async {
    if (node.loading) return;
    node.loading = true;
    if (mounted) setState(() {});
    try {
      final sftp = _sftp;
      if (sftp == null) throw StateError('服务器未连接');
      final list = await sftp.listdir(node.path);
      list.removeWhere((n) => n.filename == '.' || n.filename == '..');
      list.sort((a, b) {
        final ad = a.attr.isDirectory;
        final bd = b.attr.isDirectory;
        if (ad != bd) return ad ? -1 : 1;
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      node.children
        ..clear()
        ..addAll([
          for (final n in list)
            _TreeNode(
              n.filename,
              _join(node.path, n.filename),
              n.attr.isDirectory,
              attr: n,
            ),
        ]);
      node.error = null;
      node.loaded = true;
      _dirNodeCache[node.path] = node;
    } catch (e) {
      node.error = '$e';
    } finally {
      node.loading = false;
      if (mounted) {
        setState(() {
          // 根加载完成/失败后必须复位页面级 loading（曾漏掉导致一直转圈）
          if (node == _root) _loading = false;
        });
      }
    }
  }

  /// 重载指定目录的树节点（新建/重命名/删除后精准刷新）。
  Future<void> _reloadNode(String dirPath) async {
    if (dirPath == '/' || dirPath.isEmpty) dirPath = _rootPath;
    if (dirPath == _rootPath) {
      final root = _root;
      if (root != null && root.loaded) await _loadChildren(root);
      return;
    }
    final node = _dirNodeCache[dirPath];
    if (node != null && node.loaded) {
      await _loadChildren(node);
    }
  }

  /// 刷新树根（重载根目录子项）。
  Future<void> _loadRoot() async {
    final root = _root;
    if (root == null) {
      await _open();
      return;
    }
    root.expanded = true;
    await _loadChildren(root);
  }

  /// 以指定目录为新的树根。
  void _setRootTo(String path) {
    if (path == _rootPath) return;
    setState(() {
      _rootPath = path;
      _path = path;
      _selectedPath = null;
      _dirNodeCache.clear();
      _root = _TreeNode(
        path == '/' ? '/' : path.split('/').last,
        path,
        true,
      );
      _error = null;
      _loading = true;
    });
    _loadRoot();
  }

  /// 树节点点击：目录展开/收起（懒加载），文件打开标签。
  void _onNodeTap(_TreeNode node) {
    if (node.isDir) {
      setState(() {
        _path = node.path;
        _selectedPath = node.path;
        node.expanded = !node.expanded;
      });
      if (node.expanded && !node.loaded) _loadChildren(node);
    } else {
      _openEntryAt(node);
    }
  }

  // ---------------------------------------------------------------------
  // 文件操作
  // ---------------------------------------------------------------------

  Future<void> _downloadAt(String full, String name, int size) async {
    final sftp = _sftp;
    if (sftp == null) return;
    final remote = full;
    final docs = await getApplicationDocumentsDirectory();
    // 支持自定义保存路径：默认上次使用的目录（首次为应用下载目录），
    // 下载前可修改；目录持久化。
    final savedDir = await SecureStore.instance.loadDownloadDir();
    if (!mounted) return;
    final defaultDir =
        savedDir ?? '${docs.path}/downloads';
    final pathController =
        TextEditingController(text: '$defaultDir/$name');
    final targetPath = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载到'),
        content: TextField(
          controller: pathController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '保存路径',
            hintText: '如 D:\\Downloads\\file.txt 或 /storage/emulated/0/Download/file.txt',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, pathController.text.trim()),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (targetPath == null || targetPath.isEmpty) return;
    final local = File(targetPath);
    final targetDir = local.parent.path;
    final dir = Directory(targetDir);
    try {
      await dir.create(recursive: true);
      await SecureStore.instance.saveDownloadDir(targetDir);
    } catch (e) {
      if (!mounted) return;
      _snack('目录不可用: $e');
      return;
    }
    setState(() {
      _busy = true;
      _progressBytes = 0;
      _progressTotal = size;
      _progressLabel = '下载 $name';
    });
    try {
      final sink = local.openWrite();
      await sftp.download(
        remote,
        sink,
        onProgress: (bytes) {
          if (mounted) {
            setState(() {
              _progressBytes = bytes;
              _progressTotal = size;
            });
          }
        },
        closeDestination: true,
      );
      LogBus.instance.info('SFTP', '下载完成: $remote → ${local.path}');
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('已下载到 ${local.path}'),
            action: SnackBarAction(
              label: '分享',
              onPressed: () => SharePlus.instance
                  .share(ShareParams(files: [XFile(local.path)])),
            ),
          ),
        );
    } catch (e) {
      LogBus.instance.error('SFTP', '下载失败: $e');
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('下载失败: $e');
    }
  }

  Future<void> _mkdirIn(String dirPath) async {
    final name = await _promptText('新建文件夹', '文件夹名称');
    if (name == null || name.isEmpty) return;
    final sftp = _sftp;
    if (sftp == null) return;
    try {
      await sftp.mkdir(_join(dirPath, name));
      await _reloadNode(dirPath);
    } catch (e) {
      _snack('创建失败: $e');
    }
  }

  Future<void> _renameAt(String full, String name) async {
    final newName = await _promptText('重命名', '新名称', initial: name);
    if (newName == null || newName.isEmpty || newName == name) return;
    final sftp = _sftp;
    if (sftp == null) return;
    final dirPath = _parentOf(full);
    try {
      await sftp.rename(full, _join(dirPath, newName));
      await _reloadNode(dirPath);
    } catch (e) {
      _snack('重命名失败: $e');
    }
  }

  Future<void> _deleteAt(String full, String name,
      {required bool isDir, required bool isLink}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text('确定删除"$name"？\n此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final sftp = _sftp;
    if (sftp == null) return;
    try {
      if (isDir && !isLink) {
        await sftp.rmdir(full);
      } else {
        await sftp.remove(full);
      }
      await _reloadNode(_parentOf(full));
    } catch (e) {
      _snack('删除失败: $e');
    }
  }

  /// 打开文件：已打开则激活标签，否则读取内容新建标签。
  Future<void> _openEntryAt(_TreeNode node) async {
    final sftp = _sftp;
    if (sftp == null) return;
    final full = node.path;
    final existing = _tabs.indexWhere(
        (t) => t.serverId == _serverId && t.path == full);
    if (existing >= 0) {
      setState(() {
        _activeTab = existing;
        _selectedPath = full;
      });
      return;
    }
    final kind = _kindFor(node.name);
    final limit = switch (kind) {
      _TabKind.markdown => 3 * 1024 * 1024,
      _TabKind.image => 20 * 1024 * 1024,
      _TabKind.text => 5 * 1024 * 1024,
    };
    final size = node.attr?.attr.size ?? 0;
    if (size > limit) {
      _snack('文件过大（>${limit ~/ 1024 ~/ 1024}MB），请下载后查看');
      return;
    }
    setState(() {
      _busy = true;
      _progressLabel = '读取 ${node.name}';
      _selectedPath = full;
    });
    try {
      final handle =
          await sftp.open(full, mode: SftpFileOpenMode.read);
      final bytes = await handle.readBytes();
      await handle.close();
      if (!mounted) return;
      setState(() => _busy = false);
      final serverName = _serverNameOf(_serverId!);
      if (kind == _TabKind.image) {
        _addTab(_FileTab(
          serverId: _serverId!,
          serverName: serverName,
          path: full,
          name: node.name,
          kind: kind,
          imageBytes: bytes,
        ));
        return;
      }
      // 二进制检测：前 8KB 含 NUL 字节视为二进制
      final sampleLen = bytes.length > 8192 ? 8192 : bytes.length;
      if (bytes.sublist(0, sampleLen).contains(0)) {
        _snack('二进制文件，无法预览，请下载查看');
        return;
      }
      _addTab(_FileTab(
        serverId: _serverId!,
        serverName: serverName,
        path: full,
        name: node.name,
        kind: kind,
        text: decodeTextBytes(bytes),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('读取失败: $e');
    }
  }

  String _serverNameOf(String id) {
    final s = AppState.instance.servers
        .where((s) => s.id == id)
        .firstOrNull;
    if (s == null) return id;
    return s.name.isEmpty ? s.host : s.name;
  }

  void _addTab(_FileTab tab) {
    setState(() {
      _tabs.add(tab);
      _activeTab = _tabs.length - 1;
    });
  }

  void _activateTab(int i) {
    if (i == _activeTab) return;
    setState(() => _activeTab = i);
  }

  void _closeTab(int i) {
    setState(() {
      _tabs.removeAt(i);
      if (_tabs.isEmpty) {
        _activeTab = -1;
      } else if (_activeTab >= _tabs.length) {
        _activeTab = _tabs.length - 1;
      } else if (i < _activeTab) {
        _activeTab--;
      }
    });
  }

  void _closeOthers(int keep) {
    setState(() {
      final k = _tabs[keep];
      _tabs
        ..clear()
        ..add(k);
      _activeTab = 0;
    });
  }

  void _closeAll() {
    setState(() {
      _tabs.clear();
      _activeTab = -1;
    });
  }

  /// 重新从 SFTP 读取当前文件内容（仅限当前选中服务器的标签）。
  Future<void> _reloadTab(int i) async {
    final tab = _tabs[i];
    if (tab.serverId != _serverId) {
      _snack('请先切换到标签所属服务器（${tab.serverName}）');
      return;
    }
    final sftp = _sftp;
    if (sftp == null) {
      _snack('服务器未连接');
      return;
    }
    try {
      final handle = await sftp.open(tab.path, mode: SftpFileOpenMode.read);
      final bytes = await handle.readBytes();
      await handle.close();
      if (!mounted) return;
      setState(() {
        if (tab.kind == _TabKind.image) {
          tab.imageBytes = bytes;
        } else {
          tab.text = decodeTextBytes(bytes);
        }
        tab.revision++;
      });
      LogBus.instance.debug('SFTP', '已刷新: ${tab.path}');
    } catch (e) {
      _snack('刷新失败: $e');
    }
  }

  Future<void> _copyPath(int i) async {
    await Clipboard.setData(ClipboardData(text: _tabs[i].path));
    if (mounted) _snack('已复制路径: ${_tabs[i].path}');
  }

  Future<void> _changeFont(ViewerFontPref pref) async {
    setState(() => _fontPref = pref);
    await SecureStore.instance.saveViewerFontPref(pref.key);
  }

  /// 文本查看器滚轮倍率：调节滚轮滚动幅度（0.25x ~ 4x），
  /// 全局即时生效（re_editor 补丁 CodeWheelScale.factor）。
  Future<void> _adjustViewerScroll(BuildContext context) async {
    var v = CodeWheelScale.factor;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('文本滚动倍率'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '滚轮滚动幅度：${v.toStringAsFixed(2)}x\n'
                '（1x=默认；数值越大每格滚动越多）',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Slider(
                value: v.clamp(0.25, 4.0),
                min: 0.25,
                max: 4.0,
                divisions: 15,
                label: '${v.toStringAsFixed(2)}x',
                onChanged: (nv) => setState(() => v = nv),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      v = v.clamp(0.25, 4.0);
      CodeWheelScale.factor = v;
      await SecureStore.instance.saveViewerScrollFactor(v);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('滚动倍率已设为 ${v.toStringAsFixed(2)}x'),
            duration: const Duration(seconds: 1),
          ));
      }
    }
  }

  void _showPropsAt(SftpName n, String full) {
    final a = n.attr;
    final perm = a.mode?.value;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(20),
        children: [
          Text(n.filename, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 12),
          _propRow(ctx, '完整路径', full),
          _propRow(ctx, '类型', a.isDirectory
              ? '目录'
              : a.isSymbolicLink
                  ? '符号链接'
                  : '文件'),
          if (a.size != null) _propRow(ctx, '大小', _fmtSize(a.size!)),
          if (a.modifyTime != null)
            _propRow(ctx, '修改时间', _fmtTime(a.modifyTime!)),
          if (perm != null) _propRow(ctx, '权限', _fmtPerm(perm)),
          if (a.userID != null)
            _propRow(ctx, 'UID/GID', '${a.userID}/${a.groupID}'),
        ],
      ),
    );
  }

  Widget _propRow(BuildContext ctx, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 90,
              child: Text(k,
                  style: Theme.of(ctx)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(ctx).colorScheme.outline)),
            ),
            Expanded(
              child: Text(v,
                  style: Theme.of(ctx).textTheme.bodySmall,
                  softWrap: true),
            ),
          ],
        ),
      );

  Future<String?> _promptText(String title, String label,
      {String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 在指定目录打开终端（与终端管理联动，自动切到终端 Tab）。
  void _openTerminalAt(String dir) {
    final sid = _serverId;
    if (sid == null) return;
    TerminalManager.instance.open(
      serverId: sid,
      startDir: dir == '/' ? '~' : dir,
    );
    TerminalManager.instance.requestTab(3);
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildServerChips(),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final compact = width < 700;
              final leftW = compact
                  ? (width * 0.45).clamp(200.0, 280.0)
                  : 300.0;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    // 收起时保留窄把手（提供重新展开入口）
                    width: _showLeft ? leftW : 32,
                    child: _showLeft ? _buildLeftPanel() : _buildLeftRail(),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildRightPanel()),
                ],
              );
            },
          ),
        ),
        if (_busy)
          LinearProgressIndicator(
            value: _progressTotal > 0 ? _progressBytes / _progressTotal : null,
          ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              '$_progressLabel  '
              '${_progressTotal > 0 ? '${_fmtSize(_progressBytes)} / ${_fmtSize(_progressTotal)}' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _buildServerChips() {
    final app = AppState.instance;
    if (app.servers.isEmpty) {
      return SizedBox(
        height: 44,
        child: Center(
          child: Text(
            '没有服务器配置，请先在"服务器"Tab 添加',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ),
      );
    }
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          for (final s in app.servers)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(
                  s.name.isEmpty ? s.host : s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                avatar: _StatusDot(status: app.sessionOf(s.id)?.status),
                selected: _serverId == s.id,
                onSelected: (sel) {
                  if (sel) _selectServer(s.id);
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 收起状态下的窄把手：保留展开入口（原收起按钮在左栏内部，
  /// 收起后必然不可见，这里提供重新展开的按钮）。
  Widget _buildLeftRail() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          IconButton(
            tooltip: '展开文件栏',
            icon: const Icon(Icons.chevron_right, size: 18),
            onPressed: () => setState(() => _showLeft = true),
          ),
          const Expanded(child: SizedBox()),
        ],
      ),
    );
  }

  Widget _buildLeftPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          _buildSidebarHeader(),
          _buildBreadcrumbs(),
          const Divider(height: 1),
          Expanded(child: _buildTreeArea()),
        ],
      ),
    );
  }

  /// VS Code 风格侧边栏标题：标题 + 根路径操作（向上/刷新/新建/收起）。
  Widget _buildSidebarHeader() {
    final scheme = Theme.of(context).colorScheme;
    final atRoot = _rootPath == '/';
    return Container(
      height: 36,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: '树根: $_rootPath',
              child: Text(
                '文件管理',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                    ),
              ),
            ),
          ),
          IconButton(
            tooltip: '回到上级目录（作为树根）',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: const Icon(Icons.arrow_upward),
            onPressed: _sftp == null || atRoot
                ? null
                : () => _setRootTo(_parentOf(_rootPath)),
          ),
          IconButton(
            tooltip: '刷新文件树',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: const Icon(Icons.refresh),
            onPressed: _sftp == null ? null : _loadRoot,
          ),
          IconButton(
            tooltip: '在当前目录新建文件夹',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _sftp == null ? null : () => _mkdirIn(_path),
          ),
          IconButton(
            tooltip: '收起文件栏',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: const Icon(Icons.close_fullscreen),
            onPressed: () => setState(() => _showLeft = false),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbs() {
    final segments =
        _displayPath.split('/').where((s) => s.isNotEmpty).toList();
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: _path == '/'
                        ? null
                        : () => _setRootTo('/'),
                    child: const Text('/'),
                  ),
                ),
                for (var i = 0; i < segments.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: i == segments.length - 1
                          ? null
                          : () => _setRootTo(
                              '/${segments.sublist(0, i + 1).join('/')}'),
                      child: Text(
                        segments[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '在当前目录打开终端',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: const Icon(Icons.terminal, size: 16),
            onPressed:
                _sftp == null ? null : () => _openTerminalAt(_path),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeArea() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _open,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final root = _root;
    if (root == null) {
      return const Center(child: Text('空目录'));
    }
    if (root.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(root.error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _loadRoot,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!root.loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final kids = <Widget>[
      for (final c in root.children) _buildNode(c, 0),
    ];
    if (kids.isEmpty) {
      return const Center(child: Text('空目录'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 2),
      children: kids,
    );
  }

  /// 递归构建树节点（含其展开的子节点）。
  Widget _buildNode(_TreeNode node, int depth) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildNodeRow(node, depth),
        if (node.expanded)
          for (final c in node.children) _buildNode(c, depth + 1),
      ],
    );
  }

  /// VS Code 风格树行：缩进 + 展开箭头 + 图标 + 名称 + 操作菜单。
  Widget _buildNodeRow(_TreeNode node, int depth) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedPath == node.path;
    final isDir = node.isDir;
    final isLink = node.attr?.attr.isSymbolicLink ?? false;
    final sftpName = node.attr;
    return InkWell(
      onTap: () => _onNodeTap(node),
      child: Container(
        height: 26,
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.5)
            : null,
        padding: const EdgeInsets.only(right: 2),
        child: Row(
          children: [
            SizedBox(width: 8.0 + depth * 14),
            if (isDir)
              Icon(
                node.expanded ? Icons.expand_more : Icons.chevron_right,
                size: 15,
                color: scheme.outline,
              )
            else
              const SizedBox(width: 15),
            const SizedBox(width: 2),
            Icon(
              isDir
                  ? (node.expanded ? Icons.folder_open : Icons.folder)
                  : _iconFor(node.name, isLink),
              size: 15,
              color: isDir
                  ? Colors.amber.shade700
                  : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                node.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontSize: 12.5),
              ),
            ),
            if (node.loading)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
            PopupMenuButton<String>(
              iconSize: 14,
              padding: EdgeInsets.zero,
              tooltip: '操作',
              onSelected: (v) {
                switch (v) {
                  case 'download':
                    _downloadAt(node.path, node.name,
                        sftpName?.attr.size ?? 0);
                  case 'rename':
                    _renameAt(node.path, node.name);
                  case 'delete':
                    _deleteAt(node.path, node.name,
                        isDir: isDir, isLink: isLink);
                  case 'props':
                    if (sftpName != null) _showPropsAt(sftpName, node.path);
                  case 'terminal':
                    _openTerminalAt(node.path);
                }
              },
              itemBuilder: (context) => [
                if (isDir)
                  const PopupMenuItem(
                      value: 'terminal', child: Text('在此打开终端')),
                if (!isDir)
                  const PopupMenuItem(
                      value: 'download', child: Text('下载到本地')),
                const PopupMenuItem(value: 'rename', child: Text('重命名')),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
                const PopupMenuItem(value: 'props', child: Text('属性')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // 右侧：文件标签
  // ---------------------------------------------------------------------

  Widget _buildRightPanel() {
    return Column(
      children: [
        _buildTabBar(),
        const Divider(height: 1),
        Expanded(child: _buildTabContent()),
      ],
    );
  }

  Widget _buildTabBar() {
    final active = _activeTab >= 0 && _activeTab < _tabs.length
        ? _tabs[_activeTab]
        : null;
    final isText = active != null && active.kind == _TabKind.text;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  _buildTabChip(i, _tabs[i]),
              ],
            ),
          ),
          if (active != null) ...[
            IconButton(
              tooltip: '刷新当前文件',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => _reloadTab(_activeTab),
            ),
            IconButton(
              tooltip: '关闭全部标签',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_fullscreen, size: 18),
              onPressed: _closeAll,
            ),
            if (isText)
              PopupMenuButton<ViewerFontPref>(
                tooltip: '字体',
                icon: const Icon(Icons.format_size, size: 18),
                initialValue: _fontPref,
                onSelected: _changeFont,
                itemBuilder: (context) => [
                  for (final p in ViewerFontPref.values)
                    CheckedPopupMenuItem(
                      value: p,
                      checked: _fontPref == p,
                      child: Text(switch (p) {
                        ViewerFontPref.system => '系统默认',
                        ViewerFontPref.mono => '等宽字体',
                        ViewerFontPref.sans => '无衬线字体',
                      }),
                    ),
                ],
              ),
            if (isText)
              IconButton(
                tooltip: '文本滚动倍率（滚轮幅度）',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.speed, size: 18),
                onPressed: () => _adjustViewerScroll(context),
              ),
            PopupMenuButton<String>(
              tooltip: '标签操作',
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (v) {
                switch (v) {
                  case 'reload':
                    _reloadTab(_activeTab);
                  case 'close_others':
                    _closeOthers(_activeTab);
                  case 'close_all':
                    _closeAll();
                  case 'copy_path':
                    _copyPath(_activeTab);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'reload', child: Text('刷新')),
                const PopupMenuItem(value: 'copy_path', child: Text('复制路径')),
                const PopupMenuItem(value: 'close_others', child: Text('关闭其他')),
                const PopupMenuItem(value: 'close_all', child: Text('关闭全部')),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTabChip(int i, _FileTab tab) {
    final selected = i == _activeTab;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _activateTab(i),
        child: Container(
          padding: const EdgeInsets.only(left: 8, right: 2),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_tabIcon(tab.kind), size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Tooltip(
                  message: '${tab.serverName}:${tab.path}',
                  child: Text(
                    tab.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: scheme.onSurface),
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
                iconSize: 14,
                icon: const Icon(Icons.close),
                onPressed: () => _closeTab(i),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _tabIcon(_TabKind kind) => switch (kind) {
        _TabKind.text => Icons.code,
        _TabKind.markdown => Icons.description_outlined,
        _TabKind.image => Icons.image_outlined,
      };

  Widget _buildTabContent() {
    if (_tabs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tab_unselected,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              '点击左侧文件打开预览\n同一文件重复点击会激活已有标签',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
      );
    }
    final index = _activeTab.clamp(0, _tabs.length - 1);
    return IndexedStack(
      index: index,
      children: [for (final t in _tabs) _buildTabView(t)],
    );
  }

  Widget _buildTabView(_FileTab tab) {
    // key 包含路径与版本号：切换文件/刷新后强制重建视图
    final key = ValueKey('${tab.serverId}:${tab.path}#${tab.revision}');
    switch (tab.kind) {
      case _TabKind.text:
        return RemoteTextView(
          key: key,
          name: tab.name,
          content: tab.text,
          fontPref: _fontPref,
        );
      case _TabKind.markdown:
        return RemoteMarkdownView(
          key: key,
          name: tab.name,
          content: tab.text,
        );
      case _TabKind.image:
        final bytes = tab.imageBytes;
        if (bytes == null) return const SizedBox();
        return Center(
          child: InteractiveViewer(
            maxScale: 8,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_outlined,
                        size: 48,
                        color: Theme.of(context).colorScheme.error),
                    const SizedBox(height: 12),
                    const Text('图片无法解码'),
                  ],
                ),
              ),
            ),
          ),
        );
    }
  }
}

// ---------------------------------------------------------------------------
// 工具组件与函数
// ---------------------------------------------------------------------------

class _StatusDot extends StatelessWidget {
  const _StatusDot({this.status});

  final SshStatus? status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      SshStatus.connected => Colors.green,
      SshStatus.connecting => Colors.orange,
      SshStatus.error => Colors.red,
      _ => Colors.grey,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

_TabKind _kindFor(String name) {
  if (_isMarkdown(name)) return _TabKind.markdown;
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if (const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}.contains(ext)) {
    return _TabKind.image;
  }
  return _TabKind.text;
}

bool _isMarkdown(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return ['md', 'markdown', 'mdown', 'mkd', 'mdx']
      .contains(name.substring(dot + 1).toLowerCase());
}

IconData _iconFor(String name, bool isLink) {
  if (isLink) return Icons.link;
  final ext = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  const code = {
    'dart', 'py', 'js', 'ts', 'go', 'java', 'c', 'h', 'cpp', 'hpp', 'cc',
    'rs', 'sh', 'bash', 'zsh', 'yaml', 'yml', 'json', 'xml', 'html', 'htm',
    'css', 'scss', 'md', 'txt', 'toml', 'ini', 'conf', 'cfg', 'sql', 'log',
  };
  const image = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'ico'};
  const archive = {'zip', 'tar', 'gz', 'bz2', 'xz', '7z', 'rar'};
  if (code.contains(ext)) return Icons.code;
  if (image.contains(ext)) return Icons.image_outlined;
  if (archive.contains(ext)) return Icons.archive_outlined;
  if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
  return Icons.insert_drive_file_outlined;
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String _fmtTime(int unixSeconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000).toLocal();
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '今天 $hm';
  }
  if (t.year == now.year) return '${t.month}/${t.day} $hm';
  return '${t.year}/${t.month}/${t.day}';
}

String _fmtPerm(int mode) {
  final m = mode & 0x1FF;
  final sb = StringBuffer();
  for (var i = 8; i >= 0; i--) {
    sb.write((m & (1 << i)) != 0
        ? (i % 3 == 2 ? 'r' : i % 3 == 1 ? 'w' : 'x')
        : '-');
  }
  return sb.toString();
}
