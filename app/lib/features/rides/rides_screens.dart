// VTC : le passager choisit départ/arrivée sur la carte, voit le prix estimé et
// commande ; le chauffeur vérifié passe en ligne, accepte et fait avancer la course.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../../core/api/api_client.dart';
import '../../core/config.dart';
import '../../core/data.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../carpool/carpool_screens.dart';
import '../orders/orders_screens.dart' show runAction;

const _defaultCenter = LatLng(4.0511, 9.7679); // Douala — centre initial de la carte

/// Position GPS actuelle, ou null si refusée / indisponible.
Future<LatLng?> currentPosition() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
    return LatLng(p.latitude, p.longitude);
  } catch (_) {
    return null;
  }
}

const _rideStatus = {
  'requested': 'Recherche d\'un chauffeur…',
  'accepted': 'Chauffeur en route',
  'arrived': 'Ton chauffeur est arrivé',
  'in_progress': 'Course en cours',
};

/// Onglets Course en ville / Covoiturage.
class TransportScreen extends StatelessWidget {
  const TransportScreen({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        initialIndex: initialTab,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Trajets', style: Theme.of(context).textTheme.headlineSmall),
            bottom: const TabBar(tabs: [Tab(text: 'Course en ville'), Tab(text: 'Covoiturage')]),
          ),
          body: const TabBarView(physics: NeverScrollableScrollPhysics(), children: [RideTab(), CarpoolTab()]),
        ),
      );
}

class RideTab extends ConsumerStatefulWidget {
  const RideTab({super.key});
  @override
  ConsumerState<RideTab> createState() => _RideTabState();
}

class _RideTabState extends ConsumerState<RideTab> {
  final _map = MapController();
  LatLng? _pickup, _dropoff;
  bool _choosingPickup = true;
  Map<String, dynamic>? _estimate;
  Map<String, dynamic>? _ride;
  Timer? _timer;
  bool _busy = false;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  void initState() {
    super.initState();
    _refreshRide();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshRide());
    _locate();
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  Future<void> _locate() async {
    final p = await currentPosition();
    if (p == null || !mounted) return;
    setState(() { _pickup = p; _choosingPickup = false; });
    _map.move(p, 15);
  }

  Future<void> _refreshRide() async {
    try {
      final r = (await _api.get('/rides/current'))['ride'] as Map<String, dynamic>?;
      if (mounted) setState(() => _ride = r);
    } on ApiException catch (_) {}
  }

  Map<String, dynamic> _point(String text, LatLng p) => {'text': text, 'lat': p.latitude, 'lng': p.longitude};

