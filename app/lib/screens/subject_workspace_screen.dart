import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../auth/auth_controller.dart';
import '../curriculum/curriculum_models.dart';
import '../curriculum/curriculum_service.dart';
import '../quiz/quiz_leaf_progress.dart';
import '../quiz/quiz_models.dart';
import '../quiz/quiz_service.dart';
import '../util/debug_console_error.dart';
import '../widgets/responsive_app_shell.dart';
import 'learn_session_screen.dart';

class _WorkspaceData {
  const _WorkspaceData({
    required this.scope,
    required this.sessions,
    required this.questionsBySessionId,
    required this.endedCountsByItemId,
    required this.ongoingItemIds,
  });

  final CurriculumScope scope;
  final List<QuizSession> sessions;
  final Map<String, List<QuizQuestion>> questionsBySessionId;
  final Map<String, int> endedCountsByItemId;
  final Set<String> ongoingItemIds;
}

class SubjectWorkspaceScreen extends StatefulWidget {
  const SubjectWorkspaceScreen({required this.subject, super.key});

  final String subject;

  @override
  State<SubjectWorkspaceScreen> createState() => _SubjectWorkspaceScreenState();
}

class _SubjectWorkspaceScreenState extends State<SubjectWorkspaceScreen>
    with RouteAware {
  late CurriculumService _service;
  late Future<_WorkspaceData> _future;
  CurriculumScope? _scope;
  final Set<String> _selectedItemIds = {};
  final Set<String> _collapsedTopicIds = {};
  String? _editingTopicId;
  String? _editingItemId;
  int? _chromeId;
  ShellChromeController? _chrome;
  PageRoute<dynamic>? _route;
  bool _chromePublishScheduled = false;
  String? _loadedUserId;
  bool _creatingLearnDeck = false;

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
    final auth = AuthInherited.of(context);
    final user = auth.record;
    if (user == null) {
      _future = Future<_WorkspaceData>.error(StateError('Nicht angemeldet'));
      _loadedUserId = null;
      return;
    }
    if (_loadedUserId != user.id) {
      _loadedUserId = user.id;
      _service = CurriculumService(pb: auth.client, user: user);
      _future = _load(client: auth.client);
    }
    _scheduleChromePublish();
  }

  @override
  void didPush() {
    _scheduleChromePublish();
  }

  @override
  void didPopNext() {
    _scheduleChromePublish();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant SubjectWorkspaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subject != widget.subject) {
      _collapsedTopicIds.clear();
    }
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
    final leading = IconButton(
      tooltip: 'Zurück',
      onPressed: () => Navigator.of(context).pop(),
      icon: const Icon(Icons.arrow_back),
    );
    final actions = [
      IconButton(
        tooltip: 'Aktualisieren',
        onPressed: _refresh,
        icon: const Icon(Icons.refresh),
      ),
    ];
    final id = _chromeId;
    if (id == null) {
      _chromeId = chrome.push(
        title: widget.subject,
        leading: leading,
        actions: actions,
      );
    } else {
      chrome.update(
        id,
        title: widget.subject,
        leading: leading,
        actions: actions,
      );
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

  Future<_WorkspaceData> _load({required PocketBase client}) async {
    final scope = await _service.fetchScope(widget.subject);
    _scope = scope;
    _selectedItemIds.removeWhere(
      (id) => !scope.items.any((item) => item.id == id),
    );
    final ended = <String, int>{};
    final ongoing = <String>{};
    final sessions = <QuizSession>[];
    final qsMap = <String, List<QuizQuestion>>{};
    try {
      if (!mounted) {
        return _WorkspaceData(
          scope: scope,
          sessions: sessions,
          questionsBySessionId: qsMap,
          endedCountsByItemId: ended,
          ongoingItemIds: ongoing,
        );
      }
      final svc = QuizService(pb: client);
      final list = await svc.fetchSessionsForSubject(
        subject: scope.subject,
        grade: scope.grade,
      );
      sessions.addAll(list);
      for (final s in sessions) {
        final ids = s.curriculumItemIds;
        if (s.status == 'ended') {
          for (final id in ids) {
            ended[id] = (ended[id] ?? 0) + 1;
          }
        } else if (s.status == 'active' || s.status == 'review') {
          ongoing.addAll(ids);
        }
      }
      final needQs = <String>{};
      for (final item in scope.items) {
        final aid = activeSessionIdForItem(item.id, sessions);
        if (aid != null) {
          needQs.add(aid);
        }
        final did = latestEndedDeepenSessionIdForItem(item.id, sessions);
        if (did != null) {
          needQs.add(did);
        }
      }
      await Future.wait(
        needQs.map((id) async {
          try {
            qsMap[id] = await svc.fetchQuestions(id);
          } catch (_) {}
        }),
      );
    } catch (_) {}
    return _WorkspaceData(
      scope: scope,
      sessions: sessions,
      questionsBySessionId: qsMap,
      endedCountsByItemId: ended,
      ongoingItemIds: ongoing,
    );
  }

  Future<void> _refresh() async {
    final auth = AuthInherited.of(context);
    final client = auth.client;
    setState(() {
      _future = _load(client: client);
    });
    await _future;
  }

  void _showError(Object error, [StackTrace? stackTrace]) {
    if (!mounted) {
      return;
    }
    showAppErrorSnackBar(
      context,
      scope: 'subject_workspace',
      error: error,
      stackTrace: stackTrace,
      message: 'Änderung zurückgesetzt.',
    );
  }

  void _toggleTopic(CurriculumScope scope, CurriculumTopic topic) {
    final ids = scope.descendantItemIds(topic.id);
    final allSelected = ids.isNotEmpty && ids.every(_selectedItemIds.contains);
    setState(() {
      if (allSelected) {
        _selectedItemIds.removeAll(ids);
      } else {
        _selectedItemIds.addAll(ids);
      }
    });
  }

  void _toggleItem(String itemId, bool selected) {
    setState(() {
      if (selected) {
        _selectedItemIds.add(itemId);
      } else {
        _selectedItemIds.remove(itemId);
      }
    });
  }

  Future<void> _renameTopic(CurriculumTopic topic, String title) async {
    final trimmed = title.trim();
    setState(() => _editingTopicId = null);
    if (trimmed.isEmpty || trimmed == topic.title) {
      return;
    }
    final previous = _scope;
    try {
      await _service.renameTopic(topic, trimmed);
      await _refresh();
    } catch (e, st) {
      _scope = previous;
      _showError(e, st);
      await _refresh();
    }
  }

  Future<void> _renameItem(CurriculumItem item, String title) async {
    final trimmed = title.trim();
    setState(() => _editingItemId = null);
    if (trimmed.isEmpty || trimmed == item.title) {
      return;
    }
    final previous = _scope;
    try {
      await _service.renameItem(item, trimmed);
      await _refresh();
    } catch (e, st) {
      _scope = previous;
      _showError(e, st);
      await _refresh();
    }
  }

  Future<void> _moveTopic(
    CurriculumTopic topic,
    String? parentId, {
    String? beforeId,
  }) async {
    final scope = _scope;
    if (scope == null) {
      return;
    }
    try {
      await _service.moveTopic(
        scope: scope,
        topic: topic,
        newParentId: parentId,
        beforeTopicId: beforeId,
      );
      await _refresh();
    } catch (e, st) {
      _showError(e, st);
      await _refresh();
    }
  }

  Future<void> _moveItem(
    CurriculumItem item,
    String topicId, {
    String? beforeId,
  }) async {
    final scope = _scope;
    if (scope == null) {
      return;
    }
    try {
      await _service.moveItem(
        scope: scope,
        item: item,
        newTopicId: topicId,
        beforeItemId: beforeId,
      );
      await _refresh();
    } catch (e, st) {
      _showError(e, st);
      await _refresh();
    }
  }

  String _leafDeckTooltip(
    String itemId,
    List<QuizSession> sessions,
    Map<String, List<QuizQuestion>> qs,
  ) {
    if (activeSessionIdForItem(itemId, sessions) != null) {
      return 'Quiz fortsetzen';
    }
    final nk = nextKindForSingleLeaf(
      itemId,
      sessions,
      questionsBySessionId: qs,
    );
    if (nk == null) {
      return 'Abgeschlossen';
    }
    switch (nk) {
      case QuizSessionKind.assessment:
        return 'Check-up starten';
      case QuizSessionKind.learn:
        return 'Lern-Deck starten';
      case QuizSessionKind.deepen:
        return 'Vertiefung starten';
    }
  }

  void _openItem(CurriculumItem item) {
    final scope = _scope;
    if (scope == null) {
      return;
    }
    Navigator.of(context).push<void>(
      InstantShellRoute<void>(
        builder: (_) => CurriculumItemDetailScreen(
          subject: widget.subject,
          service: _service,
          itemsInOrder: scope.itemsInTocOrder(),
          initialItemId: item.id,
        ),
      ),
    );
  }

  Future<void> _startLearnDeck({
    List<String>? itemIds,
    QuizSessionKind multiKind = QuizSessionKind.learn,
  }) async {
    final ids = itemIds ?? _selectedItemIds.toList(growable: false);
    if (ids.isEmpty || ids.length > 12 || _creatingLearnDeck) {
      return;
    }
    final scope = _scope;
    if (scope == null) {
      return;
    }
    setState(() => _creatingLearnDeck = true);
    try {
      final auth = AuthInherited.of(context);
      final svc = QuizService(pb: auth.client);
      if (ids.length == 1) {
        final only = ids.single;
        final sessions = await svc.fetchSessionsForSubject(
          subject: scope.subject,
          grade: scope.grade,
        );
        final resume = activeSessionIdForItem(only, sessions);
        if (resume != null) {
          if (!mounted) {
            return;
          }
          await Navigator.of(context).push<void>(
            InstantShellRoute<void>(
              builder: (_) => LearnSessionScreen(sessionId: resume),
            ),
          );
          await _refresh();
          return;
        }
        final qs = <String, List<QuizQuestion>>{};
        final did = latestEndedDeepenSessionIdForItem(only, sessions);
        if (did != null) {
          try {
            qs[did] = await svc.fetchQuestions(did);
          } catch (_) {}
        }
        final nk = nextKindForSingleLeaf(
          only,
          sessions,
          questionsBySessionId: qs,
        );
        if (nk == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Für diesen Inhalt ist die Reihe abgeschlossen.'),
              ),
            );
          }
          return;
        }
        const basis = QuizProgressBasis.questions;
        final (int qc, int? tls) = switch (nk) {
          QuizSessionKind.assessment => (5, null),
          QuizSessionKind.learn => (10, 1200),
          QuizSessionKind.deepen => (10, 1200),
        };
        final session = await svc.createQuizSession(
          subject: widget.subject,
          curriculumItemIds: [only],
          kind: nk,
          progressBasis: basis,
          questionCount: qc,
          timeLimitSeconds: tls,
        );
        if (!mounted) {
          return;
        }
        await Navigator.of(context).push<void>(
          InstantShellRoute<void>(
            builder: (_) => LearnSessionScreen(sessionId: session.id),
          ),
        );
      } else {
        final qc = multiKind == QuizSessionKind.assessment
            ? assessmentQuestionCount(ids.length)
            : 10;
        final tls = multiKind == QuizSessionKind.assessment ? null : 1200;
        final session = await svc.createQuizSession(
          subject: widget.subject,
          curriculumItemIds: ids,
          kind: multiKind,
          progressBasis: QuizProgressBasis.questions,
          questionCount: qc,
          timeLimitSeconds: tls,
        );
        if (!mounted) {
          return;
        }
        await Navigator.of(context).push<void>(
          InstantShellRoute<void>(
            builder: (_) => LearnSessionScreen(sessionId: session.id),
          ),
        );
      }
    } catch (e, st) {
      if (!mounted) {
        return;
      }
      showAppErrorSnackBar(
        context,
        scope: 'quiz_learn_deck',
        error: e,
        stackTrace: st,
        message: 'Lern-Deck konnte nicht gestartet werden.',
      );
    } finally {
      if (mounted) {
        setState(() => _creatingLearnDeck = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_WorkspaceData>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final scope = data?.scope ?? _scope;
        if (snapshot.connectionState != ConnectionState.done && scope == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError && scope == null) {
          return Center(
            child: Text(
              'Inhalte konnten nicht geladen werden.\n${snapshot.error}',
            ),
          );
        }
        if (scope == null) {
          return const SizedBox.shrink();
        }
        final ended = data?.endedCountsByItemId ?? const <String, int>{};
        final ongoing = data?.ongoingItemIds ?? const <String>{};
        final sessions = data?.sessions ?? const <QuizSession>[];
        final qmap =
            data?.questionsBySessionId ?? const <String, List<QuizQuestion>>{};
        return Column(
          children: [
            _SelectionBar(
              count: _selectedItemIds.length,
              creating: _creatingLearnDeck,
              defaultKind: defaultKindForSelection(
                _selectedItemIds.toList(),
                sessions,
              ),
              onStartLearnDeck: (kind) => _startLearnDeck(multiKind: kind),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: scope.topics.isEmpty && scope.items.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(24),
                        children: const [
                          Text(
                            'Die Aufnahmen werden noch in Themen und Inhalte einsortiert.',
                          ),
                        ],
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                        children: _buildTopicTree(
                          scope,
                          null,
                          0,
                          ended,
                          ongoing,
                          sessions,
                          qmap,
                        ),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  bool _topicHasExpandableSubtree(CurriculumScope scope, CurriculumTopic topic) {
    return scope.topics.any((t) => t.parentId == topic.id) ||
        scope.items.any((item) => item.topicId == topic.id);
  }

  List<Widget> _buildTopicTree(
    CurriculumScope scope,
    String? parentId,
    int depth,
    Map<String, int> endedCountsByItemId,
    Set<String> ongoingItemIds,
    List<QuizSession> sessions,
    Map<String, List<QuizQuestion>> questionsBySessionId,
  ) {
    final topics =
        scope.topics.where((topic) => topic.parentId == parentId).toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final widgets = <Widget>[];
    for (final topic in topics) {
      widgets.add(
        _TopicDropBefore(
          depth: depth,
          onAccept: (payload) {
            if (payload.topic != null) {
              _moveTopic(payload.topic!, parentId, beforeId: topic.id);
            }
          },
        ),
      );
      final hasSubtree = _topicHasExpandableSubtree(scope, topic);
      final isCollapsed = _collapsedTopicIds.contains(topic.id);
      widgets.add(
        _TopicRow(
          topic: topic,
          depth: depth,
          selectedCount: scope
              .descendantItemIds(topic.id)
              .where(_selectedItemIds.contains)
              .length,
          totalCount: scope.descendantItemIds(topic.id).length,
          editing: _editingTopicId == topic.id,
          hasExpandableSubtree: hasSubtree,
          isCollapsed: isCollapsed,
          onToggleCollapse: hasSubtree
              ? () => setState(() {
                  if (_collapsedTopicIds.contains(topic.id)) {
                    _collapsedTopicIds.remove(topic.id);
                  } else {
                    _collapsedTopicIds.add(topic.id);
                  }
                })
              : null,
          onSelect: () => _toggleTopic(scope, topic),
          onEdit: () => setState(() => _editingTopicId = topic.id),
          onRename: (title) => _renameTopic(topic, title),
          onDropInside: (payload) {
            if (payload.topic != null) {
              _moveTopic(payload.topic!, topic.id);
            } else if (payload.item != null) {
              _moveItem(payload.item!, topic.id);
            }
          },
        ),
      );
      if (!isCollapsed) {
        final items =
            scope.items.where((item) => item.topicId == topic.id).toList()
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        for (final item in items) {
          widgets.add(
            _ItemDropBefore(
              depth: depth + 1,
              onAccept: (payload) {
                if (payload.item != null) {
                  _moveItem(payload.item!, topic.id, beforeId: item.id);
                }
              },
            ),
          );
          final _nextKind = nextKindForSingleLeaf(
            item.id,
            sessions,
            questionsBySessionId: questionsBySessionId,
          );
          final _isOngoing = activeSessionIdForItem(item.id, sessions) != null;
          final _deckIcon =
              (_isOngoing || _nextKind == QuizSessionKind.assessment)
                  ? Icons.quiz_outlined
                  : Icons.school_outlined;
          widgets.add(
            _ItemRow(
              item: item,
              depth: depth + 1,
              selected: _selectedItemIds.contains(item.id),
              editing: _editingItemId == item.id,
              endedSessionCount: endedCountsByItemId[item.id] ?? 0,
              learnDeckOngoing: _isOngoing,
              leafRingProgress: leafRingProgress(
                item.id,
                sessions,
                questionsBySessionId,
              ),
              deepenCheckMarks: deepenShowsDoubleCheckForItem(
                    item.id,
                    sessions,
                    questionsBySessionId,
                  )
                  ? 2
                  : (deepenShowsSingleCheck(
                        item.id,
                        sessions,
                        questionsBySessionId,
                      )
                      ? 1
                      : 0),
              deckEnabled: _isOngoing || _nextKind != null,
              deckIcon: _deckIcon,
              deckTooltip: _leafDeckTooltip(
                item.id,
                sessions,
                questionsBySessionId,
              ),
              onSelected: (value) => _toggleItem(item.id, value),
              onOpen: () => _openItem(item),
              onStartLearnDeck: () => _startLearnDeck(itemIds: [item.id]),
              onEdit: () => setState(() => _editingItemId = item.id),
              onRename: (title) => _renameItem(item, title),
            ),
          );
        }
        widgets.addAll(
          _buildTopicTree(
            scope,
            topic.id,
            depth + 1,
            endedCountsByItemId,
            ongoingItemIds,
            sessions,
            questionsBySessionId,
          ),
        );
      }
    }
    return widgets;
  }
}

class _DragPayload {
  const _DragPayload.topic(this.topic) : item = null;
  const _DragPayload.item(this.item) : topic = null;

  final CurriculumTopic? topic;
  final CurriculumItem? item;
}

class _SelectionBar extends StatefulWidget {
  const _SelectionBar({
    required this.count,
    required this.creating,
    required this.defaultKind,
    required this.onStartLearnDeck,
  });

  final int count;
  final bool creating;
  final QuizSessionKind defaultKind;
  final ValueChanged<QuizSessionKind> onStartLearnDeck;

  @override
  State<_SelectionBar> createState() => _SelectionBarState();
}

class _SelectionBarState extends State<_SelectionBar> {
  late QuizSessionKind _selectedKind;

  @override
  void initState() {
    super.initState();
    _selectedKind = widget.defaultKind;
  }

  @override
  void didUpdateWidget(covariant _SelectionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.defaultKind != widget.defaultKind) {
      _selectedKind = widget.defaultKind;
    }
  }

  @override
  Widget build(BuildContext context) {
    final canStart = widget.count > 0 && widget.count <= 12 && !widget.creating;
    final warning = widget.count > 12
        ? 'Aktuell sind maximal 12 Inhalte im Lern-Deck möglich.'
        : widget.count == 0
        ? 'Wähle mindestens einen Inhalt aus.'
        : null;
    final icon = _selectedKind == QuizSessionKind.assessment
        ? Icons.quiz_outlined
        : Icons.school_outlined;
    final label = _selectedKind == QuizSessionKind.assessment
        ? 'Assessment starten'
        : 'Lernen starten';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Text('${widget.count} Inhalte im Kontext'),
                  if (warning != null)
                    Tooltip(
                      message: warning,
                      child: Text(
                        warning,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: null,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Chat'),
            ),
            Tooltip(
              message: warning ?? label,
              child: TextButton.icon(
                onPressed:
                    canStart ? () => widget.onStartLearnDeck(_selectedKind) : null,
                icon: widget.creating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon),
                label: Text(label),
              ),
            ),
            PopupMenuButton<QuizSessionKind>(
              tooltip: 'Session-Typ wählen',
              icon: const Icon(Icons.arrow_drop_down),
              onSelected: (kind) => setState(() => _selectedKind = kind),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: QuizSessionKind.assessment,
                  child: Text('Assessment starten'),
                ),
                PopupMenuItem(
                  value: QuizSessionKind.learn,
                  child: Text('Lernen starten'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TopicRow extends StatefulWidget {
  const _TopicRow({
    required this.topic,
    required this.depth,
    required this.selectedCount,
    required this.totalCount,
    required this.editing,
    required this.hasExpandableSubtree,
    required this.isCollapsed,
    required this.onToggleCollapse,
    required this.onSelect,
    required this.onEdit,
    required this.onRename,
    required this.onDropInside,
  });

  final CurriculumTopic topic;
  final int depth;
  final int selectedCount;
  final int totalCount;
  final bool editing;
  final bool hasExpandableSubtree;
  final bool isCollapsed;
  final VoidCallback? onToggleCollapse;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final ValueChanged<String> onRename;
  final ValueChanged<_DragPayload> onDropInside;

  @override
  State<_TopicRow> createState() => _TopicRowState();
}

class _TopicRowState extends State<_TopicRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.topic.title,
  );
  late final FocusNode _focusNode = FocusNode();

  @override
  void didUpdateWidget(covariant _TopicRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topic.title != widget.topic.title && !widget.editing) {
      _controller.text = widget.topic.title;
    }
    if (widget.editing && !oldWidget.editing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && widget.editing) {
        widget.onRename(_controller.text);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected =
        widget.totalCount > 0 && widget.selectedCount == widget.totalCount;
    final partial = widget.selectedCount > 0 && !selected;
    return DragTarget<_DragPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.topic?.id != widget.topic.id,
      onAcceptWithDetails: (details) => widget.onDropInside(details.data),
      builder: (context, candidates, _) {
        return Draggable<_DragPayload>(
          data: _DragPayload.topic(widget.topic),
          feedback: _DragChip(
            label: widget.topic.title,
            icon: Icons.folder_outlined,
          ),
          childWhenDragging: Opacity(
            opacity: 0.45,
            child: _buildRow(context, selected, partial, candidates.isNotEmpty),
          ),
          child: _buildRow(context, selected, partial, candidates.isNotEmpty),
        );
      },
    );
  }

  Widget _buildRow(
    BuildContext context,
    bool selected,
    bool partial,
    bool hover,
  ) {
    return ListTile(
      dense: true,
      tileColor: hover ? Theme.of(context).colorScheme.primaryContainer : null,
      contentPadding: EdgeInsets.only(left: 12 + widget.depth * 22, right: 8),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.drag_indicator, size: 20),
          if (widget.hasExpandableSubtree)
            SizedBox(
              width: 36,
              height: 36,
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: widget.isCollapsed ? 'Aufklappen' : 'Zuklappen',
                onPressed: widget.onToggleCollapse,
                icon: Transform.rotate(
                  angle: widget.isCollapsed ? -math.pi / 2 : 0,
                  child: const Icon(Icons.expand_more, size: 22),
                ),
              ),
            )
          else
            const SizedBox(width: 36, height: 36),
          Checkbox(
            value: partial ? null : selected,
            tristate: true,
            onChanged: widget.totalCount == 0 ? null : (_) => widget.onSelect(),
          ),
          const Icon(Icons.folder_outlined),
        ],
      ),
      title: widget.editing
          ? TextField(
              controller: _controller,
              focusNode: _focusNode,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
              ),
              onSubmitted: widget.onRename,
            )
          : Text(widget.topic.title),
      subtitle: Text('${widget.selectedCount}/${widget.totalCount} ausgewählt'),
      trailing: IconButton(
        tooltip: 'Umbenennen',
        onPressed: widget.onEdit,
        icon: const Icon(Icons.edit_outlined),
      ),
      onTap: widget.totalCount == 0 ? null : widget.onSelect,
    );
  }
}

