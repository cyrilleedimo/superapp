// Fiche article façon marketplace européenne : grande photo, prix, protection,
// caractéristiques, vendeur, barre d'actions fixe.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/data.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
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
      _Gallery(listing: l, height: wide ? 560 : 430, radius: wide ? 20 : 0),
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
        if (l.isDemo)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: LumoColors.actionSoft, borderRadius: BorderRadius.circular(14)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline_rounded, color: LumoColors.action, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('Annonce d\'exemple : elle montre à quoi ressemble une annonce, mais cet article n\'est pas réellement à vendre.',
                  style: t.bodyMedium)),
            ]),
          )
        else
          const ProtectionBadge('Protection acheteur si tu paies en ligne'),
        if (l.photos.length > 1)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('${l.photos.length} photos — fais défiler', style: t.bodySmall)),
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

/// Photos de l'annonce : on fait défiler du doigt, des points indiquent la position.
class _Gallery extends StatefulWidget {
  const _Gallery({required this.listing, required this.height, required this.radius});
  final Listing listing;
  final double height, radius;
  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final l = widget.listing;
    if (l.photos.length < 2) {
      return ProductVisual(seed: l.id.hashCode, photoUrl: l.photos.isEmpty ? null : l.photos.first, height: widget.height, radius: widget.radius);
    }
    return SizedBox(
      height: widget.height,
      child: Stack(children: [
        PageView.builder(
          itemCount: l.photos.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (_, i) => ProductVisual(seed: l.id.hashCode, photoUrl: l.photos[i], height: widget.height, radius: widget.radius),
        ),
        Positioned(
          left: 0, right: 0, bottom: 12,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < l.photos.length; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: 8, height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: i == _index ? Colors.white : Colors.white54,
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)]),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.l, required this.available});
  final Listing l;
  final bool available;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(signedInProvider);
    // Annonce d'exemple : seul un administrateur peut la commander (simulation) ; les autres sont invités à publier.
    final isAdmin = signedIn && ref.watch(jsonProvider('/me')).valueOrNull?['role'] == 'admin';
    if (l.isDemo && available && !isAdmin) {
      return FilledButton(
        onPressed: () => context.push(signedIn ? '/sell' : '/login?next=${Uri.encodeQueryComponent('/sell')}'),
        child: const Text('Publier ma propre annonce'),
      );
    }
    // Sans compte, on peut tout regarder ; pour agir, on passe par la connexion puis on revient ici.
    void needAccount() => context.push('/login?next=${Uri.encodeQueryComponent('/listing/${l.id}')}');
    if (!available) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(color: LumoColors.mist, borderRadius: BorderRadius.circular(14)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(l.status == 'sold' ? 'Vendu' : 'Réservé par un acheteur', textAlign: TextAlign.center,
              style: const TextStyle(color: LumoColors.slate, fontWeight: FontWeight.w600)),
          if (signedIn && l.status == 'reserved')
            TextButton(onPressed: () => context.push('/orders'), child: const Text('C\'est toi ? Voir mes commandes')),
        ]),
      );
    }
    return Row(children: [
      Expanded(
        child: Builder(
          builder: (context) => OutlinedButton(
            // Ouvre (ou retrouve) la conversation avec le vendeur ; les offres se font dans le chat.
            onPressed: () async {
              if (!signedIn) { needAccount(); return; }
              try {
                final c = await ref.read(apiClientProvider).post('/conversations', body: {'listingId': l.id});
                if (context.mounted) context.push('/chat/${c['id']}');
              } on ApiException catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
              }
            },
            child: const Text('Message / offre'),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: FilledButton(
          onPressed: () {
            if (signedIn) { context.push('/checkout/${l.id}'); } else { needAccount(); }
          },
          child: const Text('Acheter'),
        ),
      ),
    ]);
  }
}
