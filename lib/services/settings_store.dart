import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the relay connection settings. The control token is a secret and
/// lives in the platform secure storage (Keychain / Keystore), never in
/// plaintext prefs or the repo.
class SettingsStore {
  SettingsStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kRelayUrl = 'relay_url';
  static const _kControlToken = 'control_token';
  static const _kRemoteTrackpad = 'remote_trackpad';

  /// Default relay endpoint the app connects to out of the box.
  static const defaultRelayUrl = 'wss://aio-relay-sb.duckdns.org/control';

  /// Default control token (sent as `Authorization: Bearer <token>`).
  ///
  /// NOTE: this is a live secret baked in for convenience. Do NOT push this
  /// file to a public remote — rotate the token and move it out (env / secure
  /// storage only) before this repo goes anywhere public.
  static const defaultControlToken =
      '85bfde38e146dfc8aa6f9054f51de27a01ebb134220be5f0c56b835ec6ff9d1b';

  Future<RelaySettings> load() async {
    final url = await _storage.read(key: _kRelayUrl);
    final token = await _storage.read(key: _kControlToken);
    return RelaySettings(
      relayUrl: url ?? defaultRelayUrl,
      controlToken: token ?? defaultControlToken,
    );
  }

  Future<void> save(RelaySettings s) async {
    await _storage.write(key: _kRelayUrl, value: s.relayUrl);
    await _storage.write(key: _kControlToken, value: s.controlToken);
  }
}

extension RemotePrefs on SettingsStore {
  /// Whether remote streams open in trackpad mode (vs direct touch).
  Future<bool> loadRemoteTrackpad() async =>
      await _storage.read(key: SettingsStore._kRemoteTrackpad) == 'true';

  Future<void> saveRemoteTrackpad(bool on) =>
      _storage.write(key: SettingsStore._kRemoteTrackpad, value: on.toString());
}

class RelaySettings {
  const RelaySettings({required this.relayUrl, required this.controlToken});

  final String relayUrl;
  final String controlToken;

  bool get isConfigured => relayUrl.trim().isNotEmpty;

  RelaySettings copyWith({String? relayUrl, String? controlToken}) => RelaySettings(
        relayUrl: relayUrl ?? this.relayUrl,
        controlToken: controlToken ?? this.controlToken,
      );
}
