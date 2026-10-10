import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_account/simple_live_account.dart';

import 'account_labels.dart';

typedef StartAccountPairing =
    Future<AccountPairingReceiver> Function(
      Future<bool> Function() confirm,
      ValueChanged<String> onStatus,
    );

class AccountReceivePage extends StatefulWidget {
  const AccountReceivePage({
    required this.siteId,
    required this.onStart,
    required this.onCancel,
    super.key,
  });
  final String siteId;
  final StartAccountPairing onStart;
  final VoidCallback onCancel;

  @override
  State<AccountReceivePage> createState() => _AccountReceivePageState();
}

class _AccountReceivePageState extends State<AccountReceivePage> {
  AccountPairingReceiver? _receiver;
  Timer? _timer;
  String _status = '正在准备配对';
  int _seconds = 0;
  bool _starting = false;
  int _generation = 0;
  DialogRoute<bool>? _confirmation;

  bool _isCurrent(int generation) => mounted && generation == _generation;

  void _dismissConfirmation() {
    final route = _confirmation;
    _confirmation = null;
    if (route == null) return;
    // Route disposal can run while Navigator is updating its history.
    scheduleMicrotask(() {
      final navigator = route.navigator;
      if (navigator != null && navigator.mounted && route.isActive) {
        navigator.removeRoute(route, false);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_start());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final receiver = _receiver;
      if (!mounted || receiver == null) return;
      final remaining = receiver.expiresAt.difference(DateTime.now()).inSeconds;
      if (remaining <= 0) _dismissConfirmation();
      setState(() {
        _seconds = remaining > 0 ? remaining : 0;
        if (_seconds == 0 && !receiver.isConsumed) _status = '配对已过期，请重新生成';
      });
    });
  }

