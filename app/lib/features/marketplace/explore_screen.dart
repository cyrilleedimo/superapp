// Explorer : recherche plein texte + filtres par catégorie (chips).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/common.dart';
import 'marketplace_repository.dart';

const _categories = {
  null: 'Tout', 'women': 'Femmes', 'men': 'Hommes', 'kids': 'Enfants',
  'electronics': 'Électronique', 'home': 'Maison', 'beauty': 'Beauté', 'sports': 'Sport',
};

final _searchProvider = FutureProvider.autoDispose.family<List<Listing>, (String, String?)>(
    (ref, args) => ref.watch(marketplaceRepoProvider).feed(query: args.$1, category: args.$2));

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key, this.initialQuery = ''});
  final String initialQuery;
  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  late String _query = widget.initialQuery;
  String? _category;

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(_searchProvider((_query, _category)));
    final wide = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(hintText: 'Rechercher un article', prefixIcon: Icon(Icons.search_rounded)),
              textInputAction: TextInputAction.search,
              onSubmitted: (q) => setState(() => _query = q.trim()),
            ),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              children: [
                for (final e in _categories.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(e.value),
                      selected: _category == e.key,
                      showCheckmark: false,
                      selectedColor: LumoColors.ink,
                      labelStyle: TextStyle(color: _category == e.key ? Colors.white : LumoColors.ink, fontWeight: FontWeight.w600),
                      shape: const StadiumBorder(side: BorderSide(color: LumoColors.line)),
                      onSelected: (_) => setState(() => _category = e.key),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: results.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: ErrorRetry(
                message: e is ApiException ? e.userMessage : 'Recherche impossible.',
                onRetry: () => ref.invalidate(_searchProvider((_query, _category))),
              )),
              data: (items) => items.isEmpty
                  ? const Center(child: Text('Aucun résultat. Essaie un autre mot ou une autre catégorie.'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(20),
                      itemCount: items.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: wide ? 5 : 2, mainAxisSpacing: 16, crossAxisSpacing: 10, mainAxisExtent: 250),
                      itemBuilder: (_, i) {
                        final l = items[i];
                        return ListingCard(
                          id: l.id, title: l.title, priceXaf: l.priceXaf, condition: l.condition,
                          photoUrl: l.photos.isEmpty ? null : l.photos.first,
                          onTap: () => context.push('/listing/${l.id}'),
                        );
                      },
                    ),
            ),
          ),
        ]),
      ),
    );
  }
}
