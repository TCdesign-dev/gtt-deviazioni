import '../geo/geometry.dart';
import '../geo/projection.dart';

/// Una linea GTT.
class TransitLine {
  const TransitLine({
    required this.routeId,
    required this.shortName,
    this.longName,
    this.color,
  });

  /// Identificatore del GTFS: "55U", "19U", "58BU".
  final String routeId;

  /// Come la chiama la gente: "55", "58 /", "STAR 1".
  final String shortName;
  final String? longName;

  /// Colore ufficiale, per disegnarla sulla mappa.
  final String? color;

  @override
  String toString() => '$shortName ($routeId)';
}

/// Una fermata.
class TransitStop {
  const TransitStop({
    required this.id,
    required this.name,
    required this.position,
    this.code,
  });

  final String id;

  /// Il numero che l'utente vede sul palo. E' questo che GTT cita negli
  /// avvisi ("fermata n. 1182"), non l'id interno.
  final String? code;
  final String name;
  final GeoPoint position;

  @override
  String toString() => code != null ? '$name [$code]' : name;
}

/// Una variante di percorso: linea + direzione + variante.
///
/// E' l'unita' su cui ragiona tutto il sistema. La specifica (§10.9) e'
/// esplicita: **mai modellare una deviazione a livello di linea**, perche'
/// quasi tutte sono asimmetriche fra andata e ritorno.
class RouteShape {
  RouteShape({
    required this.shapeId,
    required this.routeId,
    required this.directionId,
    required this.headsign,
    required this.points,
    this.stops = const [],
    this.tripCount = 0,
  });

  /// "55UDi55RA4". Le shape con suffisso numerico ("55UDi37713") sembrano
  /// essere le varianti temporanee create da GTT per le deviazioni.
  final String shapeId;
  final String routeId;

  /// 0 = andata, 1 = ritorno, secondo il GTFS.
  final int directionId;

  /// Dove va: "GERBIDO, VIA MONCALIERI".
  final String headsign;

  /// La geometria del percorso.
  final List<GeoPoint> points;

  /// Le fermate, in ordine di percorrenza.
  List<TransitStop> stops;

  /// Quante corse usano questa variante. Serve a distinguere il percorso
  /// principale (centinaia di corse) dalle varianti rare (poche decine).
  int tripCount;

  /// La fermata piu' vicina a un punto del percorso, misurato in metri
  /// dall'inizio.
  ///
  /// Serve a dire le cose come le direbbe una persona: "escono dopo
  /// Sabotino" invece di "escono al metro 1420". Nessuno sa dove sia il
  /// metro 1420, tutti sanno dov'e' Sabotino.
  TransitStop? stopNearestAlong(double alongMeters) {
    if (stops.isEmpty || points.length < 2) return null;
    final linea = meters;
    TransitStop? migliore;
    var minimo = double.infinity;
    for (final s in stops) {
      final a = Geometry.projectOnPolyline(s.position.meters, linea).alongMeters;
      final d = (a - alongMeters).abs();
      if (d < minimo) {
        minimo = d;
        migliore = s;
      }
    }
    return migliore;
  }

  List<Point>? _metersCache;

  /// La geometria in metri, calcolata una volta sola.
  List<Point> get meters =>
      _metersCache ??= points.map((p) => p.meters).toList(growable: false);

  double get lengthMeters => Geometry.length(meters);

  /// Riquadro attorno al percorso, allargato di [paddingMeters].
  /// E' il vincolo spaziale del geocoding (§5.2.2).
  Bounds boundsWithPadding(double paddingMeters) =>
      Geometry.boundsOf(points, paddingMeters: paddingMeters);

  GeoPoint get centroid => Geometry.centroid(points);

  /// Distanza di un punto da questo percorso, in metri.
  double distanceTo(GeoPoint p) => Geometry.pointToPolyline(p.meters, meters);

  @override
  String toString() =>
      '$shapeId dir$directionId "$headsign" (${points.length} pt, '
      '${stops.length} fermate, $tripCount corse)';
}

/// Tutto il GTFS che serve, in memoria, limitato alle linee che interessano.
///
/// Non si carica l'intera rete: 223 linee e 77.000 corse non servono a
/// nessuno su un telefono. Si tengono solo le linee della watchlist.
class GtfsIndex {
  GtfsIndex({
    required this.feedVersion,
    required this.builtAt,
    required this.lines,
    required this.shapes,
    required this.stops,
  });

  /// Versione del feed GTT, es. "20260731". Cambia ogni giorno.
  final String? feedVersion;
  final DateTime builtAt;

  /// routeId -> linea
  final Map<String, TransitLine> lines;

  /// routeId -> varianti di percorso
  final Map<String, List<RouteShape>> shapes;

  /// stopId -> fermata
  final Map<String, TransitStop> stops;

  bool get isEmpty => lines.isEmpty;

  /// Cerca una linea dal nome che usa la gente ("55", "58 /").
  /// Confronto normalizzato: maiuscole e spazi non contano.
  TransitLine? lineByShortName(String shortName) {
    final want = _normalize(shortName);
    for (final l in lines.values) {
      if (_normalize(l.shortName) == want) return l;
    }
    return null;
  }

  List<RouteShape> shapesOf(String routeId) => shapes[routeId] ?? const [];

  /// La variante principale per una direzione: quella con piu' corse.
  /// Le altre sono limitazioni, corse scolastiche, varianti rare.
  RouteShape? mainShape(String routeId, int directionId) {
    final candidates =
        shapesOf(routeId).where((s) => s.directionId == directionId).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.tripCount.compareTo(a.tripCount));
    return candidates.first;
  }

  /// Fermate entro [radiusMeters] da un punto, dalla piu' vicina.
  /// Serve a proporre le alternative a una fermata saltata (§6.1).
  List<({TransitStop stop, double meters})> stopsNear(
    GeoPoint p, {
    double radiusMeters = 400,
  }) {
    final origin = p.meters;
    final out = <({TransitStop stop, double meters})>[];
    for (final s in stops.values) {
      final d = origin.distanceTo(s.position.meters);
      if (d <= radiusMeters) out.add((stop: s, meters: d));
    }
    out.sort((a, b) => a.meters.compareTo(b.meters));
    return out;
  }

  static String _normalize(String s) =>
      s.toUpperCase().replaceAll(' ', '').trim();

  @override
  String toString() => 'GtfsIndex(feed $feedVersion, ${lines.length} linee, '
      '${shapes.values.fold(0, (n, l) => n + l.length)} varianti, '
      '${stops.length} fermate)';
}
