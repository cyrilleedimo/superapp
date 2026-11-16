// Écran de bienvenue (premier lancement) et page « Comment ça marche » : explique en
// clair ce qu'on peut faire, la protection acheteur, et comment devenir vendeur,
// chauffeur ou commerçant.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/config.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/common.dart';

class _Slide {
  const _Slide(this.icon, this.tone, this.title, this.body);
  final IconData icon;
  final Color tone;
  final String title, body;
}

const _slides = [
  _Slide(Icons.apps_rounded, LumoColors.actionSoft, 'Tout au même endroit',
      'Seconde main, courses en ville, covoiturage, repas, boutiques et voyages : une seule application pour ton quotidien.'),
  _Slide(Icons.verified_user_outlined, Color(0xFFE3F5EC), 'Achète sans crainte',
      'Quand tu paies en ligne, ton argent reste bloqué. Le vendeur n\'est payé que lorsque tu confirmes avoir bien reçu ta commande.'),
  _Slide(Icons.sell_outlined, Color(0xFFF3F9D2), 'Vends en deux minutes',
      'Prends des photos, laisse l\'assistant proposer une description, fixe ton prix. Tu peux aussi devenir chauffeur ou ouvrir ta boutique.'),
  _Slide(Icons.explore_outlined, Color(0xFFE3E1F0), 'Regarde d\'abord, inscris-toi ensuite',
      'Tu peux tout parcourir sans compte. On te demandera de te connecter seulement pour acheter, vendre ou écrire à quelqu\'un.'),
];

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _pages = PageController();
  int _index = 0;

  @override
  void dispose() { _pages.dispose(); super.dispose(); }

  Future<void> _finish(String route) async {
    await AppConfig.markOnboarded();
    if (mounted) context.go(route);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final last = _index == _slides.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Row(children: [
                  const LumoLogo(size: 32),
                  const Spacer(),
                  TextButton(onPressed: () => _finish('/'), child: const Text('Passer')),
                ]),
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: _slides.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (_, i) {
                      final s = _slides[i];
                      return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Container(
                          width: 168, height: 168,
                          decoration: BoxDecoration(color: s.tone, borderRadius: BorderRadius.circular(48)),
                          child: Icon(s.icon, size: 76, color: LumoColors.ink),
                        ),
                        const SizedBox(height: 36),
                        Text(s.title, style: t.headlineMedium, textAlign: TextAlign.center),
                        const SizedBox(height: 14),
                        Text(s.body, style: t.bodyLarge?.copyWith(color: LumoColors.slate, fontSize: 16), textAlign: TextAlign.center),
                      ]);
                    },
                  ),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < _slides.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _index ? 22 : 8, height: 8,
                      decoration: BoxDecoration(color: i == _index ? LumoColors.action : LumoColors.line, borderRadius: BorderRadius.circular(8)),
                    ),
                ]),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => last
                      ? _finish('/')
                      : _pages.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut),
                  child: Text(last ? 'Découvrir l\'application' : 'Suivant'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(onPressed: () => _finish('/register'), child: const Text('Créer mon compte')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Guide {
  const _Guide(this.icon, this.title, this.steps, {this.cta, this.route});
  final IconData icon;
  final String title;
  final List<String> steps;
  final String? cta, route;
}

const _guides = [
  _Guide(Icons.verified_user_outlined, 'La protection acheteur', [
    'Tu paies en ligne (Orange Money, MTN MoMo) : l\'argent n\'arrive pas chez le vendeur, il est mis de côté.',
    'Tu reçois ta commande et tu vérifies qu\'elle correspond.',
    'Tu touches « J\'ai reçu ma commande » : le vendeur est payé à ce moment-là.',
    'Un problème ? « Signaler un problème » bloque le paiement et notre équipe tranche : remboursement ou paiement du vendeur.',
    'Si tu choisis « Payer à la remise », tu paies le vendeur de la main à la main : c\'est sans frais, mais sans cette protection.',
  ]),
  _Guide(Icons.sell_outlined, 'Vendre un article', [
    'Touche le bouton « + » en bas de l\'accueil.',
    'Ajoute jusqu\'à 10 photos, puis « Décrire avec l\'IA » pour une proposition de titre et de description (à relire).',
    'Fixe ton prix et ta ville, puis publie.',
    'Quand l\'acheteur confirme la réception, l\'argent arrive dans ton porte-monnaie (Profil). Tu le retires vers Mobile Money.',
  ], cta: 'Vendre maintenant', route: '/sell'),
  _Guide(Icons.drive_eta_outlined, 'Devenir chauffeur (courses en ville)', [
    'Profil → Espace chauffeur.',
    'Indique ton véhicule et ta plaque, puis envoie ta demande.',
    'Notre équipe vérifie ton dossier. Tu reçois une notification dès qu\'il est validé.',
    'Passe « En ligne » pour voir les demandes de course près de toi et les accepter.',
  ], cta: 'Ouvrir l\'espace chauffeur', route: '/driver'),
  _Guide(Icons.directions_car_outlined, 'Proposer un covoiturage', [
    'Accueil → Covoiturage → « Publier un trajet ».',
    'Indique le départ, l\'arrivée, la date, le nombre de places et le prix par place.',
    'Les passagers réservent et paient ; tu es payé quand ils confirment le trajet.',
  ], cta: 'Publier un trajet', route: '/trips/new'),
  _Guide(Icons.storefront_outlined, 'Ouvrir un restaurant ou une boutique', [
    'Profil → Mes commerces → « Créer un commerce ».',
    'Choisis Restaurant ou Boutique, donne le nom, la ville et les frais de livraison.',
    'Notre équipe valide ton commerce, puis il apparaît dans l\'application.',
    'Ajoute tes plats ou tes articles, et fais avancer chaque commande : acceptée, en préparation, prête, en livraison, livrée.',
  ], cta: 'Ouvrir mes commerces', route: '/merchant'),
  _Guide(Icons.account_balance_wallet_outlined, 'Le porte-monnaie', [
    'Il reçoit l\'argent de tes ventes, une fois la réception confirmée par l\'acheteur.',
    'Chaque mouvement est inscrit dans un registre comptable qui ne peut être ni modifié ni effacé.',
    'Pour retirer vers Orange Money ou MTN MoMo, ton mot de passe est redemandé.',
    'Pour payer une commande, tu n\'as pas besoin de l\'alimenter : tu paies directement avec Mobile Money.',
  ]),
];

class HelpScreen extends ConsumerWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final signedIn = ref.watch(signedInProvider);
    return Scaffold(
      appBar: AppBar(title: Text('Comment ça marche', style: t.headlineSmall)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            for (final g in _guides)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(border: Border.all(color: LumoColors.line), borderRadius: BorderRadius.circular(16)),
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  shape: const Border(),
                  collapsedShape: const Border(),
                  leading: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(color: LumoColors.actionSoft, borderRadius: BorderRadius.circular(12)),
                    child: Icon(g.icon, color: LumoColors.action, size: 22),
                  ),
                  title: Text(g.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < g.steps.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Container(
                            width: 24, height: 24, alignment: Alignment.center,
                            decoration: const BoxDecoration(color: LumoColors.ink, shape: BoxShape.circle),
                            child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(g.steps[i], style: t.bodyLarge)),
                        ]),
                      ),
                    if (g.cta != null && g.route != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                          onPressed: () => context.push(signedIn ? g.route! : '/login?next=${Uri.encodeQueryComponent(g.route!)}'),
                          child: Text(g.cta!),
                        ),
                      ),
                  ],
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
