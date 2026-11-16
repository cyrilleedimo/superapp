// Graphe de dépendances Riverpod de l'application.
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'api/api_client.dart';
import 'auth/token_store.dart';

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    ref.watch(tokenStoreProvider),
    onSessionExpired: () => ref.read(sessionProvider.notifier).signedOut(),
  );
});

enum SessionState { unknown, signedOut, signedIn }

/// État de session. Le routeur s'y abonne : les pages publiques restent visibles sans
/// compte, les actions (acheter, vendre, écrire…) demandent de se connecter.
class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() {
    _restore();
    return SessionState.unknown;
  }

  Future<void> _restore() async {
    String? rt;
    try { rt = await ref.read(tokenStoreProvider).refresh(); } catch (_) {}
    state = rt == null ? SessionState.signedOut : SessionState.signedIn;
  }

  ApiClient get _api => ref.read(apiClientProvider);

  Future<void> _open(Map<String, dynamic> r) async {
    await ref.read(tokenStoreProvider).save(r['accessToken'] as String, r['refreshToken'] as String);
    state = SessionState.signedIn;
  }

  /// [identifier] : e-mail ou numéro de téléphone.
  Future<void> login(String identifier, String password) async =>
      _open(await _api.post('/auth/login', body: {'identifier': identifier, 'password': password}));

  Future<void> register({required String name, required String email, required String password, String? phone}) =>
      _api.post('/auth/register', body: {
        'displayName': name, 'email': email, 'password': password,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      });

  Future<void> verify(String email, String code) async =>
      _open(await _api.post('/auth/verify-email', body: {'email': email, 'code': code}));

  Future<void> resendCode(String email) => _api.post('/auth/resend-code', body: {'email': email});

  Future<void> forgotPassword(String email) => _api.post('/auth/forgot-password', body: {'email': email});

  Future<void> resetPassword(String email, String code, String password) async =>
      _open(await _api.post('/auth/reset-password', body: {'email': email, 'code': code, 'password': password}));

  /// Après un changement de mot de passe, le serveur renvoie de nouveaux jetons.
  Future<void> adopt(Map<String, dynamic> tokens) => _open(tokens);

  Future<void> logout() async {
    final rt = await ref.read(tokenStoreProvider).refresh();
    if (rt != null) {
      try {
        await _api.post('/auth/logout', body: {'refreshToken': rt});
      } catch (_) {/* déconnexion locale quoi qu'il arrive */}
    }
    signedOut();
  }

  void signedOut() {
    ref.read(tokenStoreProvider).clear();
    state = SessionState.signedOut;
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

/// Vrai si une personne est connectée.
final signedInProvider = Provider<bool>((ref) => ref.watch(sessionProvider) == SessionState.signedIn);

/// Pastilles : notifications non lues et messages non lus (rafraîchies toutes les 25 s).
class Badges {
  const Badges({this.notifications = 0, this.messages = 0});
  final int notifications, messages;
}

class BadgesController extends Notifier<Badges> {
  Timer? _timer;

  @override
  Badges build() {
    final signedIn = ref.watch(signedInProvider);
    _timer?.cancel();
    ref.onDispose(() => _timer?.cancel());
    if (signedIn) {
      _timer = Timer.periodic(const Duration(seconds: 25), (_) => refresh());
      Future<void>.microtask(refresh);
    }
    return const Badges();
  }

  Future<void> refresh() async {
    if (ref.read(sessionProvider) != SessionState.signedIn) return;
    try {
      final r = await ref.read(apiClientProvider).get('/me/badges');
      state = Badges(
        notifications: (r['notifications'] as num?)?.toInt() ?? 0,
        messages: (r['messages'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {/* réseau : on réessaie au prochain tour */}
  }
}

final badgesProvider = NotifierProvider<BadgesController, Badges>(BadgesController.new);
