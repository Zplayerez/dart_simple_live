import 'package:simple_live_core/simple_live_core.dart';

enum AccountPersistence { none, secure, sessionOnly }

/// Display metadata only. Credentials are deliberately absent from this model.
class PlatformAccountState {
  const PlatformAccountState({
    required this.siteId,
    this.status = LiveAccountStatus.signedOut,
    this.persistence = AccountPersistence.none,
    this.message = '未登录',
    this.storageMessage,
    this.displayName,
    this.avatarUrl,
    this.userId,
    this.playbackCapability,
    this.revision = 0,
    this.checkedAt,
    this.hasCredential = false,
  });

  final String siteId;
  final LiveAccountStatus status;
  final AccountPersistence persistence;
  final String message;
  final String? storageMessage;
  final String? displayName;
  final String? avatarUrl;
  final String? userId;
  final String? playbackCapability;
  final int revision;
  final DateTime? checkedAt;
  final bool hasCredential;

  PlatformAccountState copyWith({
    LiveAccountStatus? status,
    AccountPersistence? persistence,
    String? message,
    String? storageMessage,
    bool clearStorageMessage = false,
    String? displayName,
    String? avatarUrl,
    String? userId,
    String? playbackCapability,
    bool clearIdentity = false,
    bool? hasCredential,
    DateTime? checkedAt,
  }) => PlatformAccountState(
    siteId: siteId,
    status: status ?? this.status,
    persistence: persistence ?? this.persistence,
    message: message ?? this.message,
    storageMessage: clearStorageMessage
        ? null
        : storageMessage ?? this.storageMessage,
    displayName: clearIdentity ? null : displayName ?? this.displayName,
    avatarUrl: clearIdentity ? null : avatarUrl ?? this.avatarUrl,
    userId: clearIdentity ? null : userId ?? this.userId,
    playbackCapability: clearIdentity
        ? null
        : playbackCapability ?? this.playbackCapability,
    revision: revision,
    checkedAt: checkedAt ?? this.checkedAt,
    hasCredential: hasCredential ?? this.hasCredential,
  );

  @override
  String toString() => 'PlatformAccountState($siteId, $status, $persistence)';
}
