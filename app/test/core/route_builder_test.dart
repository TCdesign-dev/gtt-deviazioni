import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/net/gtt_http.dart';
import 'package:gtt_deviazioni/core/pipeline/route_builder.dart';

/// Un motore di routing risponde SEMPRE qualcosa, anche quando i punti che
/// gli hai dato non hanno senso. Le prove di §5.2.3 servono a distinguere
/// un percorso plausibile da uno accettato per inerzia, e qui si verifica
/// soprattutto che sappiano BOCCIARE.
///
/// Le polilinee sono state generate a parte con la libreria Python di
/// riferimento, non da questo codice.
void main() {
  // Percorso deviato: da Porta Nuova verso ovest, poi a nord. 2.443 m.
  const deviatoP6 = 'whk}tAogtsMoKnxOwQ~rN_dIf^owHf^';
  const deviatoStart = GeoPoint(45.0623, 7.6786);
  const deviatoEnd = GeoPoint(45.0730, 7.6610);

  // Percorso ufficiale: quasi dritto verso nord. 2.200 m.
  const ufficialeP6 = 'whk}tAogtsMgfFnd@_yFf^ozDff_@';

  final officialRoute = RouteShape(
    shapeId: 'UFF:0:01',
    routeId: 'TESTU',
    directionId: 0,
    headsign: 'PROVA',
    points: const [
      GeoPoint(45.0623, 7.6786),
      GeoPoint(45.0660, 7.6780),
      GeoPoint(45.0700, 7.6775),
      GeoPoint(45.0730, 7.6610),
    ],
  );

  String valhallaJson(String shape6) => jsonEncode({
        'trip': {
          'legs': [
            {'shape': shape6}
          ],
          'summary': {'length': 2.4},
        }
      });

  group('Decodifica della risposta', () {
    test('la polilinea di Valhalla e a precisione 6, non 5', () async {
      // Con precisione 5 il primo punto finisce a latitudine 450: da
      // nessuna parte. Non solleva eccezioni, produce solo una mappa vuota.
      final r = await RouteBuilder(http: _FakeHttp(valhallaJson(deviatoP6)))
          .build(
        waypoints: const [deviatoStart, deviatoEnd],
        officialRoute: officialRoute,
      );
      expect(r.geometry, isNotNull);
      expect(r.geometry!.first.lat, closeTo(45.0623, 1e-4));
      expect(r.geometry!.first.lon, closeTo(7.6786, 1e-4));
      expect(r.geometry!.last.lat, closeTo(45.0730, 1e-4));
      // Lunghezza calcolata a parte: 2.443 m.
      expect(r.lengthMeters, closeTo(2443, 30));
    });

    test('una risposta senza percorso non diventa una mappa vuota', () async {
      final r = await RouteBuilder(
              http: _FakeHttp(jsonEncode({'trip': {'legs': []}})))
          .build(
        waypoints: const [deviatoStart, deviatoEnd],
        officialRoute: officialRoute,
      );
      expect(r.status, equals(RouteBuildStatus.notRouted));
      expect(r.isUsable, isFalse);
    });

    test('un errore del servizio resta distinguibile', () async {
      final r = await RouteBuilder(http: _FailingHttp()).build(
        waypoints: const [deviatoStart, deviatoEnd],
        officialRoute: officialRoute,
      );
      expect(r.status, equals(RouteBuildStatus.error));
    });

    test('servono almeno due punti', () async {
      final r = await RouteBuilder(http: _FakeHttp('{}')).build(
        waypoints: const [deviatoStart],
        officialRoute: officialRoute,
      );
      expect(r.status, equals(RouteBuildStatus.notRouted));
    });
  });

  group('Le cinque prove di §5.2.3', () {
    test('un percorso coerente le supera tutte', () async {
      final r = await RouteBuilder(http: _FakeHttp(valhallaJson(deviatoP6)))
          .build(
        waypoints: const [deviatoStart, deviatoEnd],
        officialRoute: officialRoute,
        requiredVias: const [GeoPoint(45.0628, 7.6620)],
      );
      expect(r.failures, isEmpty, reason: r.toString());
      expect(r.status, equals(RouteBuildStatus.ok));
      expect(r.isUsable, isTrue);
    });

    test('1. boccia se non parte dal punto di stacco dichiarato', () async {
      final r = await RouteBuilder(http: _FakeHttp(valhallaJson(deviatoP6)))
          .build(
        // Stacco dichiarato lontanissimo da dove parte la geometria.
        waypoints: const [GeoPoint(45.0900, 7.7200), deviatoEnd],
        officialRoute: officialRoute,
      );
      expect(r.failures.map((f) => f.rule),
          contains(RouteValidationRule.start));
      expect(r.isUsable, isFalse);
      // La geometria c'e' comunque: si puo' mostrare come incerta.
      expect(r.hasGeometryWithDoubts, isTrue);
    });

    test('2. boccia se non arriva al punto di rientro', () async {
      final r = await RouteBuilder(http: _FakeHttp(valhallaJson(deviatoP6)))
          .build(
        waypoints: const [deviatoStart, GeoPoint(45.0400, 7.7300)],
        officialRoute: officialRoute,
      );
      expect(r.failures.map((f) => f.rule), contains(RouteValidationRule.end));
    });

    test('3. boccia se salta una via dichiarata', () async {
      // E' la prova piu' importante: se il motore ha preso un'altra strada,
      // la deviazione mostrata sarebbe semplicemente sbagliata.
      final r = await RouteBuilder(http: _FakeHttp(valhallaJson(deviatoP6)))
          .build(
        waypoints: const [deviatoStart, deviatoEnd],
        officialRoute: officialRoute,
        requiredVias: const [GeoPoint(45.0500, 7.7000)],
      );
      expect(r.failures.map((f) => f.rule),
          contains(RouteValidationRule.viaMissed));
    });

    test('4. boccia una deviazione spropositata rispetto al tratto '
        'che sostituisce', () async {
      // Percorso normale corto fra stacco e rientro: ~300 m. La deviazione
      // ne fa 2.443: oltre 8 volte tanto, non e' plausibile.
      final cortissimo = RouteShape(
        shapeId: 'CORTO:0:01',
        routeId: 'TESTU',
        directionId: 0,
        headsign: 'CORTO',
        points: const [
          GeoPoint(45.0623, 7.6786),
          GeoPoint(45.0650, 7.6786),
        ],
      );
      final r = await RouteBuilder(http: _FakeHttp(valhallaJson(deviatoP6)))
          .build(
        waypoints: const [deviatoStart, deviatoEnd],
        officialRoute: cortissimo,
      );
      expect(r.failures.map((f) => f.rule),
          contains(RouteValidationRule.tooLong));
    });

    test('5. boccia un percorso senza un tratto continuo fuori rotta', () async {
      // Se coincide col percorso normale non e' una deviazione, e
      // mostrarla come tale e' un falso positivo — il fallimento che §11.4
      // indica come il piu' grave.
      final r = await RouteBuilder(http: _FakeHttp(valhallaJson(ufficialeP6)))
          .build(
        waypoints: const [deviatoStart, deviatoEnd],
        officialRoute: officialRoute,
      );
      expect(r.failures.map((f) => f.rule),
          contains(RouteValidationRule.noDistinctDetour));
      expect(r.isUsable, isFalse);
    });

    test('il percorso deviato NON viene scambiato per coincidente', () async {
      // Controllo inverso della prova 5: deve distinguere, non bocciare
      // tutto. Il deviato condivide solo gli estremi con l'ufficiale.
      final r = await RouteBuilder(http: _FakeHttp(valhallaJson(deviatoP6)))
          .build(
        waypoints: const [deviatoStart, deviatoEnd],
        officialRoute: officialRoute,
      );
      expect(r.failures.map((f) => f.rule),
          isNot(contains(RouteValidationRule.noDistinctDetour)));
    });

    test('i fallimenti sono cumulativi e spiegati', () async {
      final r = await RouteBuilder(http: _FakeHttp(valhallaJson(deviatoP6)))
          .build(
        waypoints: const [GeoPoint(45.0900, 7.7200), GeoPoint(45.0400, 7.7300)],
        officialRoute: officialRoute,
      );
      expect(r.failures.length, greaterThanOrEqualTo(2));
      // Ogni messaggio deve dire QUANTO ha sbagliato, non solo che ha
      // sbagliato: serve a tarare le soglie sul campo.
      for (final f in r.failures) {
        expect(f.message, matches(RegExp(r'\d')));
      }
    });
  });
}

class _FakeHttp extends GttHttp {
  _FakeHttp(this.body);

  final String body;
  int calls = 0;

  @override
  Future<String> postJsonPolite(String url, Map<String, dynamic> body) async {
    calls++;
    return this.body;
  }
}

class _FailingHttp extends GttHttp {
  @override
  Future<String> postJsonPolite(String url, Map<String, dynamic> body) async =>
      throw GttHttpException(url, 502, 'Valhalla non disponibile');
}
