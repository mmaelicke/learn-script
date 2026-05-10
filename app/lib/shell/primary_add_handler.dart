import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../screens/digitizing_notes_screen.dart';
import '../screens/subject_workspace_screen.dart';
import '../ui/de_strings.dart';
import '../util/debug_console_error.dart';
import 'app_shell_breakpoint.dart';

/// Camera on Android, iOS, and narrow web; gallery multi-pick on macOS and wide web.
bool useCameraForPrimaryAdd({required double viewportWidth}) {
  if (kIsWeb) {
    return viewportWidth < kAppShellBreakpointWidth;
  }
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return true;
    default:
      return false;
  }
}

Future<void> handlePrimaryAdd(
  BuildContext context, {
  GlobalKey<NavigatorState>? innerNavigatorKey,
}) async {
  final width = MediaQuery.sizeOf(context).width;
  final useCamera = useCameraForPrimaryAdd(viewportWidth: width);
  final picker = ImagePicker();

  late final List<XFile> initial;
  try {
    if (useCamera) {
      final one = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (one == null) {
        return;
      }
      initial = [one];
    } else {
      final many = await picker.pickMultiImage(imageQuality: 85);
      if (many.isEmpty) {
        return;
      }
      initial = many;
    }
  } catch (e, st) {
    if (context.mounted) {
      showAppErrorSnackBar(
        context,
        scope: 'primary_add_image_picker',
        error: e,
        stackTrace: st,
        message: DeStrings.pickImageError,
      );
    }
    return;
  }

  if (!context.mounted) {
    return;
  }

  final nav = innerNavigatorKey?.currentState ?? Navigator.maybeOf(context);
  if (nav == null) {
    return;
  }

  final subject = await nav.push<String?>(
    MaterialPageRoute<String?>(
      fullscreenDialog: true,
      builder: (_) => DigitizingNotesScreen(initialPhotos: initial),
    ),
  );

  if (!context.mounted) {
    return;
  }
  if (subject != null && subject.isNotEmpty) {
    nav.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SubjectWorkspaceScreen(subject: subject),
      ),
    );
  }
}
