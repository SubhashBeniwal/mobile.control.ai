/// One entry from a `file.list` result.
class FileEntry {
  FileEntry({
    required this.name,
    required this.isDir,
    required this.size,
    required this.mode,
    required this.modTime,
  });

  final String name;
  final bool isDir;
  final int size;
  final String mode;
  final String modTime;

  factory FileEntry.fromJson(dynamic json) {
    final m = json as Map<String, dynamic>;
    return FileEntry(
      name: m['name'] as String? ?? '',
      isDir: m['is_dir'] as bool? ?? false,
      size: (m['size'] as num?)?.toInt() ?? 0,
      mode: m['mode'] as String? ?? '',
      modTime: m['mod_time'] as String? ?? '',
    );
  }

  bool get isHidden => name.startsWith('.');

  /// Lowercased extension without the dot, or '' if none.
  String get ext {
    final i = name.lastIndexOf('.');
    return (i <= 0) ? '' : name.substring(i + 1).toLowerCase();
  }
}

/// Result of listing a directory.
class DirListing {
  DirListing({
    required this.ok,
    required this.path,
    this.entries = const [],
    this.error = '',
  });

  final bool ok;
  final String path;
  final List<FileEntry> entries;
  final String error;

  factory DirListing.failure(String path, String error) =>
      DirListing(ok: false, path: path, error: error);
}

/// Result of reading a file.
class FileContent {
  FileContent({
    required this.ok,
    required this.path,
    this.size = 0,
    this.content = '',
    this.error = '',
  });

  final bool ok;
  final String path;
  final int size;
  final String content;
  final String error;

  factory FileContent.failure(String path, String error) =>
      FileContent(ok: false, path: path, error: error);
}

/// Join a directory and a child name into an absolute path.
String joinPath(String dir, String name) =>
    dir.endsWith('/') ? '$dir$name' : '$dir/$name';
