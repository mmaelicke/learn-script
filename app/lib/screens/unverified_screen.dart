import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../auth/auth_controller.dart';
import '../pocketbase_collections.dart';
import '../auth/pocketbase_error.dart';
import '../util/debug_console_error.dart';

class UnverifiedScreen extends StatefulWidget {
  const UnverifiedScreen({super.key});

  @override
  State<UnverifiedScreen> createState() => _UnverifiedScreenState();
}

class _UnverifiedScreenState extends State<UnverifiedScreen> {
  bool _sending = false;

  Future<void> _resend() async {
    final auth = AuthInherited.of(context);
    final email = auth.record?.getStringValue('email', '') ?? '';
    if (email.isEmpty) {
      return;
    }
    setState(() => _sending = true);
    try {
      await auth.client.collection(kUsersCollection).requestVerification(
            email,
            headers: {
              if (auth.client.authStore.token.isNotEmpty)
                'Authorization': auth.client.authStore.token,
            },
          );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verification email sent (if enabled).')),
      );
    } on ClientException catch (e, st) {
      if (!mounted) {
        return;
      }
      showAppErrorSnackBar(
        context,
        scope: 'unverified_resend',
        error: e,
        stackTrace: st,
        message: pocketBaseUserMessage(e),
      );
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthInherited.of(context);
    final email = auth.record?.getStringValue('email', '') ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Verify email')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Your account is not verified yet.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              email.isNotEmpty
                  ? 'We sent instructions to $email when verification is configured in PocketBase.'
                  : 'Complete email verification to continue.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.tonal(
              onPressed: _sending ? null : _resend,
              child: _sending
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Resend verification email'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => auth.signOut(),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}
