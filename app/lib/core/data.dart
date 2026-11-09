// Lecture générique d'une ressource JSON de l'API, mise en cache par chemin.
// Usage : ref.watch(jsonProvider('/orders?role=buyer'))
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';

final jsonProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
    (ref, path) => ref.watch(apiClientProvider).get(path));

/// Liste `items` d'une réponse paginée.
List<Map<String, dynamic>> itemsOf(Map<String, dynamic> json) =>
    ((json['items'] as List?) ?? const []).cast<Map<String, dynamic>>();

int asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
