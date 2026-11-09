// Covoiturage façon BlaBlaCar : recherche ville → ville, cartes avec frise
// horaire, réservation de places (paiement séquestre), publication de trajets.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/data.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../marketplace/marketplace_repository.dart';
import '../orders/orders_screens.dart' show runAction;

String _hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String _ddmm(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

class CarpoolTab extends ConsumerStatefulWidget {
  const CarpoolTab({super.key});
  @override
  ConsumerState<CarpoolTab> createState() => _CarpoolTabState();
}

class _CarpoolTabState extends ConsumerState<CarpoolTab> {
  final _from = TextEditingController();
  final _to = TextEditingController();
  String? _query;

  @override
  void dispose() { _from.dispose(); _to.dispose(); super.dispose(); }

  void _search() {
    if (_from.text.trim().length < 2 || _to.text.trim().length < 2) return;
    setState(() => _query = '/trips?from=${Uri.encodeQueryComponent(_from.text.trim())}&to=${Uri.encodeQueryComponent(_to.text.trim())}');
  }

  @override
  Widget build(BuildContext context) {
    final results = _query == null ? null : ref.watch(jsonProvider(_query!));
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Container(
            decoration: BoxDecoration(border: Border.all(color: LumoColors.line), borderRadius: BorderRadius.circular(18)),
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              TextField(controller: _from, decoration: const InputDecoration(labelText: 'Départ (ville)', prefixIcon: Icon(Icons.radio_button_unchecked, size: 18))),
              const SizedBox(height: 8),
              TextField(controller: _to, decoration: const InputDecoration(labelText: 'Arrivée (ville)', prefixIcon: Icon(Icons.circle, size: 14, color: LumoColors.action)),
                  onSubmitted: (_) => _search()),
            ]),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _search, child: const Text('Rechercher')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextButton.icon(onPressed: () => context.push('/trips/new'), icon: const Icon(Icons.add_rounded), label: const Text('Publier un trajet'))),
            Expanded(child: TextButton.icon(onPressed: () => context.push('/trips/mine'), icon: const Icon(Icons.route_outlined), label: const Text('Mes trajets'))),
          ]),
          const SizedBox(height: 12),
          if (results != null)
            results.when(
              loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => Text(e is ApiException ? e.userMessage : 'Recherche impossible.'),
              data: (json) {
                final items = itemsOf(json);
                if (items.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('Aucun trajet trouvé pour l\'instant.'));
                return Column(children: [for (final t in items) _TripCard(trip: t)]);
              },
            ),
        ]),
      ),
    );
  }
}

