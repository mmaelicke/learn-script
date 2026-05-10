import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../screens/home_screen.dart';
import '../screens/login_screen.dart';
import '../screens/unverified_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthInherited.of(context);
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (!auth.ready) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (!auth.isLoggedIn) {
          return const LoginScreen();
        }
        if (!auth.isVerified) {
          return const UnverifiedScreen();
        }
        return const HomeScreen();
      },
    );
  }
}
