import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';

import '../config.dart';
import '../geo/projection.dart';
import '../net/gtt_http.dart';

/// Dove si trova un mezzo, adesso.
class VehicleObservation {
  const VehicleObservation({
    required this.vehicleId,
    required this.routeId,
    required this.position,
    required this.seenAt,
    this.tripId,
    this.bearing,
  });

  final String vehicleId;
  final String routeId;
  final GeoPoint position;
  final DateTime seenAt;

  /// Popolato nel 76,6% dei casi (misurato). Quando c'e', dice esattamente
  /// quale corsa sta facendo il mezzo.
  final String? tripId;
  final double? bearing;

  @override
  String toString() => '$vehicleId@$position';
}

/// Cosa c'era nel feed a un dato istante.
///
/// Distingue due cose che sembrano uguali e non lo sono: "nessun mezzo su
/// questa linea" e "GTT non sta pubblicando le posizioni di nessuno".
class VehicleSnapshot {
  const VehicleSnapshot({required this.matching, required this.totalInFeed});

  /// I mezzi della linea richiesta.
  final List<VehicleObservation> matching;

  /// Quanti mezzi c'erano in tutto il feed, tutte le linee.
  final int totalInFeed;

  /// Il feed e' spento: GTT non sta pubblicando NIENTE.
  ///
  /// MISURATO il 31/07/2026: dopo le 23:30 `vehicle_position` restituisce
  /// un protobuf vuoto di 15 byte, mentre `trip_update` e `alerts`
  /// continuano a rispondere. I mezzi pero' circolano davvero — il GTFS
  /// ha corse programmate fino alle 01:52. Quindi feed vuoto NON
  /// significa servizio finito, e dirlo sarebbe una bugia.
  bool get feedIsOff => totalInFeed == 0;
}

/// Legge le posizioni dei mezzi dal feed GTFS-Realtime di GTT.
///
/// Un dato utile ma sporco: MISURATO il 31/07/2026, circa il 3% dei mezzi
/// pubblica `lat=0, lon=0` — Null Island. Senza scartarle sono 5.000 km di
/// "fuori percorso" e un falso positivo garantito, che secondo §11.4 e' il
/// fallimento peggiore possibile.
class VehiclesSource {
  VehiclesSource({GttHttp? http}) : _http = http ?? GttHttp();

  final GttHttp _http;

  Future<VehicleSnapshot> fetch({String? routeId}) async {
    final bytes = await _http.getBytes(GttConfig.vehiclesUrl);
    return VehicleSnapshot(
      matching: parse(bytes, routeId: routeId),
      totalInFeed: parse(bytes).length,
    );
  }

  /// Separato da [fetch] per poterlo provare su un payload salvato.
  List<VehicleObservation> parse(List<int> bytes, {String? routeId}) {
    final feed = FeedMessage.fromBuffer(bytes);
    final now = DateTime.now();
    final out = <VehicleObservation>[];

    for (final entity in feed.entity) {
      if (!entity.hasVehicle()) continue;
      final v = entity.vehicle;
      if (!v.hasPosition()) continue;

      final route = v.trip.routeId;
      if (routeId != null && route != routeId) continue;

      final p = GeoPoint(v.position.latitude, v.position.longitude);
      if (!p.isPlausible) continue; // Null Island e affini

      out.add(VehicleObservation(
        vehicleId: v.vehicle.id.isNotEmpty ? v.vehicle.id : entity.id,
        routeId: route,
        position: p,
        tripId: v.trip.tripId.isEmpty ? null : v.trip.tripId,
        bearing: v.position.hasBearing() ? v.position.bearing : null,
        seenAt: v.hasTimestamp() && v.timestamp > 0
            ? DateTime.fromMillisecondsSinceEpoch(v.timestamp.toInt() * 1000)
            : now,
      ));
    }
    return out;
  }
}
