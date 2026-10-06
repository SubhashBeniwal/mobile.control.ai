// Live host metrics collected by running shell commands on the daemon via the
// `deploy` (shell) action, then parsed from their stdout. The daemon has no
// dedicated metrics action, so this is built entirely on the existing contract.

/// Shell script that emits `@section` markers followed by each tool's output.
/// The parser below is written against the real output of these commands.
String metricsScript(String os) =>
    os == 'linux' ? _linuxScript : _darwinScript;

const _darwinScript = r'''
IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[ -z "$IFACE" ] && IFACE=en0
echo "@os"; uname -s
echo "@model"; sysctl -n hw.model 2>/dev/null
echo "@ncpu"; sysctl -n hw.ncpu
echo "@memtotal"; sysctl -n hw.memsize
echo "@iface"; echo "$IFACE"
echo "@top"; top -l 1 -n 0
echo "@batt"; pmset -g batt
echo "@wifi"; networksetup -getairportnetwork "$IFACE" 2>/dev/null || echo "n/a"
echo "@ip"; ipconfig getifaddr "$IFACE" 2>/dev/null || echo ""
echo "@disk"; df -k / | tail -1
echo "@uptime"; uptime
echo "@net"; netstat -ibn | awk -v i="$IFACE" '$1==i && $3 ~ /Link/ {print $7, $10; exit}'
''';

// Best-effort Linux collection (untested against a live daemon).
const _linuxScript = r'''
IFACE=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
[ -z "$IFACE" ] && IFACE=eth0
echo "@os"; uname -s
echo "@model"; (cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "")
echo "@ncpu"; nproc
echo "@memtotal"; awk '/MemTotal/{print $2*1024}' /proc/meminfo
echo "@iface"; echo "$IFACE"
echo "@meminfo"; awk '/MemAvailable/{print $2*1024}' /proc/meminfo
echo "@stat"; head -1 /proc/stat
echo "@batt"; (cat /sys/class/power_supply/BAT0/capacity 2>/dev/null; cat /sys/class/power_supply/BAT0/status 2>/dev/null) || echo ""
echo "@ip"; hostname -I 2>/dev/null | awk '{print $1}'
echo "@disk"; df -k / | tail -1
echo "@uptime"; uptime
echo "@net"; cat /sys/class/net/$IFACE/statistics/rx_bytes /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null | paste -sd' '
''';

class SystemMetrics {
  String os = '';
  String model = '';
  int? cpuCount;
  double? cpuUsedPercent; // 0..100
  List<double> loadAvg = const [];

  int? memTotalBytes;
  int? memUsedBytes;

  bool hasBattery = false;
  int? batteryPercent;
  String batteryState = ''; // Charging / Charged / On battery
  bool onAc = false;

  String iface = '';
  String ip = '';
  String? wifiName;
  bool get isWifi => wifiName != null && wifiName!.isNotEmpty;

  int? diskTotalBytes;
  int? diskUsedBytes;

  String uptime = '';

  int? netRxBytes; // cumulative
  int? netTxBytes;

  // Rates filled in by the screen from successive samples.
  double? rxRate; // bytes/sec
  double? txRate;

  double? get memPercent => (memTotalBytes != null && memUsedBytes != null && memTotalBytes! > 0)
      ? (memUsedBytes! / memTotalBytes!) * 100
      : null;

  double? get diskPercent =>
      (diskTotalBytes != null && diskUsedBytes != null && diskTotalBytes! > 0)
          ? (diskUsedBytes! / diskTotalBytes!) * 100
          : null;

  static SystemMetrics parse(String raw) {
    final sections = _split(raw);
    final m = SystemMetrics();
    m.os = (sections['os'] ?? '').trim();
    m.model = (sections['model'] ?? '').trim();
    m.iface = (sections['iface'] ?? '').trim();
    m.ip = (sections['ip'] ?? '').trim();
    m.cpuCount = int.tryParse((sections['ncpu'] ?? '').trim());
    m.memTotalBytes = int.tryParse((sections['memtotal'] ?? '').trim());

    _parseUptime(m, sections['uptime']);
    _parseNet(m, sections['net']);
    _parseDisk(m, sections['disk']);
    _parseWifi(m, sections['wifi']);

    if (m.os == 'Linux') {
      _parseLinux(m, sections);
    } else {
      _parseDarwin(m, sections);
    }
    return m;
  }

  static Map<String, String> _split(String raw) {
    final out = <String, String>{};
    String? key;
    final buf = StringBuffer();
    void flush() {
      final k = key;
      if (k != null) out[k] = buf.toString();
      buf.clear();
    }

    for (final line in raw.split('\n')) {
      if (line.startsWith('@')) {
        flush();
        key = line.substring(1).trim();
      } else {
        buf.writeln(line);
      }
    }
    flush();
    return out;
  }

  // ---- darwin ------------------------------------------------------------

