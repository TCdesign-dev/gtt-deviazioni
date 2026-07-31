import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/pipeline/rejoin_inference.dart';

/// Il rischio qui e' piazzare il rientro nel posto sbagliato e mostrare una
/// deviazione che finisce dove non finisce. I test insistono sui casi in
/// cui la deduzione NON va fatta.
void main() {
  // Percorso dritto verso est lungo la latitudine 45.070, ~2,3 km.
  // 0.001 gradi di longitudine a Torino sono ~79 m.
  final dritto = RouteShape(
    shapeId: 'T:0:01',
    routeId: 'TESTU',
    directionId: 0,
    headsign: 'PROVA',
    points: const [
      GeoPoint(45.0700, 7.6600),
      GeoPoint(45.0700, 7.6900),
    ],
  );

  group('Deduzione riuscita', () {
    test('l ultima via sul percorso diventa il punto di rientro', () {
      // Caso normale, e MISURATO come tale: l'ultima via nominata prima di
      // "percorso normale" giace sul percorso, mediana 1 m.
      final r = RejoinInference.infer(
        officialRoute: dritto,
        detachPoint: const GeoPoint(45.0700, 7.6650),
        lastVia: const GeoPoint(45.0701, 7.6800), // ~11 m dal percorso
      );

      expect(r.source, equals(RejoinSource.dedotto));
      expect(r.isUsable, isTrue);
      expect(r.metersFromRoute, lessThan(20));
      // Il punto sta ESATTAMENTE sul percorso, non semplicemente vicino:
      // "percorso normale" significa proprio quello.
      expect(r.point!.lat, closeTo(45.0700, 1e-6));
      expect(r.point!.lon, closeTo(7.6800, 1e-4));
    });

    test('il rientro sta a valle dello stacco', () {
      final r = RejoinInference.infer(
        officialRoute: dritto,
        detachPoint: const GeoPoint(45.0700, 7.6650),
        lastVia: const GeoPoint(45.0700, 7.6800),
      );
      expect(r.alongMeters, greaterThan(0));
      // Lo stacco e' a ~395 m dall'inizio, il rientro a ~1580 m.
      expect(r.alongMeters, greaterThan(400));
    });
  });

  group('Quando NON si deve dedurre', () {
    test('una via troppo lontana dal percorso non basta', () {
      // E' il caso della linea 7 con "corso Vittorio Emanuele II" a 310 m:
      // via lunghissima, punto geocodificato lontano da dove la linea la
      // incontra. Dedurre da li' metterebbe il rientro altrove.
      final r = RejoinInference.infer(
        officialRoute: dritto,
        detachPoint: const GeoPoint(45.0700, 7.6650),
        lastVia: const GeoPoint(45.0740, 7.6800), // ~445 m a nord
      );

      expect(r.source, equals(RejoinSource.nonDeducibile));
      expect(r.isUsable, isFalse);
      // E dice QUANTO era lontana, cosi' si capisce perche'.
      expect(r.whyNot, contains('dista'));
      expect(r.metersFromRoute, greaterThan(300));
    });

    test('la soglia e configurabile e cambia davvero l esito', () {
      const lastVia = GeoPoint(45.0715, 7.6800); // ~167 m
      expect(
        RejoinInference.infer(
                officialRoute: dritto,
                detachPoint: const GeoPoint(45.0700, 7.6650),
                lastVia: lastVia,
                maxViaDistance: 50)
            .isUsable,
        isFalse,
      );
      expect(
        RejoinInference.infer(
                officialRoute: dritto,
                detachPoint: const GeoPoint(45.0700, 7.6650),
                lastVia: lastVia,
                maxViaDistance: 500)
            .isUsable,
        isTrue,
      );
    });

    test('se dopo lo stacco non c e piu percorso, lo dichiara', () {
      // Stacco al capolinea: non c'e' nulla a valle in cui rientrare.
      final r = RejoinInference.infer(
        officialRoute: dritto,
        detachPoint: const GeoPoint(45.0700, 7.6900),
        lastVia: const GeoPoint(45.0700, 7.6800),
      );
      expect(r.source, equals(RejoinSource.nonDeducibile));
      expect(r.whyNot, contains('percorso'));
    });

    test('un percorso degenere non fa esplodere nulla', () {
      final degenere = RouteShape(
        shapeId: 'X',
        routeId: 'X',
        directionId: 0,
        headsign: '',
        points: const [GeoPoint(45.07, 7.68)],
      );
      final r = RejoinInference.infer(
        officialRoute: degenere,
        detachPoint: const GeoPoint(45.07, 7.68),
        lastVia: const GeoPoint(45.07, 7.69),
      );
      expect(r.isUsable, isFalse);
    });
  });

  group('Percorsi che ripassano vicino a se stessi', () {
    // Andata verso est e ritorno verso ovest, 20 m piu' a nord: una via
    // vicina al punto di stacco e' vicina a ENTRAMBI i passaggi.
    final andataERitorno = RouteShape(
      shapeId: 'T:0:02',
      routeId: 'TESTU',
      directionId: 0,
      headsign: 'ANELLO',
      points: const [
        GeoPoint(45.0700, 7.6600),
        GeoPoint(45.0700, 7.6900),
        GeoPoint(45.0702, 7.6900),
        GeoPoint(45.0702, 7.6600),
      ],
    );

    test('sceglie il passaggio a valle, non quello gia fatto', () {
      // L'ultima via e' vicina all'andata (che il mezzo ha gia' percorso)
      // e al ritorno. Il rientro e' quello dopo lo stacco.
      final r = RejoinInference.infer(
        officialRoute: andataERitorno,
        detachPoint: const GeoPoint(45.0700, 7.6850),
        lastVia: const GeoPoint(45.0701, 7.6700),
      );
      expect(r.isUsable, isTrue);
      // L'andata finisce a ~2374 m: il rientro deve stare oltre.
      expect(r.alongMeters, greaterThan(2374));
    });
  });
}
