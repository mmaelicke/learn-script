import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../capture_ingest/capture_subject_suggestions.dart';
import '../curriculum/curriculum_models.dart';
import '../widgets/responsive_app_shell.dart';
import 'subject_workspace_screen.dart';

class SubjectListScreen extends StatefulWidget {
  const SubjectListScreen({super.key});

  @override
  State<SubjectListScreen> createState() => _SubjectListScreenState();
}

class _SubjectListScreenState extends State<SubjectListScreen> with RouteAware {
  late Future<List<String>> _future;
  int? _chromeId;
  ShellChromeController? _chrome;
  PageRoute<dynamic>? _route;
  bool _chromePublishScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      final oldRoute = _route;
      if (oldRoute != null) {
        appShellRouteObserver.unsubscribe(this);
      }
      _route = route;
      appShellRouteObserver.subscribe(this, route);
    }
    final chrome = ShellChrome.read(context);
    _chrome = chrome;
    _scheduleChromePublish();
    final auth = AuthInherited.of(context);
    final user = auth.record;
    _future = user == null
        ? Future<List<String>>.value(const [])
        : fetchDistinctCaptureSubjects(pb: auth.client, user: user);
  }

  @override
  void didPush() {
    _scheduleChromePublish();
  }

  @override
  void didPopNext() {
    _scheduleChromePublish();
  }

  @override
  void dispose() {
    appShellRouteObserver.unsubscribe(this);
    final id = _chromeId;
    if (id != null) {
      _chrome?.discard(id);
    }
    super.dispose();
  }

  void _publishChrome() {
    if (!_routeIsCurrent) {
      return;
    }
    final chrome = ShellChrome.read(context);
    _chrome = chrome;
    final id = _chromeId;
    if (id == null) {
      _chromeId = chrome.push(title: 'Fächer');
    } else {
      chrome.update(id, title: 'Fächer', clearLeading: true, actions: const []);
      chrome.activate(id);
    }
  }

  void _scheduleChromePublish() {
    if (_chromePublishScheduled) {
      return;
    }
    _chromePublishScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chromePublishScheduled = false;
      if (!mounted) {
        return;
      }
      _publishChrome();
    });
  }

  bool get _routeIsCurrent => _route?.isCurrent ?? true;

  void _openSubject(String subject) {
    Navigator.of(context).push<void>(
      InstantShellRoute<void>(
        settings: RouteSettings(
          name: '/subjects/${Uri.encodeComponent(subject)}',
          arguments: SubjectRouteArgs(subject: subject),
        ),
        builder: (_) => SubjectWorkspaceScreen(subject: subject),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<String>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Fächer konnten nicht geladen werden.\n${snapshot.error}',
              ),
            ),
          );
        }
        final subjects = snapshot.data ?? const [];
        if (subjects.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Noch keine Fächer mit Aufnahmen.',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            final auth = AuthInherited.of(context);
            final user = auth.record;
            setState(() {
              _future = user == null
                  ? Future<List<String>>.value(const [])
                  : fetchDistinctCaptureSubjects(pb: auth.client, user: user);
            });
            await _future;
          },
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: subjects.length + 1,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text('Fächer', style: theme.textTheme.headlineSmall),
                );
              }
              final subject = subjects[index - 1];
              return Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(subject),
                  subtitle: const Text('Topic-Hierarchie öffnen'),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        tooltip: 'Fragen stellen (später)',
                        onPressed: null,
                        icon: const Icon(Icons.chat_bubble_outline),
                      ),
                      IconButton(
                        tooltip: 'Letzte Sitzung fortsetzen (später)',
                        onPressed: null,
                        icon: const Icon(Icons.play_circle_outline),
                      ),
                      IconButton(
                        tooltip: 'Öffnen',
                        onPressed: () => _openSubject(subject),
                        icon: const Icon(Icons.arrow_forward),
                      ),
                    ],
                  ),
                  onTap: () => _openSubject(subject),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
