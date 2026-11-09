// Vendre un article + Profil (portefeuille, déconnexion).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../marketplace/marketplace_repository.dart';

class SellScreen extends ConsumerStatefulWidget {
  const SellScreen({super.key});
  @override
  ConsumerState<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends ConsumerState<SellScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _price = TextEditingController();
  final _city = TextEditingController();
  String _category = 'women';
  String _condition = 'very_good';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _desc, _price, _city]) { c.dispose(); }
    super.dispose();
  }

  Future<void> _publish() async {
    if (!_form.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    try {
      final r = await ref.read(apiClientProvider).post('/listings', body: {
        'title': _title.text.trim(), 'description': _desc.text.trim(), 'category': _category,
        'condition': _condition, 'priceXaf': int.parse(_price.text.replaceAll(RegExp(r'\D'), '')),
        'city': _city.text.trim(),
      });
      ref.invalidate(feedProvider);
      if (mounted) context.pushReplacement('/listing/${r['id']}');
    } on ApiException catch (e) {
      setState(() => _error = e.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? v) => (v == null || v.trim().length < 2) ? 'Champ requis' : null;
    return Scaffold(
      appBar: AppBar(title: Text('Vendre un article', style: Theme.of(context).textTheme.headlineSmall)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Container(
                height: 120,
                decoration: BoxDecoration(color: LumoColors.mist, borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: LumoColors.line)),
                alignment: Alignment.center,
                child: const Text('Ajout de photos : Phase 2 (upload sécurisé)', style: TextStyle(color: LumoColors.slate)),
              ),
              const SizedBox(height: 16),
              TextFormField(controller: _title, decoration: const InputDecoration(labelText: 'Titre'), validator: required, maxLength: 120),
              TextFormField(controller: _desc, decoration: const InputDecoration(labelText: 'Description'), maxLines: 4, maxLength: 4000),
              DropdownButtonFormField<String>(
                value: _category,
                decoration: const InputDecoration(labelText: 'Catégorie'),
                items: const {
                  'women': 'Femmes', 'men': 'Hommes', 'kids': 'Enfants', 'electronics': 'Électronique',
                  'home': 'Maison', 'beauty': 'Beauté', 'sports': 'Sport', 'other': 'Autre',
                }.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) => setState(() => _category = v!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _condition,
                decoration: const InputDecoration(labelText: 'État'),
                items: conditionLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) => setState(() => _condition = v!),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _price, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Prix', suffixText: 'FCFA'),
                validator: (v) => (int.tryParse((v ?? '').replaceAll(RegExp(r'\D'), '')) ?? 0) > 0 ? null : 'Prix invalide',
              ),
              const SizedBox(height: 12),
              TextFormField(controller: _city, decoration: const InputDecoration(labelText: 'Ville'), validator: required),
              const SizedBox(height: 20),
              if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: const TextStyle(color: LumoColors.danger))),
              FilledButton(onPressed: _busy ? null : _publish, child: const Text('Publier l\'annonce')),
            ]),
          ),
        ),
      ),
    );
  }
}

final _walletProvider = FutureProvider.autoDispose<int>((ref) async =>
    ((await ref.watch(apiClientProvider).get('/me/wallet'))['availableXaf'] as num).toInt());
final _meProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) => ref.watch(apiClientProvider).get('/me'));

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final me = ref.watch(_meProvider);
    final wallet = ref.watch(_walletProvider);
    return Scaffold(
      appBar: AppBar(title: Text('Profil', style: t.headlineSmall)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Text(me.valueOrNull?['displayName'] as String? ?? '…', style: t.titleMedium),
            Text(me.valueOrNull?['phone'] as String? ?? '', style: t.bodySmall),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: LumoColors.ink, borderRadius: BorderRadius.circular(LumoRadius.panel)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Porte-monnaie', style: TextStyle(color: Color(0xFFC9CDD6), fontSize: 13)),
                const SizedBox(height: 6),
                Text(wallet.when(data: formatXaf, loading: () => '…', error: (_, __) => '—'),
                    style: t.headlineMedium?.copyWith(color: Colors.white)),
                const SizedBox(height: 4),
                const Text('Retrait vers Mobile Money : Phase 2', style: TextStyle(color: Color(0xFFC9CDD6), fontSize: 12)),
              ]),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () => ref.read(sessionProvider.notifier).logout(),
              child: const Text('Se déconnecter'),
            ),
          ]),
        ),
      ),
    );
  }
}
