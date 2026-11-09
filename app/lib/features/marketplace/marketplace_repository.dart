// Accès aux annonces et aux commandes (API backend).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/api/api_client.dart';
import '../../core/providers.dart';

class Listing {
  Listing({
    required this.id, required this.title, required this.description, required this.category,
    required this.condition, required this.priceXaf, required this.city, required this.photos,
    required this.status, this.sellerName,
  });

  factory Listing.fromJson(Map<String, dynamic> j) => Listing(
        id: j['id'] as String,
        title: j['title'] as String,
        description: (j['description'] as String?) ?? '',
        category: j['category'] as String,
        condition: j['condition'] as String,
        priceXaf: (j['priceXaf'] as num).toInt(),
        city: j['city'] as String,
        photos: ((j['photos'] as List?) ?? const []).cast<String>(),
        status: j['status'] as String,
        sellerName: (j['seller'] as Map?)?['displayName'] as String?,
      );

  final String id, title, description, category, condition, city, status;
  final int priceXaf;
  final List<String> photos;
  final String? sellerName;
}

class Order {
  Order(this.id, this.status, this.itemPriceXaf, this.buyerFeeXaf, this.totalXaf);
  factory Order.fromJson(Map<String, dynamic> j) => Order(
        j['id'] as String, j['status'] as String,
        (j['itemPriceXaf'] as num).toInt(), (j['buyerFeeXaf'] as num).toInt(), (j['totalXaf'] as num).toInt());
  final String id, status;
  final int itemPriceXaf, buyerFeeXaf, totalXaf;
}

class MarketplaceRepository {
  MarketplaceRepository(this._api);
  final ApiClient _api;

  Future<List<Listing>> feed({String? query, String? category}) async {
    final r = await _api.get('/listings', query: {
      if (query != null && query.isNotEmpty) 'q': query,
      if (category != null) 'category': category,
      'limit': 20,
    });
    return (r['items'] as List).cast<Map<String, dynamic>>().map(Listing.fromJson).toList();
  }

  Future<Listing> byId(String id) async => Listing.fromJson(await _api.get('/listings/$id'));

  /// Une clé d'idempotence par intention d'achat : un double tap ou une
  /// coupure réseau ne crée jamais deux commandes.
  Future<Order> createOrder(String listingId, String idempotencyKey, {String? offerId}) async => Order.fromJson(
      await _api.post('/orders',
          body: {'listingId': listingId, if (offerId != null) 'offerId': offerId},
          headers: {'Idempotency-Key': idempotencyKey}));

  Future<({String reference, String checkoutUrl})> startPayment(String orderId) async {
    final r = await _api.post('/orders/$orderId/pay');
    return (reference: r['reference'] as String, checkoutUrl: r['checkoutUrl'] as String);
  }

  Future<String> refreshPayment(String reference) async =>
      (await _api.post('/payments/$reference/refresh'))['status'] as String;

  static String newIdempotencyKey() => const Uuid().v4().replaceAll('-', '');
}

final marketplaceRepoProvider = Provider((ref) => MarketplaceRepository(ref.watch(apiClientProvider)));

final feedProvider = FutureProvider.autoDispose<List<Listing>>(
    (ref) => ref.watch(marketplaceRepoProvider).feed());

final listingProvider = FutureProvider.autoDispose.family<Listing, String>(
    (ref, id) => ref.watch(marketplaceRepoProvider).byId(id));
