import 'dart:convert';
import 'dart:io';

import '../geo/projection.dart';
import '../models/transit.dart';
import '../pipeline/line_resolver.dart';
import 'csv.dart';

/// Costruisce un [GtfsIndex] dai file GTFS estratti, tenendo solo le linee
/// che interessano.
///
/// Perche' filtrare: il GTFS di GTT ha 223 linee, 77.000 corse e un
/// `stop_times.txt` da 147 MB. Su un telefono non ha senso tenerlo tutto.
/// Filtrando sulla watchlist restano poche centinaia di KB.
///
/// `stop_times.txt` va comunque **letto** per intero per trovare le righe
/// che servono, ma se ne conservano pochissime. E' l'unica parte lenta
/// (qualche secondo), e per questo c'e' [onProgress].
class GtfsParser {
  GtfsParser({required this.directory, this.onProgress});

  /// Cartella con i .txt gia' estratti.
  final Directory directory;

  /// Avvisa a che punto e' il caricamento: serve perche' un'attesa muta di
  /// dieci secondi sembra un blocco.
  final void Function(String phase, double fraction)? onProgress;

  static const _files = [
    'feed_info.txt',
    'routes.txt',
    'trips.txt',
    'shapes.txt',
    'stops.txt',
    'stop_times.txt',
  ];

  /// Tutti i nomi brevi presenti nel feed. Serve a caricare l'intera rete
  /// quando interessa solo risolvere i nomi delle linee.
  Future<List<String>> allShortNames() async {
    var cols = <String, int>{};
    final out = <String>[];
    await for (final row in _rows('routes.txt', (h) => cols = Csv.header(h))) {
      final s = Csv.field(row, cols, 'route_short_name');
      if (s != null) out.add(s);
    }
    return out;
  }

  /// [shortNames] sono i nomi come li usa la gente: "55", "4", "STAR 1".
  ///
  /// Con [withStops] a false si salta la lettura di `stop_times.txt`, che
  /// e' l'unica parte lenta (140 MB). Utile quando servono solo linee e
  /// geometrie, per esempio per risolvere il nome di una linea.
  Future<GtfsIndex> build(List<String> shortNames,
      {bool withStops = true}) async {
    final missing = _files
        .where((f) => !File('${directory.path}/$f').existsSync())
        .toList();
    if (missing.isNotEmpty) {
      throw GtfsParseException('file GTFS mancanti: ${missing.join(", ")}');
    }

    final wanted = shortNames.where((s) => s.trim().isNotEmpty).toList();

    _report('lettura linee', 0.05);
    final feedVersion = await _readFeedVersion();
    final lines = await _readRoutes(wanted);
    if (lines.isEmpty) {
      throw GtfsParseException(
          'nessuna linea corrisponde a ${shortNames.join(", ")}');
    }

    _report('lettura corse', 0.15);
    final trips = await _readTrips(lines.keys.toSet());

    _report('lettura geometrie', 0.35);
    final shapePoints = await _readShapes(trips.shapeIds);

    _report('lettura fermate', 0.5);
    final stops = await _readStops();

    var stopSeq = <String, List<String>>{};
    if (withStops) {
      _report('lettura orari', 0.6);
      stopSeq = await _readStopTimes(trips.representativeTrips);
    }

    _report('composizione', 0.95);
    final shapes = <String, List<RouteShape>>{};
    for (final meta in trips.shapes.values) {
      final pts = shapePoints[meta.shapeId];
      if (pts == null || pts.length < 2) continue;
      final stopIds = stopSeq[meta.shapeId] ?? const <String>[];
      final shape = RouteShape(
        shapeId: meta.shapeId,
        routeId: meta.routeId,
        directionId: meta.directionId,
        headsign: meta.headsign,
        points: pts,
        tripCount: meta.tripCount,
        stops: stopIds
            .map((id) => stops[id])
            .whereType<TransitStop>()
            .toList(growable: false),
      );
      (shapes[meta.routeId] ??= []).add(shape);
    }

    _report('pronto', 1.0);
    return GtfsIndex(
      feedVersion: feedVersion,
      builtAt: DateTime.now(),
      lines: lines,
      shapes: shapes,
      stops: stops,
    );
  }

