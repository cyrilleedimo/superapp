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
  bool _suggesting = false;
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

  // Suggestion de titre/description à partir des photos déjà envoyées. Le vendeur reste
  // libre de tout corriger : c'est une aide, jamais une donnée fiable à publier telle quelle.
  Future<void> _suggestDescription() async {
    if (_photos.isEmpty) return;
    setState(() => _suggesting = true);
    try {
      final photoIds = _photos.map((u) => u.split('/').last).toList();
      final r = await ref.read(apiClientProvider).post('/listings/suggest-description', body: {'photoIds': photoIds});
      if (!mounted) return;
      setState(() {
        _title.text = r['title'] as String? ?? _title.text;
        _desc.text = r['description'] as String? ?? _desc.text;
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Suggestion de l\'IA ajoutée — relis et corrige avant de publier.')));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _suggesting = false);
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
                            child: Image.network(AppConfig.resolveMediaUrl(url), width: 100, height: 110, fit: BoxFit.cover,
                                headers: AppConfig.mediaHeaders)),
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
              if (_photos.isNotEmpty) Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12),
                child: OutlinedButton.icon(
                  onPressed: _suggesting ? null : _suggestDescription,
                  icon: _suggesting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('Décrire avec l\'IA'),
                ),
              ),
              const SizedBox(height: 4),
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
              Text([me.valueOrNull?['email'], me.valueOrNull?['phone']].whereType<String>().join(' · '), style: t.bodySmall),
              if (me.valueOrNull?['needsEmail'] == true) ...[
                const SizedBox(height: 12),
                Material(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(14),
                  child: ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    leading: const Icon(Icons.mark_email_unread_outlined, color: LumoColors.warning),
                    title: const Text('Ajoute ton e-mail', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Indispensable pour récupérer ton compte si tu oublies ton mot de passe.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/add-email'),
                  ),
                ),
              ],
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
              entry(Icons.help_outline_rounded, 'Comment ça marche', '/help'),
              ListTile(
                leading: const Icon(Icons.lock_outline_rounded), title: const Text('Changer mon mot de passe'),
                trailing: const Icon(Icons.chevron_right), onTap: () => _changePassword(context, ref),
              ),
              if (isAdmin) entry(Icons.admin_panel_settings_outlined, 'Administration', '/admin'),
              // Réglage technique réservé à l'admin (le pilote tourne sur son PC) : les autres
              // utilisateurs n'ont ni besoin ni intérêt à voir/changer l'adresse du serveur.
              if (isAdmin) const _ServerAddressTile(),
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
    final password = TextEditingController();
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
            const SizedBox(height: 8),
            TextField(controller: password, obscureText: true,
                decoration: const InputDecoration(labelText: 'Ton mot de passe', helperText: 'Demandé pour protéger ton argent.')),
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
            'msisdn': phone.text.replaceAll(' ', ''), 'channel': channel, 'password': password.text,
          }), success: 'Demande envoyée. Tu seras notifié dès le versement.');
      if (done) ref.invalidate(jsonProvider('/me/wallet'));
    }
    amount.dispose();
    phone.dispose();
    password.dispose();
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Changer mon mot de passe'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: 'Mot de passe actuel')),
          const SizedBox(height: 8),
          TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'Nouveau mot de passe', helperText: '8 caractères minimum')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Fermer')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await runAction(context, () async {
        final tokens = await ref.read(apiClientProvider).post('/me/password', body: {'current': current.text, 'password': next.text});
        await ref.read(sessionProvider.notifier).adopt(tokens);
      }, success: 'Mot de passe changé. Les autres appareils ont été déconnectés.');
    }
    current.dispose();
    next.dispose();
  }
}

