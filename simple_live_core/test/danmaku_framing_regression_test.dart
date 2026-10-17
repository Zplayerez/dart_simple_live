import 'dart:convert';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:test/test.dart';

void main() {
  List<int> chat(DouyuDanmaku decoder, String text) => decoder.serializeDouyu(
    'type@=chatmsg/dms@=1/nn@=fixture/txt@=$text/col@=0/',
  );

  test('Douyu emits every concatenated packet and assembles split UTF-8', () {
    final decoder = DouyuDanmaku();
    final received = <String>[];
    decoder.onMessage = (message) => received.add(message.message);
    final bytes = [...chat(decoder, '第一条'), ...chat(decoder, '第二条')];
    for (var i = 0; i < bytes.length; i += 3) {
      decoder.decodeMessage(bytes.sublist(i, (i + 3).clamp(0, bytes.length)));
    }
    expect(received, ['第一条', '第二条']);
    decoder.decodeMessage([
      ...chat(decoder, 'third'),
      ...chat(decoder, 'fourth'),
    ]);
    expect(received, ['第一条', '第二条', 'third', 'fourth']);
  });

  test('Douyu skips invalid lengths and recovers at the next valid packet', () {
    final decoder = DouyuDanmaku();
    final received = <String>[];
    decoder.onMessage = (message) => received.add(message.message);
    for (final length in [-1800345950, 1701732729, 8]) {
      final header = ByteData(12)
        ..setInt32(0, length, Endian.little)
        ..setInt32(4, length, Endian.little)
        ..setUint16(8, 690, Endian.little);
      decoder.decodeMessage([
        ...header.buffer.asUint8List(),
        ...chat(decoder, 'ok'),
      ]);
    }
    final mismatched = chat(decoder, 'discard')..[4] = 0;
    final unterminated = chat(decoder, 'discard')..last = 1;
    decoder.decodeMessage([
      ...mismatched,
      ...unterminated,
      ...chat(decoder, 'last'),
    ]);
    expect(received, ['ok', 'ok', 'ok', 'last']);
  });

  test('bad text cannot discard the next Douyu chat packet', () {
    final decoder = DouyuDanmaku();
    final received = <String>[];
    decoder.onMessage = (message) => received.add(message.message);
    final broken = chat(decoder, 'BAD');
    final textStart =
        utf8.decode(broken.sublist(12, broken.length - 1)).indexOf('BAD') + 12;
    broken[textStart] = 0xff;
    decoder.decodeMessage([...broken, ...chat(decoder, 'intact')]);
    expect(received, ['\uFFFDAD', 'intact']);
  });

  test(
    'Huya replaces invalid chat text without weakening other Tars reads',
    () {
      final nickname = Uint8List.fromList([0x26, 3, 0xff, 65, 66]);
      expect(
        () => TarsInputStream(nickname).readString(2, true),
        throwsFormatException,
      );
      final message = Uint8List.fromList([
        0x0a, ...nickname, 0x0b, // sender struct, then message content
        0x36, 2, 111, 107,
      ]);
      final push = TarsOutputStream()
        ..write(0, 0)
        ..write(1400, 1)
        ..write(message, 2)
        ..write(0, 3);
      final command = TarsOutputStream()
        ..write(7, 0)
        ..write(push.toUint8List(), 1);
      final decoder = HuyaDanmaku();
      final received = <LiveMessage>[];
      decoder.onMessage = received.add;
      decoder.decodeMessage(command.toUint8List());
      expect(received, hasLength(1));
      expect(received.single.userName, '\uFFFDAB');
      expect(received.single.message, 'ok');
    },
  );
}
