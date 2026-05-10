import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../config/app_config.dart';
import '../pocketbase_collections.dart';
import '../user_grade.dart';
import 'curriculum_models.dart';

class CurriculumService {
  const CurriculumService({required this.pb, required this.user});

  final PocketBase pb;
  final RecordModel user;

  int get grade => effectiveUserGrade(user);

  Future<CurriculumScope> fetchScope(String subject) async {
    final filter = _scopeFilter(subject);
    final topicsResult = await pb
        .collection(kCurriculumTopicsCollection)
        .getFullList(batch: 200, filter: filter, sort: 'sortOrder,title');
    final itemsResult = await pb
        .collection(kCurriculumItemsCollection)
        .getFullList(batch: 200, filter: filter, sort: 'sortOrder,title');
    return CurriculumScope(
      subject: subject,
      grade: grade,
      topics: topicsResult.map(CurriculumTopic.fromRecord).toList(),
      items: itemsResult.map(CurriculumItem.fromRecord).toList(),
    );
  }

  Future<void> renameTopic(CurriculumTopic topic, String title) async {
    await pb
        .collection(kCurriculumTopicsCollection)
        .update(
          topic.id,
          body: {'title': title.trim(), 'titleNorm': _titleNorm(title)},
        );
  }

  Future<void> renameItem(CurriculumItem item, String title) async {
    await pb
        .collection(kCurriculumItemsCollection)
        .update(item.id, body: {'title': title.trim(), 'summaryDirty': true});
    await notifyItemChanged(item.id, structuralOnly: true);
  }

  Future<void> moveTopic({
    required CurriculumScope scope,
    required CurriculumTopic topic,
    required String? newParentId,
    String? beforeTopicId,
  }) async {
    if (_wouldCreateCycle(scope, topic.id, newParentId)) {
      throw StateError(
        'Ein Thema kann nicht in sich selbst verschoben werden.',
      );
    }
    final siblings =
        scope.topics
            .where(
              (candidate) =>
                  candidate.id != topic.id && candidate.parentId == newParentId,
            )
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final orderedIds = _insertBefore(
      siblings.map((candidate) => candidate.id).toList(),
      topic.id,
      beforeTopicId,
    );
    await pb
        .collection(kCurriculumTopicsCollection)
        .update(
          topic.id,
          body: {
            'parent': newParentId,
            'sortOrder': _sortValueFor(orderedIds, topic.id),
          },
        );
    await _renumberTopics(subject: scope.subject, parentId: newParentId);
  }

  Future<void> moveItem({
    required CurriculumScope scope,
    required CurriculumItem item,
    required String newTopicId,
    String? beforeItemId,
  }) async {
    final siblings =
        scope.items
            .where(
              (candidate) =>
                  candidate.id != item.id && candidate.topicId == newTopicId,
            )
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final orderedIds = _insertBefore(
      siblings.map((candidate) => candidate.id).toList(),
      item.id,
      beforeItemId,
    );
    await pb
        .collection(kCurriculumItemsCollection)
        .update(
          item.id,
          body: {
            'topicId': newTopicId,
            'sortOrder': _sortValueFor(orderedIds, item.id),
            'summaryDirty': item.topicId != newTopicId,
          },
        );
    await _renumberItems(newTopicId);
    if (item.topicId != newTopicId) {
      await notifyItemChanged(item.id, structuralOnly: true);
    }
  }

  Future<List<CaptureImage>> fetchCaptureImages(List<String> captureIds) async {
    final out = <CaptureImage>[];
    final fileToken = pb.authStore.token.isEmpty
        ? null
        : await pb.files.getToken();
    for (final id in captureIds.take(3)) {
      final record = await pb.collection(kCapturesCollection).getOne(id);
      final fileName = (record.data['file'] as String?) ?? '';
      if (fileName.isEmpty) {
        continue;
      }
      out.add(
        CaptureImage(
          id: id,
          fileName: fileName,
          url: pb.files.getUrl(record, fileName, token: fileToken),
        ),
      );
    }
    return out;
  }

  Future<void> notifyItemChanged(
    String itemId, {
    required bool structuralOnly,
  }) async {
    final token = pb.authStore.token;
    if (token.isEmpty) {
      return;
    }
    final uri = Uri.parse(
      '${AppConfig.agentBackendUrl}/api/v1/curriculum/items/$itemId/notify-changed',
    );
    await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: '{"structuralOnly":$structuralOnly}',
    );
  }

  String _scopeFilter(String subject) {
    final escaped = subject.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return 'owner = "${user.id}" && grade = $grade && subject = "$escaped"';
  }

  Future<void> _renumberTopics({
    required String subject,
    required String? parentId,
  }) async {
    final escaped = subject.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final parentExpr = parentId == null
        ? 'parent = ""'
        : 'parent = "$parentId"';
    final rows = await pb
        .collection(kCurriculumTopicsCollection)
        .getFullList(
          batch: 200,
          filter:
              'owner = "${user.id}" && grade = $grade && subject = "$escaped" && $parentExpr',
          sort: 'sortOrder,title',
        );
    for (var i = 0; i < rows.length; i++) {
      await pb
          .collection(kCurriculumTopicsCollection)
          .update(rows[i].id, body: {'sortOrder': i + 1});
    }
  }

  Future<void> _renumberItems(String topicId) async {
    final rows = await pb
        .collection(kCurriculumItemsCollection)
        .getFullList(
          batch: 200,
          filter:
              'owner = "${user.id}" && grade = $grade && topicId = "$topicId"',
          sort: 'sortOrder,title',
        );
    for (var i = 0; i < rows.length; i++) {
      await pb
          .collection(kCurriculumItemsCollection)
          .update(rows[i].id, body: {'sortOrder': i + 1});
    }
  }
}

String _titleNorm(String value) => value.trim().toLowerCase();

bool _wouldCreateCycle(
  CurriculumScope scope,
  String topicId,
  String? newParentId,
) {
  var cursor = newParentId;
  while (cursor != null && cursor.isNotEmpty) {
    if (cursor == topicId) {
      return true;
    }
    cursor = scope.topics
        .where((topic) => topic.id == cursor)
        .firstOrNull
        ?.parentId;
  }
  return false;
}

List<String> _insertBefore(
  List<String> ids,
  String movingId,
  String? beforeId,
) {
  final out = ids.where((id) => id != movingId).toList();
  final beforeIndex = beforeId == null ? -1 : out.indexOf(beforeId);
  if (beforeIndex < 0) {
    out.add(movingId);
  } else {
    out.insert(beforeIndex, movingId);
  }
  return out;
}

double _sortValueFor(List<String> ids, String id) =>
    (ids.indexOf(id) + 1).toDouble();
