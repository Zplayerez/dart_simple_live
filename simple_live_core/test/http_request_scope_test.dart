import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

class _Adapter implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  final starts = <String, Completer<void>>{};
  Future<void> started(String path) => starts
      .putIfAbsent(path, Completer<void>.new)
      .future
      .timeout(const Duration(seconds: 2));
  final cancelled = <String>[];
  final gates = <String, Completer<ResponseBody>>{};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) {
    calls.add(options);
    starts.putIfAbsent(options.path, Completer<void>.new).complete();
    cancelFuture?.then((_) => cancelled.add(options.path));
    return gates.putIfAbsent(options.path, Completer<ResponseBody>.new).future;
  }

  @override
  void close({bool force = false}) {}

  void finish(String path) =>
      gates[path]!.complete(ResponseBody.fromString('ok', 200));
}

void main() {
  late Dio previous;
  late _Adapter adapter;
  setUp(() {
    previous = HttpClient.instance.dio;
    adapter = _Adapter();
    HttpClient.instance.dio = Dio()..httpClientAdapter = adapter;
  });
  tearDown(() {
    HttpClient.instance.dio.close(force: true);
    HttpClient.instance.dio = previous;
  });
  const a = 'https://fixture.invalid/a';
  const b = 'https://fixture.invalid/b';
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test(
    'deadline cancels underlying I/O and prevents fallback requests',
    () async {
      final scope = HttpRequestScope(timeout: const Duration(milliseconds: 40));
      var fallbackBlocked = false;
      final task = scope.run(() async {
        try {
          await HttpClient.instance.getText(a);
        } catch (_) {
          try {
            await HttpClient.instance.getText(b);
          } catch (_) {
            fallbackBlocked = true;
          }
        }
      });
      await expectLater(task, throwsA(isA<TimeoutException>()));
      await flush();
      expect(adapter.cancelled, contains(a));
      expect(adapter.calls.map((o) => o.path), [a]);
      expect(fallbackBlocked, isTrue);
    },
  );

  test('closing one room cancels only its operation', () async {
    final scope = HttpRequestScope();
    final cancelled = scope.run(() => HttpClient.instance.getText(a));
    final expected = expectLater(
      cancelled,
      throwsA(isA<HttpRequestCancelled>()),
    );
    final unrelated = HttpClient.instance.getText(b);
    await adapter.started(a);
    await adapter.started(b);
    scope.cancel();
    await expected;
    adapter.finish(b);
    expect(await unrelated, 'ok');
    expect(adapter.cancelled, contains(a));
    expect(adapter.cancelled, isNot(contains(b)));
  });

  test('caller cancellation is preserved inside an operation', () async {
    final caller = CancelToken();
    final scope = HttpRequestScope();
    final task = scope.run(
      () => HttpClient.instance.getText(a, cancel: caller),
    );
    final expected = expectLater(task, throwsA(anything));
    await adapter.started(a);
    caller.cancel('synthetic-cancel');
    await expected;
    expect(adapter.cancelled, contains(a));
  });

  test('a child deadline does not cancel a valid parent alternative', () async {
    final task = HttpRequestScope().run(() async {
      await expectLater(
        HttpRequestScope(
          timeout: const Duration(milliseconds: 30),
        ).run(() => HttpClient.instance.getText(a)),
        throwsA(isA<TimeoutException>()),
      );
      final good = HttpClient.instance.getText(b);
      await adapter.started(b);
      adapter.finish(b);
      return good;
    });
    expect(await task, 'ok');
    expect(adapter.cancelled, contains(a));
  });

  test('parent cancellation also stops nested requests', () async {
    final parent = HttpRequestScope();
    final task = parent.run(
      () => HttpRequestScope().run(() => HttpClient.instance.getText(a)),
    );
    final expected = expectLater(task, throwsA(isA<HttpRequestCancelled>()));
    await adapter.started(a);
    parent.cancel();
    await expected;
    await flush();
    expect(adapter.cancelled, contains(a));
  });

  test('a completed operation cannot start delayed HTTP work', () async {
    final gate = Completer<void>();
    late Future<void> lateTask;
    var blocked = false;
    await HttpRequestScope().run(() async {
      lateTask = gate.future.then((_) async {
        try {
          await HttpClient.instance.getText(a);
        } on HttpRequestCancelled {
          blocked = true;
        }
      });
    });
    gate.complete();
    await lateTask;
    expect(blocked, isTrue);
    expect(adapter.calls, isEmpty);
  });

  test(
    'deadline covers sequential provider calls, not each HTTP call',
    () async {
      final scope = HttpRequestScope(timeout: const Duration(milliseconds: 60));
      final task = scope.run(() async {
        await HttpClient.instance.getText(a);
        return HttpClient.instance.getText(b);
      });
      final expected = expectLater(task, throwsA(isA<TimeoutException>()));
      await adapter.started(a);
      adapter.finish(a);
      await expected;
      await flush();
      expect(adapter.calls, hasLength(2));
      expect(adapter.cancelled, contains(b));
    },
  );
  test(
    'a cancelled response cannot rotate the saved account session',
    () async {
      final site = DouyinSite()
        ..cookie = 'sessionid=synthetic-login; ttwid=before';
      final headers = await site.getRequestHeaders();
      const url = 'https://live.douyin.com/fixture';
      final scope = HttpRequestScope();
      final task = scope.run(
        () => HttpClient.instance.getText(url, header: headers),
      );
      final assertion = expectLater(task, throwsA(isA<HttpRequestCancelled>()));
      await adapter.started(url);
      scope.cancel();
      await assertion;
      adapter.gates[url]!.complete(
        ResponseBody.fromString(
          'ok',
          200,
          headers: {
            'set-cookie': ['ttwid=after; Domain=.douyin.com; Path=/; Secure'],
          },
        ),
      );
      await flush();
      expect(site.accountSession!.cookie.values['ttwid'], 'before');
    },
  );
}
