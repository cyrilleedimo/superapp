// Point d'entrée de l'application (Windows + Android 12+).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/config.dart';
import 'core/router.dart';
import 'core/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load(); // adresse du serveur choisie par l'utilisateur, s'il y en a une
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
