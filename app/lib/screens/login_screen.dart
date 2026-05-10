import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../auth/auth_controller.dart';
import '../auth/pocketbase_error.dart';
import '../util/debug_console_error.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordConfirm = TextEditingController();
  final _gradeRegister = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _registerMode = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordConfirm.dispose();
    _gradeRegister.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final auth = AuthInherited.of(context);
    setState(() => _busy = true);
    try {
      if (_registerMode) {
        await auth.register(
          _email.text.trim(),
          _password.text,
          _passwordConfirm.text,
          int.parse(_gradeRegister.text.trim()),
        );
      } else {
        await auth.signIn(_email.text.trim(), _password.text);
      }
    } on ClientException catch (e, st) {
      if (!mounted) {
        return;
      }
      showAppErrorSnackBar(
        context,
        scope: 'login',
        error: e,
        stackTrace: st,
        message: pocketBaseUserMessage(e),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _registerMode ? 'Create account' : 'Sign in',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                      ),
                      onFieldSubmitted: (_) {
                        FocusScope.of(context).nextFocus();
                      },
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Enter your email';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      textInputAction: _registerMode
                          ? TextInputAction.next
                          : TextInputAction.go,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        border: OutlineInputBorder(),
                      ),
                      onFieldSubmitted: (_) {
                        if (!_registerMode && !_busy) {
                          _submit();
                        }
                      },
                      validator: (v) {
                        if (v == null || v.isEmpty) {
                          return 'Enter your password';
                        }
                        if (_registerMode && v.length < 8) {
                          return 'At least 8 characters';
                        }
                        return null;
                      },
                    ),
                    if (_registerMode) ...[
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordConfirm,
                        obscureText: true,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Confirm password',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) {
                          if (v == null || v.isEmpty) {
                            return 'Confirm your password';
                          }
                          if (v != _password.text) {
                            return 'Passwords do not match';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _gradeRegister,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.go,
                        decoration: const InputDecoration(
                          labelText: 'Grade (1–12)',
                          border: OutlineInputBorder(),
                        ),
                        onFieldSubmitted: (_) {
                          if (!_busy) {
                            _submit();
                          }
                        },
                        validator: (v) {
                          final n = int.tryParse(v?.trim() ?? '');
                          if (n == null || n < 1 || n > 12) {
                            return 'Enter a grade from 1 to 12';
                          }
                          return null;
                        },
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_registerMode ? 'Register' : 'Sign in'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() {
                                _registerMode = !_registerMode;
                                if (!_registerMode) {
                                  _passwordConfirm.clear();
                                  _gradeRegister.clear();
                                }
                              });
                            },
                      child: Text(
                        _registerMode
                            ? 'Already have an account? Sign in'
                            : 'Need an account? Register',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
