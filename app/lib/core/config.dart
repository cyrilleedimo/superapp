// Adresse du serveur (API). Ordre de priorité :
//   1. adresse saisie dans l'app (écran de connexion → « Serveur ») ;
//   2. --dart-define=API_URL=https://api.[VOTRE-DOMAINE] à la compilation ;
//   3. en développement : localhost (Windows) / 10.0.2.2 (émulateur Android).
// En version finale (release), seule une adresse https est acceptée.
import 'dart:io' show Platform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppConfig {
  static const _fromEnv = String.fromEnvironment('API_URL');
  static const isRelease = bool.fromEnvironment('dart.vm.product');
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static String? _override;

  /// Charge l'adresse saisie par l'utilisateur (à appeler au démarrage).
  static Future<void> load() async {
    try { _override = await _storage.read(key: 'api_url'); } catch (_) { _override = null; }
  }

  static String get apiUrl {
    if (_override != null && _override!.isNotEmpty) return _override!;
    if (_fromEnv.isNotEmpty) return _fromEnv;
    if (isRelease) return '';
    return Platform.isAndroid ? 'http://10.0.2.2:8080' : 'http://localhost:8080';
  }

  /// L'adresse est-elle utilisable ? (https obligatoire en release)
  static bool get isConfigured => apiUrl.isNotEmpty && (!isRelease || apiUrl.startsWith('https://'));

  /// Enregistre une nouvelle adresse. Renvoie un message d'erreur, ou null si OK.
  static Future<String?> setServer(String url) async {
    final u = url.trim().replaceAll(RegExp(r'/+$'), '');
    final parsed = Uri.tryParse(u);
    if (parsed == null || !parsed.hasAuthority) return 'Adresse invalide.';
    if (isRelease && parsed.scheme != 'https') return 'L\'adresse doit commencer par https://';
    await _storage.write(key: 'api_url', value: u);
    _override = u;
    return null;
  }

  /// Tuiles de carte. Par défaut OpenStreetMap, dont la politique d'usage interdit le
  /// trafic intensif : en production, utiliser [MAPS PROVIDER] via --dart-define=MAP_TILE_URL=...
  static const tileUrl = String.fromEnvironment('MAP_TILE_URL',
      defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');

  /// Les photos uploadées (annonces, boutiques) sont renvoyées par le serveur en chemin
  /// relatif (ex. "/media/xxxx"), jamais en adresse absolue : le serveur peut tourner
  /// derrière une adresse qui change (tunnel Cloudflare gratuit du mode « PC comme
  /// serveur »). On complète ce chemin avec l'adresse actuellement configurée — la même
  /// que celle utilisée pour tous les appels d'API.
  static String resolveMediaUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url; // déjà absolue
    if (url.isEmpty) return url;
    return '$apiUrl$url';
  }
}
