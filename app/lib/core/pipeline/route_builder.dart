import 'dart:convert';

import '../config.dart';
import '../geo/geometry.dart';
import '../geo/polyline.dart';
import '../geo/projection.dart';
import '../models/transit.dart';
import '../net/gtt_http.dart';

/// Da una sequenza di vie geolocalizzate al percorso vero che il mezzo puo'
/// fare.
///
/// Il geocoder da' dei punti sparsi; questo li unisce seguendo le strade
/// reali, coi sensi unici e i divieti giusti. Usa l'istanza pubblica
/// Valhalla di FOSSGIS, che accetta il profilo `bus`: OSRM con profilo
/// `car` sbaglierebbe i sensi unici e le strade vietate ai mezzi pesanti.
///
/// **Un percorso calcolato non e' un percorso valido.** Prima di
/// restituirlo si applicano le cinque prove di §5.2.3, perche' il motore
/// di routing risponde sempre qualcosa, anche quando i punti che gli hai
/// dato non hanno senso. Se una prova fallisce il risultato lo dice, e a
/// quel punto va mostrato il testo originale invece della mappa.
class RouteBuilder {
  RouteBuilder({GttHttp? http}) : _http = http ?? GttHttp();

  final GttHttp _http;

  /// [waypoints] in ordine: punto di stacco, vie intermedie, punto di
  /// ricongiungimento. [officialRoute] serve alla prova di sovrapposizione.
  Future<RouteBuildResult> build({
    required List<GeoPoint> waypoints,
    required RouteShape officialRoute,
    List<GeoPoint> requiredVias = const [],
  }) async {
    if (waypoints.length < 2) {
      return RouteBuildResult.notRouted(
          'servono almeno due punti, ricevuti ${waypoints.length}');
    }

    final String body;
    try {
      body = await _http.postJsonPolite(GttConfig.valhallaUrl, {
        'locations': [
          for (var i = 0; i < waypoints.length; i++)
            {
              'lat': waypoints[i].lat,
              'lon': waypoints[i].lon,
              // Solo gli estremi sono fermate vere: gli intermedi devono
              // essere attraversati, non trasformati in tappe con sosta.
              'type': (i == 0 || i == waypoints.length - 1)
                  ? 'break'
                  : 'through',
            }
        ],
        'costing': 'bus',
        'directions_options': {'units': 'kilometers'},
      });
    } on GttHttpException catch (e) {
      return RouteBuildResult.error(e.toString());
    }

    final List<GeoPoint> geometry;
    try {
      geometry = _decodeShape(body);
    } on Object catch (e) {
      return RouteBuildResult.error('risposta illeggibile: $e');
    }
    if (geometry.length < 2) {
      return RouteBuildResult.notRouted('Valhalla non ha trovato un percorso');
    }

    final failures = _validate(
      geometry: geometry,
      waypoints: waypoints,
      requiredVias: requiredVias,
      officialRoute: officialRoute,
    );

    return RouteBuildResult(
      status: failures.isEmpty
          ? RouteBuildStatus.ok
          : RouteBuildStatus.validationFailed,
      geometry: geometry,
      lengthMeters:
          Geometry.length(geometry.map((p) => p.meters).toList()),
      failures: failures,
    );
  }

  /// Valhalla codifica la polilinea con **precisione 6**, non 5.
  /// Decodificarla con 5 porta il primo punto a latitudine 450: da nessuna
  /// parte. E' un errore che non da' eccezioni, solo una mappa vuota.
  static List<GeoPoint> _decodeShape(String responseBody) {
    final json = jsonDecode(responseBody) as Map<String, dynamic>;
    final trip = json['trip'] as Map<String, dynamic>?;
    final legs = (trip?['legs'] as List?) ?? const [];
    final out = <GeoPoint>[];
    for (final leg in legs) {
      final shape = (leg as Map<String, dynamic>)['shape'] as String?;
      if (shape == null) continue;
      final pts = PolylineCodec.decode(shape, precision: 6);
      // Fra un leg e l'altro il primo punto ripete l'ultimo del precedente.
      out.addAll(out.isEmpty ? pts : pts.skip(1));
    }
    return out;
  }

