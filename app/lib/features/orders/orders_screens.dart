// Commandes de tous les services : paiement sécurisé, suivi, confirmation de
// réception (libère le séquestre), litige, et suivi de livraison côté vendeur.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api/api_client.dart';
import '../../core/data.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/common.dart';
import '../auth/auth_screens.dart' show toE164;

const _statusLabels = {
  'pending_payment': 'En attente de paiement',
  'paid': 'Payée · argent bloqué en sécurité',
  'cash_due': 'À payer à la remise',
  'completed': 'Terminée',
  'disputed': 'Litige en cours',
  'refunded': 'Remboursée',
  'cancelled': 'Annulée',
};
const _kindLabels = {'listing': 'Seconde main', 'carpool': 'Covoiturage', 'food': 'Repas', 'shop': 'Boutique'};
const _steps = ['accepted', 'preparing', 'ready', 'delivering', 'delivered'];
const _stepLabels = {
  'accepted': 'Acceptée', 'preparing': 'En préparation', 'ready': 'Prête', 'delivering': 'En livraison', 'delivered': 'Livrée',
};

Color _statusColor(String s) => switch (s) {
      'paid' || 'cash_due' => LumoColors.action,
      'completed' => LumoColors.success,
      'disputed' => LumoColors.warning,
      'cancelled' || 'refunded' => LumoColors.slate,
      _ => LumoColors.ink,
    };

/// Petit utilitaire : exécute une action API et affiche l'erreur en snackbar.
Future<bool> runAction(BuildContext context, Future<void> Function() action, {String? success}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    if (success != null) messenger.showSnackBar(SnackBar(content: Text(success)));
    return true;
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    return false;
  }
}

// --------------------------------------------------------------- Liste
class MyOrdersScreen extends ConsumerWidget {
  const MyOrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Commandes', style: Theme.of(context).textTheme.headlineSmall),
          bottom: const TabBar(tabs: [Tab(text: 'Mes achats'), Tab(text: 'Mes ventes')]),
        ),
        body: const TabBarView(children: [_OrderList(role: 'buyer'), _OrderList(role: 'seller')]),
      ),
    );
  }
}

