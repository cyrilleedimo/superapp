// Point d'entrée de l'application (Windows + Android 12+).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/config.dart';
import 'core/router.dart';
import 'core/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.assertSecureInRelease(); // pas d'API en http en production
  runApp(const ProviderScope(child: SuperApp()));
}

class SuperApp extends ConsumerWidget {
  const SuperApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Lumo', // nom de travail → [APP NAME]
      debugShowCheckedModeBanner: false,
      theme: buildLumoTheme(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
