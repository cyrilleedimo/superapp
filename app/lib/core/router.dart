// Navigation : barre basse sur Android, rail latéral sur Windows (≥ 1024 px).
// L'accueil, la recherche et les fiches sont visibles sans compte ; toute action
// (acheter, vendre, écrire, profil) redirige vers la connexion puis revient au bon endroit.
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
import '../features/onboarding/onboarding_screens.dart';
import '../features/travel/travel_screen.dart';
import 'config.dart';
import 'providers.dart';
import 'theme/tokens.dart';

/// Pont Riverpod → go_router : relance les redirections quand la session change.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen(sessionProvider, (_, __) => notifyListeners());
  }
}

/// Pages visibles sans compte : on découvre l'application avant de s'inscrire.
bool _isPublic(String loc) =>
    loc == '/' || loc == '/explore' || loc == '/travel' || loc == '/help' || loc == '/welcome' ||
    loc.startsWith('/listing/') || loc.startsWith('/stores/') || loc.startsWith('/store/');

const _authPages = {'/login', '/register', '/verify', '/forgot'};

/// Destination demandée avant la connexion (toujours un chemin interne).
String _safeNext(String? next) => (next != null && next.startsWith('/') && !next.startsWith('//')) ? next : '/';

final routerProvider = Provider<GoRouter>((ref) {
  GoRoute page(String path, Widget Function(GoRouterState s) build) =>
      GoRoute(path: path, builder: (_, s) => build(s));

  return GoRouter(
    initialLocation: AppConfig.onboarded ? '/' : '/welcome',
    refreshListenable: _SessionListenable(ref),
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      if (session == SessionState.unknown) return null; // restauration en cours
      final isAuthPage = _authPages.contains(loc);
      if (session == SessionState.signedOut && !isAuthPage && !_isPublic(loc)) {
        return '/login?next=${Uri.encodeQueryComponent(state.uri.toString())}';
      }
      if (session == SessionState.signedIn && isAuthPage) return _safeNext(state.uri.queryParameters['next']);
      return null;
    },
    routes: [
      page('/welcome', (_) => const WelcomeScreen()),
      page('/help', (_) => const HelpScreen()),
      page('/login', (s) => LoginScreen(next: s.uri.queryParameters['next'])),
      page('/register', (s) => RegisterScreen(next: s.uri.queryParameters['next'])),
      page('/verify', (s) => VerifyScreen(
          email: s.uri.queryParameters['email'] ?? '', verifyToken: s.uri.queryParameters['vt'] ?? '', next: s.uri.queryParameters['next'])),
      page('/forgot', (s) => ForgotPasswordScreen(next: s.uri.queryParameters['next'])),
      page('/add-email', (_) => const AddEmailScreen()),
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

class _AdaptiveShell extends ConsumerWidget {
  const _AdaptiveShell({required this.shell});
  final StatefulNavigationShell shell;

  static const _dest = [
    (Icons.home_outlined, Icons.home_rounded, 'Accueil'),
    (Icons.search_rounded, Icons.search_rounded, 'Explorer'),
    (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Messages'),
    (Icons.person_outline_rounded, Icons.person_rounded, 'Profil'),
  ];

  void _go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);

  Widget _icon(IconData icon, int index, int unread, {Color? color}) {
    final w = Icon(icon, color: color);
    return index == 2 && unread > 0 ? Badge(label: Text(unread > 99 ? '99+' : '$unread'), child: w) : w;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(badgesProvider).messages;
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
              for (var i = 0; i < _dest.length; i++)
                NavigationRailDestination(
                    icon: _icon(_dest[i].$1, i, unread), selectedIcon: _icon(_dest[i].$2, i, unread, color: LumoColors.action), label: Text(_dest[i].$3)),
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
          for (var i = 0; i < _dest.length; i++)
            NavigationDestination(
                icon: _icon(_dest[i].$1, i, unread), selectedIcon: _icon(_dest[i].$2, i, unread, color: LumoColors.action), label: _dest[i].$3),
        ],
      ),
    );
  }
}
