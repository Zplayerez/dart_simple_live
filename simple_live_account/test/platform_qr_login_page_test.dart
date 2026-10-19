import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_account/src/qr_login.dart';
import 'package:simple_live_account/widgets/platform_qr_login_page.dart';

class PendingSession implements QrLoginSession {
  final pending = Completer<QrLoginResult>();
  int polls = 0;
  bool closed = false;
  @override
  Future<QrLoginCode> generate() async => QrLoginCode(
    text: 'https://example.invalid/qr',
    expiresAt: DateTime.now().add(const Duration(minutes: 3)),
  );
  @override
  Future<QrLoginResult> poll() {
    polls++;
    return pending.future;
  }

  @override
  void close() => closed = true;
}

void main() {
  testWidgets(
    'phone confirmation automatically saves and shows verified identity',
    (tester) async {
      final session = PendingSession();
      var imports = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PlatformQrLoginPage(
            siteId: 'douyu',
            sessionFactory: () => session,
            importCookie: (cookie) async {
              imports++;
              expect(cookie, 'acf_auth=synthetic');
              return const PlatformAccountState(
                siteId: 'douyu',
                hasCredential: true,
                status: LiveAccountStatus.verified,
                persistence: AccountPersistence.secure,
                displayName: '测试账号',
                message: '已确认登录',
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      // A slow network request must never overlap another poll.
      await tester.pump(const Duration(seconds: 12));
      expect(session.polls, 1);
      session.pending.complete(
        const QrLoginResult(
          QrLoginStage.confirmed,
          cookie: 'acf_auth=synthetic',
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(imports, 1);
      expect(find.text('已验证登录 · 测试账号'), findsOneWidget);
      expect(find.textContaining('synthetic'), findsNothing);
      expect(session.closed, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('refresh discards authorization from the previous QR session', (
    tester,
  ) async {
    final old = PendingSession();
    final fresh = PendingSession();
    var generations = 0;
    var imports = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlatformQrLoginPage(
          siteId: 'huya',
          sessionFactory: () => generations++ == 0 ? old : fresh,
          importCookie: (_) async {
            imports++;
            return const PlatformAccountState(siteId: 'huya');
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('刷新二维码'));
    await tester.pump();
    old.pending.complete(
      const QrLoginResult(QrLoginStage.confirmed, cookie: 'udb_biztoken=old'),
    );
    await tester.pump();
    expect(imports, 0);
    expect(old.closed, isTrue);
    expect(fresh.closed, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(fresh.closed, isTrue);
  });

  testWidgets('closing login discards a pending successful response', (
    tester,
  ) async {
    final session = PendingSession();
    var imports = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlatformQrLoginPage(
          siteId: 'douyu',
          sessionFactory: () => session,
          importCookie: (_) async {
            imports++;
            return const PlatformAccountState(siteId: 'douyu');
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    session.pending.complete(
      const QrLoginResult(QrLoginStage.confirmed, cookie: 'acf_auth=late'),
    );
    await tester.pump();
    expect(imports, 0);
    expect(session.closed, isTrue);
  });

  testWidgets('unavailable account validation is not displayed as logged in', (
    tester,
  ) async {
    final session = PendingSession();
    await tester.pumpWidget(
      MaterialApp(
        home: PlatformQrLoginPage(
          siteId: 'douyu',
          sessionFactory: () => session,
          importCookie: (_) async => const PlatformAccountState(
            siteId: 'douyu',
            hasCredential: true,
            status: LiveAccountStatus.unavailable,
            message: '平台验证暂不可用',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    session.pending.complete(
      const QrLoginResult(QrLoginStage.confirmed, cookie: 'acf_auth=fixture'),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining('已验证登录'), findsNothing);
    expect(find.text('暂时无法验证'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
