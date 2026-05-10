import 'package:flutter/foundation.dart';

/// Compile-time: `--dart-define=POCKETBASE_URL=https://pb.example.com`
/// and `--dart-define=AGENT_BACKEND_URL=http://localhost:8000`
class AppConfig {
  AppConfig._();

  static const String _fromEnv = String.fromEnvironment('POCKETBASE_URL');
  static const String _agentFromEnv = String.fromEnvironment('AGENT_BACKEND_URL');

  /// Debug web: same hostname as [Uri.base] (e.g. `localhost` vs `127.0.0.1`) so
  /// browser requests align with the Flutter dev server and CORS / PNA behave.
  static String _webDebugLoopbackBase(int port) {
    final host = Uri.base.host;
    if (host.isEmpty) {
      return 'http://localhost:$port';
    }
    return Uri(scheme: 'http', host: host, port: port).toString();
  }

  /// PocketBase base URL (no trailing slash).
  ///
  /// Release builds must set [POCKETBASE_URL]. Debug defaults to localhost
  /// (use `http://10.0.2.2:8090` on Android emulator when PB runs on host).
  static String get pocketbaseUrl {
    final trimmed = _fromEnv.trim();
    if (trimmed.isNotEmpty) {
      return trimmed.replaceAll(RegExp(r'/+$'), '');
    }
    if (kReleaseMode) {
      throw StateError(
        'Release build requires POCKETBASE_URL '
        '(e.g. flutter build web --dart-define=POCKETBASE_URL=https://...).',
      );
    }
    if (kIsWeb) {
      return _webDebugLoopbackBase(8090);
    }
    return 'http://127.0.0.1:8090';
  }

  /// Agent FastAPI base URL (no trailing slash).
  static String get agentBackendUrl {
    final trimmed = _agentFromEnv.trim();
    if (trimmed.isNotEmpty) {
      return trimmed.replaceAll(RegExp(r'/+$'), '');
    }
    if (kReleaseMode) {
      throw StateError(
        'Release build requires AGENT_BACKEND_URL '
        '(e.g. flutter build apk --dart-define=AGENT_BACKEND_URL=https://...).',
      );
    }
    if (kIsWeb) {
      return _webDebugLoopbackBase(8000);
    }
    return 'http://127.0.0.1:8000';
  }
}
