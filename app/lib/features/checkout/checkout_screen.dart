// Achat d'un article de seconde main : crée la commande (réserve l'article,
// clé d'idempotence unique par écran) puis ouvre l'écran de paiement générique.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../widgets/common.dart';
import '../marketplace/marketplace_repository.dart';

class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key, required this.listingId, this.offerId});
  final String listingId;
  final String? offerId;
  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  final _idemKey = MarketplaceRepository.newIdempotencyKey();
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      final order = await ref.read(marketplaceRepoProvider).createOrder(widget.listingId, _idemKey, offerId: widget.offerId);
      if (mounted) context.pushReplacement('/pay/${order.id}');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: Center(
          child: _error == null ? const CircularProgressIndicator() : ErrorRetry(message: _error!, onRetry: _start),
        ),
      );
}