  static void _parseDarwin(SystemMetrics m, Map<String, String> s) {
    final top = s['top'] ?? '';
    for (final line in top.split('\n')) {
      if (line.contains('CPU usage:')) {
        final idle = RegExp(r'([\d.]+)%\s+idle').firstMatch(line);
        if (idle != null) {
          final idleV = double.tryParse(idle.group(1)!);
          if (idleV != null) m.cpuUsedPercent = (100 - idleV).clamp(0, 100);
        }
      } else if (line.startsWith('PhysMem:')) {
        final unused = RegExp(r'([\d.]+)([KMGT])\s+unused').firstMatch(line);
        if (unused != null && m.memTotalBytes != null) {
          final free = _sizeToBytes(unused.group(1)!, unused.group(2)!);
          m.memUsedBytes = (m.memTotalBytes! - free).clamp(0, m.memTotalBytes!);
        }
      }
    }
    _parseBatteryDarwin(m, s['batt'] ?? '');
  }

  static void _parseBatteryDarwin(SystemMetrics m, String batt) {
    m.onAc = batt.contains('AC Power');
    m.hasBattery = batt.contains('InternalBattery');
    if (!m.hasBattery) return;
    final pct = RegExp(r'(\d+)%').firstMatch(batt);
    if (pct != null) m.batteryPercent = int.tryParse(pct.group(1)!);
    final low = batt.toLowerCase();
    if (low.contains('charged') || low.contains('charging complete')) {
      m.batteryState = 'Charged';
    } else if (low.contains('discharging')) {
      m.batteryState = 'On battery';
    } else if (low.contains('charging')) {
      m.batteryState = 'Charging';
    } else if (low.contains('finishing charge')) {
      m.batteryState = 'Finishing charge';
    }
  }

  // ---- linux (best-effort) ----------------------------------------------

  static void _parseLinux(SystemMetrics m, Map<String, String> s) {
    final avail = int.tryParse((s['meminfo'] ?? '').trim());
    if (avail != null && m.memTotalBytes != null) {
      m.memUsedBytes = (m.memTotalBytes! - avail).clamp(0, m.memTotalBytes!);
    }
    // CPU: single /proc/stat sample gives cumulative jiffies; approximate the
    // busy share of total since boot (not instantaneous, but a usable figure).
    final stat = (s['stat'] ?? '').trim().split(RegExp(r'\s+'));
    if (stat.length >= 8 && stat.first == 'cpu') {
      final nums = stat.skip(1).map((e) => int.tryParse(e) ?? 0).toList();
      final total = nums.fold<int>(0, (a, b) => a + b);
      final idle = nums.length > 3 ? nums[3] + nums[4] : nums[3];
      if (total > 0) m.cpuUsedPercent = ((total - idle) / total * 100).clamp(0, 100);
    }
    final batt = (s['batt'] ?? '').trim().split('\n');
    if (batt.isNotEmpty && batt.first.trim().isNotEmpty) {
      m.hasBattery = true;
      m.batteryPercent = int.tryParse(batt.first.trim());
      final state = batt.length > 1 ? batt[1].trim().toLowerCase() : '';
      m.onAc = state == 'charging' || state == 'full';
      m.batteryState = state == 'full'
          ? 'Charged'
          : state == 'charging'
              ? 'Charging'
              : state == 'discharging'
                  ? 'On battery'
                  : state;
    }
  }

  // ---- shared ------------------------------------------------------------

  static void _parseUptime(SystemMetrics m, String? uptime) {
    if (uptime == null) return;
    final line = uptime.trim();
    final up = RegExp(r'up\s+(.*?),\s+\d+\s+users?').firstMatch(line);
    if (up != null) m.uptime = up.group(1)!.trim();
    final load = RegExp(r'load averages?:\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)')
        .firstMatch(line);
    if (load != null) {
      m.loadAvg = [
        double.tryParse(load.group(1)!) ?? 0,
        double.tryParse(load.group(2)!) ?? 0,
        double.tryParse(load.group(3)!) ?? 0,
      ];
    }
  }

  static void _parseNet(SystemMetrics m, String? net) {
    if (net == null) return;
    final parts = net.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      m.netRxBytes = int.tryParse(parts[0]);
      m.netTxBytes = int.tryParse(parts[1]);
    }
  }

  static void _parseDisk(SystemMetrics m, String? disk) {
    if (disk == null) return;
    final f = disk.trim().split(RegExp(r'\s+'));
    if (f.length >= 4) {
      final total = int.tryParse(f[1]);
      final used = int.tryParse(f[2]);
      if (total != null) m.diskTotalBytes = total * 1024;
      if (used != null) m.diskUsedBytes = used * 1024;
    }
  }

  static void _parseWifi(SystemMetrics m, String? wifi) {
    if (wifi == null) return;
    final match =
        RegExp(r'Current Wi-Fi Network:\s*(.+)').firstMatch(wifi.trim());
    if (match != null) m.wifiName = match.group(1)!.trim();
  }

  static int _sizeToBytes(String num, String unit) {
    final v = double.tryParse(num) ?? 0;
    final mult = switch (unit) {
      'K' => 1024,
      'M' => 1024 * 1024,
      'G' => 1024 * 1024 * 1024,
      'T' => 1024 * 1024 * 1024 * 1024,
      _ => 1,
    };
    return (v * mult).round();
  }
}