// Adresse du serveur : fixe en temps normal. Ce réglage de secours, réservé à l'admin,
// sert uniquement à tester un autre serveur sans réinstaller l'application.
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
        subtitle: Text('${AppConfig.apiUrl} · réglage technique, visible par l\'admin seulement',
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
            decoration: const InputDecoration(hintText: 'https://app.exemple.org/api', helperText: 'Laisse vide pour revenir à l\'adresse normale.')),
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
    const roles = {'user': 'Utilisateur', 'merchant': 'Commerçant', 'driver': 'Chauffeur', 'admin': 'Admin'};
    return DefaultTabController(
      length: 8,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Administration', style: Theme.of(context).textTheme.headlineSmall),
          bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(text: 'Tableau de bord'), Tab(text: 'Litiges'), Tab(text: 'Commerces'), Tab(text: 'Chauffeurs'),
            Tab(text: 'Retraits'), Tab(text: 'Utilisateurs'), Tab(text: 'E-mails'), Tab(text: 'Réglages'),
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
          _AdminList(path: '/admin/users', itemBuilder: (ctx, ref, x, reload) => ListTile(
            title: Text('${x['displayName']} · ${roles[x['role']] ?? x['role']}${x['status'] == 'suspended' ? ' · SUSPENDU' : x['status'] == 'pending' ? ' · e-mail non vérifié' : ''}'),
            subtitle: Text([x['email'], x['phone']].whereType<String>().join(' · ')),
            trailing: PopupMenuButton<String>(
              onSelected: (v) => _act(ctx, ref, '/admin/users/${x['id']}', v.startsWith('role:') ? {'role': v.substring(5)} : {'status': v}, reload),
              itemBuilder: (_) => [
                PopupMenuItem(value: x['status'] == 'suspended' ? 'active' : 'suspended', child: Text(x['status'] == 'suspended' ? 'Réactiver le compte' : 'Suspendre le compte')),
                const PopupMenuDivider(),
                for (final r in roles.entries)
                  if (r.key != x['role']) PopupMenuItem(value: 'role:${r.key}', child: Text('Rôle : ${r.value}')),
              ],
            ),
          )),
          _AdminList(path: '/admin/mail-log', itemBuilder: (ctx, ref, x, reload) => ListTile(
            leading: Icon(x['status'] == 'sent' ? Icons.mark_email_read_outlined : Icons.error_outline,
                color: x['status'] == 'sent' ? LumoColors.success : LumoColors.danger),
            title: Text(x['code'] != null ? 'Code ${x['code']}' : (x['subject'] as String? ?? ''), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${x['email']}${x['error'] != null ? '\nNon parti : ${x['error']}' : ''}'),
          )),
          const _AdminSettings(),
        ]),
      ),
    );
  }

  static Future<void> _act(BuildContext context, WidgetRef ref, String path, Map<String, dynamic>? body, VoidCallback reload) async {
    if (await runAction(context, () => ref.read(apiClientProvider).post(path, body: body), success: 'Fait')) reload();
  }
}

// Réglages : tout ce qui se décide sans toucher à un fichier du serveur.
class _Setting {
  const _Setting(this.key, this.label, {this.help, this.choices});
  final String key, label;
  final String? help;
  final Map<String, String>? choices;
}