class _OrderList extends ConsumerWidget {
  const _OrderList({required this.role});
  final String role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = '/orders?role=$role';
    final async = ref.watch(jsonProvider(path));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: ErrorRetry(message: 'Impossible de charger les commandes.', onRetry: () => ref.invalidate(jsonProvider(path)))),
      data: (json) {
        final items = itemsOf(json);
        if (items.isEmpty) {
          return Center(child: Text(role == 'buyer' ? 'Aucun achat pour l\'instant.' : 'Aucune vente pour l\'instant.'));
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(jsonProvider(path).future),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final o = items[i];
              final lines = itemsOf({'items': o['items']});
              final firstItem = lines.isEmpty ? null : lines.first;
              final status = o['status'] as String;
              return Material(
                color: LumoColors.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: LumoColors.line)),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  onTap: () => context.push('/orders/${o['id']}'),
                  title: Text(firstItem?['name'] as String? ?? _kindLabels[o['kind']] ?? 'Commande',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${_kindLabels[o['kind']] ?? ''} · ${_statusLabels[status] ?? status}',
                      style: TextStyle(color: _statusColor(status))),
                  trailing: Text(formatXaf(asInt(o['totalXaf'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------- Détail
class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = '/orders/$id';
    final async = ref.watch(jsonProvider(path));
    final myId = ref.watch(jsonProvider('/me')).valueOrNull?['id'];
    final t = Theme.of(context).textTheme;
    void reload() => ref.invalidate(jsonProvider(path));

    return Scaffold(
      appBar: AppBar(title: Text('Commande', style: t.headlineSmall)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: ErrorRetry(message: 'Commande introuvable.', onRetry: reload)),
        data: (o) {
          final status = o['status'] as String;
          final isBuyer = o['buyerId'] == myId;
          final isSeller = o['sellerId'] == myId;
          final fulfillment = o['fulfillment'] as String?;
          final api = ref.read(apiClientProvider);
          final nextStep = fulfillment == null ? _steps.first : (_steps.indexOf(fulfillment) + 1 < _steps.length ? _steps[_steps.indexOf(fulfillment) + 1] : null);
          final usesDelivery = o['kind'] == 'food' || o['kind'] == 'shop';

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: ListView(padding: const EdgeInsets.all(20), children: [
                Text(_kindLabels[o['kind']] ?? 'Commande', style: t.bodySmall),
                const SizedBox(height: 4),
                Text(_statusLabels[status] ?? status, style: t.headlineSmall?.copyWith(color: _statusColor(status))),
                if (usesDelivery && fulfillment != null) ...[
                  const SizedBox(height: 8),
                  Text('Livraison : ${_stepLabels[fulfillment]}', style: t.bodyLarge),
                ],
                const SizedBox(height: 20),
                for (final it in itemsOf({'items': o['items']}))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(child: Text('${it['qty']} × ${it['name']}')),
                      Text(formatXaf(asInt(it['qty']) * asInt(it['unitPriceXaf']))),
                    ]),
                  ),
                const Divider(height: 24),
                if (asInt(o['buyerFeeXaf']) > 0) _line('Protection acheteur', formatXaf(asInt(o['buyerFeeXaf']))),
                _line('Total', formatXaf(asInt(o['totalXaf'])), bold: true),
                if (o['otherName'] != null) ...[
                  const SizedBox(height: 12),
                  _line(isBuyer ? 'Vendeur' : 'Acheteur', '${o['otherName']}${o['otherPhone'] != null ? ' · ${o['otherPhone']}' : ''}'),
                ],
                const SizedBox(height: 24),

                // ---- Actions acheteur
                if (isBuyer && status == 'pending_payment') ...[
                  FilledButton(onPressed: () => context.push('/pay/$id'), child: const Text('Choisir comment payer')),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () async { if (await runAction(context, () => api.post('/orders/$id/cancel'), success: 'Commande annulée')) reload(); },
                    child: const Text('Annuler la commande'),
                  ),
                ],
                if (isBuyer && status == 'paid') ...[
                  const ProtectionBadge('Ton argent est bloqué jusqu\'à ta confirmation'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      final ok = await _confirm(context, 'Confirmer la réception ?',
                          'Le vendeur sera payé. Fais-le seulement si tu as bien reçu ce que tu as commandé.');
                      if (ok && context.mounted && await runAction(context, () => api.post('/orders/$id/confirm'), success: 'Merci ! Le vendeur est payé.')) reload();
                    },
                    child: const Text('J\'ai reçu ma commande'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(onPressed: () => _dispute(context, ref, id, reload), child: const Text('Signaler un problème')),
                ],
                if (isBuyer && status == 'cash_due') ...[
                  Text('Tu paies le vendeur directement au moment de la remise (espèces ou Mobile Money). '
                      'Vérifie l\'article avant de payer : ce mode n\'inclut pas la protection acheteur.', style: t.bodyMedium),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      final ok = await _confirm(context, 'Commande reçue et payée ?', 'Confirme seulement une fois l\'article en main et le vendeur payé.');
                      if (ok && context.mounted && await runAction(context, () => api.post('/orders/$id/confirm'), success: 'Commande terminée. Merci !')) reload();
                    },
                    child: const Text('J\'ai reçu et payé ma commande'),
                  ),
                ],

                // ---- Actions vendeur / commerçant
                if (isSeller && (status == 'paid' || status == 'cash_due') && usesDelivery && nextStep != null)
                  FilledButton(
                    onPressed: () async {
                      if (await runAction(context, () => api.post('/orders/$id/fulfillment', body: {'step': nextStep}))) reload();
                    },
                    child: Text('Passer à : ${_stepLabels[nextStep]}'),
                  ),
                if (isSeller && status == 'paid')
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('Tu seras payé dès que le client confirme la réception.', style: t.bodySmall),
                  ),
                if (isSeller && status == 'cash_due')
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('L\'acheteur te paie directement à la remise. Encaisse avant de remettre l\'article.', style: t.bodySmall),
                  ),
                if (status == 'cash_due') ...[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () async {
                      final ok = await _confirm(context, 'Annuler cette commande ?', 'L\'article redeviendra disponible pour les autres.');
                      if (ok && context.mounted && await runAction(context, () => api.post('/orders/$id/cancel'), success: 'Commande annulée')) reload();
                    },
                    child: const Text('Annuler la commande'),
                  ),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _line(String a, String b, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(a, style: TextStyle(color: bold ? LumoColors.ink : LumoColors.slate, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
          const Spacer(),
          Text(b, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
        ]),
      );
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Pas encore')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Confirmer')),
        ],
      ),
    ) ??
    false;