class _TripCard extends ConsumerWidget {
  const _TripCard({required this.trip});
  final Map<String, dynamic> trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final depart = DateTime.parse(trip['departAt'] as String).toLocal();
    final driver = trip['driver'] as Map<String, dynamic>;
    final seatsLeft = asInt(trip['seatsLeft']);
    final price = asInt(trip['pricePerSeatXaf']);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(border: Border.all(color: LumoColors.line), borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_hhmm(depart), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 22),
            Text(_ddmm(depart), style: const TextStyle(color: LumoColors.slate, fontSize: 12)),
          ]),
          const SizedBox(width: 10),
          Column(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(width: 2))),
            Container(width: 2, height: 26, color: LumoColors.ink),
            Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: LumoColors.ink)),
          ]),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(trip['fromCity'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 18),
              Text(trip['toCity'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ]),
          ),
          Text(formatXaf(price), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 18)),
        ]),
        const Divider(height: 24),
        Row(children: [
          CircleAvatar(radius: 16, backgroundColor: LumoColors.actionSoft,
              child: Text((driver['displayName'] as String).characters.first, style: const TextStyle(color: LumoColors.action))),
          const SizedBox(width: 8),
          Expanded(child: Text(driver['displayName'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: LumoColors.lime, borderRadius: BorderRadius.circular(LumoRadius.pill)),
            child: Text('$seatsLeft place${seatsLeft > 1 ? 's' : ''}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ]),
        if ((trip['notes'] as String? ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(trip['notes'] as String, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 12),
        FilledButton(onPressed: () => _book(context, ref, seatsLeft, price), child: const Text('Réserver')),
      ]),
    );
  }

  Future<void> _book(BuildContext context, WidgetRef ref, int max, int price) async {
    var seats = 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Nombre de places'),
          content: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: seats > 1 ? () => set(() => seats--) : null, icon: const Icon(Icons.remove_circle_outline)),
            Text('$seats', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            IconButton(onPressed: seats < max ? () => set(() => seats++) : null, icon: const Icon(Icons.add_circle_outline)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Fermer')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: Text('Continuer · ${formatXaf(seats * price)}')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final key = MarketplaceRepository.newIdempotencyKey();
    await runAction(context, () async {
      final o = await ref.read(apiClientProvider).post('/trips/${trip['id']}/book',
          body: {'seats': seats}, headers: {'Idempotency-Key': key});
      if (context.mounted) context.push('/pay/${o['id']}');
    });
  }
}

class NewTripScreen extends ConsumerStatefulWidget {
  const NewTripScreen({super.key});
  @override
  ConsumerState<NewTripScreen> createState() => _NewTripScreenState();
}

class _NewTripScreenState extends ConsumerState<NewTripScreen> {
  final _from = TextEditingController();
  final _to = TextEditingController();
  final _price = TextEditingController();
  final _notes = TextEditingController();
  DateTime? _depart;
  int _seats = 3;

  @override
  void dispose() { for (final c in [_from, _to, _price, _notes]) { c.dispose(); } super.dispose(); }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 90)), initialDate: now);
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 7, minute: 0));
    if (t == null) return;
    setState(() => _depart = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Publier un trajet', style: Theme.of(context).textTheme.headlineSmall)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(padding: const EdgeInsets.all(20), children: [
            TextField(controller: _from, decoration: const InputDecoration(labelText: 'Ville de départ')),
            const SizedBox(height: 12),
            TextField(controller: _to, decoration: const InputDecoration(labelText: 'Ville d\'arrivée')),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickDate, icon: const Icon(Icons.event_outlined),
              label: Text(_depart == null ? 'Date et heure de départ' : '${_ddmm(_depart!)} à ${_hhmm(_depart!)}'),
            ),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Places proposées'),
              const Spacer(),
              IconButton(onPressed: _seats > 1 ? () => setState(() => _seats--) : null, icon: const Icon(Icons.remove_circle_outline)),
              Text('$_seats', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              IconButton(onPressed: _seats < 8 ? () => setState(() => _seats++) : null, icon: const Icon(Icons.add_circle_outline)),
            ]),
            TextField(controller: _price, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Prix par place', suffixText: 'FCFA')),
            const SizedBox(height: 12),
            TextField(controller: _notes, maxLines: 3, maxLength: 500,
                decoration: const InputDecoration(labelText: 'Infos utiles (bagages, point de rendez-vous…)')),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                final price = int.tryParse(_price.text.replaceAll(RegExp(r'\D'), '')) ?? 0;
                if (_depart == null || price <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Indique la date de départ et le prix.')));
                  return;
                }
                if (await runAction(context, () => ref.read(apiClientProvider).post('/trips', body: {
                      'fromCity': _from.text.trim(), 'toCity': _to.text.trim(),
                      'departAt': _depart!.toUtc().toIso8601String(), 'seats': _seats,
                      'pricePerSeatXaf': price, 'notes': _notes.text.trim(),
                    }), success: 'Trajet publié')) {
                  if (context.mounted) context.pop();
                }
              },
              child: const Text('Publier'),
            ),
          ]),
        ),
      ),
    );
  }
}

class MyTripsScreen extends ConsumerWidget {
  const MyTripsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = '/trips/mine';
    final async = ref.watch(jsonProvider(path));
    return Scaffold(
      appBar: AppBar(title: Text('Mes trajets', style: Theme.of(context).textTheme.headlineSmall)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(child: Text('Impossible de charger tes trajets.')),
        data: (json) {
          final items = itemsOf(json);
          if (items.isEmpty) return const Center(child: Text('Tu n\'as encore publié aucun trajet.'));
          return ListView(padding: const EdgeInsets.all(16), children: [
            for (final t in items)
              ListTile(
                title: Text('${t['fromCity']} → ${t['toCity']}'),
                subtitle: Text('${_ddmm(DateTime.parse(t['departAt'] as String).toLocal())} · '
                    '${t['seatsLeft']}/${t['seatsTotal']} places libres · ${t['status'] == 'open' ? 'Ouvert' : t['status']}'),
                trailing: t['status'] == 'open'
                    ? TextButton(
                        onPressed: () async {
                          if (await runAction(context, () => ref.read(apiClientProvider).post('/trips/${t['id']}/cancel'), success: 'Trajet annulé')) {
                            ref.invalidate(jsonProvider(path));
                          }
                        },
                        child: const Text('Annuler'),
                      )
                    : null,
              ),
          ]);
        },
      ),
    );
  }
}