  Future<void> _estimateFare() async {
    if (_pickup == null || _dropoff == null) return;
    setState(() => _busy = true);
    await runAction(context, () async {
      final e = await _api.post('/rides/estimate', body: {'pickup': _point('Départ', _pickup!), 'dropoff': _point('Arrivée', _dropoff!)});
      if (mounted) setState(() => _estimate = e);
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _order() async {
    setState(() => _busy = true);
    await runAction(context, () async {
      final r = await _api.post('/rides', body: {
        'pickup': _point('Point de départ choisi sur la carte', _pickup!),
        'dropoff': _point('Destination choisie sur la carte', _dropoff!),
      });
      if (mounted) setState(() { _ride = r; _estimate = null; });
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final ride = _ride;
    if (ride != null) return _activeRide(ride);
    final markers = <Marker>[
      if (_pickup != null) Marker(point: _pickup!, width: 40, height: 40, child: const Icon(Icons.radio_button_checked, color: LumoColors.ink, size: 28)),
      if (_dropoff != null) Marker(point: _dropoff!, width: 40, height: 40, child: const Icon(Icons.location_on, color: LumoColors.action, size: 36)),
    ];
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: _defaultCenter,
          initialZoom: 13,
          onTap: (_, point) => setState(() {
            if (_choosingPickup) { _pickup = point; _choosingPickup = false; } else { _dropoff = point; }
            _estimate = null;
          }),
        ),
        children: [
          TileLayer(urlTemplate: AppConfig.tileUrl, userAgentPackageName: 'app.superapp.client'),
          MarkerLayer(markers: markers),
          RichAttributionWidget(attributions: [TextSourceAttribution('© contributeurs OpenStreetMap')]),
        ],
      ),
      Positioned(
        left: 12, right: 12, bottom: 12,
        child: Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(LumoRadius.panel),
          color: LumoColors.surface,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Départ'), icon: Icon(Icons.radio_button_checked, size: 16)),
                  ButtonSegment(value: false, label: Text('Arrivée'), icon: Icon(Icons.location_on_outlined, size: 16)),
                ],
                selected: {_choosingPickup},
                onSelectionChanged: (s) => setState(() => _choosingPickup = s.first),
              ),
              const SizedBox(height: 8),
              Text(
                _choosingPickup ? 'Touche la carte pour placer le départ.' : 'Touche la carte pour placer la destination.',
                style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center,
              ),
              TextButton.icon(onPressed: _locate, icon: const Icon(Icons.my_location_rounded), label: const Text('Utiliser ma position comme départ')),
              if (_estimate != null) ...[
                Text('${(_estimate!['distanceKm'] as num).toStringAsFixed(1)} km · prix estimé',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                Text(formatXaf(asInt(_estimate!['fareXaf'])), textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                const Text('Paiement en espèces au chauffeur', textAlign: TextAlign.center, style: TextStyle(color: LumoColors.slate, fontSize: 12)),
                const SizedBox(height: 10),
                FilledButton(onPressed: _busy ? null : _order, child: const Text('Commander la course')),
              ] else
                FilledButton(
                  onPressed: _busy || _pickup == null || _dropoff == null ? null : _estimateFare,
                  child: const Text('Voir le prix'),
                ),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _activeRide(Map<String, dynamic> r) {
    final t = Theme.of(context).textTheme;
    final driver = r['driver'] as Map<String, dynamic>?;
    final status = r['status'] as String;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text(_rideStatus[status] ?? status, style: t.headlineSmall),
          const SizedBox(height: 8),
          if (status == 'requested') const LinearProgressIndicator(),
          const SizedBox(height: 16),
          Text('${(r['distanceKm'] as num).toStringAsFixed(1)} km · ${formatXaf(asInt(r['fareXaf']))} en espèces', style: t.bodyLarge),
          if (driver != null) ...[
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(backgroundColor: LumoColors.actionSoft, child: Icon(Icons.person_outline, color: LumoColors.action)),
              title: Text(driver['displayName'] as String? ?? 'Chauffeur'),
              subtitle: Text('${driver['vehicle']} · ${driver['plate']}'),
              trailing: Text(driver['phone'] as String? ?? '', style: t.bodySmall),
            ),
          ],
          const SizedBox(height: 20),
          if (['requested', 'accepted', 'arrived'].contains(status))
            OutlinedButton(
              onPressed: () async {
                if (await runAction(context, () => _api.post('/rides/${r['id']}/cancel'), success: 'Course annulée')) _refreshRide();
              },
              child: const Text('Annuler la course'),
            ),
        ]),
      ),
    );
  }
}

