// Accueil : services, bandeau de confiance, flux « Pour toi » (grille photo).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/common.dart';
import '../marketplace/marketplace_repository.dart';

class _Service {
  const _Service(this.label, this.icon, this.route, {this.highlight = false});
  final String label;
  final IconData icon;
  final String route;
  final bool highlight;
}

const _services = [
  _Service('Seconde main', Icons.checkroom_outlined, '/explore', highlight: true),
  _Service('Course', Icons.local_taxi_outlined, '/rides'),
  _Service('Covoiturage', Icons.directions_car_outlined, '/carpool'),
  _Service('Repas', Icons.ramen_dining_outlined, '/stores/restaurant'),
  _Service('Boutiques', Icons.shopping_bag_outlined, '/stores/shop'),
  _Service('Voyages', Icons.flight_outlined, '/travel'),
];

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final feed = ref.watch(feedProvider);
    final wide = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;
    final columns = wide ? 5 : 2;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.refresh(feedProvider.future),
          child: CustomScrollView(slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              sliver: SliverList.list(children: [
                Row(children: [
                  const LumoLogo(),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Notifications',
                    style: IconButton.styleFrom(backgroundColor: LumoColors.mist, minimumSize: const Size(44, 44)),
                    onPressed: () => context.push('/notifications'),
                    icon: const Icon(Icons.notifications_none_rounded),
                  ),
                ]),
                const SizedBox(height: 20),
                Text('Qu\'est-ce qu\'on fait\naujourd\'hui ?', style: t.headlineMedium),
                const SizedBox(height: 20),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Articles, restos, trajets, vols…',
                    prefixIcon: Icon(Icons.search_rounded, color: LumoColors.slate),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (q) => context.go('/explore?q=${Uri.encodeQueryComponent(q)}'),
                ),
                const SizedBox(height: 20),
                GridView.count(
                  crossAxisCount: wide ? 6 : 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.25,
                  children: [for (final s in _services) _ServiceTile(s)],
                ),
                const SizedBox(height: 20),
                const _TrustBanner(),
                const SizedBox(height: 24),
                Row(children: [
                  Text('Pour toi', style: t.titleMedium),
                  const Spacer(),
                  TextButton(onPressed: () => context.go('/explore'), child: const Text('Tout voir')),
                ]),
                const SizedBox(height: 8),
              ]),
            ),
            feed.when(
              data: (items) => items.isEmpty
                  ? const SliverToBoxAdapter(
                      child: Padding(padding: EdgeInsets.all(24), child: Text('Aucune annonce pour l\'instant. Sois le premier à vendre !')))
                  : SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      sliver: SliverGrid.builder(
                        itemCount: items.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns, mainAxisSpacing: 16, crossAxisSpacing: 10, mainAxisExtent: 250),
                        itemBuilder: (_, i) {
                          final l = items[i];
                          return ListingCard(
                            id: l.id, title: l.title, priceXaf: l.priceXaf, condition: l.condition,
                            photoUrl: l.photos.isEmpty ? null : l.photos.first,
                            onTap: () => context.push('/listing/${l.id}'),
                          );
                        },
                      ),
                    ),
              loading: () => const SliverToBoxAdapter(
                  child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))),
              error: (e, _) => SliverToBoxAdapter(
                child: ErrorRetry(
                  message: e is ApiException ? e.userMessage : 'Impossible de charger les annonces.',
                  onRetry: () => ref.invalidate(feedProvider),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile(this.s);
  final _Service s;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: s.highlight ? LumoColors.actionSoft : LumoColors.mist,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => s.route == '/explore' ? context.go(s.route) : context.push(s.route),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Icon(s.icon, color: s.highlight ? LumoColors.action : LumoColors.ink),
            Text(s.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class _TrustBanner extends StatelessWidget {
  const _TrustBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: LumoColors.ink, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: LumoColors.lime, borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.verified_user_outlined, color: LumoColors.ink),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Argent bloqué jusqu\'à réception',
                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 2),
            Text('Le vendeur est payé quand tu confirmes.', style: TextStyle(color: Color(0xFFC9CDD6), fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}
