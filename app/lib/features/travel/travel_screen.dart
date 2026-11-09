// Comparateur de vols façon Kayak. Les prix viennent UNIQUEMENT d'un partenaire de
// données sous contrat ([TRAVEL API PARTNER]) : tant qu'il n'est pas branché, l'écran le dit.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api/api_client.dart';
import '../../core/data.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';

class TravelScreen extends ConsumerStatefulWidget {
  const TravelScreen({super.key});
  @override
  ConsumerState<TravelScreen> createState() => _TravelScreenState();
}

class _TravelScreenState extends ConsumerState<TravelScreen> {
  final _from = TextEditingController(text: 'DLA');
  final _to = TextEditingController();
  DateTime? _date;
  bool _busy = false;
  String? _message;
  List<Map<String, dynamic>> _offers = [];

  @override
  void dispose() { _from.dispose(); _to.dispose(); super.dispose(); }

  Future<void> _search() async {
    if (_date == null || _to.text.trim().length != 3) {
      setState(() => _message = 'Indique un code aéroport à 3 lettres (ex. CDG) et une date.');
      return;
    }
    setState(() { _busy = true; _message = null; _offers = []; });
    final d = _date!;
    final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    try {
      final r = await ref.read(apiClientProvider).get('/travel/flights',
          query: {'from': _from.text.trim().toUpperCase(), 'to': _to.text.trim().toUpperCase(), 'departDate': date});
      setState(() { _offers = itemsOf(r); if (_offers.isEmpty) _message = 'Aucun vol trouvé pour cette date.'; });
    } on ApiException catch (e) {
      setState(() => _message = e.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Voyages', style: t.headlineSmall)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Row(children: [
              Expanded(child: TextField(controller: _from, textCapitalization: TextCapitalization.characters, maxLength: 3,
                  decoration: const InputDecoration(labelText: 'De', counterText: '', prefixIcon: Icon(Icons.flight_takeoff_rounded)))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _to, textCapitalization: TextCapitalization.characters, maxLength: 3,
                  decoration: const InputDecoration(labelText: 'Vers', counterText: '', prefixIcon: Icon(Icons.flight_land_rounded)))),
            ]),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_outlined),
              label: Text(_date == null ? 'Date de départ' : '${_date!.day}/${_date!.month}/${_date!.year}'),
              onPressed: () async {
                final now = DateTime.now();
                final d = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 330)), initialDate: now);
                if (d != null) setState(() => _date = d);
              },
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy ? null : _search, child: const Text('Comparer les prix')),
            if (_busy) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
            if (_message != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_message!, textAlign: TextAlign.center)),
            for (final o in _offers)
              Card(
                elevation: 0,
                margin: const EdgeInsets.only(top: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: LumoColors.line)),
                child: ListTile(
                  title: Text('${o['carrier']} · ${o['stops'] == 0 ? 'Direct' : '${o['stops']} escale(s)'}'),
                  subtitle: Text('${(asInt(o['durationMin']) / 60).toStringAsFixed(1)} h · via ${o['source']}'),
                  trailing: Text(formatXaf(asInt(o['priceXaf'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                  onTap: () => launchUrl(Uri.parse(o['bookingUrl'] as String), mode: LaunchMode.externalApplication),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
