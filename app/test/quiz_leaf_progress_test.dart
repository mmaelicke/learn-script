import 'package:flutter_test/flutter_test.dart';
import 'package:script/quiz/quiz_leaf_progress.dart';
import 'package:script/quiz/quiz_models.dart';

QuizSession _endedAssessment(String id, String itemId) => QuizSession(
      id: id,
      subject: 'test',
      curriculumItemIds: [itemId],
      status: 'ended',
      created: DateTime(2024),
      sessionKind: 'assessment',
    );

QuizSession _endedLearn(String id, String itemId) => QuizSession(
      id: id,
      subject: 'test',
      curriculumItemIds: [itemId],
      status: 'ended',
      created: DateTime(2024),
      sessionKind: 'learn',
    );

void main() {
  group('defaultKindForSelection', () {
    test('empty list → assessment', () {
      expect(defaultKindForSelection([], []), QuizSessionKind.assessment);
    });

    test('0% assessed → assessment', () {
      final sessions = [_endedLearn('s1', 'a'), _endedLearn('s2', 'b')];
      expect(
        defaultKindForSelection(['a', 'b', 'c', 'd'], sessions),
        QuizSessionKind.assessment,
      );
    });

    test('69% assessed (below threshold) → assessment', () {
      // 9 of 13 items assessed ≈ 69.2%
      final ids = List.generate(13, (i) => 'item$i');
      final sessions = [
        for (var i = 0; i < 9; i++) _endedAssessment('s$i', 'item$i'),
      ];
      expect(
        defaultKindForSelection(ids, sessions),
        QuizSessionKind.assessment,
      );
    });

    test('70% assessed (at threshold) → learn', () {
      // 7 of 10 items assessed = 70%
      final ids = List.generate(10, (i) => 'item$i');
      final sessions = [
        for (var i = 0; i < 7; i++) _endedAssessment('s$i', 'item$i'),
      ];
      expect(
        defaultKindForSelection(ids, sessions),
        QuizSessionKind.learn,
      );
    });

    test('100% assessed → learn', () {
      final sessions = [
        _endedAssessment('s1', 'a'),
        _endedAssessment('s2', 'b'),
      ];
      expect(
        defaultKindForSelection(['a', 'b'], sessions),
        QuizSessionKind.learn,
      );
    });
  });

  group('assessmentQuestionCount', () {
    test('1 item → 3 (minimum)', () {
      expect(assessmentQuestionCount(1), 3);
    });

    test('5 items → 5', () {
      expect(assessmentQuestionCount(5), 5);
    });

    test('12 items → 12', () {
      expect(assessmentQuestionCount(12), 12);
    });

    test('15 items → 12 (maximum)', () {
      expect(assessmentQuestionCount(15), 12);
    });
  });
}
