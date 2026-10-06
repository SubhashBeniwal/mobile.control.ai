import 'package:flutter_test/flutter_test.dart';

import 'package:aio_control/models/envelope.dart';
import 'package:aio_control/models/daemon.dart';
import 'package:aio_control/models/command.dart';

void main() {
  test('Envelope round-trips through JSON', () {
    const raw =
        '{"type":"register","daemon":"mac-1","payload":{"daemon_id":"mac-1","name":"Mac"},"ts":1700000000000}';
    final env = Envelope.decode(raw);
    expect(env.type, 'register');
    expect(env.daemon, 'mac-1');
    expect(env.payloadMap?['name'], 'Mac');
  });

  test('Daemon builds from a register payload with routing id', () {
    final env = Envelope.decode(
      '{"type":"register","daemon":"mac-1","payload":{'
      '"daemon_id":"mac-1","name":"Mac","os":"darwin","arch":"arm64",'
      '"providers":["claude"],"actions":["system.info","git"]}}',
    );
    final d = Daemon.fromRegister(env.payloadMap!, routingId: env.daemon);
    expect(d.id, 'mac-1');
    expect(d.providers, ['claude']);
    expect(d.supports('git'), isTrue);
    expect(d.supports('deploy'), isFalse);
  });

  test('CommandRun advances through ack/log/result', () {
    final run = CommandRun(
      id: 'c-1',
      daemonId: 'mac-1',
      action: 'git',
      args: const {},
      createdAt: DateTime.now(),
    );
    expect(run.status, CommandStatus.pending);
    run.markRunning();
    expect(run.status, CommandStatus.running);
    run.addLog(LogLine('stdout', 'hello', DateTime.now()));
    expect(run.logs.length, 1);
    run.finish(CommandResult(ok: true, exitCode: 0));
    expect(run.status, CommandStatus.done);
  });
}
