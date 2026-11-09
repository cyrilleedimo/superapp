// Navigation : barre basse sur Android, rail latéral sur Windows (≥ 1024 px).
// Les routes protégées redirigent vers /login tant que la session n'est pas ouverte.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/account/account_screens.dart';
import '../features/auth/auth_screens.dart';
import '../features/checkout/checkout_screen.dart';
import '../features/home/home_screen.dart';
import '../features/marketplace/explore_screen.dart';
import '../features/marketplace/listing_detail_screen.dart';
import '../features/preview/preview_screens.dart';
import 'providers.dart';
import 'theme/tokens.dart';

/// Pont Riverpod → go_router : relance les redirections quand la session change.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen(sessionProvider, (_, __) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  const publicRoutes = {'/login', '/register', '/verify'};
  return GoRouter(
    initialLocation: '/',
    refreshListenable: _SessionListenable(ref),
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      if (session == SessionState.unknown) return null; // en cours de restauration
      final isPublic = publicRoutes.contains(loc);
      if (session == SessionState.signedOut && !isPublic) return '/login';
      if (session == SessionState.signedIn && isPublic) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(path: '/verify', builder: (_, s) => VerifyScreen(phone: s.uri.queryParameters['phone'] ?? '')),
      GoRoute(path: '/listing/:id', builder: (_, s) => ListingDetailScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/checkout/:id', builder: (_, s) => CheckoutScreen(listingId: s.pathParameters['id']!)),
      GoRoute(path: '/sell', builder: (_, __) => const SellScreen()),
      GoRoute(path: '/rides', builder: (_, __) => const RidesScreen()),
      GoRoute(path: '/travel', builder: (_, __) => const TravelScreen()),
      GoRoute(path: '/soon/:name', builder: (_, s) => SoonScreen(name: s.pathParameters['name']!)),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _AdaptiveShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/', builder: (_, __) => const HomeScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/explore', builder: (_, s) => ExploreScreen(initialQuery: s.uri.queryParameters['q'] ?? '')),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/messages', builder: (_, __) => const SoonScreen(name: 'messages')),
          ]),
          StatefulShellBranch(routes: [GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen())]),
        ],
      ),
    ],
  );
});

class _AdaptiveShell extends StatelessWidget {
  const _AdaptiveShell({required this.shell});
  final StatefulNavigationShell shell;

  static const _dest = [
    (Icons.home_outlined, Icons.home_rounded, 'Accueil'),
    (Icons.search_rounded, Icons.search_rounded, 'Explorer'),
    (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Messages'),
    (Icons.person_outline_rounded, Icons.person_rounded, 'Profil'),
  ];

  void _go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;
    final sellButton = FloatingActionButton(
      tooltip: 'Vendre un article',
      backgroundColor: LumoColors.action,
      foregroundColor: Colors.white,
      elevation: 0,
      onPressed: () => context.push('/sell'),
      child: const Icon(Icons.add_rounded),
    );

    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: _go,
            labelType: NavigationRailLabelType.all,
            leading: Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: sellButton),
            destinations: [
              for (final d in _dest)
                NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2, color: LumoColors.action), label: Text(d.$3)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: shell),
        ]),
      );
    }
    return Scaffold(
      body: shell,
      floatingActionButton: sellButton,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: _go,
        destinations: [
          for (final d in _dest)
            NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2, color: LumoColors.action), label: d.$3),
        ],
      ),
    );
  }
}
