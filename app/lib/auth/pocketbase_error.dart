import 'package:pocketbase/pocketbase.dart';

String pocketBaseUserMessage(Object error) {
  if (error is ClientException) {
    final msg = error.response['message'];
    if (msg is String && msg.isNotEmpty) {
      return msg;
    }
    if (error.statusCode != 0) {
      return 'Request failed (${error.statusCode}).';
    }
  }
  return 'Something went wrong. Try again.';
}
