// Messagerie : discussions autour d'une annonce (avec offres de prix), discussions
// privées et groupes. Rafraîchissement toutes les 4 s pendant qu'une discussion est ouverte.
import 'dart:async';
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
import '../../widgets/common.dart';
import '../orders/orders_screens.dart' show runAction;

const _convPath = '/conversations';

IconData _kindIcon(String? kind) => switch (kind) {
      'group' => Icons.groups_rounded,
      'listing' => Icons.sell_outlined,
      _ => Icons.person_rounded,
    };

// ------------------------------------------------------- Choisir des personnes
/// Recherche de personnes par nom, e-mail ou numéro. Renvoie les personnes choisies.
Future<List<Map<String, dynamic>>?> pickPeople(BuildContext context, {required bool multiple, required String title}) {
  return showModalBottomSheet<List<Map<String, dynamic>>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PeoplePicker(multiple: multiple, title: title),
  );
}

class _PeoplePicker extends ConsumerStatefulWidget {
  const _PeoplePicker({required this.multiple, required this.title});
  final bool multiple;
  final String title;
  @override
  ConsumerState<_PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends ConsumerState<_PeoplePicker> {
  final _q = TextEditingController();
  final Map<String, Map<String, dynamic>> _selected = {};
  List<Map<String, dynamic>> _results = const [];
  Timer? _debounce;
  bool _searching = false;
  bool _searched = false;

  @override
  void dispose() { _debounce?.cancel(); _q.dispose(); super.dispose(); }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _search);
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.length < 3) { setState(() { _results = const []; _searched = false; }); return; }
    setState(() => _searching = true);
    try {
      final r = await ref.read(apiClientProvider).get('/users/search', query: {'q': q});
      if (mounted) setState(() { _results = itemsOf(r); _searched = true; });
    } on ApiException catch (_) {
      if (mounted) setState(() { _results = const []; _searched = true; });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _q, autofocus: true, onChanged: _onChanged, textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: const InputDecoration(hintText: 'Nom, e-mail ou numéro (+237…)', prefixIcon: Icon(Icons.search_rounded)),
          ),
          if (_selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final u in _selected.values)
                  InputChip(label: Text(u['displayName'] as String), onDeleted: () => setState(() => _selected.remove(u['id']))),
              ]),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? Center(
                        child: Text(
                          _searched ? 'Personne trouvée. Vérifie l\'orthographe, ou essaie son e-mail ou son numéro exact.' : 'Tape au moins 3 lettres.',
                          textAlign: TextAlign.center, style: const TextStyle(color: LumoColors.slate)))
                    : ListView(children: [
                        for (final u in _results)
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor: LumoColors.actionSoft, foregroundColor: LumoColors.action,
                              child: Text((u['displayName'] as String).characters.first.toUpperCase()),
                            ),
                            title: Text(u['displayName'] as String),
                            trailing: widget.multiple
                                ? Icon(_selected.containsKey(u['id']) ? Icons.check_circle_rounded : Icons.circle_outlined,
                                    color: _selected.containsKey(u['id']) ? LumoColors.action : LumoColors.line)
                                : const Icon(Icons.chevron_right),
                            onTap: () {
                              if (!widget.multiple) { Navigator.pop(context, [u]); return; }
                              setState(() {
                                if (_selected.containsKey(u['id'])) { _selected.remove(u['id']); } else { _selected[u['id'] as String] = u; }
                              });
                            },
                          ),
                      ]),
          ),
          if (widget.multiple)
            FilledButton(
              onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected.values.toList()),
              child: Text(_selected.isEmpty ? 'Choisis des personnes' : 'Continuer (${_selected.length})'),
            ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------ Liste des discussions
class ConversationsScreen extends ConsumerWidget {
  const ConversationsScreen({super.key});

