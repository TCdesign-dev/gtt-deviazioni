import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/pipeline/stop_impact.dart';

/// La geometria di prova e' costruita a mano perche' ogni fermata sia in
/// una posizione voluta rispetto alla deviazione. Su dati reali non si
/// saprebbe mai se un esito e' giusto per il motivo giusto.
///
///   percorso ufficiale: dritto verso est lungo la latitudine 45.070
///   deviazione:         esce a 1/3, scende a sud, rientra a 2/3
///
///   A----B----C--------D----E----F        A,B,F fuori dal tratto
///             \       /                   C,D,E dentro
///              c----d                     C,D,E lontane dalla deviata
void main() {
  // ~0.001 gradi di longitudine a Torino sono ~79 m.
  TransitStop stop(String code, double lat, double lon) => TransitStop(
        id: 'S$code',
        code: code,
        name: 'Fermata $code',
        position: GeoPoint(lat, lon),
      );

  final officialRoute = RouteShape(
    shapeId: 'UFF:0:01',
    routeId: 'TESTU',
    directionId: 0,
    headsign: 'PROVA',
    points: const [
      GeoPoint(45.0700, 7.6600),
      GeoPoint(45.0700, 7.6900),
    ],
    stops: [
      stop('100', 45.0700, 7.6610), // A — prima della deviazione
      stop('200', 45.0700, 7.6650), // B — prima
      stop('300', 45.0700, 7.6710), // C — dentro il tratto
      stop('400', 45.0700, 7.6750), // D — dentro
      stop('500', 45.0700, 7.6790), // E — dentro
      stop('600', 45.0700, 7.6880), // F — dopo la deviazione
    ],
  );

  // La deviazione scende di ~0.003 gradi di latitudine, ~330 m a sud.
  const deviata = [
    GeoPoint(45.0700, 7.6700),
    GeoPoint(45.0670, 7.6720),
    GeoPoint(45.0670, 7.6780),
    GeoPoint(45.0700, 7.6800),
  ];

  // Fermate vicine, per le alternative.
  final index = GtfsIndex(
    feedVersion: 'test',
    builtAt: DateTime(2026),
    lines: {'TESTU': const TransitLine(routeId: 'TESTU', shortName: 'T')},
    shapes: {'TESTU': [officialRoute]},
    stops: {
      for (final s in officialRoute.stops) s.id: s,
      // Fermata di un'altra linea, a ~110 m dalla D.
      'S900': stop('900', 45.0710, 7.6750),
      // Fermata lontanissima: non deve mai comparire.
      'S999': stop('999', 45.1200, 7.7500),
    },
  );

  final analyzer = StopImpactAnalyzer(index: index);

  group('Quale porzione di linea e interessata', () {
    test('le fermate FUORI dal tratto deviato non vengono toccate', () {
      // E' l'errore piu' facile da fare: il percorso deviato copre solo il
      // tratto della deviazione, quindi misurare la distanza da esso per
      // OGNI fermata segnerebbe come saltate anche quelle a chilometri.
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: deviata,
      );
      final codes = r.impacts.map((i) => i.stop.code).toList();
      expect(codes, isNot(contains('100')));
      expect(codes, isNot(contains('200')));
      expect(codes, isNot(contains('600')));
    });

    test('valuta solo le fermate dentro il tratto', () {
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: deviata,
      );
      expect(r.impacts.map((i) => i.stop.code), containsAll(['300', '400', '500']));
      expect(r.impacts.length, equals(3));
    });

    test('riporta da dove a dove agisce la deviazione', () {
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: deviata,
      );
      expect(r.affectedFromMeters, lessThan(r.affectedToMeters));
      // Da 7.6700 a 7.6800 sono ~790 m di percorso ufficiale.
      expect(r.affectedToMeters - r.affectedFromMeters, closeTo(790, 60));
    });
  });

  group('Servita o saltata', () {
    test('le fermate lontane dal percorso deviato risultano saltate', () {
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: deviata,
      );
      expect(r.skipped.map((i) => i.stop.code), containsAll(['300', '400', '500']));
      expect(r.hasImpact, isTrue);
    });

    test('una fermata che la deviazione sfiora resta servita', () {
      // Deviazione che scende di pochissimo: passa a ~11 m dalle fermate,
      // sotto la soglia dei 40 m.
      const quasiDritta = [
        GeoPoint(45.0700, 7.6700),
        GeoPoint(45.0699, 7.6750),
        GeoPoint(45.0700, 7.6800),
      ];
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: quasiDritta,
      );
      expect(r.skipped, isEmpty, reason: r.impacts.join('\n'));
      expect(r.served.length, equals(3));
    });

    test('nessuna deviazione, nessun impatto', () {
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: const [],
      );
      expect(r.impacts, isEmpty);
      expect(r.hasImpact, isFalse);
    });
  });

  group('La dichiarazione di GTT batte la geometria', () {
    test('una fermata dichiarata sospesa lo resta anche se la deviata '
        'le passa accanto', () {
      // §6.1: passare accanto non significa fermarsi. Se GTT dice che e'
      // sospesa, lo sa meglio di un calcolo di distanze.
      const quasiDritta = [
        GeoPoint(45.0700, 7.6700),
        GeoPoint(45.0699, 7.6750),
        GeoPoint(45.0700, 7.6800),
      ];
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: quasiDritta,
        declaredSuspendedCodes: {'400'},
      );
      final d = r.impacts.firstWhere((i) => i.stop.code == '400');
      expect(d.status, equals(StopStatus.declaredSuspended));
      expect(d.isSkipped, isTrue);
      // La distanza viene comunque riportata: serve a capire il perche'.
      expect(d.metersFromDeviatedRoute, lessThan(40));
      // Le altre restano servite: la dichiarazione vale solo per la sua.
      expect(r.skipped.length, equals(1));
    });
  });

  group('Alternative', () {
    test('propone al massimo tre alternative, le piu vicine', () {
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: deviata,
      );
      for (final i in r.skipped) {
        expect(i.alternatives.length, lessThanOrEqualTo(3));
        // Nessuna alternativa assurda: la fermata a 6 km non compare mai.
        expect(i.alternatives.map((a) => a.stop.code), isNot(contains('999')));
      }
    });

    test('non propone una fermata che e saltata anche lei', () {
      // Mandare l'utente a una fermata altrettanto non servita e' peggio
      // che non proporre nulla.
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: deviata,
      );
      final skippedCodes = r.skipped.map((i) => i.stop.code).toSet();
      for (final i in r.skipped) {
        for (final alt in i.alternatives.where((a) => a.sameLine)) {
          expect(skippedCodes, isNot(contains(alt.stop.code)),
              reason: 'proposta ${alt.stop.code}, che e saltata anche lei');
        }
      }
    });

    test('una fermata non propone se stessa', () {
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: deviata,
      );
      for (final i in r.skipped) {
        expect(i.alternatives.map((a) => a.stop.id),
            isNot(contains(i.stop.id)));
      }
    });

    test('la distanza in linea d aria non viene spacciata per distanza '
        'a piedi', () {
      final r = analyzer.analyze(
        officialRoute: officialRoute,
        deviatedRoute: deviata,
      );
      final alt = r.skipped
          .expand((i) => i.alternatives)
          .firstWhere((a) => true);
      expect(alt.walkingMeters, isNull,
          reason: 'senza routing pedonale non si puo sapere');
      expect(alt.toString(), contains('linea d\'aria'));
    });
  });

  group('Fermate sospese dichiarate, senza deviazione', () {
    // MISURATO: 14 avvisi su 198 dicono solo questo. E' il caso di massima
    // confidenza: nessuna geometria da ricostruire, solo un codice da
    // cercare nel GTFS.
    test('la fermata nominata da GTT viene marcata sospesa', () {
      final r = analyzer.declaredOnly(
          officialRoute: officialRoute, declaredCodes: {'300'});

      expect(r.impacts.length, equals(1));
      expect(r.impacts.single.stop.code, equals('300'));
      expect(r.impacts.single.status, equals(StopStatus.declaredSuspended));
      expect(r.hasImpact, isTrue);
    });

    test('piu fermate insieme', () {
      final r = analyzer.declaredOnly(
          officialRoute: officialRoute, declaredCodes: {'300', '500'});
      expect(r.skipped.length, equals(2));
    });

    test('non propone come alternativa una fermata sospesa anche lei', () {
      // La 300 e la 400 sono vicine: se sono sospese entrambe, mandare
      // l'utente dall'una all'altra sarebbe un consiglio inutile.
      final r = analyzer.declaredOnly(
          officialRoute: officialRoute, declaredCodes: {'300', '400'});
      for (final i in r.skipped) {
        expect(i.alternatives.map((a) => a.stop.code),
            isNot(contains('400')));
        expect(i.alternatives.map((a) => a.stop.code),
            isNot(contains('300')));
      }
    });

    test('propone le fermate ancora servite della stessa linea', () {
      final r = analyzer.declaredOnly(
          officialRoute: officialRoute, declaredCodes: {'300'});
      final alts = r.impacts.single.alternatives;
      expect(alts, isNotEmpty);
      expect(alts.any((a) => a.sameLine), isTrue);
    });

    test('un codice che non sta su questa linea non inventa nulla', () {
      // Un alert puo' riguardare piu' linee: la fermata potrebbe non essere
      // di questa. Meglio nessun impatto che una fermata a caso.
      final r = analyzer.declaredOnly(
          officialRoute: officialRoute, declaredCodes: {'99999'});
      expect(r.impacts, isEmpty);
      expect(r.hasImpact, isFalse);
    });

    test('nessun codice, nessun impatto', () {
      final r = analyzer.declaredOnly(
          officialRoute: officialRoute, declaredCodes: const {});
      expect(r.impacts, isEmpty);
    });

    test('riporta il tratto interessato', () {
      final r = analyzer.declaredOnly(
          officialRoute: officialRoute, declaredCodes: {'300', '500'});
      expect(r.affectedFromMeters, lessThan(r.affectedToMeters));
    });
  });
}
