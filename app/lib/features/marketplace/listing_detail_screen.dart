// Fiche article façon marketplace européenne : grande photo, prix, protection,
// caractéristiques, vendeur, barre d'actions fixe.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/common.dart';
import 'marketplace_repository.dart';

class ListingDetailScreen extends ConsumerWidget {
  const ListingDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(listingProvider(id));
    return Scaffold(
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: ErrorRetry(
            message: e is ApiException && e.status == 404 ? 'Cet article n\'existe plus.' : 'Impossible de charger l\'article.',
            onRetry: () => ref.invalidate(listingProvider(id)),
          ),
        ),
        data: (l) => _Body(l),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.l);
  final Listing l;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final available = l.status == 'active';
    final wide = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;

    final photo = Stack(children: [
      ProductVisual(seed: l.id.hashCode, photoUrl: l.photos.isEmpty ? null : l.photos.first, height: wide ? 560 : 430, radius: wide ? 20 : 0),
      Positioned(
        left: 16, top: 16,
        child: IconButton.filled(
          tooltip: 'Retour',
          style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: LumoColors.ink),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
    ]);

    final info = Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.title, style: t.titleMedium?.copyWith(fontSize: 18)),
        const SizedBox(height: 6),
        Text('${conditionLabels[l.condition] ?? l.condition} · ${l.city}', style: t.bodySmall?.copyWith(fontSize: 14)),
        const SizedBox(height: 16),
        Text(formatXaf(l.priceXaf), style: t.headlineMedium),
        const SizedBox(height: 4),
        const ProtectionBadge('Protection acheteur incluse au paiement'),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),
        if (l.description.isNotEmpty) ...[Text(l.description, style: t.bodyLarge), const SizedBox(height: 16)],
        if (l.sellerName != null)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(border: Border.all(color: LumoColors.line), borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              CircleAvatar(
                backgroundColor: LumoColors.actionSoft,
                foregroundColor: LumoColors.action,
                child: Text(l.sellerName!.characters.first.toUpperCase()),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(l.sellerName!, style: t.titleMedium?.copyWith(fontSize: 15))),
            ]),
          ),
        if (wide) ...[const SizedBox(height: 24), _Actions(l: l, available: available)],
      ]),
    );

    if (wide) {
      // Windows : photo à gauche, infos à droite, contenu centré et borné.
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1160),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 6, child: photo),
                const SizedBox(width: 24),
                Expanded(flex: 5, child: info),
              ]),
            ),
          ),
        ),
      );
    }

    return Column(children: [
      Expanded(child: ListView(padding: EdgeInsets.zero, children: [photo, info])),
      SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: LumoColors.line))),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: _Actions(l: l, available: available),
        ),
      ),
    ]);
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.l, required this.available});
  final Listing l;
  final bool available;

  @override
  Widget build(BuildContext context) {
    if (!available) {
      return const Text('Cet article n\'est plus disponible.', style: TextStyle(color: LumoColors.slate));
    }
    return Row(children: [
      Expanded(
        child: OutlinedButton(
          // Messagerie et offres : Phase 2.
          onPressed: () => ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Les offres arrivent bientôt.'))),
          child: const Text('Faire une offre'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: FilledButton(
          onPressed: () => context.push('/checkout/${l.id}'),
          child: const Text('Acheter'),
        ),
      ),
    ]);
  }
}
