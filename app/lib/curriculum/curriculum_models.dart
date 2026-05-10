import 'package:pocketbase/pocketbase.dart';

class SubjectRouteArgs {
  const SubjectRouteArgs({required this.subject});

  final String subject;
}

class CurriculumTopic {
  const CurriculumTopic({
    required this.id,
    required this.title,
    required this.sortOrder,
    this.parentId,
    this.frozen = false,
  });

  final String id;
  final String title;
  final String? parentId;
  final double sortOrder;
  final bool frozen;

  factory CurriculumTopic.fromRecord(RecordModel record) {
    return CurriculumTopic(
      id: record.id,
      title: (record.data['title'] as String?)?.trim() ?? '',
      parentId: _relationId(record.data['parent']),
      sortOrder: _numberValue(record.data['sortOrder']),
      frozen: record.data['frozen'] == true,
    );
  }
}

class CurriculumItem {
  const CurriculumItem({
    required this.id,
    required this.title,
    required this.topicId,
    required this.sortOrder,
    required this.captureIds,
    this.summaryDocument = '',
  });

  final String id;
  final String title;
  final String topicId;
  final double sortOrder;
  final List<String> captureIds;
  final String summaryDocument;

  factory CurriculumItem.fromRecord(RecordModel record) {
    final rawCaptures = record.data['captureIds'];
    return CurriculumItem(
      id: record.id,
      title: (record.data['title'] as String?)?.trim() ?? 'Ohne Titel',
      topicId: _relationId(record.data['topicId']) ?? '',
      sortOrder: _numberValue(record.data['sortOrder']),
      captureIds: rawCaptures is List
          ? rawCaptures.map((e) => '$e').toList()
          : const [],
      summaryDocument:
          (record.data['summaryDocument'] as String?)?.trim() ?? '',
    );
  }
}

class CaptureImage {
  const CaptureImage({
    required this.id,
    required this.fileName,
    required this.url,
  });

  final String id;
  final String fileName;
  final Uri url;
}

class CurriculumScope {
  const CurriculumScope({
    required this.subject,
    required this.grade,
    required this.topics,
    required this.items,
  });

  final String subject;
  final int grade;
  final List<CurriculumTopic> topics;
  final List<CurriculumItem> items;

  List<CurriculumItem> itemsInTocOrder() {
    final children = <String?, List<CurriculumTopic>>{};
    for (final topic in topics) {
      children.putIfAbsent(topic.parentId, () => []).add(topic);
    }
    for (final entry in children.entries) {
      entry.value.sort(_sortTopics);
    }

    final itemsByTopic = <String, List<CurriculumItem>>{};
    for (final item in items) {
      itemsByTopic.putIfAbsent(item.topicId, () => []).add(item);
    }
    for (final entry in itemsByTopic.entries) {
      entry.value.sort(_sortItems);
    }

    final out = <CurriculumItem>[];
    void walk(String? parent) {
      for (final topic in children[parent] ?? const <CurriculumTopic>[]) {
        out.addAll(itemsByTopic[topic.id] ?? const <CurriculumItem>[]);
        walk(topic.id);
      }
    }

    walk(null);
    return out;
  }

  List<String> descendantItemIds(String topicId) {
    final children = <String?, List<CurriculumTopic>>{};
    for (final topic in topics) {
      children.putIfAbsent(topic.parentId, () => []).add(topic);
    }
    final out = <String>[];
    void walk(String id) {
      out.addAll(
        items.where((item) => item.topicId == id).map((item) => item.id),
      );
      for (final child in children[id] ?? const <CurriculumTopic>[]) {
        walk(child.id);
      }
    }

    walk(topicId);
    return out;
  }
}

int _sortTopics(CurriculumTopic a, CurriculumTopic b) {
  final byOrder = a.sortOrder.compareTo(b.sortOrder);
  if (byOrder != 0) {
    return byOrder;
  }
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

int _sortItems(CurriculumItem a, CurriculumItem b) {
  final byOrder = a.sortOrder.compareTo(b.sortOrder);
  if (byOrder != 0) {
    return byOrder;
  }
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

String? _relationId(Object? raw) {
  if (raw is String && raw.isNotEmpty) {
    return raw;
  }
  if (raw is List && raw.isNotEmpty) {
    return '${raw.first}';
  }
  return null;
}

double _numberValue(Object? raw) {
  if (raw is num) {
    return raw.toDouble();
  }
  return double.tryParse('$raw') ?? 0;
}
