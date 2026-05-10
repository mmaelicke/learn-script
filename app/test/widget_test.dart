import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:reorderables/reorderables.dart';

import 'package:script/auth/auth_controller.dart';
import 'package:script/screens/digitizing_notes_screen.dart';
import 'package:script/widgets/auth_gate.dart';

void main() {
  testWidgets('AuthGate shows bootstrap loading', (WidgetTester tester) async {
    final auth = AuthController(baseUrl: 'http://127.0.0.1:8090');
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      AuthInherited(
        notifier: auth,
        child: const MaterialApp(home: AuthGate()),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets(
    'DigitizingNotesScreen lets photos be dragged without long press',
    (WidgetTester tester) async {
      final auth = AuthController(baseUrl: 'http://127.0.0.1:8090');
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        AuthInherited(
          notifier: auth,
          child: MaterialApp(
            home: DigitizingNotesScreen(
              initialPhotos: [
                XFile.fromData(
                  Uint8List.fromList([1, 2, 3]),
                  name: 'first.jpg',
                  mimeType: 'image/jpeg',
                ),
                XFile.fromData(
                  Uint8List.fromList([4, 5, 6]),
                  name: 'second.jpg',
                  mimeType: 'image/jpeg',
                ),
              ],
            ),
          ),
        ),
      );

      final row = tester.widget<ReorderableRow>(find.byType(ReorderableRow));

      expect(row.needsLongPressDraggable, isFalse);
    },
  );
}
