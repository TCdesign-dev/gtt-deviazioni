import '../config.dart';
import '../geo/geometry.dart';
import '../geo/projection.dart';
import '../models/transit.dart';

/// Da dove viene il punto di rientro.
enum RejoinSource {
  /// GTT ha nominato la via: "riprende il percorso normale dopo via Leinì".
  dichiarato,

  /// Dedotto dall'ultima via nominata prima di "percorso normale".
  dedotto,

  /// Non deducibile con sufficiente fiducia. Non si inventa.
  nonDeducibile,
}

class RejoinPoint {
  const RejoinPoint({
    required this.source,
    this.point,
    this.alongMeters,
    this.metersFromRoute,
    this.whyNot,
  });

  const RejoinPoint.notFound(String why)
      : source = RejoinSource.nonDeducibile,
        point = null,
        alongMeters = null,
        metersFromRoute = null,
        whyNot = why;

  final RejoinSource source;

  /// Il punto, che sta **esattamente** sul percorso ufficiale: "percorso
  /// normale" significa proprio quello.
  final GeoPoint? point;

  /// A che punto del percorso ufficiale corrisponde.
  final double? alongMeters;

  /// Quanto distava dal percorso l'ultima via nominata. E' la misura della
  /// fiducia: piu' e' vicina, piu' la deduzione e' solida.
  final double? metersFromRoute;

  final String? whyNot;

  bool get isUsable => point != null;

  @override
  String toString() => switch (source) {
        RejoinSource.dichiarato => 'rientro dichiarato @$point',
        RejoinSource.dedotto =>
          'rientro dedotto @$point (ultima via a ${metersFromRoute?.round()} m)',
        RejoinSource.nonDeducibile => 'rientro non deducibile: $whyNot',
      };
}

/// Dove rientra un mezzo quando l'avviso dice solo "percorso normale".
///
/// **E' il caso normale, non l'eccezione:** MISURATO sulle 34 fixture
/// annotate, 24 deviazioni su 28 non nominano la via di rientro. Senza
/// dedurlo, il percorso deviato si ferma all'ultima via nominata invece di
/// arrivare fino a dove il mezzo riprende la strada di sempre — e il
/// tratto di linea considerato "interessato" resta troncato, con le
/// fermate che ne conseguono.
///
/// **L'ipotesi, e la misura che la sostiene.** L'ultima via nominata prima
/// di "percorso normale" e' quella su cui il mezzo rientra, quindi giace
/// sul percorso ufficiale. Verificato sui 22 casi reali con rientro non
/// dichiarato: distanza dal percorso con **mediana 1 m**, 75° percentile
/// 2 m, e 21 casi su 22 entro 100 m.
///
/// L'unico fuori scala e' la linea 7 con "corso Vittorio Emanuele II" a
/// 310 m: una via lunghissima, dove il geocoder restituisce un punto solo
/// che puo' cadere lontano da dove la linea la incontra. Per quello c'e'
/// [GttConfig.rejoinMaxViaDistanceMeters]: oltre quella soglia si dichiara
/// di non sapere, invece di piazzare il rientro nel posto sbagliato.
class RejoinInference {
  const RejoinInference._();

  /// [lastVia] e' l'ultima via nominata prima di "percorso normale".
  /// [detachPoint] serve a cercare il rientro **a valle**: una linea puo'
  /// passare due volte vicino alla stessa via, e il rientro sta dopo lo
  /// stacco, non prima.
  static RejoinPoint infer({
    required RouteShape officialRoute,
    required GeoPoint detachPoint,
    required GeoPoint lastVia,
    double? maxViaDistance,
  }) {
    final limit = maxViaDistance ?? GttConfig.rejoinMaxViaDistanceMeters;
    final route = officialRoute.meters;
    if (route.length < 2) {
      return const RejoinPoint.notFound('percorso ufficiale non disponibile');
    }

    final detach = Geometry.projectOnPolyline(detachPoint.meters, route);
    final projected = Geometry.projectOnPolyline(
      lastVia.meters,
      route,
      // Un margine: il rientro deve stare avanti allo stacco, non
      // coincidere con esso.
      fromAlong: detach.alongMeters + GttConfig.rejoinMinForwardMeters,
    );

    if (projected.distance.isInfinite) {
      return const RejoinPoint.notFound(
          'dopo il punto di stacco non c\'è altro percorso');
    }
    if (projected.distance > limit) {
      return RejoinPoint(
        source: RejoinSource.nonDeducibile,
        metersFromRoute: projected.distance,
        whyNot: 'l\'ultima via nominata dista ${projected.distance.round()} m '
            'dal percorso: troppo per dedurre dove rientra',
      );
    }

    final onRoute = Geometry.pointAtAlong(route, projected.alongMeters);
    if (onRoute == null) {
      return const RejoinPoint.notFound('punto non materializzabile');
    }
    final (lat, lon) = Projection.toDegrees(onRoute);

    return RejoinPoint(
      source: RejoinSource.dedotto,
      point: GeoPoint(lat, lon),
      alongMeters: projected.alongMeters,
      metersFromRoute: projected.distance,
    );
  }
}