Future<void> _dispute(BuildContext context, WidgetRef ref, String id, VoidCallback reload) async {
  final controller = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Signaler un problème'),
      content: TextField(controller: controller, maxLines: 4, decoration: const InputDecoration(hintText: 'Décris ce qui ne va pas (10 caractères min.)')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Fermer')),
        TextButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: const Text('Envoyer')),
      ],
    ),
  );
  controller.dispose();
  if (reason == null || reason.length < 10 || !context.mounted) return;
  if (await runAction(context, () => ref.read(apiClientProvider).post('/orders/$id/dispute', body: {'reason': reason}),
      success: 'Litige ouvert. Notre équipe revient vers toi.')) {
    reload();
  }
}

// ------------------------------------------------------------ Paiement
enum _PayStep { ready, waiting, verifying, paid }

/// Paiement d'une commande, quel que soit le service. Trois façons :
///  1. Mobile Money direct : on saisit son numéro, on confirme sur son téléphone (code secret
///     tapé dans le menu de l'opérateur, jamais dans l'application) ;
///  2. page sécurisée du prestataire ;
///  3. à la remise, de la main à la main (sans protection acheteur, sans frais).
class PayOrderScreen extends ConsumerStatefulWidget {
  const PayOrderScreen({super.key, required this.orderId});
  final String orderId;
  @override
  ConsumerState<PayOrderScreen> createState() => _PayOrderScreenState();
}

class _PayOrderScreenState extends ConsumerState<PayOrderScreen> with WidgetsBindingObserver {
  _PayStep _step = _PayStep.ready;
  final _phone = TextEditingController();
  String? _ref;
  String? _error;
  bool _busy = false;
  bool _phonePrefilled = false;

