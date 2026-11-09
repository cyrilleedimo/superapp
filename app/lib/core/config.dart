// URL de l'API injectée à la compilation :
//   flutter run --dart-define=API_URL=https://api.[VOTRE-DOMAINE]
// Par défaut : localhost (Windows) ; l'émulateur Android utilise 10.0.2.2.
import 'dart:io' show Platform;

class AppConfig {
  static const _fromEnv = String.fromEnvironment('API_URL');

  static String get apiUrl {
    if (_fromEnv.isNotEmpty) return _fromEnv;
    return Platform.isAndroid ? 'http://10.0.2.2:8080' : 'http://localhost:8080';
  }

  /// Tuiles de carte. Par défaut OpenStreetMap, dont la politique d'usage interdit le
  /// trafic intensif : en production, utiliser [MAPS PROVIDER] via --dart-define=MAP_TILE_URL=...
  static const tileUrl = String.fromEnvironment('MAP_TILE_URL',
      defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');

  /// En build release, on refuse tout transport non chiffré.
  static void assertSecureInRelease() {
    const isRelease = bool.fromEnvironment('dart.vm.product');
    if (isRelease && !apiUrl.startsWith('https://')) {
      throw StateError('API_URL doit être en https en production');
    }
  }
}
