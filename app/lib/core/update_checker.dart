// Vérifie au démarrage si une nouvelle version d'Ovia est publiée sur GitHub Releases,
// et propose de la télécharger en un clic. Aucune installation silencieuse : Windows et
// Android exigent tous deux une confirmation de l'utilisateur pour installer un exécutable
// ou un APK venu d'en dehors du Store — c'est une règle du système, pas une limite d'Ovia.
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const _repo = 'cyrilleedimo/superapp';

Future<void> maybeCheckForUpdate(BuildContext context) async {
  try {
    final info = await PackageInfo.fromPlatform();
    final current = info.version; // ex. "1.0.11" (donné par la CI à la compilation)

    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 6), receiveTimeout: const Duration(seconds: 6)));
    final res = await dio.get<String>(
      'https://api.github.com/repos/$_repo/releases/latest',
      options: Options(responseType: ResponseType.plain, headers: {'Accept': 'application/vnd.github+json'}),
    );
    final json = jsonDecode(res.data ?? '{}') as Map<String, dynamic>;
    final tag = (json['tag_name'] as String?) ?? '';
    final latest = tag.startsWith('v') ? tag.substring(1) : tag;
    if (latest.isEmpty || latest == current) return; // à jour, ou réponse inattendue

    final assets = (json['assets'] as List? ?? const []).cast<Map<String, dynamic>>();
    final wantSuffix = Platform.isWindows ? '.exe' : '.apk';
    final asset = assets.cast<Map<String, dynamic>?>().firstWhere(
          (a) => (a?['name'] as String? ?? '').endsWith(wantSuffix),
          orElse: () => null,
        );
    final downloadUrl = asset?['browser_download_url'] as String?;
    if (downloadUrl == null) return;

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nouvelle version disponible'),
        content: Text('Tu as la version $current. La version $latest est disponible.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Plus tard')),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await launchUrl(Uri.parse(downloadUrl), mode: LaunchMode.externalApplication);
            },
            child: const Text('Télécharger'),
          ),
        ],
      ),
    );
  } catch (_) {
    // Pas de réseau, GitHub inaccessible, etc. : on n'embête pas l'utilisateur pour ça.
  }
}
