import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:simple_live_account/widgets/account_labels.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';

/// Remote-friendly editor; saved credentials are never placed in this field.
class CookieImportDialog extends StatefulWidget {
  final String siteId;

  const CookieImportDialog({required this.siteId, super.key});

  @override
  State<CookieImportDialog> createState() => _CookieImportDialogState();
}

class _CookieImportDialogState extends State<CookieImportDialog> {
  final _controller = TextEditingController();
  final _inputFocus = FocusNode();
  final _visibilityFocus = AppFocusNode();
  final _clearFocus = AppFocusNode();
  final _cancelFocus = AppFocusNode();
  final _saveFocus = AppFocusNode();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    for (final node in [
      _inputFocus,
      _visibilityFocus,
      _clearFocus,
      _cancelFocus,
      _saveFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final cookie = _controller.text.trim();
    if (cookie.isEmpty) {
      setState(() => _error = '请输入 Cookie');
      _inputFocus.requestFocus();
      return;
    }
    Navigator.of(context).pop(cookie);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).cardColor,
      title: Text(
        '导入${accountPlatformName(widget.siteId)} Cookie',
        style: AppStyle.titleStyleWhite,
      ),
      content: SizedBox(
        width: 1000.w,
        child: SingleChildScrollView(
          child: FocusTraversalGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '输入完整 Cookie（名称=值; 名称=值）。按确定键打开屏幕键盘，向下键移至操作按钮。',
                  style: AppStyle.textStyleWhite,
                ),
                if (widget.siteId == 'douyin') ...[
                  AppStyle.vGap24,
                  Text(
                    '单独的 ttwid 仅用于游客设备配置，不能证明账号已登录。',
                    style: AppStyle.textStyleWhite,
                  ),
                ],
                AppStyle.vGap24,
                Focus(
                  canRequestFocus: false,
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent && _inputFocus.hasFocus) {
                      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                        _visibilityFocus.requestFocus();
                        return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.select ||
                          event.logicalKey == LogicalKeyboardKey.enter) {
                        SystemChannels.textInput.invokeMethod<void>(
                          'TextInput.show',
                        );
                        return KeyEventResult.handled;
                      }
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: _controller,
                    focusNode: _inputFocus,
                    autofocus: true,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.done,
                    style: AppStyle.textStyleWhite,
                    decoration: InputDecoration(
                      hintText: '名称=值; 名称=值',
                      hintStyle: AppStyle.textStyleWhite.copyWith(
                        color: Colors.white60,
                      ),
                      border: const OutlineInputBorder(),
                      enabledBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white54),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white, width: 3),
                      ),
                      errorText: _error,
                    ),
                    onSubmitted: (_) => _saveFocus.requestFocus(),
                  ),
                ),
                AppStyle.vGap24,
                HighlightButton(
                  focusNode: _visibilityFocus,
                  iconData: _obscure ? Icons.visibility : Icons.visibility_off,
                  text: _obscure ? '显示本次输入' : '隐藏本次输入',
                  onTap: () => setState(() => _obscure = !_obscure),
                ),
                AppStyle.vGap24,
                Text(
                  '已有凭据不会显示在此处；取消不会修改当前账号。保存后尝试验证，保存凭据不代表已登录。',
                  style: AppStyle.textStyleWhite,
                ),
                AppStyle.vGap24,
                Wrap(
                  spacing: 24.w,
                  runSpacing: 24.w,
                  children: [
                    HighlightButton(
                      focusNode: _clearFocus,
                      text: '清空输入',
                      onTap: () {
                        _controller.clear();
                        setState(() => _error = null);
                        _inputFocus.requestFocus();
                      },
                    ),
                    HighlightButton(
                      focusNode: _cancelFocus,
                      text: '取消',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    HighlightButton(
                      focusNode: _saveFocus,
                      text: '保存并验证',
                      onTap: _submit,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
