import 'package:flutter/material.dart';

import 'subject_list_screen.dart';
import '../widgets/responsive_app_shell.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<NavigatorState> _innerNavKey = GlobalKey<NavigatorState>();
  final ShellChromeController _chromeController = ShellChromeController();

  @override
  void dispose() {
    _chromeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ResponsiveAppShell(
      chromeController: _chromeController,
      innerNavigatorKey: _innerNavKey,
      body: ShellChrome(
        controller: _chromeController,
        child: Navigator(
          key: _innerNavKey,
          observers: [appShellRouteObserver],
          initialRoute: '/',
          onGenerateRoute: (settings) {
            if (settings.name == '/') {
              return InstantShellRoute<void>(
                settings: settings,
                builder: (_) => const SubjectListScreen(),
              );
            }
            return null;
          },
        ),
      ),
    );
  }
}
