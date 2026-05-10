import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import 'auth/auth_controller.dart';
import 'config/app_config.dart';
import 'widgets/auth_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  late final String pocketbaseUrl;
  try {
    pocketbaseUrl = AppConfig.pocketbaseUrl;
    // Fail fast in release if agent URL is missing (same pattern as PocketBase).
    AppConfig.agentBackendUrl;
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Configuration error:\n$e',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }
  runApp(ScriptRoot(pocketbaseUrl: pocketbaseUrl));
}

class ScriptRoot extends StatefulWidget {
  const ScriptRoot({required this.pocketbaseUrl, super.key});

  final String pocketbaseUrl;

  @override
  State<ScriptRoot> createState() => _ScriptRootState();
}

class _ScriptRootState extends State<ScriptRoot> {
  late final AuthController _auth = AuthController(
    baseUrl: widget.pocketbaseUrl,
  );

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AuthInherited(notifier: _auth, child: const ScriptApp());
  }
}

class ScriptApp extends StatefulWidget {
  const ScriptApp({super.key});

  @override
  State<ScriptApp> createState() => _ScriptAppState();
}

class _ScriptAppState extends State<ScriptApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      final auth = AuthInherited.maybeOf(context);
      if (auth != null && auth.ready && auth.isLoggedIn) {
        auth.refreshSession();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Script',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      scrollBehavior: const _AppScrollBehavior(),
      home: const AuthGate(),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
