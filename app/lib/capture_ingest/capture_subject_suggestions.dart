import 'package:pocketbase/pocketbase.dart';

import '../pocketbase_collections.dart';
import '../user_grade.dart';

/// Distinct non-empty subjects from existing captures for this user and grade.
Future<List<String>> fetchDistinctCaptureSubjects({
  required PocketBase pb,
  required RecordModel user,
}) async {
  final userId = user.id;
  final grade = effectiveUserGrade(user);
  final seen = <String>{};
  var page = 1;
  const perPage = 100;
  const maxPages = 10;

  while (page <= maxPages) {
    final result = await pb.collection(kCapturesCollection).getList(
          page: page,
          perPage: perPage,
          filter: 'owner = "$userId" && grade = $grade',
        );
    for (final r in result.items) {
      final raw = r.data['subject'];
      if (raw is! String) {
        continue;
      }
      final s = raw.trim();
      if (s.isNotEmpty) {
        seen.add(s);
      }
    }
    if (result.items.length < perPage) {
      break;
    }
    page++;
  }

  final list = seen.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return list;
}
