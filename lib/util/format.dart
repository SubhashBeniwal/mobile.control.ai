// Small display formatters shared across screens.

/// "just now", "3m ago", "2h ago", "4d ago".
String relativeTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 5) return 'just now';
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Human-readable byte size: "512 MB", "23.4 GB".
String humanBytes(num bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  final digits = (value >= 100 || i == 0) ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[i]}';
}

/// Human-readable transfer rate: "1.2 MB/s".
String humanRate(num bytesPerSecond) => '${humanBytes(bytesPerSecond)}/s';

/// Compact duration: "820ms", "3.4s", "1m 05s".
String formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
  if (d.inSeconds < 60) return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '${m}m ${s.toString().padLeft(2, '0')}s';
}
