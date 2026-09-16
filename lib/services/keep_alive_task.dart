/// 前台服务保活的回调（运行在插件创建的后台 isolate 中）。
///
/// 真实工作（SSH 连接、端口转发）运行在主 isolate；
/// 这里只需要让前台服务持续存活，保证进程不被系统回收。
@pragma('vm:entry-point')
Future<void> keepAliveTask() async {
  while (true) {
    await Future<void>.delayed(const Duration(seconds: 30));
  }
}
