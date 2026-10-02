import 'package:simple_live_account/simple_live_account.dart';

const accountPlatformIds = ['bilibili', 'douyu', 'huya', 'douyin'];

String accountPlatformName(String siteId) => switch (siteId) {
  'bilibili' => '哔哩哔哩',
  'douyu' => '斗鱼直播',
  'huya' => '虎牙直播',
  'douyin' => '抖音直播',
  _ => siteId,
};

String accountStatusLabel(LiveAccountStatus status) => switch (status) {
  LiveAccountStatus.signedOut => '未登录',
  LiveAccountStatus.configured => '已配置待验证',
  LiveAccountStatus.verifying => '验证中',
  LiveAccountStatus.verified => '已验证登录',
  LiveAccountStatus.expired => '登录失效',
  LiveAccountStatus.unavailable => '暂时无法验证',
};

String accountSummary(PlatformAccountState state) {
  final parts = [accountStatusLabel(state.status)];
  if (state.status == LiveAccountStatus.verified &&
      (state.displayName?.isNotEmpty ?? false)) {
    parts.add(state.displayName!);
  }
  if (state.persistence == AccountPersistence.sessionOnly) {
    parts.add('仅本次会话');
  }
  return parts.join(' · ');
}

String accountDetails(PlatformAccountState state) {
  final parts = <String>[];
  if (state.message.isNotEmpty) parts.add(state.message);
  if (state.playbackCapability?.isNotEmpty ?? false) {
    parts.add('播放能力：${state.playbackCapability}');
  }
  if (state.storageMessage?.isNotEmpty ?? false) {
    parts.add(state.storageMessage!);
  } else if (state.persistence == AccountPersistence.sessionOnly) {
    parts.add('安全存储不可用，凭据仅在本次运行中使用，退出应用后需重新导入。');
  }
  if (state.checkedAt != null) {
    final time = state.checkedAt!.toLocal();
    final minute = time.minute.toString().padLeft(2, '0');
    parts.add('上次验证：${time.month}/${time.day} ${time.hour}:$minute');
  }
  return parts.join('\n');
}

String accountResultMessage(PlatformAccountState state) {
  final detail = state.message.isEmpty ? '' : '\n${state.message}';
  return '${accountSummary(state)}$detail';
}
