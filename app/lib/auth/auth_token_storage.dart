import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the PocketBase auth JWT only (record is re-fetched via auth-refresh).
class AuthTokenStorage {
  AuthTokenStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _kToken = 'pb_auth_token';

  final FlutterSecureStorage _storage;

  Future<String?> readToken() => _storage.read(key: _kToken);

  Future<void> writeToken(String token) =>
      _storage.write(key: _kToken, value: token);

  Future<void> clearAll() async {
    await _storage.delete(key: _kToken);
  }
}
