// Petits composants réutilisés : logo, badge de protection, visuel produit, carte article.
import 'package:flutter/material.dart';
import '../core/format.dart';
import '../core/theme/tokens.dart';

class LumoLogo extends StatelessWidget {
  const LumoLogo({super.key, this.size = 30});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Lumo', // nom de travail — à remplacer par [APP NAME]
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: size, height: size,
          decoration: BoxDecoration(color: LumoColors.action, borderRadius: BorderRadius.circular(size * 0.3)),
          alignment: Alignment.center,
          child: Container(
            width: size * 0.37, height: size * 0.37,
            decoration: const BoxDecoration(color: LumoColors.lime, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 8),
        ExcludeSemantics(
          child: Text('lumo', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: size * 0.73)),
        ),
      ]),
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
