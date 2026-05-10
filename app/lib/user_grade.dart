import 'package:pocketbase/pocketbase.dart';

/// Mirrors agent-backend `effective_grade` for PocketBase `users.grade`.
int effectiveUserGrade(RecordModel user) {
  final g = user.getIntValue('grade');
  if (g >= 1 && g <= 12) {
    return g;
  }
  return 5;
}
