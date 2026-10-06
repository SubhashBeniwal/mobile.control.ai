import 'package:flutter_test/flutter_test.dart';

import 'package:aio_control/models/system_metrics.dart';

// Real output captured from the live macOS daemon (tool/probe_metrics.dart).
const _darwinRaw = '''
@os
Darwin
@model
Mac14,2
@ncpu
10
@memtotal
25769803776
@iface
en0
@top
Processes: 650 total, 2 running, 648 sleeping, 5215 threads
2026/07/22 15:52:23
Load Avg: 1.99, 1.94, 1.96
CPU usage: 6.20% user, 12.60% sys, 81.19% idle
SharedLibs: 560M resident, 119M data, 111M linkedit.
MemRegions: 1122872 total, 6948M resident, 188M private, 1617M shared.
PhysMem: 23G used (6426M wired, 6692M compressor), 78M unused.
VM: 349T vsize, 6144M framework vsize, 5038271(0) swapins, 7552502(0) swapouts.
@batt
Now drawing from 'AC Power'
 -InternalBattery-0 (id=34996323)\t100%; charged; 0:00 remaining present: true
@wifi
You are not associated with an AirPort network.
@ip
192.168.0.81
@disk
/dev/disk3s1s1   971298980  12275848 714638160     2%  458726 4294102504    0%   /
@uptime
15:52  up 7 days, 17 hrs, 2 users, load averages: 1.99 1.94 1.96
@net
18779921919 3057301067
''';

void main() {
  group('SystemMetrics.parse (darwin)', () {
    final m = SystemMetrics.parse(_darwinRaw);

    test('identity', () {
      expect(m.os, 'Darwin');
      expect(m.model, 'Mac14,2');
      expect(m.cpuCount, 10);
      expect(m.iface, 'en0');
      expect(m.ip, '192.168.0.81');
    });

    test('cpu usage from idle', () {
      expect(m.cpuUsedPercent, closeTo(18.81, 0.01));
      expect(m.loadAvg, [1.99, 1.94, 1.96]);
    });

    test('memory used = total - unused', () {
      expect(m.memTotalBytes, 25769803776);
      // 78 MiB unused.
      expect(m.memUsedBytes, 25769803776 - 78 * 1024 * 1024);
      expect(m.memPercent, greaterThan(99));
    });

    test('battery on AC, charged', () {
      expect(m.hasBattery, isTrue);
      expect(m.batteryPercent, 100);
      expect(m.batteryState, 'Charged');
      expect(m.onAc, isTrue);
    });

    test('wired network (no wifi association)', () {
      expect(m.isWifi, isFalse);
      expect(m.wifiName, isNull);
    });

    test('disk', () {
      expect(m.diskTotalBytes, 971298980 * 1024);
      expect(m.diskUsedBytes, 12275848 * 1024);
      expect(m.diskPercent, isNotNull);
    });

    test('uptime + net counters', () {
      expect(m.uptime, '7 days, 17 hrs');
      expect(m.netRxBytes, 18779921919);
      expect(m.netTxBytes, 3057301067);
    });
  });
}
