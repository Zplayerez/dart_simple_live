import 'dart:async';
import 'dart:convert';

import 'account_pairing.dart';
import 'platform_account_manager.dart';

/// Transient receive state shared by App and TV. The HTTP adapter must reject
/// oversized requests before buffering and must never log their body.
class AccountPairingHost {
  AccountPairingHost(this.manager);
  final PlatformAccountManager manager;
  AccountPairingReceiver? _receiver;
  Future<bool> Function()? _confirm;
  void Function(String)? _onStatus;
  AccountPairingReceiver? _receivingFor;
  Completer<void>? _cancelled;

  AccountPairingReceiver start(
    Uri address,
    String siteId, {
    required Future<bool> Function() confirm,
    required void Function(String) onStatus,
  }) {
    cancel();
    final receiver = AccountPairingReceiver.create(
      receiverUri: address,
      siteId: siteId,
    );
    _receiver = receiver;
    _confirm = confirm;
    _onStatus = onStatus;
    _cancelled = Completer<void>();
    return receiver;
  }

  void cancel() {
    _receiver?.close();
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    _receiver = null;
    _confirm = null;
    _onStatus = null;
    _cancelled = null;
    _receivingFor = null;
  }

  Future<Map<String, dynamic>> receive(String body) async {
    final receiver = _receiver;
    final confirm = _confirm;
    final onStatus = _onStatus;
    final cancelled = _cancelled;
    if (receiver == null ||
        confirm == null ||
        cancelled == null ||
        _receivingFor != null ||
        utf8.encode(body).length > accountPairingMaxPayloadBytes) {
      return {'status': false, 'message': '配对不可用，请重新扫码'};
    }
    _receivingFor = receiver;
    var authenticated = false;
    void emit(String message) {
      if (identical(receiver, _receiver) && !receiver.isClosed) {
        onStatus?.call(message);
      }
    }

    try {
      final credential = await receiver.decrypt(body);
      authenticated = true;
      if (!identical(receiver, _receiver) || receiver.isClosed) {
        return _reply(receiver, false, '配对已取消');
      }
      emit('已收到加密凭据，等待本机确认');
      final remaining = receiver.expiresAt.difference(DateTime.now());
      final accepted =
          remaining > Duration.zero &&
          await Future.any<bool>([
            confirm(),
            cancelled.future.then((_) => false),
          ]).timeout(remaining, onTimeout: () => false);
      if (!accepted ||
          !identical(receiver, _receiver) ||
          receiver.isClosed ||
          !DateTime.now().isBefore(receiver.expiresAt)) {
        emit('未导入账号，请重新发起配对');
        return _reply(receiver, false, '接收端未确认或配对已失效');
      }
      final state = await manager.importCookie(
        receiver.invitation.siteId,
        credential,
      );
      final message = state.storageMessage == null
          ? state.message
          : '${state.message}；${state.storageMessage}';
      emit(message);
      return _reply(receiver, true, message);
    } catch (_) {
      emit('配对验证失败或已失效，请重新扫码');
      if (authenticated) {
        return _reply(receiver, false, '账号未能导入，请在接收端查看状态');
      }
      return {'status': false, 'message': '配对验证失败，请重新扫码'};
    } finally {
      if (identical(_receivingFor, receiver)) _receivingFor = null;
    }
  }

  Future<Map<String, dynamic>> _reply(
    AccountPairingReceiver receiver,
    bool status,
    String message,
  ) async {
    final envelope = await receiver.encryptReply({
      'status': status,
      'message': message,
    });
    return (jsonDecode(envelope) as Map).cast<String, dynamic>();
  }
}
