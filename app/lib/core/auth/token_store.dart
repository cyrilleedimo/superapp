// Stockage chiffré des jetons : Android Keystore (EncryptedSharedPreferences)
// et DPAPI sous Windows. Jamais de SharedPreferences en clair.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStore {
  TokenStore([FlutterSecureStorage? storage])
      : _s = storage ??
            const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  final FlutterSecureStorage _s;

  static const _access = 'access_token';
  static const _refresh = 'refresh_token';

  String? _accessCache; // le jeton d'accès vit aussi en mémoire (lecture rapide)

  Future<String?> access() async => _accessCache ??= await _s.read(key: _access);
  Future<String?> refresh() => _s.read(key: _refresh);

  Future<void> save(String access, String refresh) async {
    _accessCache = access;
    await _s.write(key: _access, value: access);
    await _s.write(key: _refresh, value: refresh);
  }

  Future<void> clear() async {
    _accessCache = null;
    await _s.delete(key: _access);
    await _s.delete(key: _refresh);
  }
}