  Future<void> _newDirect(BuildContext context, WidgetRef ref) async {
    final people = await pickPeople(context, multiple: false, title: 'Nouvelle discussion');
    if (people == null || people.isEmpty || !context.mounted) return;
    try {
      final c = await ref.read(apiClientProvider).post('/conversations/direct', body: {'userId': people.first['id']});
      ref.invalidate(jsonProvider(_convPath));
      if (context.mounted) context.push('/chat/${c['id']}');
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  Future<void> _newGroup(BuildContext context, WidgetRef ref) async {
    final people = await pickPeople(context, multiple: true, title: 'Nouveau groupe : qui inviter ?');
    if (people == null || people.isEmpty || !context.mounted) return;
    final name = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nom du groupe'),
        content: TextField(controller: name, autofocus: true, maxLength: 80, decoration: const InputDecoration(hintText: 'Ex. Famille, Équipe Douala…')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Fermer')),
          TextButton(onPressed: () => Navigator.pop(c, name.text.trim()), child: const Text('Créer')),
        ],
      ),
    );
    name.dispose();
    if (title == null || title.length < 2 || !context.mounted) return;
    try {
      final c = await ref.read(apiClientProvider).post('/groups', body: {'title': title, 'memberIds': [for (final p in people) p['id']]});
      ref.invalidate(jsonProvider(_convPath));
      if (context.mounted) context.push('/chat/${c['id']}');
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(jsonProvider(_convPath));
    // La pastille change (nouveau message) → on recharge la liste.
    ref.listen(badgesProvider, (prev, next) {
      if (prev?.messages != next.messages) ref.invalidate(jsonProvider(_convPath));
    });
    return Scaffold(
      appBar: AppBar(
        title: Text('Messages', style: Theme.of(context).textTheme.headlineSmall),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Nouveau',
            icon: const Icon(Icons.edit_square),
            onSelected: (v) => v == 'group' ? _newGroup(context, ref) : _newDirect(context, ref),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'direct', child: ListTile(leading: Icon(Icons.person_add_alt_1_outlined), title: Text('Nouvelle discussion'), contentPadding: EdgeInsets.zero)),
              PopupMenuItem(value: 'group', child: ListTile(leading: Icon(Icons.group_add_outlined), title: Text('Nouveau groupe'), contentPadding: EdgeInsets.zero)),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: ErrorRetry(message: 'Impossible de charger les messages.', onRetry: () => ref.invalidate(jsonProvider(_convPath)))),
        data: (json) {
          final items = itemsOf(json);
          if (items.isEmpty) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.forum_outlined, size: 56, color: LumoColors.slate),
                const SizedBox(height: 12),
                const Text('Aucune discussion pour l\'instant.\nÉcris à un vendeur depuis une annonce, ou lance une discussion.', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: () => _newDirect(context, ref), child: const Text('Nouvelle discussion')),
              ]),
            ));
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(jsonProvider(_convPath).future),
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(indent: 72),
              itemBuilder: (_, i) {
                final c = items[i];
                final name = (c['title'] as String?) ?? (c['otherName'] as String?) ?? '?';
                final unread = asInt(c['unread']);
                final listing = c['listingTitle'] as String?;
                final last = (c['lastMessage'] as String?) ?? 'Nouvelle discussion';
                return ListTile(
                  minVerticalPadding: 12,
                  leading: CircleAvatar(
                    backgroundColor: LumoColors.actionSoft, foregroundColor: LumoColors.action,
                    child: c['kind'] == 'direct' && name.isNotEmpty ? Text(name.characters.first.toUpperCase()) : Icon(_kindIcon(c['kind'] as String?), size: 20),
                  ),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w600)),
                  subtitle: Text(listing == null ? last : '$listing · $last', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: unread > 0 ? LumoColors.ink : LumoColors.slate)),
                  trailing: unread > 0 ? Badge(label: Text(unread > 99 ? '99+' : '$unread'), backgroundColor: LumoColors.action) : null,
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

