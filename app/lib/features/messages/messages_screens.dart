// Messagerie acheteur ↔ vendeur et offres de prix (rafraîchissement toutes les 4 s).
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/data.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/common.dart';
import '../orders/orders_screens.dart' show runAction;

class ConversationsScreen extends ConsumerWidget {
  const ConversationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = '/conversations';
    final async = ref.watch(jsonProvider(path));
    return Scaffold(
      appBar: AppBar(title: Text('Messages', style: Theme.of(context).textTheme.headlineSmall)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: ErrorRetry(message: 'Impossible de charger les messages.', onRetry: () => ref.invalidate(jsonProvider(path)))),
        data: (json) {
          final items = itemsOf(json);
          if (items.isEmpty) {
            return const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Aucune conversation. Écris à un vendeur depuis une annonce.', textAlign: TextAlign.center),
            ));
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(jsonProvider(path).future),
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(indent: 72),
              itemBuilder: (_, i) {
                final c = items[i];
                final name = (c['otherName'] as String?) ?? '?';
                return ListTile(
                  minVerticalPadding: 12,
                  leading: CircleAvatar(
                    backgroundColor: LumoColors.actionSoft, foregroundColor: LumoColors.action,
                    child: Text(name.characters.first.toUpperCase()),
                  ),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${c['listingTitle']} · ${c['lastMessage'] ?? 'Nouvelle conversation'}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => context.push('/chat/${c['id']}'),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});
  final String conversationId;
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  Map<String, dynamic>? _conv;
  String? _myId;
  Timer? _timer;
  bool _sending = false;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _myId = (await _api.get('/me'))['id'] as String?;
      final convs = itemsOf(await _api.get('/conversations'));
      _conv = convs.where((c) => c['id'] == widget.conversationId).firstOrNullCompat;
    } on ApiException catch (_) {}
    await _poll();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
  }

  Future<void> _poll() async {
    final after = _messages.isEmpty ? 0 : asInt(_messages.last['id']);
    try {
      final fresh = itemsOf(await _api.get('/conversations/${widget.conversationId}/messages', query: {'after': after}));
      if (fresh.isEmpty || !mounted) return;
      setState(() => _messages.addAll(fresh));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    } on ApiException catch (_) {/* réseau : on réessaie au prochain tour */}
  }

  /// Les offres changent de statut : on recharge tout l'historique.
  Future<void> _reloadAll() async {
    setState(() => _messages.clear());
    await _poll();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await runAction(context, () => _api.post('/conversations/${widget.conversationId}/messages', body: {'body': text}));
    if (ok) { _input.clear(); await _poll(); }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _makeOffer() async {
    final controller = TextEditingController();
    final amount = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Faire une offre'),
        content: TextField(
          controller: controller, keyboardType: TextInputType.number, autofocus: true,
          decoration: const InputDecoration(suffixText: 'FCFA', labelText: 'Ton prix'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Fermer')),
          TextButton(onPressed: () => Navigator.pop(c, int.tryParse(controller.text.replaceAll(RegExp(r'\D'), ''))), child: const Text('Envoyer')),
        ],
      ),
    );
    controller.dispose();
    if (amount == null || amount <= 0 || !mounted) return;
    if (await runAction(context, () => _api.post('/conversations/${widget.conversationId}/offers', body: {'amountXaf': amount}))) {
      await _poll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final iAmBuyer = _conv?['iAmBuyer'] == true;
    final listingId = _conv?['listingId'] as String?;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text((_conv?['otherName'] as String?) ?? 'Conversation', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          if (_conv != null)
            Text('${_conv!['listingTitle']} · ${formatXaf(asInt(_conv!['listingPriceXaf']))}',
                style: const TextStyle(fontSize: 12, color: LumoColors.slate)),
        ]),
        actions: [
          if (listingId != null)
            IconButton(tooltip: 'Voir l\'annonce', onPressed: () => context.push('/listing/$listingId'), icon: const Icon(Icons.open_in_new_rounded)),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length,
            itemBuilder: (_, i) {
              final m = _messages[i];
              final mine = m['senderId'] == _myId;
              final offer = m['offer'] as Map<String, dynamic>?;
              return Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 320),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: offer != null ? LumoColors.actionSoft : (mine ? LumoColors.action : LumoColors.mist),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: offer == null
                      ? Text(m['body'] as String, style: TextStyle(color: mine ? Colors.white : LumoColors.ink, fontSize: 15))
                      : _OfferBubble(
                          offer: offer, mine: mine, iAmBuyer: iAmBuyer, listingId: listingId,
                          onDecided: _reloadAll,
                        ),
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: LumoColors.line))),
            child: Row(children: [
              if (iAmBuyer)
                IconButton(tooltip: 'Faire une offre', onPressed: _makeOffer, icon: const Icon(Icons.local_offer_outlined)),
              Expanded(
                child: TextField(
                  controller: _input, minLines: 1, maxLines: 4, textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(hintText: 'Écrire un message…'),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(tooltip: 'Envoyer', onPressed: _sending ? null : _send, icon: const Icon(Icons.send_rounded)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _OfferBubble extends ConsumerWidget {
  const _OfferBubble({required this.offer, required this.mine, required this.iAmBuyer, required this.listingId, required this.onDecided});
  final Map<String, dynamic> offer;
  final bool mine, iAmBuyer;
  final String? listingId;
  final VoidCallback onDecided;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = offer['status'] as String;
    final amount = asInt(offer['amountXaf']);
    final label = {'pending': 'En attente', 'accepted': 'Acceptée', 'declined': 'Refusée', 'used': 'Utilisée'}[status] ?? status;
    final api = ref.read(apiClientProvider);
    Future<void> decide(bool accept) async {
      if (await runAction(context, () => api.post('/offers/${offer['id']}/decision', body: {'accept': accept}))) onDecided();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      const Text('Offre', style: TextStyle(fontSize: 12, color: LumoColors.slate)),
      Text(formatXaf(amount), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: LumoColors.action)),
      if (!iAmBuyer && status == 'pending') ...[
        const SizedBox(height: 8),
        Row(mainAxisSize: MainAxisSize.min, children: [
          TextButton(onPressed: () => decide(false), child: const Text('Refuser')),
          const SizedBox(width: 4),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => decide(true), child: const Text('Accepter'),
          ),
        ]),
      ],
      if (iAmBuyer && status == 'accepted' && listingId != null) ...[
        const SizedBox(height: 8),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: () => context.push('/checkout/$listingId?offer=${offer['id']}'),
          child: Text('Acheter à ${formatXaf(amount)}'),
        ),
      ],
    ]);
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNullCompat => isEmpty ? null : first;
}
