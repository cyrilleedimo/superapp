// Restaurants et boutiques locales : liste, catalogue avec panier, commande
// (paiement séquestre) ; et l'espace commerçant pour gérer son commerce.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/data.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/common.dart';
import '../marketplace/marketplace_repository.dart';
import '../orders/orders_screens.dart' show runAction;

String _kindTitle(String kind) => kind == 'restaurant' ? 'Repas' : 'Boutiques';

class StoresScreen extends ConsumerStatefulWidget {
  const StoresScreen({super.key, required this.kind});
  final String kind;
  @override
  ConsumerState<StoresScreen> createState() => _StoresScreenState();
}

class _StoresScreenState extends ConsumerState<StoresScreen> {
  String _city = '';

  @override
  Widget build(BuildContext context) {
    final path = '/stores?kind=${widget.kind}${_city.isEmpty ? '' : '&city=${Uri.encodeQueryComponent(_city)}'}';
    final async = ref.watch(jsonProvider(path));
    final wide = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;
    return Scaffold(
      appBar: AppBar(title: Text(_kindTitle(widget.kind), style: Theme.of(context).textTheme.headlineSmall)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Filtrer par ville (ex. Douala)', prefixIcon: Icon(Icons.place_outlined)),
            onSubmitted: (v) => setState(() => _city = v.trim()),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: ErrorRetry(message: 'Impossible de charger la liste.', onRetry: () => ref.invalidate(jsonProvider(path)))),
            data: (json) {
              final items = itemsOf(json);
              if (items.isEmpty) {
                return Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(widget.kind == 'restaurant'
                      ? 'Aucun restaurant pour l\'instant. Tu es restaurateur ? Inscris-toi depuis ton profil.'
                      : 'Aucune boutique pour l\'instant. Tu es commerçant ? Inscris-toi depuis ton profil.', textAlign: TextAlign.center),
                ));
              }
              return GridView.builder(
                padding: const EdgeInsets.all(20),
                itemCount: items.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: wide ? 3 : 1, mainAxisSpacing: 14, crossAxisSpacing: 14, mainAxisExtent: 220),
                itemBuilder: (_, i) {
                  final s = items[i];
                  final open = s['isOpen'] == true;
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => context.push('/store/${s['id']}'),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      ProductVisual(seed: (s['id'] as String).hashCode, height: 140, radius: 16,
                          icon: widget.kind == 'restaurant' ? Icons.ramen_dining_outlined : Icons.storefront_outlined),
                      const SizedBox(height: 8),
                      Text(s['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      Text('${s['city']} · ${open ? 'Ouvert' : 'Fermé'} · Livraison ${formatXaf(asInt(s['deliveryFeeXaf']))}',
                          style: TextStyle(fontSize: 13, color: open ? LumoColors.slate : LumoColors.danger)),
                    ]),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

class StoreScreen extends ConsumerStatefulWidget {
  const StoreScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends ConsumerState<StoreScreen> {
  final Map<String, int> _cart = {};
  final _idemKey = MarketplaceRepository.newIdempotencyKey();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final async = ref.watch(jsonProvider('/stores/${widget.id}'));
    return Scaffold(
      appBar: AppBar(),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(child: Text('Commerce introuvable.')),
        data: (s) {
          final products = itemsOf({'items': s['products']});
          final byId = {for (final p in products) p['id'] as String: p};
          final subtotal = _cart.entries.fold<int>(0, (sum, e) => sum + asInt(byId[e.key]?['priceXaf']) * e.value);
          final fee = asInt(s['deliveryFeeXaf']);
          final count = _cart.values.fold<int>(0, (a, b) => a + b);
          return Column(children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(padding: const EdgeInsets.all(20), children: [
                    Text(s['name'] as String, style: t.headlineMedium),
                    const SizedBox(height: 6),
                    Text('${s['city']}${(s['address'] as String).isEmpty ? '' : ' · ${s['address']}'}', style: t.bodySmall),
                    if ((s['description'] as String).isNotEmpty) ...[const SizedBox(height: 10), Text(s['description'] as String)],
                    if (s['isOpen'] != true) ...[
                      const SizedBox(height: 10),
                      const Text('Fermé pour le moment', style: TextStyle(color: LumoColors.danger, fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(height: 16),
                    if (products.isEmpty) const Text('Aucun article pour l\'instant.'),
                    for (final p in products) _productTile(p),
                  ]),
                ),
              ),
            ),
            if (count > 0)
              SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: LumoColors.line))),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: FilledButton(
                      onPressed: _busy || s['isOpen'] != true ? null : _order,
                      child: Text('Commander $count article${count > 1 ? 's' : ''} · ${formatXaf(subtotal + fee)}'),
                    ),
                  ),
                ),
              ),
          ]);
        },
      ),
    );
  }

  Widget _productTile(Map<String, dynamic> p) {
    final id = p['id'] as String;
    final qty = _cart[id] ?? 0;
    final stock = p['stock'] as int?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        SizedBox(width: 72, child: ProductVisual(seed: id.hashCode, height: 72, radius: 12, photoUrl: p['photoUrl'] as String?,
            icon: Icons.inventory_2_outlined)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
            if ((p['description'] as String).isNotEmpty)
              Text(p['description'] as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LumoColors.slate, fontSize: 13)),
            Text(formatXaf(asInt(p['priceXaf'])), style: const TextStyle(fontWeight: FontWeight.w700)),
            if (stock != null) Text('$stock en stock', style: const TextStyle(fontSize: 12, color: LumoColors.slate)),
          ]),
        ),
        if (qty > 0) ...[
          IconButton(tooltip: 'Retirer', onPressed: () => setState(() { if (qty == 1) { _cart.remove(id); } else { _cart[id] = qty - 1; } }),
              icon: const Icon(Icons.remove_circle_outline)),
          Text('$qty', style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
        IconButton(
          tooltip: 'Ajouter',
          onPressed: stock != null && qty >= stock ? null : () => setState(() => _cart[id] = qty + 1),
          icon: const Icon(Icons.add_circle, color: LumoColors.action),
        ),
      ]),
    );
  }

  Future<void> _order() async {
    setState(() => _busy = true);
    await runAction(context, () async {
      final o = await ref.read(apiClientProvider).post('/stores/${widget.id}/orders',
          body: {'items': [for (final e in _cart.entries) {'productId': e.key, 'qty': e.value}]},
          headers: {'Idempotency-Key': _idemKey});
      if (mounted) context.pushReplacement('/pay/${o['id']}');
    });
    if (mounted) setState(() => _busy = false);
  }
}

