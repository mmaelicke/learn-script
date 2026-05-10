import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import '../config/app_config.dart';
import '../util/debug_console_error.dart';

class CaptureIngestException implements Exception {
  CaptureIngestException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'CaptureIngestException($statusCode): $message';
}

class CaptureIngestResult {
  CaptureIngestResult({
    required this.captureIds,
    required this.gradeUsed,
    required this.subject,
  });

  final List<String> captureIds;
  final int gradeUsed;
  final String subject;
}

/// Multipart POST to agent-backend `/api/v1/ingest/captures`.
Future<CaptureIngestResult> ingestCaptures({
  required String pocketbaseToken,
  required String subject,
  required List<XFile> filesInOrder,
}) async {
  final base = AppConfig.agentBackendUrl;
  final uri = Uri.parse('$base/api/v1/ingest/captures');
  final request = http.MultipartRequest('POST', uri)
    ..headers['Authorization'] = 'Bearer $pocketbaseToken'
    ..fields['subject'] = subject;

  reportInfoToDebugConsole(
    'capture_ingest',
    'POST $uri (${filesInOrder.length} file(s))',
  );

  for (var i = 0; i < filesInOrder.length; i++) {
    final f = filesInOrder[i];
    late final List<int> bytes;
    try {
      bytes = await f.readAsBytes();
    } catch (e, st) {
      reportToDebugConsole(
        'capture_ingest',
        e,
        st,
        'readAsBytes failed for name=${f.name} path=${f.path}',
      );
      throw CaptureIngestException('Could not read image “${f.name}”: $e');
    }
    if (bytes.isEmpty) {
      throw CaptureIngestException('Empty image: ${f.name}');
    }
    final name = f.name.isNotEmpty ? f.name : 'capture_$i.jpg';
    final guessed = lookupMimeType(name, headerBytes: bytes);
    final mediaType = guessed != null ? MediaType.parse(guessed) : MediaType('image', 'jpeg');
    request.files.add(
      http.MultipartFile.fromBytes(
        'files',
        bytes,
        filename: name,
        contentType: mediaType,
      ),
    );
  }

  late final http.StreamedResponse streamed;
  try {
    streamed = await request.send();
  } catch (e, st) {
    reportToDebugConsole(
      'capture_ingest',
      e,
      st,
      'request.send failed url=$uri',
    );
    final hint = kIsWeb
        ? 'Flutter web: the browser often reports this when the API is unreachable or when '
            'CORS is not enabled on the agent-backend. Restart the API after updating it; '
            'or open the browser devtools Network tab for the failed request.'
        : 'On Android emulator use --dart-define=AGENT_BACKEND_URL=http://10.0.2.2:8000 '
            'if the API runs on your computer.';
    throw CaptureIngestException(
      'Could not reach agent backend at $base ($e). $hint',
    );
  }

  final body = await streamed.stream.bytesToString();

  if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
    String detail = body;
    try {
      final map = jsonDecode(body) as Map<String, dynamic>?;
      final d = map?['detail'];
      if (d is String) {
        detail = d;
      } else if (d is List) {
        detail = d.join('\n');
      }
    } catch (_) {}
    const maxBodyPrint = 12000;
    final bodyForConsole = detail.length > maxBodyPrint
        ? '${detail.substring(0, maxBodyPrint)}…\n(truncated for console)'
        : detail;
    reportToDebugConsole(
      'capture_ingest',
      'HTTP ${streamed.statusCode} from $uri',
      null,
      'Response body:\n$bodyForConsole',
    );
    throw CaptureIngestException(
      detail.isNotEmpty ? detail : 'Upload failed',
      statusCode: streamed.statusCode,
    );
  }

  late final Map<String, dynamic> map;
  try {
    map = jsonDecode(body) as Map<String, dynamic>;
  } catch (e, st) {
    final preview = body.length > 2000 ? '${body.substring(0, 2000)}…' : body;
    reportToDebugConsole(
      'capture_ingest',
      e,
      st,
      'JSON decode failed status=${streamed.statusCode} body:\n$preview',
    );
    throw CaptureIngestException(
      'Unexpected response from server (not JSON). Status ${streamed.statusCode}.',
      statusCode: streamed.statusCode,
    );
  }
  final captures = map['captures'] as List<dynamic>? ?? [];
  final ids = <String>[];
  for (final c in captures) {
    if (c is Map<String, dynamic> && c['id'] is String) {
      ids.add(c['id'] as String);
    }
  }
  final gradeUsed = (map['gradeUsed'] is int)
      ? map['gradeUsed'] as int
      : int.tryParse('${map['gradeUsed']}') ?? 5;
  final subj = map['subject'] as String? ?? subject;
  return CaptureIngestResult(
    captureIds: ids,
    gradeUsed: gradeUsed,
    subject: subj,
  );
}