  ApiClient get _api => ref.read(apiClientProvider);
  String get _orderPath => '/orders/${widget.orderId}';

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); _phone.dispose(); super.dispose(); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _step == _PayStep.waiting) _verify();
  }

  Future<void> _guard(Future<void> Function() action) async {
    setState(() { _busy = true; _error = null; });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // 1. Demande envoyée sur le téléphone.
  Future<void> _payMobile() async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8) { setState(() => _error = 'Saisis ton numéro Orange Money ou MTN MoMo.'); return; }
    await _guard(() async {
      final r = await _api.post('$_orderPath/pay-mobile', body: {'phone': toE164(_phone.text)});
      _ref = r['reference'] as String;
      if (mounted) setState(() => _step = _PayStep.waiting);
    });
    if (_step == _PayStep.waiting) _verify(rounds: 20);
  }

  // 2. Page sécurisée du prestataire.
  Future<void> _payHosted() => _guard(() async {
        final r = await _api.post('$_orderPath/pay');
        _ref = r['reference'] as String;
        final uri = Uri.parse(r['checkoutUrl'] as String);
        if (uri.scheme != 'https') throw ApiException('insecure_checkout_url');
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) throw ApiException('cannot_open_checkout');
        if (mounted) setState(() => _step = _PayStep.waiting);
      });

  // 3. À la remise.
  Future<void> _payCash() async {
    final ok = await _confirm(context, 'Payer à la remise ?',
        'Tu paieras le vendeur directement en récupérant ta commande. C\'est sans frais, mais sans protection acheteur : vérifie bien l\'article avant de payer.');
    if (!ok || !mounted) return;
    await _guard(() async {
      await _api.post('$_orderPath/pay-cash');
      ref.invalidate(jsonProvider(_orderPath));
      if (mounted) context.go(_orderPath);
    });
  }

  Future<void> _verify({int rounds = 6}) async {
    final reference = _ref;
    if (reference == null || _step == _PayStep.verifying) return;
    setState(() { _step = _PayStep.verifying; _error = null; });
    for (var i = 0; i < rounds; i++) {
      try {
        final status = (await _api.post('/payments/$reference/refresh'))['status'] as String;
        if (!mounted) return;
        if (status == 'succeeded') {
          ref.invalidate(jsonProvider(_orderPath));
          setState(() => _step = _PayStep.paid);
          return;
        }
        if (status == 'failed' || status == 'mismatch') {
          setState(() { _step = _PayStep.ready; _error = 'Le paiement n\'a pas abouti. Aucun montant n\'a été débité pour cette commande.'; });
          return;
        }
      } on ApiException catch (_) {/* on réessaie */}
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted) return;
    }
    if (mounted) setState(() { _step = _PayStep.waiting; _error = 'Paiement pas encore confirmé. Valide la demande sur ton téléphone, puis touche « J\'ai payé, vérifier ».'; });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final async = ref.watch(jsonProvider(_orderPath));
    final options = ref.watch(jsonProvider('/payments/options')).valueOrNull;
    final me = ref.watch(jsonProvider('/me')).valueOrNull;
    if (!_phonePrefilled && me != null) {
      _phonePrefilled = true;
      final p = (me['phone'] as String?) ?? '';
      if (p.startsWith('+237')) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _phone.text.isEmpty) _phone.text = p.substring(4);
        });
      }
    }
    final online = options?['online'] == true;
    final cash = options?['cash'] == true;
    final working = _busy || _step == _PayStep.verifying;

    return Scaffold(
      appBar: AppBar(title: Text('Paiement', style: t.headlineSmall)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: _step == _PayStep.paid
              ? _PaidView(onDone: () => context.go(_orderPath))
              : async.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: ErrorRetry(message: 'Commande introuvable.', onRetry: () => ref.invalidate(jsonProvider(_orderPath)))),
                  data: (o) => ListView(padding: const EdgeInsets.all(20), children: [
                    for (final it in itemsOf({'items': o['items']}))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [Expanded(child: Text('${it['qty']} × ${it['name']}')),
                          Text(formatXaf(asInt(it['qty']) * asInt(it['unitPriceXaf'])))]),
                      ),
                    const Divider(height: 24),
                    Row(children: [Text('Protection acheteur', style: t.bodyMedium?.copyWith(color: LumoColors.slate)), const Spacer(),
                      Text(formatXaf(asInt(o['buyerFeeXaf'])))]),
                    const SizedBox(height: 8),
                    Row(children: [Text('Total en ligne', style: t.titleMedium), const Spacer(),
                      Text(formatXaf(asInt(o['totalXaf'])), style: t.headlineSmall?.copyWith(fontSize: 20))]),
                    const SizedBox(height: 20),
                    if (_error != null) ...[
                      Text(_error!, style: const TextStyle(color: LumoColors.warning, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                    ],
                    if (o['status'] != 'pending_payment')
                      Text('Cette commande n\'est plus à payer (${_statusLabels[o['status']] ?? o['status']}).', textAlign: TextAlign.center)
                    else if (options == null)
                      const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
                    else if (_step == _PayStep.waiting || _step == _PayStep.verifying) ...[
                      _PayCard(
                        icon: Icons.phonelink_ring_outlined,
                        title: 'Confirme sur ton téléphone',
                        body: 'Une demande de paiement vient d\'être envoyée. Valide-la avec ton code secret Orange Money ou MTN MoMo. '
                            'Rien ne s\'affiche ? Ouvre le menu Mobile Money de ton opérateur pour valider la demande en attente.',
                        child: FilledButton(
                          onPressed: working ? null : () => _verify(),
                          child: working
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text('J\'ai payé, vérifier'),
                        ),
                      ),
                      TextButton(onPressed: working ? null : () => setState(() { _step = _PayStep.ready; _error = null; }), child: const Text('Choisir un autre moyen')),
                    ] else ...[
                      if (online)
                        _PayCard(
                          icon: Icons.smartphone_rounded,
                          title: 'Orange Money · MTN MoMo',
                          tag: 'Protégé',
                          body: 'Saisis ton numéro : tu reçois la demande sur ton téléphone et tu valides avec ton code secret. '
                              'L\'argent reste bloqué jusqu\'à ta confirmation de réception.',
                          child: Column(children: [
                            TextField(
                              controller: _phone, keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(labelText: 'Numéro Mobile Money', prefixText: '+237 ', hintText: '6XX XX XX XX'),
                            ),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: working ? null : _payMobile,
                              child: working
                                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : Text('Payer ${formatXaf(asInt(o['totalXaf']))}'),
                            ),
                            TextButton(onPressed: working ? null : _payHosted, child: const Text('Autre moyen : page sécurisée du prestataire')),
                          ]),
                        ),
                      if (cash)
                        _PayCard(
                          icon: Icons.handshake_outlined,
                          title: 'Payer à la remise',
                          tag: 'Sans frais',
                          body: 'Tu paies ${formatXaf(asInt(o['itemPriceXaf']))} directement au vendeur quand tu récupères ta commande. Pas de protection acheteur.',
                          child: OutlinedButton(onPressed: working ? null : _payCash, child: const Text('Choisir ce mode')),
                        ),
                      if (!online && !cash)
                        const Text('Aucun moyen de paiement n\'est activé pour le moment. Réessaie plus tard.', textAlign: TextAlign.center),
                      if (online) ...[
                        const SizedBox(height: 4),
                        Text('Ton code secret n\'est jamais saisi dans l\'application : tu le tapes uniquement dans le menu de ton opérateur.', style: t.bodySmall),
                      ],
                    ],
                  ]),
                ),
        ),
      ),
    );
  }
}