class _ItemRow extends StatefulWidget {
  const _ItemRow({
    required this.item,
    required this.depth,
    required this.selected,
    required this.editing,
    required this.endedSessionCount,
    required this.learnDeckOngoing,
    required this.leafRingProgress,
    required this.deepenCheckMarks,
    required this.deckEnabled,
    required this.deckIcon,
    required this.deckTooltip,
    required this.onSelected,
    required this.onOpen,
    required this.onStartLearnDeck,
    required this.onEdit,
    required this.onRename,
  });

  final CurriculumItem item;
  final int depth;
  final bool selected;
  final bool editing;
  final int endedSessionCount;
  final bool learnDeckOngoing;
  final double leafRingProgress;
  final int deepenCheckMarks;
  final bool deckEnabled;
  final IconData deckIcon;
  final String deckTooltip;
  final ValueChanged<bool> onSelected;
  final VoidCallback onOpen;
  final VoidCallback onStartLearnDeck;
  final VoidCallback onEdit;
  final ValueChanged<String> onRename;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.item.title,
  );
  late final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && widget.editing) {
        widget.onRename(_controller.text);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _ItemRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.title != widget.item.title && !widget.editing) {
      _controller.text = widget.item.title;
    }
    if (widget.editing && !oldWidget.editing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Draggable<_DragPayload>(
      data: _DragPayload.item(widget.item),
      feedback: _DragChip(
        label: widget.item.title,
        icon: Icons.article_outlined,
      ),
      childWhenDragging: Opacity(opacity: 0.45, child: _buildTile(context)),
      child: _buildTile(context),
    );
  }

  Widget _buildTile(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.only(left: 12 + widget.depth * 22, right: 8),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.drag_indicator, size: 20),
          Checkbox(
            value: widget.selected,
            onChanged: (value) => widget.onSelected(value == true),
          ),
          _LeafProgressLeading(
            progress: widget.leafRingProgress,
            checkMarks: widget.deepenCheckMarks,
          ),
        ],
      ),
      title: widget.editing
          ? TextField(
              controller: _controller,
              focusNode: _focusNode,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
              ),
              onSubmitted: widget.onRename,
            )
          : Row(
              children: [
                Expanded(child: Text(widget.item.title)),
                if (widget.endedSessionCount > 0) ...[
                  const SizedBox(width: 8),
                  Badge.count(
                    count: widget.endedSessionCount,
                    isLabelVisible: true,
                  ),
                ],
              ],
            ),
      subtitle: widget.item.summaryDocument.isEmpty
          ? null
          : Text(
              widget.item.summaryDocument,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Wrap(
        spacing: 2,
        children: [
          IconButton(
            tooltip: 'Chat (später)',
            onPressed: null,
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          _LearnDeckIconButton(
            ongoing: widget.learnDeckOngoing,
            icon: widget.deckIcon,
            tooltip: widget.deckTooltip,
            onPressed: widget.deckEnabled ? widget.onStartLearnDeck : null,
          ),
          IconButton(
            tooltip: 'Umbenennen',
            onPressed: widget.onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      onTap: widget.onOpen,
    );
  }
}

class _LearnDeckIconButton extends StatelessWidget {
  const _LearnDeckIconButton({
    required this.ongoing,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final bool ongoing;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          tooltip: ongoing ? 'Quiz (läuft)' : tooltip,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
        if (ongoing)
          Positioned(
            right: 6,
            top: 6,
            child: IgnorePointer(
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _LeafProgressLeading extends StatelessWidget {
  const _LeafProgressLeading({
    required this.progress,
    required this.checkMarks,
  });

  final double progress;
  final int checkMarks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ringColor = progress < 0.5 ? scheme.tertiary : scheme.primary;
    return SizedBox(
      width: 44,
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              strokeWidth: 2.5,
              backgroundColor: scheme.surfaceContainerHighest,
              color: ringColor,
            ),
          ),
          if (checkMarks > 0) ...[
            const SizedBox(width: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check, size: 12, color: scheme.primary),
                if (checkMarks > 1)
                  Icon(Icons.check, size: 12, color: scheme.primary),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TopicDropBefore extends StatelessWidget {
  const _TopicDropBefore({required this.depth, required this.onAccept});

  final int depth;
  final ValueChanged<_DragPayload> onAccept;

  @override
  Widget build(BuildContext context) {
    return _DropLine(
      depth: depth,
      accepts: (payload) => payload.topic != null,
      onAccept: onAccept,
    );
  }
}

class _ItemDropBefore extends StatelessWidget {
  const _ItemDropBefore({required this.depth, required this.onAccept});

  final int depth;
  final ValueChanged<_DragPayload> onAccept;

  @override
  Widget build(BuildContext context) {
    return _DropLine(
      depth: depth,
      accepts: (payload) => payload.item != null,
      onAccept: onAccept,
    );
  }
}

class _DropLine extends StatelessWidget {
  const _DropLine({
    required this.depth,
    required this.accepts,
    required this.onAccept,
  });

  final int depth;
  final bool Function(_DragPayload payload) accepts;
  final ValueChanged<_DragPayload> onAccept;

  @override
  Widget build(BuildContext context) {
    return DragTarget<_DragPayload>(
      onWillAcceptWithDetails: (details) => accepts(details.data),
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidates, _) {
        return Container(
          margin: EdgeInsets.only(left: 12 + depth * 22, right: 12),
          height: candidates.isEmpty ? 6 : 18,
          decoration: BoxDecoration(
            border: candidates.isEmpty
                ? null
                : Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _DragChip extends StatelessWidget {
  const _DragChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class CurriculumItemDetailScreen extends StatefulWidget {
  const CurriculumItemDetailScreen({
    required this.subject,
    required this.service,
    required this.itemsInOrder,
    required this.initialItemId,
    super.key,
  });

  final String subject;
  final CurriculumService service;
  final List<CurriculumItem> itemsInOrder;
  final String initialItemId;

  @override
  State<CurriculumItemDetailScreen> createState() =>
      _CurriculumItemDetailScreenState();
}

class _CurriculumItemDetailScreenState extends State<CurriculumItemDetailScreen>
    with RouteAware {
  late int _index;
  late final PageController _controller;
  int? _chromeId;
  ShellChromeController? _chrome;
  PageRoute<dynamic>? _route;
  bool _chromePublishScheduled = false;

  @override
  void initState() {
    super.initState();
    final found = widget.itemsInOrder.indexWhere(
      (item) => item.id == widget.initialItemId,
    );
    _index = found < 0 ? 0 : found;
    _controller = PageController(initialPage: _index);
  }

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
    _scheduleChromePublish();
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
    _controller.dispose();
    super.dispose();
  }

  void _publishChrome() {
    if (!_routeIsCurrent) {
      return;
    }
    final chrome = ShellChrome.read(context);
    _chrome = chrome;
    final title = widget.itemsInOrder[_index].title;
    final leading = IconButton(
      tooltip: 'Zurück',
      onPressed: () => Navigator.of(context).pop(),
      icon: const Icon(Icons.arrow_back),
    );
    final id = _chromeId;
    if (id == null) {
      _chromeId = chrome.push(title: title, leading: leading);
    } else {
      chrome.update(id, title: title, leading: leading, actions: const []);
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

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.itemsInOrder.length) {
      return;
    }
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView.builder(
        controller: _controller,
        onPageChanged: (index) {
          setState(() {
            _index = index;
          });
          _publishChrome();
        },
        itemCount: widget.itemsInOrder.length,
        itemBuilder: (context, pageIndex) {
          final pageItem = widget.itemsInOrder[pageIndex];
          return _ItemDetailBody(
            key: ValueKey(pageItem.id),
            item: pageItem,
            service: widget.service,
            canGoPrevious: pageIndex > 0,
            canGoNext: pageIndex < widget.itemsInOrder.length - 1,
            onPrevious: () => _go(-1),
            onNext: () => _go(1),
          );
        },
      ),
    );
  }
}

class _ItemDetailBody extends StatefulWidget {
  const _ItemDetailBody({
    required this.item,
    required this.service,
    required this.canGoPrevious,
    required this.canGoNext,
    required this.onPrevious,
    required this.onNext,
    super.key,
  });

  final CurriculumItem item;
  final CurriculumService service;
  final bool canGoPrevious;
  final bool canGoNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  State<_ItemDetailBody> createState() => _ItemDetailBodyState();
}

class _ItemDetailBodyState extends State<_ItemDetailBody> {
  late Future<List<CaptureImage>> _capturesFuture;

  @override
  void initState() {
    super.initState();
    _capturesFuture = widget.service.fetchCaptureImages(widget.item.captureIds);
  }

  @override
  void didUpdateWidget(covariant _ItemDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _capturesFuture = widget.service.fetchCaptureImages(
        widget.item.captureIds,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Vorheriger Inhalt',
              onPressed: widget.canGoPrevious ? widget.onPrevious : null,
              icon: const Icon(Icons.chevron_left),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Nächster Inhalt',
              onPressed: widget.canGoNext ? widget.onNext : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (widget.item.summaryDocument.isNotEmpty) ...[
          Text(widget.item.summaryDocument),
          const SizedBox(height: 24),
        ],
        FutureBuilder<List<CaptureImage>>(
          future: _capturesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 240,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Text(
                'Aufnahmen konnten nicht geladen werden: ${snapshot.error}',
              );
            }
            final captures = snapshot.data ?? const [];
            if (captures.isEmpty) {
              return const Text('Keine Aufnahme verknüpft.');
            }
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final capture in captures)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      capture.url.toString(),
                      width: captures.length == 1 ? double.infinity : 280,
                      fit: BoxFit.contain,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
