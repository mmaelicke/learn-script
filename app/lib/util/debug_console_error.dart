// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void reportInfoToDebugConsole(String scope, String message) {
  print('');
  print('.... [$scope] $message');
  print('');
}

/// Prints a clearly delimited block to the **IDE Debug Console** so errors can
/// be selected and copied. `developer.log` is easy to miss there.
void reportToDebugConsole(
  String scope,
  Object error, [
  StackTrace? stackTrace,
  String? extraLines,
]) {
  print('');
  print('>>>> APP ERROR [$scope] <<<<');
  if (extraLines != null && extraLines.isNotEmpty) {
    print(extraLines);
  }
  print(error);
  if (stackTrace != null) {
    print(stackTrace);
  }
  print('>>>> END APP ERROR <<<<');
  print('');
}

/// Logs to the IDE / `flutter run` console and shows a SnackBar with
/// selectable text and a copy action (clipboard gets the same full text).
void showAppErrorSnackBar(
  BuildContext context, {
  required String scope,
  required Object error,
  StackTrace? stackTrace,
  String? message,
}) {
  final parts = <String>[
    if (message != null && message.trim().isNotEmpty) message.trim(),
    '$error',
    if (stackTrace != null) '$stackTrace',
  ];
  final fullText = parts.join('\n');
  reportToDebugConsole(scope, error, stackTrace, message);

  if (!context.mounted) {
    return;
  }
  final theme = Theme.of(context);
  final style =
      theme.snackBarTheme.contentTextStyle ??
      TextStyle(color: theme.colorScheme.onInverseSurface);

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 30),
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      action: SnackBarAction(
        label: 'Kopieren',
        onPressed: () {
          unawaited(Clipboard.setData(ClipboardData(text: fullText)));
        },
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: SingleChildScrollView(
          child: SelectableText(fullText, style: style),
        ),
      ),
    ),
  );
}
