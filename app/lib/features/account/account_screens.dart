// Vendre un article (avec photos), Profil (porte-monnaie, retraits, espaces
// chauffeur / commerçant / admin), Notifications, et Administration.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/api/api_client.dart';
import '../../core/config.dart';
import '../../core/data.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../marketplace/marketplace_repository.dart';
import '../orders/orders_screens.dart' show runAction;

// ---------------------------------------------------------------- Vendre
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
  final List<String> _photos = [];
  String _category = 'women';
  String _condition = 'very_good';
  bool _busy = false;
  bool _uploading = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _desc, _price, _city]) { c.dispose(); }
    super.dispose();
  }

  Future<void> _addPhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, imageQuality: 90);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final bytes = await file.readAsBytes();
      final name = file.name.toLowerCase();
      final mime = name.endsWith('.png') ? 'image/png' : name.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
      final r = await ref.read(apiClientProvider).uploadImage(bytes, mime);
      setState(() => _photos.add(r['url'] as String));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _publish() async {
    if (!_form.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    try {
      final r = await ref.read(apiClientProvider).post('/listings', body: {
        'title': _title.text.trim(), 'description': _desc.text.trim(), 'category': _category,
        'condition': _condition, 'priceXaf': int.parse(_price.text.replaceAll(RegExp(r'\D'), '')),
        'city': _city.text.trim(), 'photos': _photos,
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
              SizedBox(
                height: 110,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final url in _photos)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Stack(children: [
                        ClipRRect(borderRadius: BorderRadius.circular(12),
                            child: Image.network(AppConfig.resolveMediaUrl(url), width: 100, height: 110, fit: BoxFit.cover)),
                        Positioned(right: 2, top: 2, child: IconButton.filled(
                          tooltip: 'Retirer', iconSize: 16,
                          style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: LumoColors.ink, minimumSize: const Size(32, 32)),
                          onPressed: () => setState(() => _photos.remove(url)), icon: const Icon(Icons.close))),
                      ]),
                    ),
                  if (_photos.length < 10)
                    InkWell(
                      onTap: _uploading ? null : _addPhoto,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: 100,
                        decoration: BoxDecoration(color: LumoColors.mist, borderRadius: BorderRadius.circular(12), border: Border.all(color: LumoColors.line)),
                        child: Center(child: _uploading
                            ? const CircularProgressIndicator()
                            : const Column(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.add_a_photo_outlined, color: LumoColors.action), SizedBox(height: 4),
                                Text('Photo', style: TextStyle(fontSize: 12)),
                              ])),
                      ),
                    ),
                ]),
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
              FilledButton(onPressed: _busy || _uploading ? null : _publish, child: const Text('Publier l\'annonce')),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Profil
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final me = ref.watch(jsonProvider('/me'));
    final wallet = ref.watch(jsonProvider('/me/wallet'));
    final available = asInt(wallet.valueOrNull?['availableXaf']);
    final isAdmin = me.valueOrNull?['role'] == 'admin';

    Widget entry(IconData icon, String label, String route) => ListTile(
          leading: Icon(icon), title: Text(label), trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push(route),
        );

    return Scaffold(
      appBar: AppBar(title: Text('Profil', style: t.headlineSmall), actions: [
        IconButton(tooltip: 'Notifications', onPressed: () => context.push('/notifications'), icon: const Icon(Icons.notifications_none_rounded)),
      ]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: RefreshIndicator(
            onRefresh: () async { ref.invalidate(jsonProvider('/me')); ref.invalidate(jsonProvider('/me/wallet')); },
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
                  Text(wallet.when(data: (w) => formatXaf(asInt(w['availableXaf'])), loading: () => '…', error: (_, __) => '—'),
                      style: t.headlineMedium?.copyWith(color: Colors.white)),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: LumoColors.lime, foregroundColor: LumoColors.ink),
                    onPressed: available > 0 ? () => _payout(context, ref, available) : null,
                    child: const Text('Retirer vers Mobile Money'),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              entry(Icons.receipt_long_outlined, 'Mes commandes', '/orders'),
              entry(Icons.local_shipping_outlined, 'Mes retraits', '/payouts'),
              entry(Icons.drive_eta_outlined, 'Espace chauffeur', '/driver'),
              entry(Icons.storefront_outlined, 'Mes commerces (restaurant, boutique)', '/merchant'),
              if (isAdmin) entry(Icons.admin_panel_settings_outlined, 'Administration', '/admin'),
              const _ServerAddressTile(),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: () => ref.read(sessionProvider.notifier).logout(), child: const Text('Se déconnecter')),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _payout(BuildContext context, WidgetRef ref, int available) async {
    final amount = TextEditingController(text: '$available');
    final phone = TextEditingController(text: (ref.read(jsonProvider('/me')).valueOrNull?['phone'] as String?) ?? '+237');
    var channel = 'orange_money';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Retirer mon argent'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'orange_money', label: Text('Orange Money')), ButtonSegment(value: 'mtn_momo', label: Text('MTN MoMo'))],
              selected: {channel}, onSelectionChanged: (s) => set(() => channel = s.first),
            ),
            const SizedBox(height: 12),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Numéro (format +237…)')),
            const SizedBox(height: 8),
            TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Montant', suffixText: 'FCFA')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Fermer')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Demander le retrait')),
          ],
        ),
      ),
    );
    if (ok == true && context.mounted) {
      final done = await runAction(context, () => ref.read(apiClientProvider).post('/payouts', body: {
            'amountXaf': int.tryParse(amount.text.replaceAll(RegExp(r'\D'), '')) ?? 0,
            'msisdn': phone.text.replaceAll(' ', ''), 'channel': channel,
          }), success: 'Demande envoyée. Tu seras notifié dès le versement.');
      if (done) ref.invalidate(jsonProvider('/me/wallet'));
    }
    amount.dispose();
    phone.dispose();
  }
}

