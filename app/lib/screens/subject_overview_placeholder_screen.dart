import 'package:flutter/material.dart';

import '../ui/de_strings.dart';

/// Shell body placeholder after a successful batch ingest (content later).
class SubjectOverviewPlaceholderScreen extends StatelessWidget {
  const SubjectOverviewPlaceholderScreen({required this.subject, super.key});

  final String subject;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              DeStrings.overviewStubTitle,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Text(
              DeStrings.overviewStubBody(subject),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
