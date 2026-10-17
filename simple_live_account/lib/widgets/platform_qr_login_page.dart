import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../simple_live_account.dart';
import '../src/qr_login.dart';
import 'account_labels.dart';

class PlatformQrLoginPage extends StatefulWidget {
  const PlatformQrLoginPage({
    required this.siteId,
    this.onWebLogin,
    this.sessionFactory,
    this.importCookie,
    super.key,
  });
  final String siteId;
  final VoidCallback? onWebLogin;
  final QrLoginSession Function()? sessionFactory;
  final Future<PlatformAccountState> Function(String cookie)? importCookie;

  @override
  State<PlatformQrLoginPage> createState() => _PlatformQrLoginPageState();
}

class _PlatformQrLoginPageState extends State<PlatformQrLoginPage> {
  QrLoginSession? _session;
  QrLoginCode? _code;
  Timer? _pollTimer;
  Timer? _expiryTimer;
  int _generation = 0;
  bool _loading = true;
  bool _saving = false;
  bool _scanned = false;
  String? _error;
  PlatformAccountState? _result;

  bool _current(int generation) => mounted && generation == _generation;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  void _stop() {
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    _session?.close();
    _session = null;
  }

  Future<void> _generate() async {
    if (_saving) return;
    final generation = ++_generation;
    _stop();
    setState(() {
      _loading = true;
      _code = null;
      _error = null;
      _result = null;
      _scanned = false;
    });
    try {
      final session =
          widget.sessionFactory?.call() ??
          OfficialQrLoginSession(widget.siteId);
      _session = session;
      final code = await session.generate();
      if (!_current(generation)) return;
      setState(() {
        _code = code;
        _loading = false;
      });
      _expiryTimer = Timer(code.expiresAt.difference(DateTime.now()), () {
        if (_current(generation) && !_saving) _fail('二维码已过期，请刷新后重新扫码');
      });
      _schedulePoll(generation, session);
    } catch (error) {
      if (_current(generation))
        _fail(error is QrLoginException ? error.message : '无法获取登录二维码，请重试');
    }
  }

  void _schedulePoll(int generation, QrLoginSession session) {
    _pollTimer = Timer(
      const Duration(seconds: 3),
      () => _poll(generation, session),
    );
  }

  Future<void> _poll(int generation, QrLoginSession session) async {
    if (!_current(generation)) return;
    try {
      final result = await session.poll();
      if (!_current(generation)) return;
      switch (result.stage) {
        case QrLoginStage.waiting:
          break;
        case QrLoginStage.scanned:
          setState(() => _scanned = true);
        case QrLoginStage.expired:
          _fail('二维码已过期，请刷新后重新扫码');
          return;
        case QrLoginStage.cancelled:
          _fail('已取消手机授权，可以刷新二维码重试');
          return;
        case QrLoginStage.confirmed:
          _expiryTimer?.cancel();
          if (result.cookie == null || result.cookie!.isEmpty) {
            _fail('未收到登录信息，请重新扫码');
            return;
          }
          setState(() {
            _saving = true;
            _code = null;
          });
          final state =
              await (widget.importCookie?.call(result.cookie!) ??
                  PlatformAccountManager.instance.importCookie(
                    widget.siteId,
                    result.cookie!,
                  ));
          if (!_current(generation)) return;
          _stop();
          setState(() {
            _saving = false;
            _result = state;
          });
          return;
      }
      _schedulePoll(generation, session);
    } catch (error) {
      if (_current(generation))
        _fail(error is QrLoginException ? error.message : '扫码登录未完成，请重试');
    }
  }

  void _fail(String message) {
    ++_generation;
    _stop();
    setState(() {
      _loading = false;
      _saving = false;
      _code = null;
      _error = message;
    });
  }

  @override
  void dispose() {
    ++_generation;
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = accountPlatformName(widget.siteId);
    return Scaffold(
      appBar: AppBar(title: Text('$name扫码登录')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_loading || _saving) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Text(_saving ? '正在保存并验证登录状态…' : '正在获取二维码…'),
                ] else if (_result != null) ...[
                  Icon(
                    _result!.status == LiveAccountStatus.verified
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    size: 56,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    accountSummary(_result!),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(accountDetails(_result!), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  FilledButton(
                    autofocus: true,
                    onPressed: () => Navigator.of(context).pop(_result),
                    child: const Text('返回账号管理'),
                  ),
                ] else ...[
                  if (_code != null) ...[
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: _code!.image != null
                          ? Image.memory(
                              _code!.image!,
                              width: 240,
                              height: 240,
                              errorBuilder: (_, __, ___) => const SizedBox(
                                width: 240,
                                height: 240,
                                child: Center(
                                  child: Text(
                                    '二维码图片无效，请刷新',
                                    style: TextStyle(color: Colors.black),
                                  ),
                                ),
                              ),
                            )
                          : QrImageView(
                              data: _code!.text!,
                              size: 240,
                              backgroundColor: Colors.white,
                            ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _scanned ? '扫描成功，请在手机上确认登录' : '使用$name App 的扫一扫扫描二维码',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text('手机确认后自动保存并验证账号', textAlign: TextAlign.center),
                  ],
                  if (_error != null) ...[
                    const Icon(Icons.info_outline, size: 48),
                    const SizedBox(height: 16),
                    Text(_error!, textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    autofocus: true,
                    onPressed: _generate,
                    child: const Text('刷新二维码'),
                  ),
                  if (_error != null && widget.onWebLogin != null)
                    TextButton(
                      onPressed: widget.onWebLogin,
                      child: const Text('使用网页登录'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
