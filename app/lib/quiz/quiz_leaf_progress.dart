import 'quiz_models.dart';

bool _sessionTouchesItem(QuizSession s, String itemId) =>
    s.curriculumItemIds.contains(itemId);

bool _ended(QuizSession s) => s.status == 'ended';

bool _active(QuizSession s) => s.status == 'active' || s.status == 'review';

Iterable<QuizSession> _forItem(String itemId, List<QuizSession> all) =>
    all.where((s) => _sessionTouchesItem(s, itemId));

/// Active session for this leaf (most recently created).
String? activeSessionIdForItem(String itemId, List<QuizSession> all) {
  final act = _forItem(itemId, all).where(_active).toList()
    ..sort((a, b) => b.created.compareTo(a.created));
  return act.isEmpty ? null : act.first.id;
}

bool hasEndedAssessment(String itemId, List<QuizSession> all) =>
    _forItem(itemId, all).any(
      (s) => _ended(s) && s.effectiveKind == QuizSessionKind.assessment,
    );

bool hasEndedLearn(String itemId, List<QuizSession> all) =>
    _forItem(itemId, all).any(
      (s) => _ended(s) && s.effectiveKind == QuizSessionKind.learn,
    );

String? latestEndedDeepenSessionIdForItem(
  String itemId,
  List<QuizSession> all,
) {
  final d = _latestEndedDeepen(itemId, all);
  return d?.id;
}

QuizSession? _latestEndedDeepen(String itemId, List<QuizSession> all) {
  final ds = _forItem(itemId, all)
      .where(
        (s) => _ended(s) && s.effectiveKind == QuizSessionKind.deepen,
      )
      .toList()
    ..sort((a, b) => b.created.compareTo(a.created));
  return ds.isEmpty ? null : ds.first;
}

/// Whether every answered question in this deepen session is graded and
/// strictly more than 80% are correct.
bool deepenShowsDoubleCheck(List<QuizQuestion> questions) {
  final answered = questions.where((q) => q.answered).toList();
  if (answered.isEmpty) {
    return false;
  }
  final graded = answered.where((q) => q.answerCorrect != null).toList();
  if (graded.length != answered.length) {
    return false;
  }
  final correct = graded.where((q) => q.answerCorrect == true).length;
  return correct / graded.length > 0.8;
}

/// Latest ended deepen exists and is not in the double-check (>80%) band.
bool deepenShowsSingleCheck(
  String itemId,
  List<QuizSession> all,
  Map<String, List<QuizQuestion>> questionsBySessionId,
) {
  final d = _latestEndedDeepen(itemId, all);
  if (d == null) {
    return false;
  }
  return !deepenShowsDoubleCheckForItem(itemId, all, questionsBySessionId);
}

bool deepenShowsDoubleCheckForItem(
  String itemId,
  List<QuizSession> all,
  Map<String, List<QuizQuestion>> questionsBySessionId,
) {
  final d = _latestEndedDeepen(itemId, all);
  if (d == null) {
    return false;
  }
  final qs = questionsBySessionId[d.id];
  if (qs == null) {
    return false;
  }
  return deepenShowsDoubleCheck(qs);
}

/// Next session kind for a single leaf, or null if pipeline is complete (two checks)
/// or blocked until questions are loaded.
QuizSessionKind? nextKindForSingleLeaf(
  String itemId,
  List<QuizSession> all, {
  required Map<String, List<QuizQuestion>> questionsBySessionId,
}) {
  if (activeSessionIdForItem(itemId, all) != null) {
    return null;
  }
  if (!hasEndedAssessment(itemId, all)) {
    return QuizSessionKind.assessment;
  }
  if (!hasEndedLearn(itemId, all)) {
    return QuizSessionKind.learn;
  }
  if (deepenShowsDoubleCheckForItem(itemId, all, questionsBySessionId)) {
    return null;
  }
  return QuizSessionKind.deepen;
}

/// Default session kind for a multi-item selection based on the 70% threshold.
///
/// Returns [QuizSessionKind.learn] when ≥ 70% of the selected items have
/// passed the assessment stage. An item is counted as assessed when it has an
/// ended assessment session OR an ended learn session (the latter implies
/// assessment was completed first, and also handles legacy sessions where
/// [QuizSession.sessionKind] was null and defaults to learn).
QuizSessionKind defaultKindForSelection(
  List<String> ids,
  List<QuizSession> sessions,
) {
  if (ids.isEmpty) {
    return QuizSessionKind.assessment;
  }
  final assessed = ids
      .where((id) =>
          hasEndedAssessment(id, sessions) || hasEndedLearn(id, sessions))
      .length;
  return assessed / ids.length >= 0.7
      ? QuizSessionKind.learn
      : QuizSessionKind.assessment;
}

/// Question count for a multi-item assessment: one per item, clamped [3, 12].
int assessmentQuestionCount(int itemCount) => itemCount.clamp(3, 12);

double leafRingProgress(
  String itemId,
  List<QuizSession> all,
  Map<String, List<QuizQuestion>> questionsBySessionId,
) {
  final active = _forItem(itemId, all).where(_active).toList()
    ..sort((a, b) => b.created.compareTo(a.created));
  final activeS = active.isEmpty ? null : active.first;

  if (!hasEndedAssessment(itemId, all)) {
    if (activeS != null && activeS.effectiveKind == QuizSessionKind.assessment) {
      final cap = activeS.questionCount ?? 5;
      if (cap <= 0) {
        return 0;
      }
      final qs = questionsBySessionId[activeS.id] ?? const [];
      final n = qs.where((q) => q.answered).length;
      return (0.5 * (n / cap)).clamp(0.0, 0.5);
    }
    return 0;
  }

  if (activeS != null && activeS.effectiveKind == QuizSessionKind.learn) {
    final qs = questionsBySessionId[activeS.id] ?? const [];
    if (activeS.effectiveProgressBasis == QuizProgressBasis.questions) {
      final cap = activeS.questionCount ?? 10;
      if (cap <= 0) {
        return 0.5;
      }
      final n = qs.where((q) => q.answered).length;
      return (0.5 + 0.5 * (n / cap)).clamp(0.0, 1.0);
    }
    final capSec = activeS.timeLimitSeconds ?? 1200;
    if (capSec <= 0) {
      return 0.5;
    }
    final elapsed = DateTime.now().difference(activeS.created).inSeconds;
    return (0.5 + 0.5 * (elapsed / capSec)).clamp(0.0, 1.0);
  }

  if (!hasEndedLearn(itemId, all)) {
    return 0.5;
  }

  return 1;
}