  Future<bool> _confirm(int generation) async {
    if (!_isCurrent(generation)) return false;
    final route = DialogRoute<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('接收账号'),
        content: Text('是否将收到的${accountPlatformName(widget.siteId)}账号用于本机？'),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('接收'),
          ),
        ],
      ),
    );
    _confirmation = route;
    final accepted = await Navigator.of(
      context,
      rootNavigator: true,
    ).push(route);
    if (identical(_confirmation, route)) _confirmation = null;
    return _isCurrent(generation) && accepted == true;
  }

  Future<void> _start() async {
    if (_starting || !mounted) return;
    final generation = ++_generation;
    _receiver?.close();
    _dismissConfirmation();
    widget.onCancel();
    setState(() {
      _starting = true;
      _receiver = null;
      _status = '正在准备配对';
    });
    try {
      final receiver = await widget.onStart(() => _confirm(generation), (
        status,
      ) {
        if (_isCurrent(generation)) setState(() => _status = status);
      });
      if (!_isCurrent(generation)) {
        receiver.close();
        return;
      }
      setState(() {
        _receiver = receiver;
        _seconds = 120;
        _status = '等待另一台设备扫描';
      });
    } catch (_) {
      if (_isCurrent(generation))
        setState(() => _status = '无法创建配对，请确认本机已连接局域网');
    } finally {
      if (_isCurrent(generation)) setState(() => _starting = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    _timer?.cancel();
    _receiver?.close();
    _dismissConfirmation();
    widget.onCancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final receiver = _receiver;
    final usable =
        receiver != null &&
        !receiver.isClosed &&
        !receiver.isConsumed &&
        _seconds > 0;
    return Scaffold(
      appBar: AppBar(title: Text('接收${accountPlatformName(widget.siteId)}账号')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '在已登录的 Simple Live 中打开该平台账号，选择“发送到其他设备”，扫描此二维码。两台设备需连接同一局域网。',
                ),
                const SizedBox(height: 16),
                if (usable)
                  QrImageView(
                    data: receiver.qrPayload,
                    size: 240,
                    backgroundColor: Colors.white,
                  )
                else if (_starting)
                  const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(_status, textAlign: TextAlign.center),
                if (usable) Text('$_seconds 秒内有效，仅可接收一次'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      autofocus: true,
                      onPressed: _starting ? null : _start,
                      child: const Text('重新生成'),
                    ),
                    OutlinedButton(
                      onPressed: usable
                          ? () async {
                              await Clipboard.setData(
                                ClipboardData(text: receiver.qrPayload),
                              );
                              if (mounted)
                                setState(() => _status = '配对信息已复制，请在发送设备粘贴');
                            }
                          : null,
                      child: const Text('复制配对信息'),
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

class AccountSendPage extends StatefulWidget {
  const AccountSendPage({required this.siteId, this.scan, super.key});
  final String siteId;
  final Future<String?> Function()? scan;
  @override
  State<AccountSendPage> createState() => _AccountSendPageState();
}

class _AccountSendPageState extends State<AccountSendPage> {
  final _invitation = TextEditingController();
  HttpClient? _client;
  bool _sending = false;
  int _generation = 0;
  String _status = '请在接收设备打开同一平台账号，选择“从其他设备接收”。';

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _send() async {
    if (_sending || !mounted) return;
    final generation = ++_generation;
    HttpClient? client;
    setState(() {
      _sending = true;
      _status = '正在加密发送，请在接收端确认';
    });
    try {
      final invitation = AccountPairingInvitation.parse(
        _invitation.text.trim(),
      );
      if (invitation.siteId != widget.siteId)
        throw const FormatException('平台不匹配');
      final manager = PlatformAccountManager.instance;
      final revision = manager.account(widget.siteId).revision;
      final cookie = manager.credentialFor(widget.siteId);
      if (cookie.isEmpty) throw const FormatException('请先配置账号');
      final body = await invitation.encryptCookie(cookie);
      if (!_isCurrent(generation)) return;
      if (manager.account(widget.siteId).revision != revision) {
        throw StateError('发送账号已变化，请重新配对');
      }
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      _client = client;
      final request = await client.postUrl(invitation.receiverUri);
      if (!_isCurrent(generation) ||
          manager.account(widget.siteId).revision != revision) {
        request.abort();
        return;
      }
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.contentLength = utf8.encode(body).length;
      request.write(body);
      final response = await request.close().timeout(
        const Duration(seconds: 90),
      );
      if (response.statusCode != 200) throw const FormatException();
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        if (bytes.length + chunk.length > 8192) throw const FormatException();
        bytes.addAll(chunk);
      }
      final result = await invitation.decryptReply(utf8.decode(bytes));
      if (result['status'] != true) {
        if (_isCurrent(generation))
          setState(() => _status = result['message'] as String);
        return;
      }
      if (_isCurrent(generation))
        setState(() {
          _invitation.clear();
          _status = '接收端已接收账号凭据。\n${result['message']}';
        });
    } catch (_) {
      if (_isCurrent(generation))
        setState(() => _status = '未能确认接收结果，请在接收设备查看账号状态；需要重试时请重新配对。');
    } finally {
      client?.close(force: true);
      if (identical(_client, client)) _client = null;
      if (_isCurrent(generation)) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    _client?.close(force: true);
    _invitation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('发送${accountPlatformName(widget.siteId)}账号')),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_status),
              const SizedBox(height: 16),
              TextField(
                controller: _invitation,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                enabled: !_sending,
                decoration: const InputDecoration(
                  labelText: '接收端的配对信息',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (widget.scan != null)
                    OutlinedButton(
                      onPressed: _sending
                          ? null
                          : () async {
                              final text = await widget.scan!();
                              if (mounted && !_sending && text != null)
                                _invitation.text = text;
                            },
                      child: const Text('扫描接收端二维码'),
                    ),
                  FilledButton(
                    autofocus: true,
                    onPressed: _sending ? null : _send,
                    child: Text(_sending ? '等待接收端确认…' : '加密发送'),
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
