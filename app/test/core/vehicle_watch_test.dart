import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/pipeline/vehicle_watch.dart';
import 'package:gtt_deviazioni/core/sources/vehicles_source.dart';

/// Il rischio di questa funzione e' il falso positivo: dire "il mezzo sta
/// deviando" quando invece sta facendo una variante di percorso, o quando
/// il GPS ha pubblicato spazzatura. I test provano soprattutto quello.
void main() {
  const line = TransitLine(routeId: 'TESTU', shortName: 'T');

  // Percorso principale: dritto verso est lungo la latitudine 45.070.
  final principale = RouteShape(
    shapeId: 'T:0:01',
    routeId: 'TESTU',
    directionId: 0,
    headsign: 'PRINCIPALE',
    points: const [GeoPoint(45.0700, 7.6600), GeoPoint(45.0700, 7.6900)],
  );

  // Variante legittima: la corsa limitata, che scende a sud.
  final variante = RouteShape(
    shapeId: 'T:0:02',
    routeId: 'TESTU',
    directionId: 0,
    headsign: 'LIMITATA',
    points: const [GeoPoint(45.0700, 7.6600), GeoPoint(45.0600, 7.6750)],
  );

  VehicleObservation obs(String id, double lat, double lon, int second) =>
      VehicleObservation(
        vehicleId: id,
        routeId: 'TESTU',
        position: GeoPoint(lat, lon),
        seenAt: DateTime(2026, 8, 1, 10, 0, second),
      );

  Future<WatchResult> run(
    List<List<VehicleObservation>> samples, {
    List<RouteShape>? shapes,
  }) =>
      VehicleWatch(
        source: _ScriptedSource(samples),
        pollInterval: Duration.zero,
        maxDuration: const Duration(seconds: 5),
      ).watch(line: line, shapes: shapes ?? [principale]);

  test('mezzi sul percorso: nessun allarme', () async {
    final r = await run([
      [obs('A', 45.0700, 7.6700, 0), obs('B', 45.0700, 7.6800, 0)],
      [obs('A', 45.0700, 7.6710, 30), obs('B', 45.0700, 7.6810, 30)],
    ]);
    expect(r.outcome, equals(WatchOutcome.tuttiSulPercorso));
    expect(r.vehiclesSeen, equals(2));
    expect(r.offRoute, isEmpty);
    expect(r.summary, contains('percorso normale'));
  });

  test('mezzi lontani dal percorso: deviazione in corso', () async {
    // ~330 m a sud del percorso principale.
    final r = await run([
      [obs('A', 45.0670, 7.6700, 0)],
      [obs('A', 45.0670, 7.6750, 30)],
      [obs('A', 45.0670, 7.6800, 60)],
    ]);
    expect(r.outcome, equals(WatchOutcome.fuoriPercorso));
    expect(r.offRoute.length, equals(1));
    expect(r.maxDistance, greaterThan(200));
    expect(r.summary, contains('fuori dal percorso'));
  });

  test('una VARIANTE legittima non e una deviazione', () async {
    // Stesso mezzo, stessa posizione del test precedente: ma se la linea
    // ha una corsa limitata che passa di li', non sta deviando affatto.
    // E' il falso positivo che §5.3.2 mette in guardia dal produrre.
    final r = await run(
      [
        [obs('A', 45.0650, 7.6675, 0)],
        [obs('A', 45.0630, 7.6700, 30)],
      ],
      shapes: [principale, variante],
    );
    expect(r.outcome, equals(WatchOutcome.tuttiSulPercorso),
        reason: 'il mezzo segue la variante, non sta deviando');
  });

  test('nessun mezzo NON significa "tutto regolare"', () async {
    // La distinzione che conta: di notte o su una linea scarica non c'e'
    // nulla da guardare, e dire "tutto bene" sarebbe inventare.
    final r = await run([[], []]);
    expect(r.outcome, equals(WatchOutcome.nessunMezzo));
    expect(r.summary, contains('non posso dire nulla'));
    expect(r.summary, isNot(contains('normale')));
  });

  test('se la linea non ha mezzi, smette presto invece di insistere',
      () async {
    final source = _ScriptedSource([[], [], [], [], [], [], []]);
    final r = await VehicleWatch(
      source: source,
      pollInterval: Duration.zero,
      maxDuration: const Duration(seconds: 30),
    ).watch(line: line, shapes: [principale]);
    expect(r.outcome, equals(WatchOutcome.nessunMezzo));
    expect(source.calls, lessThanOrEqualTo(3),
        reason: 'insistere non cambierebbe la risposta');
  });

  test('un solo punto per mezzo non basta a concludere', () async {
    final r = await run([
      [obs('A', 45.0700, 7.6700, 0)],
    ]);
    expect(r.outcome, equals(WatchOutcome.inconcludente));
    expect(r.summary, contains('troppo poco tempo'));
  });

  test('un singolo punto anomalo non fa scattare l allarme', () async {
    // GPS impazzito per un istante: servono almeno due punti fuori rotta.
    final r = await run([
      [obs('A', 45.0700, 7.6700, 0)],
      [obs('A', 45.0670, 7.6750, 30)], // uno solo, lontano
      [obs('A', 45.0700, 7.6800, 60)],
    ]);
    expect(r.outcome, equals(WatchOutcome.tuttiSulPercorso));
  });

  test('lo stesso timestamp non conta due volte', () async {
    // Il feed si aggiorna ogni ~20 s: interrogandolo piu' spesso si
    // riceve due volte la stessa posizione, che non e' un punto nuovo.
    final r = await run([
      [obs('A', 45.0700, 7.6700, 0)],
      [obs('A', 45.0700, 7.6700, 0)],
      [obs('A', 45.0700, 7.6700, 0)],
    ]);
    expect(r.tracks.single.points.length, equals(1));
    expect(r.outcome, equals(WatchOutcome.inconcludente));
  });

  test('si ferma appena ha abbastanza mezzi', () async {
    final source = _ScriptedSource([
      [obs('A', 45.0700, 7.6700, 0), obs('B', 45.0700, 7.6800, 0)],
      [obs('A', 45.0700, 7.6710, 30), obs('B', 45.0700, 7.6810, 30)],
      [obs('A', 45.0700, 7.6720, 60)], // non dovrebbe servire
    ]);
    final r = await VehicleWatch(
      source: source,
      pollInterval: Duration.zero,
      maxDuration: const Duration(seconds: 5),
    ).watch(line: line, shapes: [principale]);
    expect(r.samples, equals(2), reason: 'inutile continuare a interrogare');
    expect(source.calls, equals(2));
  });
}

/// Sorgente con risposte preparate: un campione per chiamata.
class _ScriptedSource implements VehiclesSource {
  _ScriptedSource(this.samples);

  final List<List<VehicleObservation>> samples;
  int calls = 0;

  @override
  Future<List<VehicleObservation>> fetch({String? routeId}) async {
    final s = calls < samples.length ? samples[calls] : const <VehicleObservation>[];
    calls++;
    return s;
  }

  @override
  List<VehicleObservation> parse(List<int> bytes, {String? routeId}) =>
      throw UnimplementedError();
}
