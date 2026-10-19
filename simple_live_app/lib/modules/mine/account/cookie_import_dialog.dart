import 'package:flutter/material.dart';
import 'package:simple_live_account/widgets/account_labels.dart';

/// Stored credentials are never loaded into this editor.
class CookieImportDialog extends StatefulWidget {
  final String siteId;

  const CookieImportDialog({required this.siteId, super.key});

  @override
  State<CookieImportDialog> createState() => _CookieImportDialogState();
}

class _CookieImportDialogState extends State<CookieImportDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final cookie = _controller.text.trim();
    if (cookie.isEmpty) {
      setState(() => _error = '请输入 Cookie');
      return;
    }
    Navigator.of(context).pop(cookie);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('导入${accountPlatformName(widget.siteId)} Cookie'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('粘贴完整 Cookie（名称=值; 名称=值）。保存后尝试验证；保存凭据不代表已登录。'),
              if (widget.siteId == 'douyin')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('单独的 ttwid 仅用于游客设备配置，不能证明账号已登录。'),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                autofocus: true,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: '完整 Cookie',
                  hintText: '名称=值; 名称=值',
                  border: const OutlineInputBorder(),
                  errorText: _error,
                  suffixIcon: IconButton(
                    tooltip: _obscure ? '显示本次输入' : '隐藏本次输入',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              const Text('已有凭据不会显示在此处；取消不会修改当前账号。'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _controller.clear();
            setState(() => _error = null);
          },
          child: const Text('清空输入'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('保存并验证')),
      ],
    );
  }
}
