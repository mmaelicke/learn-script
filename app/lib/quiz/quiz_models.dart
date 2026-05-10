import 'dart:convert';

import 'package:pocketbase/pocketbase.dart';

enum QuizSessionKind { assessment, learn, deepen }

QuizSessionKind quizSessionKindFromJson(Object? raw) {
  final s = '$raw'.trim().toLowerCase();
  switch (s) {
    case 'assessment':
      return QuizSessionKind.assessment;
    case 'deepen':
      return QuizSessionKind.deepen;
    default:
      return QuizSessionKind.learn;
  }
}

enum QuizProgressBasis { questions, time }

QuizProgressBasis quizProgressBasisFromJson(Object? raw) {
  final s = '$raw'.trim().toLowerCase();
  if (s == 'time') {
    return QuizProgressBasis.time;
  }
  return QuizProgressBasis.questions;
}

class QuizSession {
  const QuizSession({
    required this.id,
    required this.subject,
    required this.curriculumItemIds,
    required this.status,
    required this.created,
    this.questionCount,
    this.timeLimitSeconds,
    this.sessionKind,
    this.progressBasis,
  });

  final String id;
  final String subject;
  final List<String> curriculumItemIds;
  final String status;
  final DateTime created;
  final int? questionCount;
  final int? timeLimitSeconds;
  final String? sessionKind;
  final String? progressBasis;

  QuizSessionKind get effectiveKind => quizSessionKindFromJson(sessionKind);

  QuizProgressBasis get effectiveProgressBasis =>
      quizProgressBasisFromJson(progressBasis);

  factory QuizSession.fromRecord(RecordModel record) {
    final rawIds = record.data['curriculumItemIds'];
    return QuizSession(
      id: record.id,
      subject: (record.data['subject'] as String?)?.trim() ?? '',
      curriculumItemIds: rawIds is List
          ? rawIds.map((value) => '$value').toList()
          : const [],
      status: (record.data['status'] as String?) ?? 'active',
      created:
          DateTime.tryParse(record.getStringValue('created', '')) ??
          DateTime.now(),
      questionCount: _intOrNull(record.data['questionCount']),
      timeLimitSeconds: _intOrNull(record.data['timeLimitSeconds']),
      sessionKind: (record.data['sessionKind'] as String?)?.trim(),
      progressBasis: (record.data['progressBasis'] as String?)?.trim(),
    );
  }
}

class QuizQuestion {
  const QuizQuestion({
    required this.id,
    required this.kind,
    required this.content,
    this.planIndex,
    this.curriculumItemId,
    this.created,
    this.answerPayload,
    this.answerCorrect,
    this.answerComment,
    this.answerScore,
    this.checkedAt,
    this.checkerKind,
    this.checkError,
  });

  final String id;
  final String kind;
  final QuizQuestionContent content;
  final int? planIndex;
  final String? curriculumItemId;
  final DateTime? created;
  final Map<String, dynamic>? answerPayload;
  final bool? answerCorrect;
  final String? answerComment;
  final num? answerScore;
  final DateTime? checkedAt;
  final String? checkerKind;
  final String? checkError;

  bool get answered => answerPayload != null;

  factory QuizQuestion.fromRecord(RecordModel record) {
    final rawContent = _mapValue(record.data['content']);
    return QuizQuestion(
      id: record.id,
      kind: (record.data['kind'] as String?) ?? '',
      content: QuizQuestionContent.fromJson(rawContent),
      planIndex: _intOrNull(record.data['planIndex']),
      curriculumItemId: (record.data['curriculumItemId'] as String?)?.trim(),
      created: DateTime.tryParse(record.getStringValue('created', '')),
      answerPayload: _mapValueOrNull(record.data['answerPayload']),
      answerCorrect: record.data['answerCorrect'] as bool?,
      answerComment: (record.data['answerComment'] as String?)?.trim(),
      answerScore: record.data['answerScore'] as num?,
      checkedAt: _dateOrNull(record.data['checkedAt']),
      checkerKind: (record.data['checkerKind'] as String?)?.trim(),
      checkError: (record.data['checkError'] as String?)?.trim(),
    );
  }
}

