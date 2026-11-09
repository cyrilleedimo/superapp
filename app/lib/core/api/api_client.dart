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
        'not_enough_seats' => 'Il ne reste plus assez de places sur ce trajet.',
        'trip_unavailable' => 'Ce trajet n\'est plus disponible.',
        'store_closed' => 'Ce commerce est fermé pour le moment.',
        'out_of_stock' => 'Un des articles n\'est plus en stock en quantité suffisante.',
        'product_unavailable' => 'Un des articles n\'est plus disponible.',
        'insufficient_balance' => 'Ton solde est insuffisant pour ce retrait.',
        'payout_below_minimum' => 'Le montant est en dessous du minimum de retrait.',
        'rides_not_configured' => 'Les courses en ville ne sont pas encore ouvertes.',
        'travel_not_configured' => 'Le comparateur de voyages n\'est pas encore relié à un partenaire.',
        'driver_not_verified' => 'Ton compte chauffeur est en cours de vérification.',
        'driver_not_online' => 'Passe en ligne pour voir les courses.',
        'ride_already_taken' => 'Un autre chauffeur a déjà pris cette course.',
        'ride_already_active' => 'Tu as déjà une course en cours.',
        'ride_too_short' => 'Le départ et l\'arrivée sont trop proches.',
        'ride_too_long' => 'Cette distance dépasse la limite des courses en ville.',
        'offer_not_below_price' => 'Ton offre doit être inférieure au prix affiché.',
        'offer_already_decided' => 'Cette offre a déjà reçu une réponse.',
        'unsupported_image' || 'unreadable_image' => 'Cette image n\'est pas acceptée. Utilise une photo JPEG, PNG ou WebP.',
        'departure_too_soon' => 'Le départ doit être dans au moins 15 minutes.',
        'order_not_confirmable' => 'Cette commande ne peut pas encore être confirmée.',
        'own_listing' || 'cannot_buy_own_listing' => 'C\'est ta propre annonce.',
        'validation_failed' => 'Vérifie les informations saisies.',
        'server_not_configured' => 'Adresse du serveur non configurée. Touche « Serveur » en bas de l\'écran de connexion.',
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
        if (!AppConfig.isConfigured) {
          return handler.reject(DioException(requestOptions: options, error: 'server_not_configured'));
        }
        options.baseUrl = AppConfig.apiUrl; // l'adresse peut changer depuis l'écran de connexion
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
      if (e.error == 'server_not_configured') throw ApiException('server_not_configured');
      throw ApiException('network', status: e.response?.statusCode);
    }
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) =>
      _wrap(() => dio.get<Map<String, dynamic>>(path, queryParameters: query));

  Future<Map<String, dynamic>> post(String path, {Object? body, Map<String, String>? headers}) =>
      _wrap(() => dio.post<Map<String, dynamic>>(path, data: body ?? const {}, options: Options(headers: headers)));

  Future<Map<String, dynamic>> patch(String path, {Object? body}) =>
      _wrap(() => dio.patch<Map<String, dynamic>>(path, data: body ?? const {}));

  /// Envoie une image brute (le serveur la vérifie et la ré-encode). Renvoie {id, url}.
  Future<Map<String, dynamic>> uploadImage(List<int> bytes, String mime) => _wrap(() => dio.post<Map<String, dynamic>>(
        '/media',
        data: Stream<List<int>>.value(bytes),
        options: Options(contentType: mime, headers: {Headers.contentLengthHeader: bytes.length}),
      ));
}
