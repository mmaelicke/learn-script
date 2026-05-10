import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pocketbase/pocketbase.dart';

import '../pocketbase_collections.dart';
import 'auth_token_storage.dart';

/// Session + PocketBase client. Persists JWT; restores with auth-refresh on startup.
class AuthController extends ChangeNotifier {
  AuthController({
    required String baseUrl,
    AuthTokenStorage? tokenStorage,
  })  : _pb = PocketBase(baseUrl),
        _tokenStorage = tokenStorage ?? AuthTokenStorage() {
    _authSubscription = _pb.authStore.onChange.listen(_onAuthStoreChanged);
    scheduleMicrotask(_bootstrap);
  }

  final PocketBase _pb;
  final AuthTokenStorage _tokenStorage;
  late final StreamSubscription<AuthStoreEvent> _authSubscription;

  bool _ready = false;
  bool get ready => _ready;

  PocketBase get client => _pb;

  RecordModel? get record => _pb.authStore.record;

  bool get isLoggedIn =>
      _pb.authStore.token.isNotEmpty && _pb.authStore.record != null;

  bool get isVerified {
    final r = _pb.authStore.record;
    if (r == null) {
      return false;
    }
    return r.getBoolValue('verified', false);
  }

  Future<void> _bootstrap() async {
    try {
      final stored = await _tokenStorage.readToken();
      if (stored == null || stored.isEmpty) {
        _pb.authStore.clear();
      } else {
        _pb.authStore.save(stored, null);
        try {
          await _pb.collection(kUsersCollection).authRefresh(
                headers: {'Authorization': stored},
              );
        } on ClientException {
          await _signOutLocal();
        }
      }
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  Future<void> _onAuthStoreChanged(AuthStoreEvent event) async {
    if (event.token.isEmpty) {
      await _tokenStorage.clearAll();
    } else {
      await _tokenStorage.writeToken(event.token);
    }
  }

  Future<void> signIn(String email, String password) async {
    await _pb.collection(kUsersCollection).authWithPassword(email, password);
    notifyListeners();
  }

  Future<void> register(
    String email,
    String password,
    String passwordConfirm,
    int grade,
  ) async {
    await _pb.collection(kUsersCollection).create(
          body: {
            'email': email,
            'password': password,
            'passwordConfirm': passwordConfirm,
            'grade': grade,
          },
        );
    await signIn(email, password);
  }

  /// Silent refresh (e.g. app resume). Uses explicit header so expired JWTs can still refresh.
  Future<void> refreshSession() async {
    final t = _pb.authStore.token;
    if (t.isEmpty) {
      return;
    }
    try {
      await _pb.collection(kUsersCollection).authRefresh(
            headers: {'Authorization': t},
          );
      notifyListeners();
    } on ClientException {
      await signOut();
    }
  }

  /// After any API call that gets 401: one refresh attempt; returns true if session recovered.
  Future<bool> recoverSessionOnce() async {
    final t = _pb.authStore.token;
    if (t.isEmpty) {
      return false;
    }
    try {
      await _pb.collection(kUsersCollection).authRefresh(
            headers: {'Authorization': t},
          );
      notifyListeners();
      return true;
    } on ClientException {
      await signOut();
      return false;
    }
  }

  Future<void> signOut() async {
    await _signOutLocal();
    notifyListeners();
  }

  Future<void> _signOutLocal() async {
    _pb.authStore.clear();
    await _tokenStorage.clearAll();
  }

  @override
  void dispose() {
    unawaited(_authSubscription.cancel());
    super.dispose();
  }
}

class AuthInherited extends InheritedNotifier<AuthController> {
  const AuthInherited({
    required AuthController super.notifier,
    required super.child,
    super.key,
  });

  static AuthController of(BuildContext context) {
    final inherited =
        context.dependOnInheritedWidgetOfExactType<AuthInherited>();
    assert(inherited != null, 'AuthInherited missing above this context');
    return inherited!.notifier!;
  }

  /// Does not register a dependency (safe from [State.didChangeAppLifecycleState]).
  static AuthController? maybeOf(BuildContext context) {
    final element =
        context.getElementForInheritedWidgetOfExactType<AuthInherited>();
    final widget = element?.widget;
    if (widget is AuthInherited) {
      return widget.notifier;
    }
    return null;
  }
}
