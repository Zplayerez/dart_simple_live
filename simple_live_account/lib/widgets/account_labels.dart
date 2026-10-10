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
  LiveAccountStatus.configured => '待验证',
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
  } else if (state.hasCredential) {
    parts.add('可用画质以直播间实际返回为准。');
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

String accountNextStep(PlatformAccountState state) => switch (state.status) {
  LiveAccountStatus.signedOut => '登录后可使用平台允许的账号观看权限',
  LiveAccountStatus.configured => '点击“重新验证”，向平台确认登录是否有效',
  LiveAccountStatus.verifying => '正在检查登录状态，请稍候',
  LiveAccountStatus.verified => '账号验证通过，可进入直播间选择画质',
  LiveAccountStatus.expired => '请重新登录，完成后可继续观看当前直播间',
  LiveAccountStatus.unavailable => '请查看失败原因，稍后点击“重新验证”；登录信息已保留',
};

String accountResultMessage(PlatformAccountState state) {
  final detail = state.message.isEmpty ? '' : '\n${state.message}';
  return '${accountSummary(state)}$detail';
}