// ----------------------------------------------------------------- Chauffeur
class DriverScreen extends ConsumerStatefulWidget {
  const DriverScreen({super.key});
  @override
  ConsumerState<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends ConsumerState<DriverScreen> {
  final _vehicle = TextEditingController();
  final _plate = TextEditingController();
  Timer? _timer;
  List<Map<String, dynamic>> _nearby = [];
  Map<String, dynamic>? _ride;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  void dispose() {
    _timer?.cancel();
    _vehicle.dispose();
    _plate.dispose();
    super.dispose();
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
    _poll();
  }

  Future<void> _poll() async {
    try {
      final current = (await _api.get('/rides/current'))['ride'] as Map<String, dynamic>?;
      List<Map<String, dynamic>> nearby = [];
      if (current == null) nearby = itemsOf(await _api.get('/rides/nearby'));
      if (mounted) setState(() { _ride = current; _nearby = nearby; });
    } on ApiException catch (_) {}
  }

  Future<void> _setOnline(bool online) async {
    LatLng? p;
    if (online) {
      p = await currentPosition();
      if (p == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Active la localisation pour passer en ligne.')));
        return;
      }
    }
    if (!mounted) return;
    final ok = await runAction(context, () => _api.post('/drivers/me/status',
        body: {'online': online, if (p != null) 'lat': p.latitude, if (p != null) 'lng': p.longitude}));
    if (!ok) return;
    ref.invalidate(jsonProvider('/drivers/me'));
    if (online) { _startPolling(); } else { _timer?.cancel(); setState(() => _nearby = []); }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final me = ref.watch(jsonProvider('/drivers/me'));
    return Scaffold(
      appBar: AppBar(title: Text('Espace chauffeur', style: t.headlineSmall)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: me.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => const Center(child: Text('Impossible de charger ton profil chauffeur.')),
            data: (d) {
              if (d['applied'] == false) return _applyForm(t);
              if (d['verified'] != true) {
                return const Padding(padding: EdgeInsets.all(24),
                    child: Text('Ta demande est en cours de vérification par notre équipe. Tu recevras une notification.', textAlign: TextAlign.center));
              }
              final online = d['online'] == true;
              if (online && _timer == null) WidgetsBinding.instance.addPostFrameCallback((_) => _startPolling());
              return ListView(padding: const EdgeInsets.all(20), children: [
                SwitchListTile(
                  value: online, onChanged: _setOnline,
                  title: Text(online ? 'En ligne' : 'Hors ligne', style: t.titleMedium),
                  subtitle: Text('${d['vehicle']} · ${d['plate']}'),
                ),
                const Divider(),
                if (_ride != null) _currentRide(_ride!, t)
                else if (online && _nearby.isEmpty)
                  const Padding(padding: EdgeInsets.all(24), child: Text('Aucune demande à proximité pour l\'instant.', textAlign: TextAlign.center))
                else
                  for (final r in _nearby)
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: LumoColors.line)),
                      child: ListTile(
                        title: Text('${formatXaf(asInt(r['fareXaf']))} · ${(r['distanceKm'] as num).toStringAsFixed(1)} km'),
                        subtitle: Text('Départ à ${(r['pickupDistanceKm'] as num).toStringAsFixed(1)} km de toi'),
                        trailing: FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                          onPressed: () async { if (await runAction(context, () => _api.post('/rides/${r['id']}/accept'))) _poll(); },
                          child: const Text('Accepter'),
                        ),
                      ),
                    ),
              ]);
            },
          ),
        ),
      ),
    );
  }

  Widget _applyForm(TextTheme t) => ListView(padding: const EdgeInsets.all(20), children: [
        Text('Deviens chauffeur', style: t.headlineSmall),
        const SizedBox(height: 8),
        const Text('Ton profil sera vérifié par notre équipe avant ta première course.'),
        const SizedBox(height: 20),
        TextField(controller: _vehicle, decoration: const InputDecoration(labelText: 'Véhicule (marque, modèle, couleur)')),
        const SizedBox(height: 12),
        TextField(controller: _plate, decoration: const InputDecoration(labelText: 'Immatriculation')),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () async {
            if (await runAction(context, () => _api.post('/drivers/apply', body: {'vehicle': _vehicle.text.trim(), 'plate': _plate.text.trim()}),
                success: 'Demande envoyée')) {
              ref.invalidate(jsonProvider('/drivers/me'));
            }
          },
          child: const Text('Envoyer ma demande'),
        ),
      ]);

  Widget _currentRide(Map<String, dynamic> r, TextTheme t) {
    final status = r['status'] as String;
    final next = {'accepted': 'arrived', 'arrived': 'in_progress', 'in_progress': 'completed'}[status];
    final label = {'arrived': 'Je suis arrivé', 'in_progress': 'Démarrer la course', 'completed': 'Terminer la course'}[next];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Course en cours', style: t.titleMedium),
      const SizedBox(height: 6),
      Text('${formatXaf(asInt(r['fareXaf']))} à encaisser en espèces · ${(r['distanceKm'] as num).toStringAsFixed(1)} km'),
      const SizedBox(height: 4),
      Text('Départ : ${(r['pickupLat'] as num).toStringAsFixed(5)}, ${(r['pickupLng'] as num).toStringAsFixed(5)}', style: t.bodySmall),
      const SizedBox(height: 16),
      if (next != null)
        FilledButton(
          onPressed: () async { if (await runAction(context, () => _api.post('/rides/${r['id']}/status', body: {'status': next}))) _poll(); },
          child: Text(label!),
        ),
      if (status == 'accepted' || status == 'arrived') ...[
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: () async { if (await runAction(context, () => _api.post('/rides/${r['id']}/cancel'))) _poll(); },
          child: const Text('Annuler'),
        ),
      ],
    ]);
  }
}