// Adresse du serveur, modifiable depuis le profil sans se déconnecter : le client
// relit AppConfig.apiUrl à chaque requête, donc la nouvelle adresse est prise en
// compte immédiatement. Utile en mode pilote, où l'adresse du tunnel change à
// chaque redémarrage du serveur.
class _ServerAddressTile extends ConsumerStatefulWidget {
  const _ServerAddressTile();
  @override
  ConsumerState<_ServerAddressTile> createState() => _ServerAddressTileState();
}

class _ServerAddressTileState extends ConsumerState<_ServerAddressTile> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
        leading: const Icon(Icons.dns_outlined),
        title: const Text('Adresse du serveur'),
        subtitle: Text(AppConfig.isConfigured ? AppConfig.apiUrl : 'à configurer',
            style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.edit_outlined, size: 18),
        onTap: _edit,
      ),
      if (_error != null)
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_error!, style: const TextStyle(color: LumoColors.danger, fontSize: 12))),
    ]);
  }

  Future<void> _edit() async {
    final c = TextEditingController(text: AppConfig.apiUrl.isEmpty ? 'https://' : AppConfig.apiUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Adresse du serveur'),
        content: TextField(controller: c, keyboardType: TextInputType.url,
            decoration: const InputDecoration(hintText: 'https://api.exemple.com')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Fermer')),
          TextButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Enregistrer')),
        ],
      ),
    );
    c.dispose();
    if (url == null) return;
    final err = await AppConfig.setServer(url);
    if (!mounted) return;
    setState(() => _error = err);
    if (err == null) {
      // Rafraîchit les écrans ouverts avec la nouvelle adresse, sans se déconnecter.
      ref.invalidate(jsonProvider('/me'));
      ref.invalidate(jsonProvider('/me/wallet'));
    }
  }
}

class PayoutsScreen extends ConsumerWidget {
  const PayoutsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(jsonProvider('/payouts'));
    const labels = {'requested': 'En cours', 'paid': 'Versé', 'rejected': 'Refusé'};
    return Scaffold(
      appBar: AppBar(title: Text('Mes retraits', style: Theme.of(context).textTheme.headlineSmall)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(child: Text('Impossible de charger tes retraits.')),
        data: (json) {
          final items = itemsOf(json);
          if (items.isEmpty) return const Center(child: Text('Aucun retrait pour l\'instant.'));
          return ListView(children: [
            for (final p in items)
              ListTile(
                title: Text(formatXaf(asInt(p['amountXaf']))),
                subtitle: Text('${p['channel'] == 'mtn_momo' ? 'MTN MoMo' : 'Orange Money'} · ${p['msisdn']}'),
                trailing: Text(labels[p['status']] ?? '${p['status']}'),
              ),
          ]);
        },
      ),
    );
  }
}