// ---------------------------------------------------------- Espace commerçant
class MyStoresScreen extends ConsumerWidget {
  const MyStoresScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = '/stores/mine';
    final async = ref.watch(jsonProvider(path));
    return Scaffold(
      appBar: AppBar(title: Text('Mes commerces', style: Theme.of(context).textTheme.headlineSmall)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async { await _createStore(context, ref); ref.invalidate(jsonProvider(path)); },
        icon: const Icon(Icons.add_business_outlined), label: const Text('Créer'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(child: Text('Impossible de charger tes commerces.')),
        data: (json) {
          final items = itemsOf(json);
          if (items.isEmpty) {
            return const Center(child: Padding(padding: EdgeInsets.all(24),
                child: Text('Crée ton restaurant ou ta boutique. Il sera visible après validation par notre équipe.', textAlign: TextAlign.center)));
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            for (final s in items)
              ListTile(
                title: Text(s['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${s['kind'] == 'restaurant' ? 'Restaurant' : 'Boutique'} · '
                    '${s['approved'] == true ? (s['isOpen'] == true ? 'Ouvert' : 'Fermé') : 'En attente de validation'}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/merchant/${s['id']}'),
              ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => context.push('/orders'), child: const Text('Voir les commandes reçues')),
          ]);
        },
      ),
    );
  }

