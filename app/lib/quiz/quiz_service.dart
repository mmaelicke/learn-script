import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../config/app_config.dart';
import '../pocketbase_collections.dart';
import 'quiz_models.dart';

class QuizService {
  const QuizService({required this.pb});

  final PocketBase pb;

  Future<QuizSession> createQuizSession({
    required String subject,
    required List<String> curriculumItemIds,
    required QuizSessionKind kind,
    QuizProgressBasis progressBasis = QuizProgressBasis.questions,
    int? questionCount,
    int? timeLimitSeconds,
  }) async {
    final token = _requiredToken;
    final kindStr = switch (kind) {
      QuizSessionKind.assessment => 'assessment',
      QuizSessionKind.deepen => 'deepen',
      QuizSessionKind.learn => 'learn',
    };
    final basisStr = progressBasis == QuizProgressBasis.time
        ? 'time'
        : 'questions';
    final body = <String, dynamic>{
      'subject': subject,
      'curriculumItemIds': jsonEncode(curriculumItemIds),
      'sessionKind': kindStr,
      'progressBasis': basisStr,
    };
    final qc = questionCount;
    final tls = timeLimitSeconds;
    if (qc != null) {
      body['questionCount'] = '$qc';
    }
    if (tls != null) {
      body['timeLimitSeconds'] = '$tls';
    }
    final response = await http.post(
      Uri.parse('${AppConfig.agentBackendUrl}/api/v1/learn-deck/sessions'),
      headers: {'Authorization': 'Bearer $token'},
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Lern-Deck konnte nicht erstellt werden: ${response.body}',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final id = '${data['id']}';
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        return await fetchSession(id);
      } on ClientException catch (e) {
        final isLast = attempt == 5;
        if (e.statusCode != 404 || isLast) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 40 * (1 << attempt)));
      }
    }
    throw StateError('Lern-Deck-Session nicht gefunden (id=$id).');
  }

  Future<QuizSession> fetchSession(String sessionId) async {
    final record = await pb
        .collection(kQuizSessionsCollection)
        .getOne(sessionId);
    return QuizSession.fromRecord(record);
  }

  /// All learn-deck sessions for the current user in this subject and grade
  /// (list rule already scopes by owner).
  Future<List<QuizSession>> fetchSessionsForSubject({
    required String subject,
    required int grade,
  }) async {
    final escaped = subject.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final rows = await pb
        .collection(kQuizSessionsCollection)
        .getFullList(batch: 200, filter: 'subject="$escaped"&&grade=$grade');
    return rows.map(QuizSession.fromRecord).toList();
  }

  Future<List<QuizQuestion>> fetchQuestions(String sessionId) async {
    final escaped = sessionId.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final rows = await pb
        .collection(kQuizQuestionsCollection)
        .getFullList(batch: 200, filter: 'session="$escaped"');
    return rows.map(QuizQuestion.fromRecord).toList();
  }

  Future<void> updateSessionLimits({
    required String sessionId,
    int? questionCount,
    int? timeLimitSeconds,
  }) async {
    final body = <String, dynamic>{};
    if (questionCount != null) {
      body['questionCount'] = questionCount;
    }
    if (timeLimitSeconds != null) {
      body['timeLimitSeconds'] = timeLimitSeconds;
    }
    if (body.isEmpty) {
      return;
    }
    await pb.collection(kQuizSessionsCollection).update(sessionId, body: body);
  }

  Future<void> updateProgressBasis({
    required String sessionId,
    required QuizProgressBasis basis,
  }) async {
    await pb
        .collection(kQuizSessionsCollection)
        .update(
          sessionId,
          body: {
            'progressBasis': basis == QuizProgressBasis.time
                ? 'time'
                : 'questions',
          },
        );
  }

  Future<void> patchSessionStatus(String sessionId, String status) async {
    final response = await http.patch(
      Uri.parse(
        '${AppConfig.agentBackendUrl}/api/v1/learn-deck/sessions/$sessionId',
      ),
      headers: {
        'Authorization': 'Bearer $_requiredToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'status': status}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Sessionstatus konnte nicht geändert werden: ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> requestNextQuestion({
    required String sessionId,
    int prefetchCount = 2,
    String? requestId,
  }) async {
    final rid = requestId ?? _newRequestId('next');
    final response = await http.post(
      Uri.parse(
        '${AppConfig.agentBackendUrl}/api/v1/learn-deck/sessions/$sessionId/next',
      ),
      headers: {
        'Authorization': 'Bearer $_requiredToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'requestId': rid,
        'prefetchCount': prefetchCount.clamp(0, 2),
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Nächste Frage konnte nicht geladen werden: ${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> submitAnswer({
    required String sessionId,
    required String questionId,
    String? selectedOptionId,
    String? freeText,
    String? idempotencyKey,
  }) async {
    final payload = <String, dynamic>{
      'questionId': questionId,
      'idempotencyKey': idempotencyKey ?? _newRequestId('answer'),
    };
    if (selectedOptionId != null) {
      payload['selectedOptionId'] = selectedOptionId;
    }
    if (freeText != null) {
      payload['freeText'] = freeText;
    }
    final response = await http.post(
      Uri.parse(
        '${AppConfig.agentBackendUrl}/api/v1/learn-deck/sessions/$sessionId/answer',
      ),
      headers: {
        'Authorization': 'Bearer $_requiredToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Antwort konnte nicht gespeichert werden: ${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<QuizProgressSnapshot> fetchProgress(String sessionId) async {
    final response = await http.get(
      Uri.parse(
        '${AppConfig.agentBackendUrl}/api/v1/learn-deck/sessions/$sessionId/progress',
      ),
      headers: {
        'Authorization': 'Bearer $_requiredToken',
        'Content-Type': 'application/json',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Fortschritt konnte nicht geladen werden: ${response.body}',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final progress = data['progress'];
    if (progress is! Map) {
      throw StateError('Ungültige Fortschrittsantwort');
    }
    return QuizProgressSnapshot.fromJson(
      progress.map((key, value) => MapEntry('$key', value)),
    );
  }

  Future<QuizEvaluationSnapshot> evaluateSession({
    required String sessionId,
    String label = 'evaluation',
    String? requestId,
  }) async {
    final rid = requestId ?? _newRequestId('eval');
    final response = await http.post(
      Uri.parse(
        '${AppConfig.agentBackendUrl}/api/v1/learn-deck/sessions/$sessionId/evaluate',
      ),
      headers: {
        'Authorization': 'Bearer $_requiredToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'requestId': rid, 'label': label}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Auswertung konnte nicht erstellt werden: ${response.body}',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final eval = data['evaluation'];
    if (eval is! Map) {
      throw StateError('Ungültige Auswertungsantwort');
    }
    return QuizEvaluationSnapshot.fromJson(
      eval.map((key, value) => MapEntry('$key', value)),
    );
  }

  String get _requiredToken {
    final token = pb.authStore.token;
    if (token.isEmpty) {
      throw StateError('Nicht angemeldet');
    }
    return token;
  }

  static final Random _rng = Random();

  static String _newRequestId(String prefix) {
    final ms = DateTime.now().microsecondsSinceEpoch;
    final r = _rng.nextInt(1 << 32);
    return '$prefix-$ms-$r';
  }
}
