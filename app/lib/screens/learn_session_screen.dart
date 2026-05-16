import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_controller.dart';
import '../quiz/quiz_models.dart';
import '../quiz/quiz_service.dart';
import '../widgets/responsive_app_shell.dart';

enum _LimitMode { time, questions }

const _kMinQuestionLimit = 1;
const _kMaxQuestionLimit = 500;
const _kMinTimeMinutes = 1;
const _kMaxTimeMinutes = 480;

class LearnSessionScreen extends StatefulWidget {
  const LearnSessionScreen({required this.sessionId, super.key});

  final String sessionId;

  @override
  State<LearnSessionScreen> createState() => _LearnSessionScreenState();
}

class _LearnSessionScreenState extends State<LearnSessionScreen>
    with RouteAware {
  late QuizService _service;
  QuizSession? _session;
  List<QuizQuestion> _questions = const [];
  String _activityText = 'Lern-Deck wird vorbereitet...';
  String _reviewText = '';
  String? _error;
  bool _loading = true;
  bool _streaming = false;
  String? _checkingQuestionId;
  bool _started = false;
  bool _chromePublishScheduled = false;
  _LimitMode _limitMode = _LimitMode.questions;
  int _timeLimitMinutes = 20;
  int _questionLimit = 10;
  int? _chromeId;
  ShellChromeController? _chrome;
  PageRoute<dynamic>? _route;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  QuizProgressSnapshot? _progressSnapshot;
  bool _sessionLimitsApplied = false;
  DateTime? _timeLimitAnchor;
  late final TextEditingController _questionLimitController;
  late final TextEditingController _timeLimitController;
  late final FocusNode _questionLimitFocus;
  late final FocusNode _timeLimitFocus;

  @override
  void initState() {
    super.initState();
    _questionLimitController = TextEditingController(text: '$_questionLimit');
    _timeLimitController = TextEditingController(text: '$_timeLimitMinutes');
    _questionLimitFocus = FocusNode();
    _timeLimitFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant LearnSessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _sessionLimitsApplied = false;
      _timeLimitAnchor = null;
      _ticker?.cancel();
      _questionLimitController.text = '$_questionLimit';
      _timeLimitController.text = '$_timeLimitMinutes';
      unawaited(_loadAndStart());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _service = QuizService(pb: AuthInherited.of(context).client);
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      final oldRoute = _route;
      if (oldRoute != null) appShellRouteObserver.unsubscribe(this);
      _route = route;
      appShellRouteObserver.subscribe(this, route);
    }
    _scheduleChromePublish();
    if (!_started) {
      _started = true;
      unawaited(_loadAndStart());
    }
  }

  @override
  void didPush() => _scheduleChromePublish();

  @override
  void didPopNext() => _scheduleChromePublish();

  @override
  void dispose() {
    _ticker?.cancel();
    appShellRouteObserver.unsubscribe(this);
    final id = _chromeId;
    if (id != null) _chrome?.discard(id);
    _questionLimitController.dispose();
    _timeLimitController.dispose();
    _questionLimitFocus.dispose();
    _timeLimitFocus.dispose();
    super.dispose();
  }

  void _scheduleChromePublish() {
    if (_chromePublishScheduled) return;
    _chromePublishScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chromePublishScheduled = false;
      if (!mounted) return;
      _publishChrome();
    });
  }

  void _publishChrome() {
    if (!(_route?.isCurrent ?? true)) return;
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
        onPressed: () => unawaited(_reloadAndEnsureIfGap()),
        icon: const Icon(Icons.refresh),
      ),
    ];
    final id = _chromeId;
    final title = switch (_session?.effectiveKind) {
      QuizSessionKind.assessment => 'Check-up',
      QuizSessionKind.deepen => 'Vertiefung',
      QuizSessionKind.learn => 'Lern-Deck',
      null => 'Lern-Deck',
    };
    if (id == null) {
      _chromeId = chrome.push(title: title, leading: leading, actions: actions);
    } else {
      chrome.update(id, title: title, leading: leading, actions: actions);
      chrome.activate(id);
    }
  }

  Future<void> _loadAndStart() async {
    await _reload();
    if (!mounted) return;
    _scheduleChromePublish();
    if (_questions.isEmpty) {
      await _requestNextQuestion();
      if (mounted) {
        _scheduleChromePublish();
      }
      return;
    }
    if (_session?.status != 'active') return;
    if (_limitMode != _LimitMode.questions) return;
    final answeredQs = _questions.where((q) => q.answered).toList();
    if (_questions.any((q) => !q.answered)) return;
    if (answeredQs.isEmpty) return;
    if (_isLimitReached) return;
    await _requestNextQuestion();
    if (mounted) {
      _scheduleChromePublish();
    }
  }

  void _startTicker(DateTime anchor) {
    _ticker?.cancel();
    _elapsed = DateTime.now().difference(anchor);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _ticker?.cancel();
        return;
      }
      setState(() => _elapsed = DateTime.now().difference(anchor));
    });
  }

  void _syncTimeTickerForSession(String status) {
    if (status == 'active' && _limitMode == _LimitMode.time) {
      _timeLimitAnchor ??= DateTime.now();
      _startTicker(_timeLimitAnchor!);
    } else {
      _ticker?.cancel();
    }
  }

  Future<void> _onLimitModeChanged(_LimitMode mode) async {
    setState(() => _limitMode = mode);
    _syncTimeTickerForSession(_session?.status ?? '');
    try {
      await _service.updateProgressBasis(
        sessionId: widget.sessionId,
        basis: mode == _LimitMode.questions
            ? QuizProgressBasis.questions
            : QuizProgressBasis.time,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    }
  }

  Future<void> _commitQuestionLimitFromField() async {
    final parsed = int.tryParse(_questionLimitController.text.trim());
    if (parsed == null) {
      setState(() => _questionLimitController.text = '$_questionLimit');
      return;
    }
    final v = parsed.clamp(_kMinQuestionLimit, _kMaxQuestionLimit);
    _questionLimitController.text = '$v';
    if (v == _questionLimit) {
      return;
    }
    setState(() => _questionLimit = v);
    try {
      await _service.updateSessionLimits(
        sessionId: widget.sessionId,
        questionCount: v,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _commitTimeLimitFromField() async {
    final parsed = int.tryParse(_timeLimitController.text.trim());
    if (parsed == null) {
      setState(() => _timeLimitController.text = '$_timeLimitMinutes');
      return;
    }
    final v = parsed.clamp(_kMinTimeMinutes, _kMaxTimeMinutes);
    _timeLimitController.text = '$v';
    if (v == _timeLimitMinutes) {
      return;
    }
    setState(() => _timeLimitMinutes = v);
    try {
      await _service.updateSessionLimits(
        sessionId: widget.sessionId,
        timeLimitSeconds: v * 60,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _reload() async {
    try {
      final session = await _service.fetchSession(widget.sessionId);
      final questions = await _service.fetchQuestions(widget.sessionId);
      final progress = await _service.fetchProgress(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _session = session;
        _questions = questions;
        _progressSnapshot = progress;
        if (!_sessionLimitsApplied) {
          if (session.effectiveProgressBasis == QuizProgressBasis.time) {
            _limitMode = _LimitMode.time;
          } else {
            _limitMode = _LimitMode.questions;
          }
          final tls = session.timeLimitSeconds ?? 0;
          if (tls > 0) {
            _timeLimitMinutes = (tls / 60).round().clamp(
              _kMinTimeMinutes,
              _kMaxTimeMinutes,
            );
          }
          final qc = session.questionCount ?? 0;
          if (qc > 0) {
            _questionLimit = qc.clamp(_kMinQuestionLimit, _kMaxQuestionLimit);
          }
          _sessionLimitsApplied = true;
        }
        if (!_timeLimitFocus.hasFocus) {
          _timeLimitController.text = '$_timeLimitMinutes';
        }
        if (!_questionLimitFocus.hasFocus) {
          _questionLimitController.text = '$_questionLimit';
        }
        _loading = false;
        _error = null;
      });
      _syncTimeTickerForSession(session.status);
      _scheduleChromePublish();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _reloadAndEnsureIfGap() async {
    await _reload();
    if (mounted) {
      await _ensureContinueIfNeeded();
    }
  }

  Future<void> _requestNextQuestion() async {
    if (!mounted) return;
    setState(() {
      _streaming = true;
      _activityText = 'Frage wird vorbereitet...';
      _error = null;
    });
    try {
      final response = await _service.requestNextQuestion(
        sessionId: widget.sessionId,
        prefetchCount: 2,
      );
      final progress = response['progress'];
      if (progress is Map<String, dynamic>) {
        _progressSnapshot = QuizProgressSnapshot.fromJson(progress);
      } else if (progress is Map) {
        _progressSnapshot = QuizProgressSnapshot.fromJson(
          progress.map((key, value) => MapEntry('$key', value)),
        );
      }
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _streaming = false);
    }
  }

  /// PocketBase does not guarantee question order; creation time is the stable axis.
  static int _compareQuestionsByOrder(QuizQuestion a, QuizQuestion b) {
    final pa = a.planIndex;
    final pb = b.planIndex;
    if (pa != null && pb != null && pa != pb) {
      return pa.compareTo(pb);
    }
    final ca = a.created ?? DateTime.fromMillisecondsSinceEpoch(0);
    final cb = b.created ?? DateTime.fromMillisecondsSinceEpoch(0);
    final byTime = ca.compareTo(cb);
    if (byTime != 0) return byTime;
    return a.id.compareTo(b.id);
  }

  int get _effectiveQuestionCap {
    final serverCap = _progressSnapshot?.targetQuestions;
    if (serverCap != null && serverCap > 0) {
      return serverCap.clamp(_kMinQuestionLimit, _kMaxQuestionLimit);
    }
    final qc = _session?.questionCount;
    if (qc != null && qc > 0) {
      return qc.clamp(_kMinQuestionLimit, _kMaxQuestionLimit);
    }
    return _questionLimit.clamp(_kMinQuestionLimit, _kMaxQuestionLimit);
  }

  Future<void> _ensureContinueIfNeeded() async {
    if (!mounted || _streaming) return;
    if (_error != null) return;
    final sess = _session;
    if (sess == null || sess.status != 'active') return;
    if (_limitMode != _LimitMode.questions) return;
    final cap = _effectiveQuestionCap;
    final answered = _questions.where((q) => q.answered).length;
    if (answered >= cap) return;
    if (_questions.any((q) => !q.answered)) return;
    final answeredQs = _questions.where((q) => q.answered).toList();
    if (answeredQs.isEmpty) return;
    final idsBefore = _questions.map((q) => q.id).toSet();
    final answeredBefore = _questions.where((q) => q.answered).length;
    await _requestNextQuestion();
    if (!mounted) return;
    final idsAfter = _questions.map((q) => q.id).toSet();
    final answeredAfter = _questions.where((q) => q.answered).length;
    if (idsAfter.length == idsBefore.length &&
        answeredAfter == answeredBefore &&
        answeredAfter < cap) {
      setState(() {
        _error =
            'Es kam keine neue Frage vom Server. „Weiter lernen“ oder Aktualisieren.';
      });
    }
  }

  Future<void> _submitMultipleChoice(
    QuizQuestion question,
    String selectedOptionId,
  ) async {
    await _service.submitAnswer(
      sessionId: widget.sessionId,
      questionId: question.id,
      selectedOptionId: selectedOptionId,
    );
    await _reload();
    await _continueOrFinish(question);
  }

  Future<void> _submitFreeText(QuizQuestion question, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _service.submitAnswer(
      sessionId: widget.sessionId,
      questionId: question.id,
      freeText: trimmed,
    );
    await _reload();
    await _continueOrFinish(question);
  }

  Future<void> _continueOrFinish(QuizQuestion question) async {
    if (!mounted) return;
    if (_isLimitReached) {
      setState(() {});
      return;
    }
    await _requestNextQuestion();
  }

  Future<void> _evaluate() async {
    try {
      final review = await _service.evaluateSession(
        sessionId: widget.sessionId,
      );
      if (mounted) {
        setState(() => _reviewText = review.text.trim());
      }
      await _service.patchSessionStatus(widget.sessionId, 'ended');
      await _reload();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  bool get _isLimitReached {
    final answered = _questions.where((q) => q.answered).length;
    if (_limitMode == _LimitMode.questions) {
      return answered >= _effectiveQuestionCap;
    }
    return _elapsed.inMinutes >= _timeLimitMinutes;
  }

  double get _progress {
    final answered = _questions.where((q) => q.answered).length;
    if (_limitMode == _LimitMode.questions) {
      final cap = _effectiveQuestionCap;
      if (cap == 0) return 0;
      return (answered / cap).clamp(0.0, 1.0);
    }
    final totalSeconds = _timeLimitMinutes * 60;
    if (totalSeconds == 0) return 0;
    return (_elapsed.inSeconds / totalSeconds).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Lern-Deck wird geladen...'),
          ],
        ),
      );
    }
    if (_error != null && _questions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            'Lern-Deck konnte nicht geladen werden.\n$_error',
          ),
        ),
      );
    }

    final ordered = [..._questions]..sort(_compareQuestionsByOrder);
    final answered = ordered.where((q) => q.answered).toList();
    QuizQuestion? activeQuestion;
    for (final q in ordered) {
      if (!q.answered) {
        activeQuestion = q;
        break;
      }
    }
    final inReview = _reviewText.isNotEmpty;
    final awaitingNextQuestion =
        !inReview &&
        !_streaming &&
        _limitMode == _LimitMode.questions &&
        activeQuestion == null &&
        answered.isNotEmpty &&
        !_isLimitReached;

    return Column(
      children: [
        if (_session != null &&
            _session!.effectiveKind != QuizSessionKind.learn)
          _SessionModeBanner(kind: _session!.effectiveKind),
        _ControlsBar(
          mode: _limitMode,
          timeLimitMinutes: _timeLimitMinutes,
          questionLimit: _questionLimit,
          questionCap: _effectiveQuestionCap,
          timeLimitController: _timeLimitController,
          questionLimitController: _questionLimitController,
          timeLimitFocus: _timeLimitFocus,
          questionLimitFocus: _questionLimitFocus,
          elapsed: _elapsed,
          progress: _progress,
          isLimitReached: _isLimitReached,
          answeredCount: answered.length,
          canEvaluate: !inReview && !_streaming && answered.isNotEmpty,
          onModeChanged: (v) => unawaited(_onLimitModeChanged(v)),
          onTimeLimitEditingComplete: () =>
              unawaited(_commitTimeLimitFromField()),
          onQuestionLimitEditingComplete: () =>
              unawaited(_commitQuestionLimitFromField()),
          onEvaluate: _evaluate,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (answered.isNotEmpty)
                _AnsweredHistory(
                  questions: answered,
                  checkingId: _checkingQuestionId,
                ),
              if (inReview)
                _ReviewCard(text: _reviewText),
              if (!inReview) ...[
                if (_streaming)
                  _LoadingCard(text: _activityText)
                else if (awaitingNextQuestion)
                  _LoadingCard(text: 'Nächste Frage wird geladen…')
                else if (activeQuestion case final q?)
                  _QuestionCard(
                    question: q,
                    checking: _checkingQuestionId == q.id,
                    onSelectOption: (id) => _submitMultipleChoice(q, id),
                    onSubmitText: (text) => _submitFreeText(q, text),
                  )
                else if (answered.isNotEmpty)
                  _FinishCard(
                    isLimitReached: _isLimitReached,
                    onEvaluate: _evaluate,
                    onContinue: () {
                      final last = [...answered]
                        ..sort(_compareQuestionsByOrder);
                      if (last.isEmpty) return;
                      unawaited(_requestNextQuestion());
                    },
                  ),
              ],
              if (_error != null && _questions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Session kind (assessment / learn / deepen) ───────────────────────────────

class _SessionModeBanner extends StatelessWidget {
  const _SessionModeBanner({required this.kind});

  final QuizSessionKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String title, String subtitle, Color bg, Color fg) = switch (kind) {
      QuizSessionKind.assessment => (
        'Check-up',
        'Kurzer Überblick: 5 Multiple-Choice-Fragen zu diesem Inhalt.',
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      QuizSessionKind.deepen => (
        'Vertiefung',
        'Fokus auf schwächere Bereiche nach deinem Lern-Deck.',
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      QuizSessionKind.learn => (
        'Lern-Deck',
        '',
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
    };
    return Material(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              switch (kind) {
                QuizSessionKind.assessment => Icons.fact_check_outlined,
                QuizSessionKind.deepen => Icons.layers_outlined,
                QuizSessionKind.learn => Icons.school_outlined,
              },
              size: 22,
              color: fg,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: fg.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Session limit numeric fields ─────────────────────────────────────────────

class _LimitIntField extends StatelessWidget {
  const _LimitIntField({
    required this.controller,
    required this.focusNode,
    required this.suffix,
    required this.hintRange,
    required this.onEditingComplete,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String suffix;
  final String hintRange;
  final VoidCallback onEditingComplete;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 64,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 10,
              ),
              hintText: hintRange,
              hintStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.done,
            onEditingComplete: onEditingComplete,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Text(suffix, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

// ── Controls + progress bar ──────────────────────────────────────────────────

class _ControlsBar extends StatelessWidget {
  const _ControlsBar({
    required this.mode,
    required this.timeLimitMinutes,
    required this.questionLimit,
    required this.questionCap,
    required this.timeLimitController,
    required this.questionLimitController,
    required this.timeLimitFocus,
    required this.questionLimitFocus,
    required this.elapsed,
    required this.progress,
    required this.isLimitReached,
    required this.answeredCount,
    required this.canEvaluate,
    required this.onModeChanged,
    required this.onTimeLimitEditingComplete,
    required this.onQuestionLimitEditingComplete,
    required this.onEvaluate,
  });

  final _LimitMode mode;
  final int timeLimitMinutes;
  final int questionLimit;
  final int questionCap;
  final TextEditingController timeLimitController;
  final TextEditingController questionLimitController;
  final FocusNode timeLimitFocus;
  final FocusNode questionLimitFocus;
  final Duration elapsed;
  final double progress;
  final bool isLimitReached;
  final int answeredCount;
  final bool canEvaluate;
  final ValueChanged<_LimitMode> onModeChanged;
  final VoidCallback onTimeLimitEditingComplete;
  final VoidCallback onQuestionLimitEditingComplete;
  final VoidCallback onEvaluate;

  String get _statusLabel {
    if (mode == _LimitMode.questions) {
      return '$answeredCount / $questionCap';
    }
    final remaining = Duration(minutes: timeLimitMinutes) - elapsed;
    final clamped = remaining.isNegative ? Duration.zero : remaining;
    final m = clamped.inMinutes.toString().padLeft(2, '0');
    final s = (clamped.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final limitColor = isLimitReached ? colorScheme.error : null;

    return Material(
      color: colorScheme.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                SegmentedButton<_LimitMode>(
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: _LimitMode.time,
                      icon: Icon(Icons.timer_outlined),
                      label: Text('Zeit'),
                    ),
                    ButtonSegment(
                      value: _LimitMode.questions,
                      icon: Icon(Icons.format_list_numbered),
                      label: Text('Fragen'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (v) => onModeChanged(v.first),
                ),
                const SizedBox(width: 12),
                if (mode == _LimitMode.time)
                  _LimitIntField(
                    controller: timeLimitController,
                    focusNode: timeLimitFocus,
                    suffix: 'min',
                    hintRange: '$_kMinTimeMinutes–$_kMaxTimeMinutes',
                    onEditingComplete: onTimeLimitEditingComplete,
                  )
                else
                  _LimitIntField(
                    controller: questionLimitController,
                    focusNode: questionLimitFocus,
                    suffix: 'Fragen',
                    hintRange: '$_kMinQuestionLimit–$_kMaxQuestionLimit',
                    onEditingComplete: onQuestionLimitEditingComplete,
                  ),
                const Spacer(),
                Text(
                  _statusLabel,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: limitColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (canEvaluate) ...[
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    onPressed: onEvaluate,
                    child: const Text('Abschließen'),
                  ),
                ],
              ],
            ),
          ),
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            color: isLimitReached ? colorScheme.error : null,
            backgroundColor: colorScheme.surfaceContainerHighest,
          ),
        ],
      ),
    );
  }
}

// ── Answered questions (one collapsible per question, dense when collapsed) ──

class _AnsweredHistory extends StatelessWidget {
  const _AnsweredHistory({required this.questions, required this.checkingId});

  final List<QuizQuestion> questions;
  final String? checkingId;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(color: colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '${questions.length} ${questions.length == 1 ? 'Frage' : 'Fragen'} beantwortet',
            style: labelStyle,
          ),
        ),
        for (var i = 0; i < questions.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          _AnsweredQuestionExpansion(
            index: i + 1,
            question: questions[i],
            checking: checkingId == questions[i].id,
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }
}

class _AnsweredQuestionExpansion extends StatelessWidget {
  const _AnsweredQuestionExpansion({
    required this.index,
    required this.question,
    required this.checking,
  });

  final int index;
  final QuizQuestion question;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final correct = question.answerCorrect;
    final comment = question.answerComment;
    final colorScheme = Theme.of(context).colorScheme;
    final icon = Icon(
      correct == true
          ? Icons.check_circle_outline
          : correct == false
          ? Icons.cancel_outlined
          : Icons.radio_button_unchecked,
      color: correct == true
          ? Colors.green
          : correct == false
          ? colorScheme.error
          : colorScheme.onSurfaceVariant,
      size: 20,
    );

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        tilePadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
        childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
        leading: SizedBox(width: 28, child: Center(child: icon)),
        title: Text(
          '$index. ${question.content.stem}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        subtitle: checking
            ? Text(
                'Wird geprüft…',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            : (comment != null && comment.isNotEmpty)
            ? Text(
                comment,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            : null,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 4, top: 4, right: 0),
              child: _QuestionContent(
                question: question,
                checking: checking,
                interactive: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Active question (no card) ────────────────────────────────────────────────

class _QuestionCard extends StatefulWidget {
  const _QuestionCard({
    required this.question,
    required this.checking,
    required this.onSelectOption,
    required this.onSubmitText,
  });

  final QuizQuestion question;
  final bool checking;
  final ValueChanged<String> onSelectOption;
  final ValueChanged<String> onSubmitText;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  late final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.question;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _QuestionContent(
            question: question,
            checking: widget.checking,
            interactive: true,
            controller: _controller,
            onSelectOption: widget.onSelectOption,
            onSubmitText: widget.onSubmitText,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Tooltip(
              message: 'Kommt bald',
              child: TextButton.icon(
                onPressed: null,
                icon: const Icon(Icons.chat_bubble_outline, size: 16),
                label: const Text('Über diese Frage fragen'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestionContent extends StatelessWidget {
  const _QuestionContent({
    required this.question,
    required this.checking,
    required this.interactive,
    this.controller,
    this.onSelectOption,
    this.onSubmitText,
  });

  final QuizQuestion question;
  final bool checking;
  final bool interactive;
  final TextEditingController? controller;
  final ValueChanged<String>? onSelectOption;
  final ValueChanged<String>? onSubmitText;

  @override
  Widget build(BuildContext context) {
    final answered = question.answered;
    final stemStyle = Theme.of(context).textTheme.titleMedium;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(question.content.stem, style: stemStyle),
        const SizedBox(height: 12),
        switch (question.content) {
          QuizMultipleChoiceContent(:final options) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
                ChoiceChip(
                  label: Text('${option.id}) ${option.label}'),
                  selected:
                      question.answerPayload?['selectedOptionId'] == option.id,
                  onSelected: interactive && !answered && onSelectOption != null
                      ? (_) => onSelectOption!(option.id)
                      : null,
                ),
            ],
          ),
          QuizFreeTextContent() =>
            interactive && !answered && controller != null
                ? _FreeTextInput(
                    controller: controller!,
                    enabled: true,
                    savedText: null,
                    onSubmit: onSubmitText!,
                  )
                : Text(
                    'Deine Antwort: ${question.answerPayload?['text'] ?? '—'}',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
        },
        if (answered) ...[
          const SizedBox(height: 12),
          _FeedbackLine(question: question, checking: checking),
        ],
      ],
    );
  }
}

// ── Loading card ─────────────────────────────────────────────────────────────

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

// ── Finish card (limit reached, no more active questions) ────────────────────

class _FinishCard extends StatelessWidget {
  const _FinishCard({
    required this.isLimitReached,
    required this.onEvaluate,
    required this.onContinue,
  });

  final bool isLimitReached;
  final VoidCallback onEvaluate;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          Icon(
            isLimitReached ? Icons.flag_outlined : Icons.check_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            isLimitReached
                ? 'Ziel erreicht! Möchtest du die Auswertung sehen?'
                : 'Alle Fragen beantwortet.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: onContinue,
                child: const Text('Weiter lernen'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: onEvaluate,
                child: const Text('Auswertung'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Review card (post-evaluation) ────────────────────────────────────────────

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: colorScheme.primary, width: 3),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    color: colorScheme.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Auswertung',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SelectableText(
                text,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _FreeTextInput extends StatelessWidget {
  const _FreeTextInput({
    required this.controller,
    required this.enabled,
    required this.onSubmit,
    this.savedText,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? savedText;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    if (savedText != null) {
      return Text('Deine Antwort: $savedText');
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Antwort eingeben',
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: 'Antwort senden',
          onPressed: enabled ? () => onSubmit(controller.text) : null,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }
}

class _FeedbackLine extends StatelessWidget {
  const _FeedbackLine({required this.question, required this.checking});

  final QuizQuestion question;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final correct = question.answerCorrect;
    final comment = question.answerComment;
    final error = question.checkError;

    if (error != null && error.isNotEmpty) {
      return Text('Prüfung fehlgeschlagen: $error');
    }
    if ((comment == null || comment.isEmpty) && checking) {
      return const Text('Wird geprüft...');
    }
    if (comment == null || comment.isEmpty) {
      return const Text('Antwort gespeichert.');
    }
    return Row(
      children: [
        Icon(
          correct == true ? Icons.check_circle : Icons.info_outline,
          color: correct == true ? Colors.green : colorScheme.primary,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(comment)),
      ],
    );
  }
}