// --------------------------------------------------------- Notifications
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});
  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // Ouvrir l'écran marque tout comme lu (après affichage).
    Future<void>.delayed(const Duration(seconds: 1), () async {
      try { await ref.read(apiClientProvider).post('/notifications/read-all'); } on ApiException catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(jsonProvider('/notifications'));
    return Scaffold(
      appBar: AppBar(title: Text('Notifications', style: Theme.of(context).textTheme.headlineSmall)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(child: Text('Impossible de charger les notifications.')),
        data: (json) {
          final items = itemsOf(json);
          if (items.isEmpty) return const Center(child: Text('Rien de neuf pour l\'instant.'));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (_, i) {
              final n = items[i];
              final link = n['link'] as String?;
              return ListTile(
                leading: Icon(Icons.circle, size: 10, color: n['read'] == true ? Colors.transparent : LumoColors.action),
                title: Text(n['title'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(n['body'] as String),
                onTap: link == null ? null : () => context.push(link),
              );
            },
          );
        },
      ),
    );
  }
}

// -------------------------------------------------------- Administration
class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Administration', style: Theme.of(context).textTheme.headlineSmall),
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Tableau de bord'), Tab(text: 'Litiges'), Tab(text: 'Commerces'), Tab(text: 'Chauffeurs'), Tab(text: 'Retraits'), Tab(text: 'Codes SMS'),
          ]),
        ),
        body: TabBarView(children: [
          const _AdminDashboard(),
          _AdminList(path: '/admin/disputes', itemBuilder: (ctx, ref, x, reload) => ListTile(
            title: Text('${x['kind']} · ${formatXaf(asInt(x['totalXaf']))}'),
            subtitle: Text(x['reason'] as String? ?? ''),
            trailing: Wrap(spacing: 4, children: [
              TextButton(onPressed: () => _act(ctx, ref, '/admin/orders/${x['id']}/refund', null, reload), child: const Text('Rembourser')),
              TextButton(onPressed: () => _act(ctx, ref, '/admin/orders/${x['id']}/release', null, reload), child: const Text('Payer vendeur')),
            ]),
          )),
          _AdminList(path: '/admin/stores', itemBuilder: (ctx, ref, x, reload) => ListTile(
            title: Text(x['name'] as String),
            subtitle: Text('${x['kind'] == 'restaurant' ? 'Restaurant' : 'Boutique'} · ${x['city']}'),
            trailing: TextButton(onPressed: () => _act(ctx, ref, '/admin/stores/${x['id']}/approve', null, reload), child: const Text('Valider')),
          )),
          _AdminList(path: '/admin/drivers', itemBuilder: (ctx, ref, x, reload) => ListTile(
            title: Text('${x['displayName']} · ${x['phone']}'),
            subtitle: Text('${x['vehicle']} · ${x['plate']}'),
            trailing: TextButton(
              onPressed: () => _act(ctx, ref, '/admin/drivers/${x['userId']}/verify', {'verified': x['verified'] != true}, reload),
              child: Text(x['verified'] == true ? 'Suspendre' : 'Vérifier'),
            ),
          )),
          _AdminList(path: '/admin/payouts', itemBuilder: (ctx, ref, x, reload) => ListTile(
            title: Text('${x['userName']} · ${formatXaf(asInt(x['amountXaf']))}'),
            subtitle: Text('${x['channel']} · ${x['msisdn']}'),
            trailing: Wrap(spacing: 4, children: [
              TextButton(onPressed: () => _act(ctx, ref, '/admin/payouts/${x['id']}/decision', {'paid': false}, reload), child: const Text('Refuser')),
              TextButton(onPressed: () => _act(ctx, ref, '/admin/payouts/${x['id']}/decision', {'paid': true}, reload), child: const Text('Marquer versé')),
            ]),
          )),
          _AdminList(path: '/admin/pilot-sms', itemBuilder: (ctx, ref, x, reload) => ListTile(
            title: Text(x['code'] as String? ?? '—', style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 2)),
            subtitle: Text(x['phone'] as String? ?? ''),
          )),
        ]),
      ),
    );
  }

  static Future<void> _act(BuildContext context, WidgetRef ref, String path, Map<String, dynamic>? body, VoidCallback reload) async {
    if (await runAction(context, () => ref.read(apiClientProvider).post(path, body: body), success: 'Fait')) reload();
  }
}