class _PayCard extends StatelessWidget {
  const _PayCard({required this.icon, required this.title, required this.body, required this.child, this.tag});
  final IconData icon;
  final String title, body;
  final String? tag;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(border: Border.all(color: LumoColors.line), borderRadius: BorderRadius.circular(LumoRadius.panel)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: LumoColors.actionSoft, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: LumoColors.action),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            if (tag != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: LumoColors.lime, borderRadius: BorderRadius.circular(LumoRadius.pill)),
                child: Text(tag!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
          ]),
          const SizedBox(height: 10),
          Text(body, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: LumoColors.slate)),
          const SizedBox(height: 14),
          child,
        ]),
      );
}

class _PaidView extends StatelessWidget {
  const _PaidView({required this.onDone});
  final VoidCallback onDone;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 72, height: 72,
            decoration: const BoxDecoration(color: LumoColors.successSoft, shape: BoxShape.circle),
            child: const Icon(Icons.check_rounded, size: 40, color: LumoColors.success)),
        const SizedBox(height: 20),
        Text('Paiement confirmé', style: t.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text('Ton argent est bloqué en sécurité. Confirme la réception pour payer le vendeur.',
            style: t.bodyLarge, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton(onPressed: onDone, child: const Text('Voir ma commande')),
      ]),
    );
  }
}
