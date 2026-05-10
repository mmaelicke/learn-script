import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:reorderables/reorderables.dart';

import '../auth/auth_controller.dart';
import '../capture_ingest/capture_ingest_service.dart';
import '../capture_ingest/capture_subject_suggestions.dart';
import '../ui/de_strings.dart';
import '../util/debug_console_error.dart';

class DigitizingNotesScreen extends StatefulWidget {
  const DigitizingNotesScreen({required this.initialPhotos, super.key});

  final List<XFile> initialPhotos;

  @override
  State<DigitizingNotesScreen> createState() => _DigitizingNotesScreenState();
}

class _DigitizingNotesScreenState extends State<DigitizingNotesScreen> {
  final TextEditingController _subjectCtrl = TextEditingController();
  final List<XFile> _photos = [];
  final Map<String, Future<Uint8List>> _thumbBytes = {};

  List<String> _suggestions = [];
  bool _suggestionsLoading = true;
  String? _suggestionsError;
  bool _suggestionsRequested = false;

  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _photos.addAll(widget.initialPhotos);
    for (final p in widget.initialPhotos) {
      _thumbBytes[_thumbKey(p)] = p.readAsBytes();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_suggestionsRequested) {
      _suggestionsRequested = true;
      _loadSuggestions();
    }
  }

  @override
  void dispose() {
    _subjectCtrl.dispose();
    super.dispose();
  }

  String _thumbKey(XFile f) => f.path.isNotEmpty ? f.path : f.name;

  Future<void> _loadSuggestions() async {
    final auth = AuthInherited.of(context);
    final user = auth.record;
    if (user == null) {
      setState(() {
        _suggestionsLoading = false;
        _suggestionsError = 'Not signed in';
      });
      return;
    }
    try {
      final list = await fetchDistinctCaptureSubjects(
        pb: auth.client,
        user: user,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _suggestions = list;
        _suggestionsLoading = false;
        _suggestionsError = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _suggestionsLoading = false;
        _suggestionsError = '$e';
      });
    }
  }

  List<String> _filteredSuggestions() {
    final q = _subjectCtrl.text.trim().toLowerCase();
    if (q.isEmpty) {
      return _suggestions.take(16).toList();
    }
    return _suggestions
        .where((s) => s.toLowerCase().contains(q))
        .take(24)
        .toList();
  }

  Future<void> _addFromGallery() async {
    final picker = ImagePicker();
    final more = await picker.pickMultiImage(imageQuality: 85);
    if (!mounted || more.isEmpty) {
      return;
    }
    setState(() {
      for (final f in more) {
        _photos.add(f);
        _thumbBytes[_thumbKey(f)] = f.readAsBytes();
      }
    });
  }

  void _removeAt(int index) {
    setState(() {
      final removed = _photos.removeAt(index);
      _thumbBytes.remove(_thumbKey(removed));
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final x = _photos.removeAt(oldIndex);
      _photos.insert(newIndex, x);
    });
  }

  Future<void> _submit() async {
    final subject = _subjectCtrl.text.trim();
    if (subject.isEmpty || _photos.isEmpty) {
      return;
    }
    final auth = AuthInherited.of(context);
    final token = auth.client.authStore.token;
    if (token.isEmpty) {
      reportToDebugConsole(
        'digitizing_notes',
        'Empty PocketBase auth token (authStore.token)',
        StackTrace.current,
        DeStrings.uploadNeedSignIn,
      );
      if (!mounted) {
        return;
      }
      await _showUploadErrorDialog(DeStrings.uploadNeedSignIn);
      return;
    }
    setState(() => _uploading = true);
    try {
      await ingestCaptures(
        pocketbaseToken: token,
        subject: subject,
        filesInOrder: List<XFile>.of(_photos),
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop<String>(subject);
    } on CaptureIngestException catch (e, st) {
      final text = e.statusCode != null
          ? '${DeStrings.uploadErrorTitle} (HTTP ${e.statusCode})\n\n${e.message}'
          : '${DeStrings.uploadErrorTitle}\n\n${e.message}';
      reportToDebugConsole('digitizing_notes', e, st, text);
      if (!mounted) {
        return;
      }
      await _showUploadErrorDialog(text);
    } catch (e, st) {
      final text = '${DeStrings.uploadErrorTitle}\n\n$e';
      reportToDebugConsole('digitizing_notes', e, st, text);
      if (!mounted) {
        return;
      }
      await _showUploadErrorDialog(text);
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  Future<void> _showUploadErrorDialog(String message) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(DeStrings.uploadErrorTitle),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(DeStrings.uploadErrorDismiss),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDiscard() async {
    final r = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(DeStrings.discardTitle),
        content: const Text(DeStrings.discardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(DeStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(DeStrings.discardConfirm),
          ),
        ],
      ),
    );
    return r == true;
  }

  Widget _photoTile(int index) {
    final f = _photos[index];
    final key = _thumbKey(f);
    return Padding(
      key: ValueKey<String>(key),
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        width: 96,
        height: 96,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List>(
                future: _thumbBytes[key],
                builder: (context, snap) {
                  if (snap.hasError) {
                    return ColoredBox(
                      color: Colors.grey.shade300,
                      child: const Icon(Icons.broken_image_outlined),
                    );
                  }
                  if (!snap.hasData) {
                    return const ColoredBox(
                      color: Color(0xFFE0E0E0),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  return Image.memory(snap.data!, fit: BoxFit.cover);
                },
              ),
              if (!_uploading)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Material(
                    color: Colors.black45,
                    shape: const CircleBorder(),
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 18,
                      ),
                      tooltip: DeStrings.deletePhotoTooltip,
                      onPressed: () => _removeAt(index),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addTile() {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Material(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: _uploading ? null : _addFromGallery,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 96,
            height: 96,
            child: Icon(
              Icons.add_photo_alternate_outlined,
              size: 40,
              color: Colors.grey.shade700,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canPopWithoutBlock = !_uploading && _photos.isEmpty;
    final filtered = _filteredSuggestions();

    return PopScope(
      canPop: canPopWithoutBlock,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        if (_uploading) {
          return;
        }
        if (_photos.isEmpty) {
          return;
        }
        final discard = await _confirmDiscard();
        if (!context.mounted) {
          return;
        }
        if (discard) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text(DeStrings.digitizingTitle)),
        body: AbsorbPointer(
          absorbing: _uploading,
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: _subjectCtrl,
                    enabled: !_uploading,
                    decoration: const InputDecoration(
                      labelText: DeStrings.subjectLabel,
                      hintText: DeStrings.subjectHint,
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                  ),
                  if (_suggestionsLoading)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(),
                    )
                  else if (_suggestionsError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _suggestionsError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    )
                  else if (filtered.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Material(
                        elevation: 2,
                        borderRadius: BorderRadius.circular(8),
                        clipBehavior: Clip.antiAlias,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: filtered.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final s = filtered[i];
                              return ListTile(
                                dense: true,
                                title: Text(s),
                                onTap: () {
                                  _subjectCtrl.text = s;
                                  _subjectCtrl.selection =
                                      TextSelection.collapsed(offset: s.length);
                                  setState(() {});
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  Text(
                    DeStrings.photosSection,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ReorderableRow(
                    mainAxisSize: MainAxisSize.min,
                    needsLongPressDraggable: false,
                    onReorder: _onReorder,
                    footer: Tooltip(
                      message: DeStrings.addPhotoTooltip,
                      child: _addTile(),
                    ),
                    children: [
                      for (var i = 0; i < _photos.length; i++) _photoTile(i),
                    ],
                  ),
                  const SizedBox(height: 100),
                ],
              ),
              if (_uploading)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Color(0x66000000),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text(DeStrings.uploading),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: FilledButton(
              onPressed:
                  _uploading ||
                      _subjectCtrl.text.trim().isEmpty ||
                      _photos.isEmpty
                  ? null
                  : _submit,
              child: Text(
                _uploading ? DeStrings.uploading : DeStrings.submitUpload,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
