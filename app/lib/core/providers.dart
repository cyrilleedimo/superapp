// Graphe de dépendances Riverpod de l'application.
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

/// État de session. Le routeur s'y abonne pour rediriger vers la connexion.
class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() {
    _restore();
    return SessionState.unknown;
  }

  Future<void> _restore() async {
    final rt = await ref.read(tokenStoreProvider).refresh();
    state = rt == null ? SessionState.signedOut : SessionState.signedIn;
  }

  ApiClient get _api => ref.read(apiClientProvider);

  Future<void> login(String phone, String password) async {
    final r = await _api.post('/auth/login', body: {'phone': phone, 'password': password});
    await ref.read(tokenStoreProvider).save(r['accessToken'] as String, r['refreshToken'] as String);
    state = SessionState.signedIn;
  }

  Future<void> register(String phone, String name, String password) =>
      _api.post('/auth/register', body: {'phone': phone, 'displayName': name, 'password': password});

  Future<void> verify(String phone, String code) async {
    final r = await _api.post('/auth/verify-phone', body: {'phone': phone, 'code': code});
    await ref.read(tokenStoreProvider).save(r['accessToken'] as String, r['refreshToken'] as String);
    state = SessionState.signedIn;
  }

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
