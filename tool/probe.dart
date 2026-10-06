// ignore_for_file: avoid_print
// Diagnostic: reproduce the APP's exact connect path — IOWebSocketChannel +
// await ready + then listen — to check whether the immediate `register` frame
// is missed in the gap.
//
//   dart run tool/probe.dart
import 'dart:async';

import 'package:web_socket_channel/io.dart';

const url = 'wss://aio-relay-sb.duckdns.org/control';
const token = '85bfde38e146dfc8aa6f9054f51de27a01ebb134220be5f0c56b835ec6ff9d1b';

Future<void> main() async {
  print('Connecting (IOWebSocketChannel, listen AFTER ready) …');
  final channel = IOWebSocketChannel.connect(
    Uri.parse(url),
    headers: {'Authorization': 'Bearer $token'},
  );
  channel.sink.done.catchError((_) {});
  await channel.ready;
  print('ready resolved');

  var frames = 0;
  channel.stream.listen(
    (data) {
      frames++;
      print('<<< $data');
    },
    onDone: () => print('CLOSED code=${channel.closeCode}'),
  );

  await Future<void>.delayed(const Duration(seconds: 8));
  print('--- received $frames frame(s) ---');
  await channel.sink.close();
}
