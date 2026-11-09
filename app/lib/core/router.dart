// Navigation : barre basse sur Android, rail latéral sur Windows (≥ 1024 px).
// Les routes protégées redirigent vers /login tant que la session n'est pas ouverte.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/account/account_screens.dart';
import '../features/auth/auth_screens.dart';
import '../features/carpool/carpool_screens.dart';
import '../features/checkout/checkout_screen.dart';
import '../features/home/home_screen.dart';
import '../features/marketplace/explore_screen.dart';
import '../features/marketplace/listing_detail_screen.dart';
import '../features/messages/messages_screens.dart';
import '../features/orders/orders_screens.dart';
import '../features/rides/rides_screens.dart';
import '../features/stores/stores_screens.dart';
import '../features/travel/travel_screen.dart';
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
  GoRoute page(String path, Widget Function(GoRouterState s) build) =>
      GoRoute(path: path, builder: (_, s) => build(s));

  return GoRouter(
    initialLocation: '/',
    refreshListenable: _SessionListenable(ref),
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      if (session == SessionState.unknown) return null; // restauration en cours
      final isPublic = publicRoutes.contains(loc);
      if (session == SessionState.signedOut && !isPublic) return '/login';
      if (session == SessionState.signedIn && isPublic) return '/';
      return null;
    },
    routes: [
      page('/login', (_) => const LoginScreen()),
      page('/register', (_) => const RegisterScreen()),
      page('/verify', (s) => VerifyScreen(phone: s.uri.queryParameters['phone'] ?? '')),
      page('/listing/:id', (s) => ListingDetailScreen(id: s.pathParameters['id']!)),
      page('/checkout/:id', (s) => CheckoutScreen(listingId: s.pathParameters['id']!, offerId: s.uri.queryParameters['offer'])),
      page('/pay/:id', (s) => PayOrderScreen(orderId: s.pathParameters['id']!)),
      page('/orders', (_) => const MyOrdersScreen()),
      page('/orders/:id', (s) => OrderDetailScreen(id: s.pathParameters['id']!)),
      page('/sell', (_) => const SellScreen()),
      page('/chat/:id', (s) => ChatScreen(conversationId: s.pathParameters['id']!)),
      page('/rides', (_) => const TransportScreen()),
      page('/carpool', (_) => const TransportScreen(initialTab: 1)),
      page('/trips/new', (_) => const NewTripScreen()),
      page('/trips/mine', (_) => const MyTripsScreen()),
      page('/driver', (_) => const DriverScreen()),
      page('/stores/:kind', (s) => StoresScreen(kind: s.pathParameters['kind'] == 'shop' ? 'shop' : 'restaurant')),
      page('/store/:id', (s) => StoreScreen(id: s.pathParameters['id']!)),
      page('/merchant', (_) => const MyStoresScreen()),
      page('/merchant/:id', (s) => MerchantStoreScreen(id: s.pathParameters['id']!)),
      page('/travel', (_) => const TravelScreen()),
      page('/notifications', (_) => const NotificationsScreen()),
      page('/payouts', (_) => const PayoutsScreen()),
      page('/admin', (_) => const AdminScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _AdaptiveShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/', builder: (_, __) => const HomeScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/explore', builder: (_, s) => ExploreScreen(initialQuery: s.uri.queryParameters['q'] ?? '')),
          ]),
          StatefulShellBranch(routes: [GoRoute(path: '/messages', builder: (_, __) => const ConversationsScreen())]),
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
      heroTag: 'sell',
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
      floatingActionButton: shell.currentIndex == 0 || shell.currentIndex == 1 ? sellButton : null,
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