  void _report(String phase, double f) => onProgress?.call(phase, f);

  /// [keepFirstField] e' un filtro rapido sul PRIMO campo, applicato prima
  /// dello split completo. Su `stop_times.txt` (2,3 milioni di righe, ~200
  /// utili) fa la differenza fra decine di secondi e pochi.
  Stream<List<String>> _rows(
    String file,
    Map<String, int> Function(String) onHeader, {
    bool Function(String firstField)? keepFirstField,
  }) async* {
    var isHeader = true;
    final stream = File('${directory.path}/$file')
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final line in stream) {
      if (line.isEmpty) continue;
      if (isHeader) {
        onHeader(line);
        isHeader = false;
        continue;
      }
      if (keepFirstField != null) {
        final f = Csv.firstField(line);
        if (f == null || !keepFirstField(f)) continue;
      }
      yield Csv.split(line);
    }
  }

  Future<String?> _readFeedVersion() async {
    var cols = <String, int>{};
    await for (final row in _rows('feed_info.txt', (h) => cols = Csv.header(h))) {
      return Csv.field(row, cols, 'feed_version');
    }
    return null;
  }

  /// Le linee chieste, riconosciute con le STESSE regole degli avvisi.
  ///
  /// Si legge tutto `routes.txt` — sono poche centinaia di righe — e poi
  /// si sceglie con [LineResolver.matchIn]. Prima il confronto era fatto
  /// qui, a mano, con un semplice maiuscolo-senza-spazi: chi scriveva
  /// "10N" non trovava la N10, "N8" non trovava la N08, "58 barrata" non
  /// trovava la 58/. Le regole erano gia' scritte, ma da un'altra parte.
  Future<Map<String, TransitLine>> _readRoutes(List<String> wanted) async {
    var cols = <String, int>{};
    final all = <TransitLine>[];
    await for (final row in _rows('routes.txt', (h) => cols = Csv.header(h))) {
      final short = Csv.field(row, cols, 'route_short_name');
      final id = Csv.field(row, cols, 'route_id');
      if (short == null || id == null) continue;
      all.add(TransitLine(
        routeId: id,
        shortName: short,
        longName: Csv.field(row, cols, 'route_long_name'),
        color: Csv.field(row, cols, 'route_color'),
      ));
    }

    final out = <String, TransitLine>{};
    for (final name in wanted) {
      final line = LineResolver.matchIn(all, name);
      if (line != null) out[line.routeId] = line;
    }
    return out;
  }

  Future<_Trips> _readTrips(Set<String> routeIds) async {
    var cols = <String, int>{};
    final shapes = <String, _ShapeMeta>{};
    final repr = <String, String>{}; // shapeId -> tripId rappresentativo

    await for (final row in _rows(
      'trips.txt',
      (h) => cols = Csv.header(h),
      keepFirstField: routeIds.contains,
    )) {
      final routeId = Csv.field(row, cols, 'route_id');
      if (routeId == null || !routeIds.contains(routeId)) continue;
      final shapeId = Csv.field(row, cols, 'shape_id');
      final tripId = Csv.field(row, cols, 'trip_id');
      if (shapeId == null || tripId == null) continue;

      final meta = shapes.putIfAbsent(
        shapeId,
        () => _ShapeMeta(
          shapeId: shapeId,
          routeId: routeId,
          directionId: int.tryParse(Csv.field(row, cols, 'direction_id') ?? '') ?? 0,
          headsign: Csv.field(row, cols, 'trip_headsign') ?? '',
        ),
      );
      meta.tripCount++;
      // Una corsa qualsiasi basta a dare la sequenza fermate: sono tutte
      // uguali dentro la stessa shape. Si prende la minore per rendere il
      // risultato riproducibile fra un caricamento e l'altro.
      final cur = repr[shapeId];
      if (cur == null || tripId.compareTo(cur) < 0) repr[shapeId] = tripId;
    }
    return _Trips(shapes, {for (final e in repr.entries) e.value: e.key});
  }

  Future<Map<String, List<GeoPoint>>> _readShapes(Set<String> shapeIds) async {
    var cols = <String, int>{};
    final raw = <String, List<(int, GeoPoint)>>{};
    await for (final row in _rows(
      'shapes.txt',
      (h) => cols = Csv.header(h),
      keepFirstField: shapeIds.contains,
    )) {
      final id = Csv.field(row, cols, 'shape_id');
      if (id == null || !shapeIds.contains(id)) continue;
      final lat = double.tryParse(Csv.field(row, cols, 'shape_pt_lat') ?? '');
      final lon = double.tryParse(Csv.field(row, cols, 'shape_pt_lon') ?? '');
      final seq = int.tryParse(Csv.field(row, cols, 'shape_pt_sequence') ?? '');
      if (lat == null || lon == null || seq == null) continue;
      (raw[id] ??= []).add((seq, GeoPoint(lat, lon)));
    }
    return {
      for (final e in raw.entries)
        e.key: (e.value..sort((a, b) => a.$1.compareTo(b.$1)))
            .map((p) => p.$2)
            .toList(growable: false)
    };
  }

  /// Tutte le fermate, non solo quelle delle linee scelte: servono per
  /// proporre alternative servite da ALTRE linee (§6.1).
  Future<Map<String, TransitStop>> _readStops() async {
    var cols = <String, int>{};
    final out = <String, TransitStop>{};
    await for (final row in _rows('stops.txt', (h) => cols = Csv.header(h))) {
      final id = Csv.field(row, cols, 'stop_id');
      final lat = double.tryParse(Csv.field(row, cols, 'stop_lat') ?? '');
      final lon = double.tryParse(Csv.field(row, cols, 'stop_lon') ?? '');
      if (id == null || lat == null || lon == null) continue;
      out[id] = TransitStop(
        id: id,
        code: Csv.field(row, cols, 'stop_code'),
        name: Csv.field(row, cols, 'stop_name') ?? id,
        position: GeoPoint(lat, lon),
      );
    }
    return out;
  }

  /// L'unica lettura pesante: 147 MB da scorrere per tenerne pochi KB.
  Future<Map<String, List<String>>> _readStopTimes(
      Map<String, String> tripToShape) async {
    var cols = <String, int>{};
    final raw = <String, List<(int, String)>>{};
    await for (final row in _rows(
      'stop_times.txt',
      (h) => cols = Csv.header(h),
      keepFirstField: tripToShape.containsKey,
    )) {
      final tripId = Csv.field(row, cols, 'trip_id');
      if (tripId == null) continue;
      final shapeId = tripToShape[tripId];
      if (shapeId == null) continue;
      final stopId = Csv.field(row, cols, 'stop_id');
      final seq = int.tryParse(Csv.field(row, cols, 'stop_sequence') ?? '');
      if (stopId == null || seq == null) continue;
      (raw[shapeId] ??= []).add((seq, stopId));
    }
    return {
      for (final e in raw.entries)
        e.key: (e.value..sort((a, b) => a.$1.compareTo(b.$1)))
            .map((p) => p.$2)
            .toList(growable: false)
    };
  }

}

class _ShapeMeta {
  _ShapeMeta({
    required this.shapeId,
    required this.routeId,
    required this.directionId,
    required this.headsign,
  });

  final String shapeId;
  final String routeId;
  final int directionId;
  final String headsign;
  int tripCount = 0;
}

class _Trips {
  _Trips(this.shapes, this.representativeTrips);

  final Map<String, _ShapeMeta> shapes;

  /// tripId -> shapeId, per le sole corse rappresentative.
  final Map<String, String> representativeTrips;

  Set<String> get shapeIds => shapes.keys.toSet();
}

class GtfsParseException implements Exception {
  GtfsParseException(this.message);

  final String message;

  @override
  String toString() => 'GtfsParseException: $message';
}