const _settingGroups = <String, List<_Setting>>{
  'Paiement': [
    _Setting('payments.provider', 'Paiement en ligne', choices: {'none': 'Désactivé', 'notchpay': 'Notch Pay (Orange Money, MTN MoMo)'}),
    _Setting('notchpay.public_key', 'Notch Pay — clé publique', help: 'Commence par pk_test. (essais) ou pk. (réel). Jamais la clé secrète.'),
    _Setting('notchpay.webhook_hash', 'Notch Pay — clé de signature des webhooks', help: 'Commence par hsk_. Sert à vérifier que les confirmations viennent bien de Notch Pay.'),
    _Setting('payments.cash_enabled', 'Autoriser « Payer à la remise »'),
    _Setting('fees.buyer_bps', 'Frais de protection acheteur', help: 'En centièmes de % : 500 = 5 %.'),
    _Setting('fees.buyer_fixed_xaf', 'Frais fixe par commande (FCFA)'),
    _Setting('payout.min_xaf', 'Retrait minimum (FCFA)'),
    _Setting('orders.auto_release_days', 'Libération automatique du paiement', help: 'Nombre de jours après paiement sans litige. 0 = jamais automatique.'),
    _Setting('orders.pending_ttl_min', 'Annulation des commandes impayées (minutes)'),
  ],
  'E-mails': [
    _Setting('smtp.host', 'Serveur SMTP', help: 'Ex. mail.itsscm.org. Vide = fonction mail() de l\'hébergeur.'),
    _Setting('smtp.port', 'Port SMTP', help: '465 (SSL) ou 587 (TLS).'),
    _Setting('smtp.secure', 'Sécurité SMTP', choices: {'ssl': 'SSL (port 465)', 'tls': 'STARTTLS (port 587)', 'none': 'Aucune'}),
    _Setting('smtp.user', 'Compte e-mail', help: 'Ex. no-reply@itsscm.org'),
    _Setting('smtp.pass', 'Mot de passe du compte e-mail'),
    _Setting('mail.from', 'Adresse d\'expédition', help: 'Vide = le compte e-mail ci-dessus.'),
    _Setting('mail.from_name', 'Nom d\'expéditeur'),
    _Setting('pilot.show_codes', 'Montrer les codes dans l\'onglet E-mails', help: 'Pratique pendant les essais. À désactiver ensuite.'),
  ],
  'Courses en ville': [
    _Setting('rides.base_xaf', 'Prise en charge (FCFA)'),
    _Setting('rides.per_km_xaf', 'Prix par km (FCFA)', help: '0 = service de courses fermé.'),
    _Setting('rides.radius_km', 'Rayon de recherche des chauffeurs (km)'),
  ],
  'Assistant IA': [
    _Setting('gemini.api_key', 'Clé Google AI Studio (Gemini)', help: 'Sert à « Décrire avec l\'IA ». Vide = assistant désactivé.'),
    _Setting('gemini.model', 'Modèle Gemini'),
  ],
  'Général': [
    _Setting('app.name', 'Nom affiché dans les e-mails'),
    _Setting('app.public_url', 'Adresse publique du site', help: 'Vide = détectée automatiquement. Ex. https://app.itsscm.org'),
  ],
};

class _AdminSettings extends ConsumerWidget {
  const _AdminSettings();
  static const _path = '/admin/settings';
  static const _sysPath = '/admin/system';

