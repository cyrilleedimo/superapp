// Petits composants réutilisés : logo, badge de protection, visuel produit, carte article.
import 'package:flutter/material.dart';
import '../core/format.dart';
import '../core/theme/tokens.dart';

/// Logo Ovia (symbole + nom). `light` : version blanche pour fonds sombres.
class LumoLogo extends StatelessWidget {
  const LumoLogo({super.key, this.size = 30, this.light = false, this.markOnly = false});
  final double size;
  final bool light;
  final bool markOnly;

  @override
  Widget build(BuildContext context) {
    final file = markOnly
        ? (light ? 'assets/ovia_mark_light.png' : 'assets/ovia_mark_dark.png')
        : (light ? 'assets/ovia_lockup_light.png' : 'assets/ovia_lockup_dark.png');
    return Semantics(
      label: 'Ovia',
      image: true,
      child: Image.asset(file, height: size, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
    );
  }
}

class ProtectionBadge extends StatelessWidget {
  const ProtectionBadge(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.verified_user_outlined, size: 16, color: LumoColors.success),
      const SizedBox(width: 6),
      Flexible(
        child: Text(text,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: LumoColors.success)),
      ),
    ]);
  }
}

/// Photo produit ; tant qu'il n'y a pas de photo, un aplat doux + pictogramme.
class ProductVisual extends StatelessWidget {
  const ProductVisual({super.key, required this.seed, this.photoUrl, this.height = 196, this.radius = LumoRadius.card, this.icon = Icons.checkroom_outlined});
  final int seed;
  final String? photoUrl;
  final double height;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tone = LumoColors.photoTones[seed.abs() % LumoColors.photoTones.length];
    final placeholder = Container(
      color: tone,
      alignment: Alignment.center,
      child: Icon(icon, size: height * 0.28, color: Color.lerp(tone, Colors.black, 0.45)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: photoUrl == null
            ? placeholder
            : Image.network(photoUrl!, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder,
                loadingBuilder: (_, child, p) => p == null ? child : placeholder),
      ),
    );
  }
}

class ListingCard extends StatelessWidget {
  const ListingCard({super.key, required this.id, required this.title, required this.priceXaf,
      required this.condition, this.photoUrl, required this.onTap});
  final String id, title, condition;
  final int priceXaf;
  final String? photoUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '$title, ${formatXaf(priceXaf)}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LumoRadius.card),
        child: ExcludeSemantics(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ProductVisual(seed: id.hashCode, photoUrl: photoUrl),
            const SizedBox(height: 6),
            Text(formatXaf(priceXaf), style: t.titleMedium?.copyWith(fontSize: 15)),
            const SizedBox(height: 2),
            Text('$title · ${conditionLabels[condition] ?? condition}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

/// État d'erreur réutilisable : message + bouton pour réessayer.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(LumoSpace.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: LumoSpace.l),
        OutlinedButton(onPressed: onRetry, child: const Text('Réessayer')),
      ]),
    );
  }
}