// Tableau de bord : totaux + tendance sur 14 jours (inscriptions, annonces, commandes/CA).
class _AdminDashboard extends ConsumerWidget {
  const _AdminDashboard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(jsonProvider('/admin/metrics'));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Center(child: Text('Impossible de charger le tableau de bord.')),
      data: (json) {
        final totals = (json['totals'] as Map).cast<String, dynamic>();
        final days = (json['days'] as Map).cast<String, dynamic>();
        final usersSeries = (days['users'] as List).cast<Map<String, dynamic>>();
        final listingsSeries = (days['listings'] as List).cast<Map<String, dynamic>>();
        final ordersSeries = (days['orders'] as List).cast<Map<String, dynamic>>();

        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(jsonProvider('/admin/metrics')),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Wrap(spacing: 12, runSpacing: 12, children: [
              _StatTile('Utilisateurs', '${totals['usersTotal']}'),
              _StatTile('Annonces actives', '${totals['listingsActive']}'),
              _StatTile('Commandes', '${totals['ordersTotal']}'),
              _StatTile('Chiffre d\'affaires', formatXaf(asInt(totals['revenueTotalXaf']))),
              _StatTile('Retraits en attente', '${totals['payoutsPending']} (${formatXaf(asInt(totals['payoutsPendingXaf']))})'),
            ]),
            const SizedBox(height: 24),
            _TrendChart(title: 'Nouveaux utilisateurs (14 derniers jours)', series: usersSeries, valueKey: 'count'),
            const SizedBox(height: 24),
            _TrendChart(title: 'Nouvelles annonces (14 derniers jours)', series: listingsSeries, valueKey: 'count'),
            const SizedBox(height: 24),
            _TrendChart(title: 'Commandes (14 derniers jours)', series: ordersSeries, valueKey: 'count'),
          ]),
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      width: 160,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: LumoColors.mist, borderRadius: BorderRadius.circular(LumoRadius.card), border: Border.all(color: LumoColors.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.bodySmall),
        const SizedBox(height: 4),
        Text(value, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

// Courbe simple (fl_chart) + variation en % vs les 7 jours précédents.
class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.title, required this.series, required this.valueKey});
  final String title;
  final List<Map<String, dynamic>> series;
  final String valueKey;

  @override
  Widget build(BuildContext context) {
    final values = series.map((d) => asInt(d[valueKey]).toDouble()).toList();
    final half = values.length ~/ 2;
    final recent = values.sublist(half).fold(0.0, (a, b) => a + b);
    final previous = values.sublist(0, half).fold(0.0, (a, b) => a + b);
    final trendPct = previous > 0 ? ((recent - previous) / previous * 100).round() : (recent > 0 ? 100 : 0);
    final up = recent >= previous;
    final maxY = (values.isEmpty ? 1.0 : values.reduce((a, b) => a > b ? a : b)).clamp(1.0, double.infinity);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
        Icon(up ? Icons.trending_up : Icons.trending_down, size: 16, color: up ? LumoColors.success : LumoColors.danger),
        const SizedBox(width: 4),
        Text('${trendPct >= 0 ? '+' : ''}$trendPct %', style: TextStyle(color: up ? LumoColors.success : LumoColors.danger, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        height: 120,
        child: LineChart(LineChartData(
          minY: 0,
          maxY: maxY * 1.2,
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i])],
              isCurved: true,
              color: LumoColors.action,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: true, color: LumoColors.action.withValues(alpha: 0.12)),
            ),
          ],
        )),
      ),
    ]);
  }
}

class _AdminList extends ConsumerWidget {
  const _AdminList({required this.path, required this.itemBuilder});
  final String path;
  final Widget Function(BuildContext, WidgetRef, Map<String, dynamic>, VoidCallback) itemBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(jsonProvider(path));
    void reload() => ref.invalidate(jsonProvider(path));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Center(child: Text('Accès refusé ou erreur réseau.')),
      data: (json) {
        final items = itemsOf(json);
        if (items.isEmpty) return const Center(child: Text('Rien à traiter.'));
        return ListView(children: [for (final x in items) itemBuilder(context, ref, x, reload)]);
      },
    );
  }
}