  Future<void> _save(BuildContext context, WidgetRef ref, String key, Object value) async {
    if (await runAction(context, () => ref.read(apiClientProvider).patch(_path, body: {key: value}), success: 'Enregistré')) {
      ref.invalidate(jsonProvider(_path));
      ref.invalidate(jsonProvider(_sysPath));
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, _Setting def, Map<String, dynamic> cur) async {
    final type = cur['type'] as String;
    final secret = cur['secret'] == true;
    if (def.choices != null) {
      final v = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(title: Text(def.label), children: [
          for (final e in def.choices!.entries)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, e.key), child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(e.value))),
        ]),
      );
      if (v != null && context.mounted) await _save(context, ref, def.key, v);
      return;
    }
    final c = TextEditingController(text: secret ? '' : '${cur['value'] ?? ''}');
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(def.label),
        content: TextField(
          controller: c, autofocus: true, autocorrect: false,
          keyboardType: type == 'int' ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(helperText: def.help, helperMaxLines: 3, hintText: secret ? 'Colle la nouvelle valeur' : null),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Fermer')),
          TextButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Enregistrer')),
        ],
      ),
    );
    c.dispose();
    if (v == null || !context.mounted) return;
    if (type == 'int') {
      final n = int.tryParse(v.replaceAll(RegExp(r'\D'), ''));
      if (n == null) return;
      await _save(context, ref, def.key, n);
    } else {
      await _save(context, ref, def.key, v);
    }
  }

  Future<void> _testMail(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController(text: (ref.read(jsonProvider('/me')).valueOrNull?['email'] as String?) ?? '');
    final to = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Envoyer un e-mail de test'),
        content: TextField(controller: c, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Envoyer à')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Fermer')),
          TextButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Envoyer')),
        ],
      ),
    );
    c.dispose();
    if (to == null || to.isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ref.read(apiClientProvider).post('/admin/mail-test', body: {'to': to});
      messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(r['sent'] == true
              ? 'Parti depuis ${r['from']}. Regarde ta boîte (et les indésirables).'
              : 'Échec : ${r['error']}')));
      ref.invalidate(jsonProvider('/admin/mail-log'));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  Future<void> _mysql(BuildContext context, WidgetRef ref) async {
    final host = TextEditingController(text: 'localhost');
    final name = TextEditingController();
    final user = TextEditingController();
    final pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Brancher une base MySQL'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Crée d\'abord la base et son utilisateur chez l\'hébergeur (DirectAdmin → Gestion MySQL). '
                'Les données actuelles y seront recopiées automatiquement, puis le fichier provisoire sera supprimé.'),
            const SizedBox(height: 12),
            TextField(controller: host, decoration: const InputDecoration(labelText: 'Serveur')),
            const SizedBox(height: 8),
            TextField(controller: name, autocorrect: false, decoration: const InputDecoration(labelText: 'Nom de la base')),
            const SizedBox(height: 8),
            TextField(controller: user, autocorrect: false, decoration: const InputDecoration(labelText: 'Utilisateur')),
            const SizedBox(height: 8),
            TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Mot de passe')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Fermer')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Tester et basculer')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      final done = await runAction(context, () => ref.read(apiClientProvider).post('/admin/database',
          body: {'host': host.text.trim(), 'name': name.text.trim(), 'user': user.text.trim(), 'pass': pass.text}),
          success: 'Base branchée. Les données ont été basculées.');
      if (done) ref.invalidate(jsonProvider(_sysPath));
    }
    for (final c in [host, name, user, pass]) { c.dispose(); }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(jsonProvider(_path));
    final sys = ref.watch(jsonProvider(_sysPath)).valueOrNull;
    final t = Theme.of(context).textTheme;
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Center(child: Text('Impossible de charger les réglages.')),
      data: (json) {
        final all = (json['settings'] as Map).cast<String, dynamic>();
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (sys != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: LumoColors.mist, borderRadius: BorderRadius.circular(LumoRadius.panel)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('État du serveur', style: t.titleMedium),
                    const SizedBox(height: 8),
                    Text('Données : ${sys['storageLabel']}'),
                    Text('Paiement en ligne : ${sys['paymentsReady'] == true ? 'prêt' : 'non configuré'}'),
                    Text('E-mails : ${sys['mailMode']} · expéditeur ${sys['mailFrom']}'),
                    const SizedBox(height: 4),
                    SelectableText('Adresse à donner à Notch Pay (webhook) :\n${sys['webhookUrl']}', style: t.bodySmall),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                        onPressed: () => _testMail(context, ref), child: const Text('Tester l\'envoi d\'e-mail')),
                      if (sys['storage'] == 'file')
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                          onPressed: () => _mysql(context, ref), child: const Text('Brancher MySQL')),
                    ]),
                  ]),
                ),
              for (final group in _settingGroups.entries) ...[
                Padding(padding: const EdgeInsets.fromLTRB(4, 20, 4, 4), child: Text(group.key, style: t.titleMedium)),
                for (final def in group.value)
                  if (all[def.key] is Map)
                    _row(context, ref, def, (all[def.key] as Map).cast<String, dynamic>()),
              ],
            ]),
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, WidgetRef ref, _Setting def, Map<String, dynamic> cur) {
    if (cur['type'] == 'bool') {
      return SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(def.label), subtitle: def.help == null ? null : Text(def.help!),
        value: cur['value'] == true, onChanged: (v) => _save(context, ref, def.key, v),
      );
    }
    final String shown;
    if (cur['secret'] == true) {
      shown = cur['isSet'] == true ? 'Enregistrée (${cur['hint']})' : 'Non renseignée';
    } else if (def.choices != null) {
      shown = def.choices!['${cur['value']}'] ?? '${cur['value']}';
    } else {
      shown = '${cur['value']}'.isEmpty ? '—' : '${cur['value']}';
    }
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(def.label),
      subtitle: Text(def.help == null ? shown : '$shown\n${def.help}'),
      trailing: const Icon(Icons.edit_outlined, size: 18),
      onTap: () => _edit(context, ref, def, cur),
    );
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
