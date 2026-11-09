// Client HTTP : ajoute le jeton, le renouvelle UNE fois sur 401 (requêtes mises
// en file pendant le renouvellement), et convertit les erreurs en ApiException.
import 'package:dio/dio.dart';
import '../auth/token_store.dart';
import '../config.dart';

class ApiException implements Exception {
  ApiException(this.code, {this.status, this.message});
  final String code;
  final int? status;
  final String? message;

  /// Message prêt à afficher, en français, sans jamais blâmer l'utilisateur.
  String get userMessage => switch (code) {
        'invalid_credentials' => 'Numéro ou mot de passe incorrect.',
        'account_locked' => 'Trop de tentatives. Réessaie dans 15 minutes.',
        'invalid_code' => 'Ce code ne fonctionne pas. Demande-en un nouveau.',
        'account_exists' => 'Un compte existe déjà avec ce numéro. Connecte-toi.',
        'listing_unavailable' => 'Cet article vient d\'être réservé par quelqu\'un d\'autre.',
        'payment_provider_unavailable' => 'Le service de paiement ne répond pas. Réessaie dans un instant.',
        'rate_limited' => 'Beaucoup de demandes d\'un coup. Patiente quelques secondes.',
        'network' => 'Connexion impossible. Vérifie ton réseau puis réessaie.',
        _ => 'Une erreur est survenue. Réessaie.',
      };

  @override
  String toString() => 'ApiException($code, $status)';
}

class ApiClient {
  ApiClient(this._tokens, {void Function()? onSessionExpired})
      : _onSessionExpired = onSessionExpired,
        dio = Dio(BaseOptions(
          baseUrl: AppConfig.apiUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          contentType: 'application/json',
        )) {
    dio.interceptors.add(QueuedInterceptorsWrapper(
      onRequest: (options, handler) async {
        final t = await _tokens.access();
        if (t != null) options.headers['Authorization'] = 'Bearer $t';
        handler.next(options);
      },
      onError: (err, handler) async {
        final req = err.requestOptions;
        final isAuthCall = req.path.startsWith('/auth/');
        if (err.response?.statusCode == 401 && !isAuthCall && req.extra['retried'] != true) {
          if (await _tryRefresh()) {
            req.extra['retried'] = true;
            req.headers['Authorization'] = 'Bearer ${await _tokens.access()}';
            try {
              return handler.resolve(await dio.fetch(req));
            } on DioException catch (e) {
              return handler.next(e);
            }
          }
          _onSessionExpired?.call();
        }
        handler.next(err);
      },
    ));
  }

  final TokenStore _tokens;
  final void Function()? _onSessionExpired;
  final Dio dio;

  Future<bool> _tryRefresh() async {
    final rt = await _tokens.refresh();
    if (rt == null) return false;
    try {
      // Dio séparé : pas d'intercepteur, donc pas de boucle de renouvellement.
      final r = await Dio(BaseOptions(baseUrl: AppConfig.apiUrl))
          .post<Map<String, dynamic>>('/auth/refresh', data: {'refreshToken': rt});
      await _tokens.save(r.data!['accessToken'] as String, r.data!['refreshToken'] as String);
      return true;
    } catch (_) {
      await _tokens.clear();
      return false;
    }
  }

  Future<Map<String, dynamic>> _wrap(Future<Response<Map<String, dynamic>>> Function() call) async {
    try {
      return (await call()).data ?? <String, dynamic>{}; // 204 → corps vide
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['error'] is String) {
        throw ApiException(data['error'] as String, status: e.response?.statusCode, message: data['message'] as String?);
      }
      throw ApiException('network', status: e.response?.statusCode);
    }
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) =>
      _wrap(() => dio.get<Map<String, dynamic>>(path, queryParameters: query));

  Future<Map<String, dynamic>> post(String path, {Object? body, Map<String, String>? headers}) =>
      _wrap(() => dio.post<Map<String, dynamic>>(path, data: body ?? const {}, options: Options(headers: headers)));
}