sealed class QuizQuestionContent {
  const QuizQuestionContent({required this.stem});

  final String stem;

  factory QuizQuestionContent.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    if (type == 'multiple_choice') {
      final raw = _mapValue(json['multiple_choice']);
      final rawOptions = raw['options'];
      return QuizMultipleChoiceContent(
        stem: (raw['stem'] as String?)?.trim() ?? '',
        options: rawOptions is List
            ? rawOptions
                  .whereType<Map>()
                  .map(
                    (value) => QuizOption(
                      id: '${value['id']}',
                      label: '${value['label']}',
                    ),
                  )
                  .toList()
            : const [],
        correctOptionId: (raw['correct_option_id'] as String?) ?? '',
      );
    }
    final raw = _mapValue(json['free_text']);
    return QuizFreeTextContent(
      stem: (raw['stem'] as String?)?.trim() ?? '',
      expectedAnswer: (raw['expected_answer'] as String?)?.trim() ?? '',
      rubricHint: (raw['rubric_hint'] as String?)?.trim(),
    );
  }
}

class QuizMultipleChoiceContent extends QuizQuestionContent {
  const QuizMultipleChoiceContent({
    required super.stem,
    required this.options,
    required this.correctOptionId,
  });

  final List<QuizOption> options;
  final String correctOptionId;
}

class QuizFreeTextContent extends QuizQuestionContent {
  const QuizFreeTextContent({
    required super.stem,
    required this.expectedAnswer,
    this.rubricHint,
  });

  final String expectedAnswer;
  final String? rubricHint;
}

class QuizOption {
  const QuizOption({required this.id, required this.label});

  final String id;
  final String label;
}

class QuizProgressSnapshot {
  const QuizProgressSnapshot({
    required this.targetQuestions,
    required this.generatedQuestions,
    required this.answeredQuestions,
    required this.remainingQuestions,
  });

  final int targetQuestions;
  final int generatedQuestions;
  final int answeredQuestions;
  final int remainingQuestions;

  factory QuizProgressSnapshot.fromJson(Map<String, dynamic> json) {
    return QuizProgressSnapshot(
      targetQuestions: _intOrNull(json['targetQuestions']) ?? 0,
      generatedQuestions: _intOrNull(json['generatedQuestions']) ?? 0,
      answeredQuestions: _intOrNull(json['answeredQuestions']) ?? 0,
      remainingQuestions: _intOrNull(json['remainingQuestions']) ?? 0,
    );
  }
}

class QuizEvaluationSnapshot {
  const QuizEvaluationSnapshot({
    required this.requestId,
    required this.label,
    required this.text,
    required this.answeredCount,
    required this.targetQuestionCount,
  });

  final String requestId;
  final String label;
  final String text;
  final int answeredCount;
  final int targetQuestionCount;

  factory QuizEvaluationSnapshot.fromJson(Map<String, dynamic> json) {
    return QuizEvaluationSnapshot(
      requestId: '${json['requestId'] ?? ''}',
      label: '${json['label'] ?? ''}',
      text: '${json['text'] ?? ''}',
      answeredCount: _intOrNull(json['answeredCount']) ?? 0,
      targetQuestionCount: _intOrNull(json['targetQuestionCount']) ?? 0,
    );
  }
}

Map<String, dynamic> _mapValue(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, val) => MapEntry('$key', val));
  }
  if (value is String && value.trim().isNotEmpty) {
    final decoded = jsonDecode(value);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, val) => MapEntry('$key', val));
    }
  }
  return <String, dynamic>{};
}

Map<String, dynamic>? _mapValueOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  final mapped = _mapValue(value);
  return mapped.isEmpty ? null : mapped;
}

DateTime? _dateOrNull(Object? value) {
  final raw = '$value'.trim();
  if (raw.isEmpty || raw == 'null') {
    return null;
  }
  return DateTime.tryParse(raw);
}

int? _intOrNull(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse('$value');
}
