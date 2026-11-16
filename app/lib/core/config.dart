// Adresse du serveur (API). L'application est livrée avec une adresse fixe ; ordre de priorité :
//   1. adresse saisie par un administrateur (Profil → Adresse du serveur) ;
//   2. sur le web : le site qui sert l'application (même domaine, dossier /api) ;
//   3. adresse publiée dans le fichier server.json du dépôt (permet de déménager le
//      serveur plus tard sans obliger tout le monde à réinstaller l'application) ;
//   4. adresse fixée à la compilation (--dart-define=API_URL=...), sinon kDefaultApiUrl.
// En version finale (release), seule une adresse https est acceptée.
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Sous-domaine de l'hébergeur où le serveur Ovia est installé.
const kDefaultApiUrl = 'https://app.itsscm.org/api';
const _remoteConfigUrl = 'https://raw.githubusercontent.com/cyrilleedimo/superapp/main/server.json';

class AppConfig {
  static const _fromEnv = String.fromEnvironment('API_URL');
  static const isRelease = kReleaseMode;
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static String? _override;
  static String? _remote;

  /// Faux tant que la personne n'a pas vu l'écran de bienvenue.
  static bool onboarded = true;

  static Future<String?> _read(String key) async {
    try { return await _storage.read(key: key); } catch (_) { return null; }
  }

  /// Charge les réglages locaux (à appeler au démarrage).
  static Future<void> load() async {
    _override = await _read('api_url');
    _remote = await _read('api_url_remote');
    onboarded = (await _read('onboarded')) == '1';
    if (!kIsWeb) _refreshRemote(); // en arrière-plan : ne retarde jamais l'ouverture
  }

  static Future<void> markOnboarded() async {
    onboarded = true;
    try { await _storage.write(key: 'onboarded', value: '1'); } catch (_) {}
  }

  static bool _valid(String? u) => u != null && u.startsWith('https://') && (Uri.tryParse(u)?.hasAuthority ?? false);

  static Future<void> _refreshRemote() async {
    try {
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 5)));
      final res = await dio.get<String>(_remoteConfigUrl, options: Options(responseType: ResponseType.plain));
      final url = ((jsonDecode(res.data ?? '{}') as Map)['apiUrl'] as String?)?.replaceAll(RegExp(r'/+$'), '');
      if (_valid(url) && url != _remote) {
        _remote = url;
        await _storage.write(key: 'api_url_remote', value: url);
      }
    } catch (_) {/* pas de réseau : on garde la dernière adresse connue */}
  }

  static String get apiUrl {
    if (_override != null && _override!.isNotEmpty) return _override!;
    if (kIsWeb && _fromEnv.isEmpty) return '${Uri.base.origin}/api';
    if (_valid(_remote)) return _remote!;
    if (_fromEnv.isNotEmpty) return _fromEnv;
    if (isRelease) return kDefaultApiUrl;
    return defaultTargetPlatform == TargetPlatform.android ? 'http://10.0.2.2:8080/api' : 'http://localhost:8080/api';
  }

  /// L'adresse est-elle utilisable ? (https obligatoire en release, sauf site web servi en local)
  static bool get isConfigured => apiUrl.isNotEmpty && (!isRelease || apiUrl.startsWith('https://') || kIsWeb);

  /// Enregistre une adresse choisie par l'administrateur ; vide = revenir à l'adresse normale.
  static Future<String?> setServer(String url) async {
    final u = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isEmpty || u == 'https:') {
      _override = null;
      try { await _storage.delete(key: 'api_url'); } catch (_) {}
      return null;
    }
    final parsed = Uri.tryParse(u);
    if (parsed == null || !parsed.hasAuthority) return 'Adresse invalide.';
    if (isRelease && parsed.scheme != 'https') return 'L\'adresse doit commencer par https://';
    try { await _storage.write(key: 'api_url', value: u); } catch (_) {}
    _override = u;
    return null;
  }

  /// En-têtes des images servies par l'API (aucun n'est nécessaire sur l'hébergement actuel).
  static const Map<String, String> mediaHeaders = {};

  /// Tuiles de carte. Par défaut OpenStreetMap, dont la politique d'usage interdit le
  /// trafic intensif : en production, utiliser [MAPS PROVIDER] via --dart-define=MAP_TILE_URL=...
  static const tileUrl = String.fromEnvironment('MAP_TILE_URL',
      defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');

  /// Les photos envoyées sont renvoyées par le serveur en chemin relatif ("/media/xxxx") :
  /// on le complète avec l'adresse du serveur utilisée pour tout le reste.
  static String resolveMediaUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url; // déjà absolue
    if (url.isEmpty) return url;
    return '$apiUrl$url';
  }
}
