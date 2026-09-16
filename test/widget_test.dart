import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sshagent/ui/home_page.dart';

void main() {
  testWidgets('HomePage renders empty state', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    // Tab 栏已并入 AppBar 单行（标题行即标签行），不再有独立标题
    expect(find.text('服务器'), findsOneWidget);
    expect(find.text('隧道'), findsOneWidget);
    expect(find.text('网页'), findsOneWidget);
    expect(find.text('终端'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);
    expect(find.textContaining('还没有服务器'), findsOneWidget);
  });
}
