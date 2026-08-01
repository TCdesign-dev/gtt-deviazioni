import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/pipeline/route_excursion.dart';
import 'package:gtt_deviazioni/core/pipeline/vehicle_watch.dart';
import 'package:gtt_deviazioni/core/sources/vehicles_source.dart';

/// Percorso dritto verso est lungo la latitudine 45.070, da 7.6600 a
/// 7.6900: circa 2,3 km. Le tracce si costruiscono a mano perche' ogni
/// esito sia giusto per il motivo giusto — su dati reali non si saprebbe.
void main() {
  final percorso = [
    const GeoPoint(45.0700, 7.6600).meters,
    const GeoPoint(45.0700, 7.6900).meters,
  ];

  var orologio = DateTime(2026, 8, 1, 12);
  VehicleObservation obs(double lat, double lon, {int? secondi}) {
    orologio = orologio.add(Duration(seconds: secondi ?? 20));
    return VehicleObservation(
      vehicleId: 'v',
      routeId: 'TESTU',
      position: GeoPoint(lat, lon),
      seenAt: orologio,
    );
  }

  VehicleTrack traccia(String id, List<VehicleObservation> punti) {
    final t = VehicleTrack(id);
    for (final p in punti) {
      t.points.add(VehicleObservation(
          vehicleId: id,
          routeId: 'TESTU',
          position: p.position,
          seenAt: p.seenAt));
    }
    return t;
  }

  List<RouteExcursion> rileva(VehicleTrack t) => RouteExcursion.detect(
        track: t,
        officialRoute: percorso,
        offRouteMeters: 50,
      );

  group('Dove esce e dove rientra', () {
    test('un mezzo che esce e rientra da' ' entrambi gli estremi', () {
      // Sul percorso, poi 300 m a sud per due punti, poi di nuovo sopra.
      final t = traccia('A', [
        obs(45.0700, 7.6650),
        obs(45.0700, 7.6680),
        obs(45.0673, 7.6700), // fuori
        obs(45.0673, 7.6740), // fuori
        obs(45.0700, 7.6780), // rientrato
        obs(45.0700, 7.6820),
      ]);

      final e = rileva(t).single;
      expect(e.isComplete, isTrue);
      expect(e.path.length, equals(2));
      expect(e.maxDistanceMeters, greaterThan(250));
      // Lo stacco e' l'ultimo punto SUL percorso (7.6680), il rientro il
      // primo dopo (7.6780): non le proiezioni dei punti fuori rotta.
      expect(e.detachAlongMeters, closeTo(632, 40));
      expect(e.rejoinAlongMeters, closeTo(1420, 40));
      expect(e.spanMeters, closeTo(790, 60));
    });

    test('se non e ancora rientrato non si inventa dove lo fara', () {
      final t = traccia('A', [
        obs(45.0700, 7.6650),
        obs(45.0673, 7.6700),
        obs(45.0673, 7.6740),
      ]);

      final e = rileva(t).single;
      expect(e.isComplete, isFalse);
      expect(e.rejoinAlongMeters, isNull);
      expect(e.spanMeters, isNull);
      expect(e.toString(), contains('non ancora rientrato'));
    });

    test('un punto isolato fuori soglia non e una deviazione', () {
      // MISURATO: il 3% delle posizioni del feed e' spazzatura. Un solo
      // punto anomalo non deve produrre un'escursione.
      final t = traccia('A', [
        obs(45.0700, 7.6650),
        obs(45.0673, 7.6700), // uno solo
        obs(45.0700, 7.6740),
        obs(45.0700, 7.6780),
      ]);
      expect(rileva(t), isEmpty);
    });

    test('un mezzo sempre sul percorso non produce niente', () {
      final t = traccia('A', [
        obs(45.0700, 7.6650),
        obs(45.0700, 7.6700),
        obs(45.0700, 7.6750),
      ]);
      expect(rileva(t), isEmpty);
    });

    test('i punti fuori ordine non ingannano', () {
      // Il feed non garantisce l'ordine, e un'escursione ha un prima e un
      // dopo: senza riordinare, lo stacco e il rientro si scambiano.
      final punti = [
        obs(45.0700, 7.6650),
        obs(45.0673, 7.6700),
        obs(45.0673, 7.6740),
        obs(45.0700, 7.6780),
      ];
      final t = traccia('A', [punti[2], punti[0], punti[3], punti[1]]);

      final e = rileva(t).single;
      expect(e.isComplete, isTrue);
      expect(e.detachAlongMeters, lessThan(e.rejoinAlongMeters!));
    });

    test('una VARIANTE legittima non e una deviazione', () {
      // Il caso che si e' visto sul campo: la 65 aveva un mezzo su una
      // diramazione, lontano dal percorso principale ma sul suo. Senza
      // confrontarlo con TUTTE le varianti, l'esito diceva "tutti sul
      // percorso" e sotto compariva una deviazione inventata.
      final diramazione = [
        const GeoPoint(45.0700, 7.6650).meters,
        const GeoPoint(45.0660, 7.6700).meters,
        const GeoPoint(45.0660, 7.6760).meters,
        const GeoPoint(45.0700, 7.6800).meters,
      ];
      final t = traccia('A', [
        obs(45.0700, 7.6650),
        obs(45.0660, 7.6710), // sulla diramazione, non sul principale
        obs(45.0660, 7.6750), // idem
        obs(45.0700, 7.6800),
      ]);

      // Col solo percorso principale sembrerebbe una deviazione...
      expect(rileva(t), isNotEmpty);
      // ...ma sapendo che quella diramazione esiste, non lo e'.
      expect(
        RouteExcursion.detect(
          track: t,
          officialRoute: percorso,
          allRoutes: [percorso, diramazione],
          offRouteMeters: 50,
        ),
        isEmpty,
      );
    });

    test('fuori da TUTTE le varianti resta una deviazione', () {
      final diramazione = [
        const GeoPoint(45.0700, 7.6650).meters,
        const GeoPoint(45.0690, 7.6800).meters,
      ];
      final t = traccia('A', [
        obs(45.0700, 7.6650),
        obs(45.0620, 7.6700), // lontano da entrambe
        obs(45.0620, 7.6740),
        obs(45.0700, 7.6800),
      ]);

      expect(
        RouteExcursion.detect(
          track: t,
          officialRoute: percorso,
          allRoutes: [percorso, diramazione],
          offRouteMeters: 50,
        ),
        hasLength(1),
      );
    });

    test('due escursioni distinte nella stessa traccia', () {
      final t = traccia('A', [
        obs(45.0700, 7.6610),
        obs(45.0673, 7.6630),
        obs(45.0673, 7.6650),
        obs(45.0700, 7.6700), // rientro
        obs(45.0673, 7.6760),
        obs(45.0673, 7.6790),
        obs(45.0700, 7.6850), // rientro
      ]);
      expect(rileva(t).length, equals(2));
    });
  });

  group('Su cosa i mezzi sono d accordo', () {
    RouteExcursion esc(String id, double detach, double? rejoin,
            {int punti = 2}) =>
        RouteExcursion(
          vehicleId: id,
          detachAlongMeters: detach,
          rejoinAlongMeters: rejoin,
          path: [for (var i = 0; i < punti; i++) const GeoPoint(45.067, 7.67)],
          maxDistanceMeters: 300,
        );

    test('due mezzi che fanno la stessa cosa fanno consenso', () {
      final c = ExcursionConsensus.from([
        esc('A', 600, 1400),
        esc('B', 700, 1450),
      ])!;
      expect(c.vehicles, equals(2));
      expect(c.isSolid, isTrue);
      // Stacco piu' a monte, rientro piu' a valle: sbagliare per eccesso
      // segnala una fermata in piu' come dubbia, per difetto ne dichiara
      // una servita che non lo e'.
      expect(c.detachAlongMeters, equals(600));
      expect(c.rejoinAlongMeters, equals(1450));
    });

    test('un mezzo solo non e solido, ma si riporta lo stesso', () {
      // Puo' essere un guasto o un rientro in deposito. Non si nasconde:
      // si dice che e' uno solo.
      final c = ExcursionConsensus.from([esc('A', 600, 1400)])!;
      expect(c.vehicles, equals(1));
      expect(c.isSolid, isFalse);
    });

    test('due deviazioni diverse non si mescolano', () {
      // A esce al km 0,6 e B al km 5: sono due cose diverse, e il
      // consenso deve prendere la piu' numerosa, non fonderle.
      final c = ExcursionConsensus.from([
        esc('A', 600, 1400),
        esc('B', 700, 1450),
        esc('C', 5000, 5800),
      ])!;
      expect(c.vehicles, equals(2));
      expect(c.detachAlongMeters, equals(600));
      expect(c.rejoinAlongMeters, lessThan(2000));
    });

    test('se nessuno e rientrato il rientro resta ignoto', () {
      final c = ExcursionConsensus.from([
        esc('A', 600, null),
        esc('B', 650, null),
      ])!;
      expect(c.vehicles, equals(2));
      expect(c.rejoinAlongMeters, isNull);
    });

    test('nessuna escursione, nessun consenso', () {
      expect(ExcursionConsensus.from([]), isNull);
    });

    test('si tiene la traccia meglio campionata', () {
      final c = ExcursionConsensus.from([
        esc('A', 600, 1400, punti: 2),
        esc('B', 620, 1420, punti: 7),
      ])!;
      expect(c.path.length, equals(7));
    });
  });
}
