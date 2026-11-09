// Trajets et Voyages : interfaces livrées en Phase 1, branchement backend en Phase 2/3.
// Un bandeau l'indique clairement à l'utilisateur ; aucune donnée fictive n'est affichée.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/tokens.dart';

class _SoonBanner extends StatelessWidget {
  const _SoonBanner(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: LumoColors.actionSoft, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          const Icon(Icons.schedule_rounded, color: LumoColors.action),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4))),
        ]),
      );
}

class RidesScreen extends StatefulWidget {
  const RidesScreen({super.key});
  @override
  State<RidesScreen> createState() => _RidesScreenState();
}

class _RidesScreenState extends State<RidesScreen> {
  bool _carpool = true;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Trajets', style: t.headlineSmall)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(padding: const EdgeInsets.all(20), children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Course en ville')),
                ButtonSegment(value: true, label: Text('Covoiturage')),
              ],
              selected: {_carpool},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _carpool = s.first),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(border: Border.all(color: LumoColors.line), borderRadius: BorderRadius.circular(18)),
              child: const Column(children: [
                _Field(icon: Icons.radio_button_unchecked, label: 'Départ'),
                Divider(),
                _Field(icon: Icons.circle, label: 'Arrivée', color: LumoColors.action),
                Divider(),
                _Field(icon: Icons.calendar_today_outlined, label: 'Date et passagers'),
              ]),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: null, child: Text(_carpool ? 'Rechercher un covoiturage' : 'Commander une course')),
            const SizedBox(height: 16),
            const _SoonBanner('Aperçu. Les trajets (géolocalisation, chauffeurs vérifiés, paiement) ouvrent en Phase 2.'),
          ]),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.icon, required this.label, this.color = LumoColors.ink});
  final IconData icon;
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, size: 16, color: color),
        title: TextField(enabled: false, decoration: InputDecoration(hintText: label, filled: false, border: InputBorder.none)),
      );
}

class TravelScreen extends StatelessWidget {
  const TravelScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Voyages', style: t.headlineSmall)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const TextField(enabled: false, decoration: InputDecoration(hintText: 'De (ex. DLA)', prefixIcon: Icon(Icons.flight_takeoff_rounded))),
            const SizedBox(height: 10),
            const TextField(enabled: false, decoration: InputDecoration(hintText: 'Vers', prefixIcon: Icon(Icons.flight_land_rounded))),
            const SizedBox(height: 16),
            const FilledButton(onPressed: null, child: Text('Comparer les prix')),
            const SizedBox(height: 16),
            const _SoonBanner('Aperçu. La comparaison de vols et d\'hôtels dépend d\'un partenaire de données [TRAVEL API PARTNER], prévu en Phase 3.'),
          ]),
        ),
      ),
    );
  }
}

class SoonScreen extends StatelessWidget {
  const SoonScreen({super.key, required this.name});
  final String name;
  @override
  Widget build(BuildContext context) {
    final label = {'repas': 'Repas', 'boutiques': 'Boutiques', 'colis': 'Colis'}[name] ?? 'Ce service';
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$label arrive bientôt', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            const Text('On prépare ce service avec des partenaires locaux.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            SizedBox(width: 240, child: OutlinedButton(onPressed: () => context.go('/'), child: const Text('Retour à l\'accueil'))),
          ]),
        ),
      ),
    );
  }
}