// ----------------------------------------------------------------- Discussion
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
  bool _missing = false;

  ApiClient get _api => ref.read(apiClientProvider);
  String get _base => '/conversations/${widget.conversationId}';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _loadConv() async {
    try {
      final c = await _api.get(_base);
      if (mounted) setState(() => _conv = c);
    } on ApiException catch (e) {
      if (mounted && e.status == 404) setState(() => _missing = true);
    }
  }

  Future<void> _init() async {
    try {
      _myId = (await _api.get('/me'))['id'] as String?;
    } on ApiException catch (_) {}
    await _loadConv();
    await _poll();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_missing) return;
    final after = _messages.isEmpty ? 0 : asInt(_messages.last['id']);
    try {
      final fresh = itemsOf(await _api.get('$_base/messages', query: {'after': after}));
      if (fresh.isEmpty || !mounted) return;
      setState(() => _messages.addAll(fresh));
      ref.read(badgesProvider.notifier).refresh(); // ces messages viennent d'être lus
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
    final ok = await runAction(context, () => _api.post('$_base/messages', body: {'body': text}));
    if (ok) { _input.clear(); await _poll(); }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _sendPhoto() async {
    if (_sending) return;
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, imageQuality: 88);
    if (file == null || !mounted) return;
    setState(() => _sending = true);
    final ok = await runAction(context, () async {
      final name = file.name.toLowerCase();
      final mime = name.endsWith('.png') ? 'image/png' : name.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
      final media = await _api.uploadImage(await file.readAsBytes(), mime);
      await _api.post('$_base/messages', body: {'mediaId': media['id'], 'body': ''});
    });
    if (ok) await _poll();
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
    if (await runAction(context, () => _api.post('$_base/offers', body: {'amountXaf': amount}))) {
      await _poll();
    }
  }

  Future<void> _groupInfo() async {
    final conv = _conv;
    if (conv == null) return;
    final members = itemsOf({'items': conv['members']});
    final isAdmin = conv['myRole'] == 'admin';
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('${conv['title']} · ${members.length} membre${members.length > 1 ? 's' : ''}', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final m in members)
            ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 16, backgroundColor: LumoColors.actionSoft, foregroundColor: LumoColors.action,
                child: Text((m['displayName'] as String).characters.first.toUpperCase(), style: const TextStyle(fontSize: 13)),
              ),
              title: Text('${m['displayName']}${m['id'] == _myId ? ' (toi)' : ''}'),
              trailing: m['role'] == 'admin' ? const Text('Responsable', style: TextStyle(fontSize: 12, color: LumoColors.slate)) : null,
            ),
          const Divider(),
          if (isAdmin) ListTile(leading: const Icon(Icons.person_add_alt_1_outlined), title: const Text('Ajouter quelqu\'un'), onTap: () => Navigator.pop(c, 'add')),
          if (isAdmin) ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Renommer le groupe'), onTap: () => Navigator.pop(c, 'rename')),
          ListTile(leading: const Icon(Icons.logout_rounded, color: LumoColors.danger), title: const Text('Quitter le groupe', style: TextStyle(color: LumoColors.danger)),
              onTap: () => Navigator.pop(c, 'leave')),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    final groupPath = '/groups/${widget.conversationId}';
    if (action == 'add') {
      final people = await pickPeople(context, multiple: false, title: 'Ajouter au groupe');
      if (people == null || people.isEmpty || !mounted) return;
      if (await runAction(context, () => _api.post('$groupPath/members', body: {'userId': people.first['id']}), success: 'Ajouté au groupe')) {
        await _loadConv();
        await _poll();
      }
    } else if (action == 'rename') {
      final name = TextEditingController(text: conv['title'] as String? ?? '');
      final title = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Renommer le groupe'),
          content: TextField(controller: name, autofocus: true, maxLength: 80),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Fermer')),
            TextButton(onPressed: () => Navigator.pop(c, name.text.trim()), child: const Text('Enregistrer')),
          ],
        ),
      );
      name.dispose();
      if (title == null || title.length < 2 || !mounted) return;
      if (await runAction(context, () => _api.patch(groupPath, body: {'title': title}))) await _loadConv();
    } else if (action == 'leave') {
      if (await runAction(context, () => _api.post('$groupPath/leave'), success: 'Tu as quitté le groupe')) {
        ref.invalidate(jsonProvider(_convPath));
        if (mounted) context.canPop() ? context.pop() : context.go('/messages');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_missing) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Cette discussion n\'existe plus.')));
    }
    final kind = _conv?['kind'] as String?;
    final isGroup = kind == 'group';
    final iAmBuyer = _conv?['iAmBuyer'] == true;
    final listingId = _conv?['listingId'] as String?;
    final listingTitle = _conv?['listingTitle'] as String?;
    final memberCount = ((_conv?['members'] as List?) ?? const []).length;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text((_conv?['title'] as String?) ?? 'Discussion', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          if (listingTitle != null)
            Text('$listingTitle · ${formatXaf(asInt(_conv!['listingPriceXaf']))}', style: const TextStyle(fontSize: 12, color: LumoColors.slate))
          else if (isGroup)
            Text('$memberCount membre${memberCount > 1 ? 's' : ''}', style: const TextStyle(fontSize: 12, color: LumoColors.slate)),
        ]),
        actions: [
          if (listingId != null)
            IconButton(tooltip: 'Voir l\'annonce', onPressed: () => context.push('/listing/$listingId'), icon: const Icon(Icons.open_in_new_rounded)),
          if (isGroup) IconButton(tooltip: 'Membres du groupe', onPressed: _groupInfo, icon: const Icon(Icons.group_outlined)),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: _messages.isEmpty
              ? const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Écris le premier message.', style: TextStyle(color: LumoColors.slate))))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _bubble(_messages[i], isGroup: isGroup, iAmBuyer: iAmBuyer, listingId: listingId),
                ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: LumoColors.line))),
            child: Row(children: [
              IconButton(tooltip: 'Envoyer une photo', onPressed: _sending ? null : _sendPhoto, icon: const Icon(Icons.image_outlined)),
              if (iAmBuyer && kind == 'listing')
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

  Widget _bubble(Map<String, dynamic> m, {required bool isGroup, required bool iAmBuyer, required String? listingId}) {
    final body = (m['body'] as String?) ?? '';
    if (m['kind'] == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(child: Text(body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: LumoColors.slate))),
      );
    }
    final mine = m['senderId'] == _myId;
    final offer = m['offer'] as Map<String, dynamic>?;
    final mediaUrl = m['mediaUrl'] as String?;
    final textColor = mine && offer == null ? Colors.white : LumoColors.ink;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: mediaUrl != null && offer == null ? const EdgeInsets.all(4) : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: offer != null ? LumoColors.actionSoft : (mine ? LumoColors.action : LumoColors.mist),
          borderRadius: BorderRadius.circular(18),
        ),
        child: offer != null
            ? _OfferBubble(offer: offer, mine: mine, iAmBuyer: iAmBuyer, listingId: listingId, onDecided: _reloadAll)
            : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                if (isGroup && !mine)
                  Padding(
                    padding: EdgeInsets.fromLTRB(mediaUrl != null ? 10 : 0, mediaUrl != null ? 6 : 0, 0, 2),
                    child: Text((m['senderName'] as String?) ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: LumoColors.action)),
                  ),
                if (mediaUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.network(AppConfig.resolveMediaUrl(mediaUrl), width: 240, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox(width: 240, height: 120, child: Center(child: Icon(Icons.broken_image_outlined)))),
                  ),
                if (body.isNotEmpty)
                  Padding(
                    padding: mediaUrl != null ? const EdgeInsets.fromLTRB(10, 6, 10, 6) : EdgeInsets.zero,
                    child: Text(body, style: TextStyle(color: textColor, fontSize: 15)),
                  ),
              ]),
      ),
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