  Future<void> _createStore(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(), city = TextEditingController(), fee = TextEditingController(text: '0');
    var kind = 'restaurant';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Nouveau commerce'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'restaurant', label: Text('Restaurant')), ButtonSegment(value: 'shop', label: Text('Boutique'))],
                selected: {kind}, onSelectionChanged: (s) => set(() => kind = s.first),
              ),
              const SizedBox(height: 12),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
              const SizedBox(height: 8),
              TextField(controller: city, decoration: const InputDecoration(labelText: 'Ville')),
              const SizedBox(height: 8),
              TextField(controller: fee, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Frais de livraison', suffixText: 'FCFA')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Fermer')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Créer')),
          ],
        ),
      ),
    );
    if (ok == true && context.mounted) {
      await runAction(context, () => ref.read(apiClientProvider).post('/stores', body: {
            'kind': kind, 'name': name.text.trim(), 'city': city.text.trim(),
            'deliveryFeeXaf': int.tryParse(fee.text.replaceAll(RegExp(r'\D'), '')) ?? 0,
          }), success: 'Commerce créé. Il sera visible après validation.');
    }
    for (final c in [name, city, fee]) { c.dispose(); }
  }
}

class MerchantStoreScreen extends ConsumerWidget {
  const MerchantStoreScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storePath = '/stores/mine';
    final productsPath = '/stores/$id/products/all';
    final stores = ref.watch(jsonProvider(storePath));
    final products = ref.watch(jsonProvider(productsPath));
    final api = ref.read(apiClientProvider);
    final store = stores.valueOrNull == null ? null
        : itemsOf(stores.value!).where((s) => s['id'] == id).fold<Map<String, dynamic>?>(null, (_, s) => s);
    return Scaffold(
      appBar: AppBar(title: Text(store?['name'] as String? ?? 'Mon commerce')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await _editProduct(context, ref, null);
          ref.invalidate(jsonProvider(productsPath));
        },
        icon: const Icon(Icons.add_rounded), label: const Text('Article'),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (store != null)
          SwitchListTile(
            title: const Text('Ouvert aux commandes'),
            value: store['isOpen'] == true,
            onChanged: (v) async {
              if (await runAction(context, () => api.patch('/stores/$id', body: {'isOpen': v}))) ref.invalidate(jsonProvider(storePath));
            },
          ),
        const Divider(),
        ...products.when(
          loading: () => [const Center(child: CircularProgressIndicator())],
          error: (_, __) => [const Text('Impossible de charger le catalogue.')],
          data: (json) => [
            for (final p in itemsOf(json))
              ListTile(
                title: Text(p['name'] as String),
                subtitle: Text('${formatXaf(asInt(p['priceXaf']))}${p['stock'] == null ? '' : ' · stock ${p['stock']}'}'
                    '${p['available'] == true ? '' : ' · masqué'}'),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () async { await _editProduct(context, ref, p); ref.invalidate(jsonProvider(productsPath)); },
              ),
          ],
        ),
      ]),
    );
  }

  Future<void> _editProduct(BuildContext context, WidgetRef ref, Map<String, dynamic>? p) async {
    final name = TextEditingController(text: p?['name'] as String? ?? '');
    final price = TextEditingController(text: p == null ? '' : '${p['priceXaf']}');
    final stock = TextEditingController(text: p?['stock'] == null ? '' : '${p!['stock']}');
    final desc = TextEditingController(text: p?['description'] as String? ?? '');
    var available = p?['available'] != false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(p == null ? 'Nouvel article' : 'Modifier l\'article'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
              const SizedBox(height: 8),
              TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
              const SizedBox(height: 8),
              TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Prix', suffixText: 'FCFA')),
              const SizedBox(height: 8),
              TextField(controller: stock, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Stock (vide = illimité)')),
              if (p != null) SwitchListTile(title: const Text('Visible'), value: available, onChanged: (v) => set(() => available = v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Fermer')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (ok == true && context.mounted) {
      final body = <String, dynamic>{
        'name': name.text.trim(),
        'description': desc.text.trim(),
        'priceXaf': int.tryParse(price.text.replaceAll(RegExp(r'\D'), '')) ?? 0,
        'stock': stock.text.trim().isEmpty ? null : int.tryParse(stock.text.trim()),
      };
      final api = ref.read(apiClientProvider);
      await runAction(context, () => p == null
          ? api.post('/stores/$id/products', body: body)
          : api.patch('/products/${p['id']}', body: {...body, 'available': available}));
    }
    for (final c in [name, price, stock, desc]) { c.dispose(); }
  }
}