  /// Le cinque prove di §5.2.3.
  List<RouteValidationFailure> _validate({
    required List<GeoPoint> geometry,
    required List<GeoPoint> waypoints,
    required List<GeoPoint> requiredVias,
    required RouteShape officialRoute,
  }) {
    final failures = <RouteValidationFailure>[];
    final route = geometry.map((p) => p.meters).toList();

    // 1. Parte dal punto di stacco dichiarato.
    final startGap = route.first.distanceTo(waypoints.first.meters);
    if (startGap > GttConfig.routeStartToleranceMeters) {
      failures.add(RouteValidationFailure(
        RouteValidationRule.start,
        'il percorso inizia a ${startGap.round()} m dal punto di stacco '
        'dichiarato (max ${GttConfig.routeStartToleranceMeters.round()} m)',
      ));
    }

    // 2. Arriva al punto di ricongiungimento.
    final endGap = route.last.distanceTo(waypoints.last.meters);
    if (endGap > GttConfig.routeEndToleranceMeters) {
      failures.add(RouteValidationFailure(
        RouteValidationRule.end,
        'il percorso finisce a ${endGap.round()} m dal punto di rientro '
        'dichiarato (max ${GttConfig.routeEndToleranceMeters.round()} m)',
      ));
    }

    // 3. Passa vicino a OGNI via nominata. Se ne salta una, ha preso
    //    un'altra strada e la deviazione mostrata sarebbe sbagliata.
    for (final via in requiredVias) {
      final d = Geometry.pointToPolyline(via.meters, route);
      if (d > GttConfig.routeViaToleranceMeters) {
        failures.add(RouteValidationFailure(
          RouteValidationRule.viaMissed,
          'il percorso non passa da una delle vie dichiarate: '
          'dista ${d.round()} m',
        ));
      }
    }

    // 4. La deviazione non e' spropositata rispetto al tratto che
    //    sostituisce. Il confronto NON e' con la linea d'aria fra stacco e
    //    rientro: molte deviazioni sono anelli che rientrano vicino a dove
    //    sono usciti, e verrebbero bocciate pur essendo giuste.
    final official = officialRoute.meters;
    final length = Geometry.length(route);
    final replaced = _replacedLength(route, official);
    final baseline = replaced < 200 ? 200.0 : replaced;
    if (length / baseline > GttConfig.routeMaxDetourRatio) {
      failures.add(RouteValidationFailure(
        RouteValidationRule.tooLong,
        'lungo ${(length / 1000).toStringAsFixed(1)} km per sostituire '
        '${(replaced / 1000).toStringAsFixed(1)} km di percorso normale '
        '(${(length / baseline).toStringAsFixed(1)}x, max '
        '${GttConfig.routeMaxDetourRatio.toStringAsFixed(0)}x)',
      ));
    }

    // 5. Esiste davvero un tratto fuori percorso.
    //    Non si misura la sovrapposizione totale: gli avvisi dicono spesso
    //    "prosegue per la stessa via", quindi condividere strada col
    //    percorso normale e' normale. Quello che distingue una deviazione
    //    vera e' un tratto CONTINUO fuori rotta.
    final detour = _longestOffRouteRun(route, official);
    if (detour < GttConfig.routeMinDetourMeters) {
      failures.add(RouteValidationFailure(
        RouteValidationRule.noDistinctDetour,
        'il tratto continuo fuori percorso e lungo solo '
        '${detour.round()} m (min ${GttConfig.routeMinDetourMeters.round()} m): '
        'coincide di fatto col percorso normale',
      ));
    }

    return failures;
  }

  /// Lunghezza del tratto di percorso normale che la deviazione sostituisce.
  ///
  /// Si proiettano gli estremi della deviazione sul percorso ufficiale e si
  /// misura quanto percorso c'e' fra i due punti.
  static double _replacedLength(List<Point> route, List<Point> official) {
    if (route.length < 2 || official.length < 2) return 0;
    final a = Geometry.projectOnPolyline(route.first, official);
    final b = Geometry.projectOnPolyline(route.last, official);
    return (b.alongMeters - a.alongMeters).abs();
  }

  /// Il piu' lungo tratto CONTINUO in cui il percorso calcolato sta fuori
  /// da quello ufficiale, in metri.
  ///
  /// Si campiona a passo costante invece di contare i vertici: i vertici
  /// sono distribuiti in modo irregolare, e un tratto lungo con pochi
  /// vertici peserebbe quanto uno corto con molti.
  static double _longestOffRouteRun(List<Point> route, List<Point> official) {
    if (route.length < 2 || official.length < 2) return 0;
    final samples = Geometry.densify(route, GttConfig.routeSampleMeters);
    var best = 0.0;
    var current = 0.0;
    for (var i = 0; i < samples.length; i++) {
      final off = Geometry.pointToPolyline(samples[i], official) >
          GttConfig.routeOverlapMeters;
      if (off) {
        if (i > 0) current += samples[i - 1].distanceTo(samples[i]);
        if (current > best) best = current;
      } else {
        current = 0;
      }
    }
    return best;
  }
}

enum RouteBuildStatus {
  /// Percorso calcolato e superate tutte le prove.
  ok,

  /// Calcolato ma una prova e' fallita: mostrarlo come certo sarebbe un
  /// falso positivo.
  validationFailed,

  /// Il motore non ha trovato un percorso.
  notRouted,

  /// Rete o servizio in errore. Ritentare puo' avere senso.
  error,
}

enum RouteValidationRule {
  start,
  end,
  viaMissed,
  tooLong,
  noDistinctDetour,
}

class RouteValidationFailure {
  const RouteValidationFailure(this.rule, this.message);

  final RouteValidationRule rule;
  final String message;

  @override
  String toString() => '${rule.name}: $message';
}

class RouteBuildResult {
  const RouteBuildResult({
    required this.status,
    this.geometry,
    this.lengthMeters,
    this.failures = const [],
    this.detail,
  });

  factory RouteBuildResult.notRouted(String detail) => RouteBuildResult(
      status: RouteBuildStatus.notRouted, detail: detail);

  factory RouteBuildResult.error(String detail) =>
      RouteBuildResult(status: RouteBuildStatus.error, detail: detail);

  final RouteBuildStatus status;
  final List<GeoPoint>? geometry;
  final double? lengthMeters;
  final List<RouteValidationFailure> failures;
  final String? detail;

  /// Utilizzabile per disegnare una mappa "certa".
  bool get isUsable => status == RouteBuildStatus.ok;

  /// C'e' una geometria, ma con riserva: si puo' mostrare accanto al testo
  /// originale segnalando l'incertezza, mai come dato affidabile.
  bool get hasGeometryWithDoubts =>
      status == RouteBuildStatus.validationFailed && geometry != null;

  @override
  String toString() => switch (status) {
        RouteBuildStatus.ok =>
          'OK ${(lengthMeters! / 1000).toStringAsFixed(2)} km, '
              '${geometry!.length} punti',
        RouteBuildStatus.validationFailed =>
          'DA VERIFICARE ${(lengthMeters! / 1000).toStringAsFixed(2)} km — '
              '${failures.join("; ")}',
        RouteBuildStatus.notRouted => 'NESSUN PERCORSO: $detail',
        RouteBuildStatus.error => 'ERRORE: $detail',
      };
}
