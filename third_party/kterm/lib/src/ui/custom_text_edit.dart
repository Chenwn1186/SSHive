import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// PATCH (ssh_agent): 输入链路调试日志——写入临时目录文件，
// 与应用的 TermDebug 共用同一文件（ssh_agent_term.log）。
void _debugLog(String msg) {
  try {
    final f = File('${Directory.systemTemp.path}/ssh_agent_term.log');
    f.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] [kterm] $msg\n',
        mode: FileMode.append);
  } catch (_) {}
}

class CustomTextEdit extends StatefulWidget {
  const CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
  });

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection {
    final conn = _connection;
    return conn != null && conn.attached;
  }

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }

    _connection?.setEditableSizeAndTransform(
      rect.size,
      Matrix4.translationValues(0, 0, 0),
    );

    _connection?.setCaretRect(caretRect);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    // PATCH (ssh_agent): 键盘事件到达时若输入连接尚未建立则立即补建，
    // 避免因 token 时序问题导致按键全部丢失。
    _debugLog('_onKeyEvent ${event.runtimeType} '
        'logical=${event.logicalKey.keyLabel} '
        'char="${event.character}" '
        'conn=${hasInputConnection} focus=${widget.focusNode.hasFocus} '
        'composing=${_currentEditingState.composing}');
    if (!hasInputConnection && widget.focusNode.hasFocus) {
      _openInputConnection();
    }
    if (_currentEditingState.composing.isCollapsed) {
      final r = widget.onKeyEvent(focusNode, event);
      _debugLog('_onKeyEvent -> $r');
      return r;
    }

    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    // PATCH (ssh_agent): 不再依赖一次性 keyboard token —— 桌面平台
    // （尤其 Windows）焦点经 Tab 切换/点击获得时常常拿不到 token，
    // 导致 TextInput 连接永不建立、字母数字按键全部丢失。
    // 只要节点持有焦点就建立输入连接。
    _debugLog('_openOrClose: focus=${widget.focusNode.hasFocus} '
        'conn=${hasInputConnection}');
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      _debugLog('_openInputConnection SKIPPED (readOnly/web)');
      return;
    }

    if (hasInputConnection) {
      _debugLog('_openInputConnection already attached, show()');
      _connection!.show();
    } else {
      final config = TextInputConfiguration(
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      );

      final conn = TextInput.attach(this, config);
      _connection = conn;
      conn.show();
      conn.setEditingState(_initEditingState);
      _debugLog('_openInputConnection ATTACHED type=${widget.inputType}');
    }
  }

  void _closeInputConnectionIfNeeded() {
    final conn = _connection;
    if (conn != null && conn.attached) {
      conn.close();
      _connection = null;
      _debugLog('_closeInputConnection closed');
    }
  }

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    _currentEditingState = value;
    _debugLog('updateEditingValue text="${value.text}" '
        'composing=${value.composing} '
        'initLen=${_initEditingState.text.length}');

    // Get input after composing is done
    if (!_currentEditingState.composing.isCollapsed) {
      final text = _currentEditingState.text;
      final composingText = _currentEditingState.composing.textInside(text);
      widget.onComposing(composingText);
      return;
    }

    widget.onComposing(null);

    if (_currentEditingState.text.length < _initEditingState.text.length) {
      widget.onDelete();
    } else {
      final textDelta = _currentEditingState.text.substring(
        _initEditingState.text.length,
      );
      _debugLog('updateEditingValue DELTA="${textDelta}"');
      widget.onInsert(textDelta);
    }

    // Reset editing state if composing is done
    if (_currentEditingState.composing.isCollapsed &&
        _currentEditingState.text != _initEditingState.text) {
      _connection?.setEditingState(_initEditingState);
    }
  }

  @override
  void performAction(TextInputAction action) {
    widget.onAction(action);
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _debugLog('connectionClosed');
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}
}
