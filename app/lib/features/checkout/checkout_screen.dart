// Paiement sécurisé. Le client ne saisit JAMAIS de numéro de carte ni de code
// Mobile Money dans l'app : il est envoyé sur la page hébergée du prestataire
// (PCI-DSS SAQ A), puis l'app vérifie le statut auprès de NOTRE serveur.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/common.dart';
import '../marketplace/marketplace_repository.dart';

enum _Step { preparing, ready, redirected, verifying, paid, failed }

class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key, required this.listingId});
  final String listingId;

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> with WidgetsBindingObserver {
  // Une seule clé pour toute la vie de l'écran : réessayer ne duplique pas la commande.
  final _idemKey = MarketplaceRepository.newIdempotencyKey();
  _Step _step = _Step.preparing;
  Listing? _listing;
  Order? _order;
  String? _paymentRef;
  String? _error;

  MarketplaceRepository get _repo => ref.read(marketplaceRepoProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() { _step = _Step.preparing; _error = null; });
    try {
      final l = await _repo.byId(widget.listingId);
      final o = await _repo.createOrder(widget.listingId, _idemKey); // réserve l'article
      if (!mounted) return;
      setState(() { _listing = l; _order = o; _step = _Step.ready; });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.userMessage; _step = _Step.failed; });
    }
  }

  Future<void> _pay() async {
    final order = _order;
    if (order == null) return;
    try {
      final p = await _repo.startPayment(order.id);
      _paymentRef = p.reference;
      final uri = Uri.parse(p.checkoutUrl);
      if (uri.scheme != 'https') throw ApiException('insecure_checkout_url');
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) throw ApiException('cannot_open_checkout');
      if (mounted) setState(() => _step = _Step.redirected);
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.userMessage; });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Retour dans l'app après la page de paiement : on vérifie le statut.
    if (state == AppLifecycleState.resumed && _step == _Step.redirected) _verify();
  }

  Future<void> _verify() async {
    final ref0 = _paymentRef;
    if (ref0 == null) return;
    setState(() { _step = _Step.verifying; _error = null; });
    // Le webhook peut arriver quelques secondes après : 6 essais espacés.
    for (var i = 0; i < 6; i++) {
      try {
        final status = await _repo.refreshPayment(ref0);
        if (!mounted) return;
        if (status == 'succeeded') { setState(() => _step = _Step.paid); return; }
        if (status == 'failed' || status == 'mismatch') {
          setState(() { _step = _Step.ready; _error = 'Le paiement n\'a pas abouti. Aucun montant n\'a été débité pour cette commande.'; });
          return;
        }
      } on ApiException catch (_) {/* on réessaie */}
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (mounted) {
      setState(() { _step = _Step.redirected; _error = 'Paiement encore en cours de confirmation. Vérifie dans quelques instants.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Paiement', style: t.headlineSmall)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: switch (_step) {
              _Step.preparing => const Center(child: CircularProgressIndicator()),
              _Step.failed => ErrorRetry(message: _error ?? 'Erreur', onRetry: _prepare),
              _Step.paid => _Success(onDone: () => context.go('/')),
              _ => _summary(context),
            },
          ),
        ),
      ),
    );
  }

  Widget _summary(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final l = _listing!, o = _order!;
    final busy = _step == _Step.verifying;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [
        SizedBox(width: 56, child: ProductVisual(seed: l.id.hashCode, height: 64, radius: 10, photoUrl: l.photos.isEmpty ? null : l.photos.first)),
        const SizedBox(width: 12),
        Expanded(child: Text(l.title, style: t.titleMedium?.copyWith(fontSize: 15))),
      ]),
      const SizedBox(height: 24),
      Text('Moyens acceptés', style: t.titleMedium?.copyWith(fontSize: 15)),
      const SizedBox(height: 10),
      // [PAYMENT PROVIDERS] : liste indicative ; le choix se fait sur la page sécurisée du prestataire.
      const Wrap(spacing: 8, runSpacing: 8, children: [
        _MethodChip('Orange Money'), _MethodChip('MTN Mobile Money'), _MethodChip('Carte bancaire · 3-D Secure'),
      ]),
      const SizedBox(height: 8),
      Text('Tu confirmes sur la page sécurisée du prestataire. Ton code secret et ton numéro de carte ne sont jamais saisis dans l\'app.',
          style: t.bodySmall),
      const SizedBox(height: 20),
      const Divider(),
      const SizedBox(height: 12),
      _row('Article', formatXaf(o.itemPriceXaf), t),
      _row('Protection acheteur', formatXaf(o.buyerFeeXaf), t),
      const SizedBox(height: 6),
      Row(children: [
        Text('Total', style: t.titleMedium),
        const Spacer(),
        Text(formatXaf(o.totalXaf), style: t.headlineSmall?.copyWith(fontSize: 20)),
      ]),
      if (_error != null) ...[
        const SizedBox(height: 16),
        Text(_error!, style: const TextStyle(color: LumoColors.warning, fontWeight: FontWeight.w600)),
      ],
      const SizedBox(height: 24),
      const Center(child: ProtectionBadge('Argent bloqué jusqu\'à ta confirmation de réception')),
      const SizedBox(height: 10),
      if (_step == _Step.redirected)
        FilledButton(onPressed: _verify, child: const Text('J\'ai payé, vérifier'))
      else
        FilledButton(
          onPressed: busy ? null : _pay,
          child: busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text('Payer ${formatXaf(o.totalXaf)}'),
        ),
    ]);
  }

  Widget _row(String a, String b, TextTheme t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Text(a, style: t.bodyMedium?.copyWith(color: LumoColors.slate)), const Spacer(), Text(b, style: t.bodyMedium)]),
      );
}

class _MethodChip extends StatelessWidget {
  const _MethodChip(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(border: Border.all(color: LumoColors.line), borderRadius: BorderRadius.circular(LumoRadius.pill)),
        child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      );
}

class _Success extends StatelessWidget {
  const _Success({required this.onDone});
  final VoidCallback onDone;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 72, height: 72,
          decoration: const BoxDecoration(color: LumoColors.successSoft, shape: BoxShape.circle),
          child: const Icon(Icons.check_rounded, size: 40, color: LumoColors.success),
        ),
        const SizedBox(height: 20),
        Text('Paiement confirmé', style: t.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text('Ton argent est bloqué en sécurité. Confirme la réception une fois l\'article en main pour payer le vendeur.',
            style: t.bodyLarge, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton(onPressed: onDone, child: const Text('Retour à l\'accueil')),
      ]),
    );
  }
}
