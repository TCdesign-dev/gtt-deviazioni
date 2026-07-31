import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/gtfs/csv.dart';
import 'package:gtt_deviazioni/core/gtfs/gtfs_parser.dart';

/// I valori attesi vengono da un'analisi indipendente del GTFS del
/// 31/07/2026 fatta in Python (scripts/snapshot_gtfs.py), non dall'output
/// di questo parser.
///
/// Il test sul GTFS vero si salta da solo se i file non ci sono, cosi' chi
/// clona il repo non deve scaricare 24 MB per far girare la suite:
///   cd data && unzip -o gtt_gtfs-*.zip -d gtfs
void main() {
  // Il parsing legge 140 MB di stop_times: il timeout di 30 s non basta.
  const long = Timeout(Duration(minutes: 3));

  group('Csv.split — RFC 4180', () {
    test('campi semplici', () {
      expect(Csv.split('a,b,c'), equals(['a', 'b', 'c']));
    });

    test('virgola dentro un campo fra virgolette', () {
      // Senza questo, tutte le colonne successive slittano di uno e il bug
      // e' silenzioso: si scopre giorni dopo da una fermata sbagliata.
      expect(
        Csv.split('"Gruppo Torinese Trasporti S.p.A","http://gtt.to.it",it'),
        equals(['Gruppo Torinese Trasporti S.p.A', 'http://gtt.to.it', 'it']),
      );
    });

    test('virgolette raddoppiate dentro un campo', () {
      expect(Csv.split('"fermata ""Sabotino""",3445'),
          equals(['fermata "Sabotino"', '3445']));
    });

    test('campi vuoti conservati', () {
      expect(Csv.split('a,,c'), equals(['a', '', 'c']));
      expect(Csv.split(',,'), equals(['', '', '']));
    });

    test('intestazione: il BOM viene tolto', () {
      // I file di GTT iniziano col BOM: senza toglierlo la prima colonna
      // si chiama "﻿route_id" e non viene mai trovata.
      final cols = Csv.header('${Csv.bom}route_id,route_short_name');
      expect(cols.containsKey('route_id'), isTrue);
      expect(cols['route_short_name'], equals(1));
    });

    test('field() tollera righe corte e colonne assenti', () {
      final cols = Csv.header('a,b,c');
      expect(Csv.field(['1'], cols, 'c'), isNull);
      expect(Csv.field(['1', '2', '3'], cols, 'inesistente'), isNull);
      expect(Csv.field(['1', '  ', '3'], cols, 'b'), isNull);
    });
  });

  group('GtfsParser sul GTFS reale', () {
    final dir = Directory('../data/gtfs');
    final available = dir.existsSync() &&
        File('${dir.path}/stop_times.txt').existsSync();

    test('costruisce l\'indice per una watchlist', () async {
      final index = await GtfsParser(directory: dir).build(['55', '19', '4']);

      expect(index.feedVersion, equals('20260731'));
      expect(index.lines.length, equals(3));

      // Le fermate sono TUTTE, non solo quelle delle linee scelte: servono
      // per proporre alternative servite da altre linee.
      expect(index.stops.length, greaterThan(5000));
    }, timeout: long, skip: available ? false : 'GTFS non estratto in data/gtfs');

    test('risolve la linea dal nome che usa la gente', () async {
      final index = await GtfsParser(directory: dir).build(['55']);
      expect(index.lineByShortName('55')?.routeId, equals('55U'));
      expect(index.lineByShortName(' 55 ')?.routeId, equals('55U'));
      expect(index.lineByShortName('999'), isNull);
    }, timeout: long, skip: available ? false : 'GTFS non estratto in data/gtfs');

    test('geometria e fermate della linea 55', () async {
      final index = await GtfsParser(directory: dir).build(['55']);
      final shapes = index.shapesOf('55U');

      // Analisi Python: 6 shape distinte per la 55.
      expect(shapes.length, equals(6));

      final main0 = index.mainShape('55U', 0)!;
      expect(main0.shapeId, equals('55UDi55RA4'));
      expect(main0.tripCount, equals(363));
      expect(main0.points.length, equals(68));
      // Python: 13.092 m.
      expect(main0.lengthMeters, closeTo(13092, 60));
      expect(main0.stops.length, greaterThan(30));

      // Le fermate devono essere IN ORDINE lungo il percorso: e' cio' che
      // permette di dire quali cadono nel tratto deviato.
      var prev = -1.0;
      var monotone = true;
      for (final s in main0.stops) {
        final along = _alongMeters(main0, s.position.lat, s.position.lon);
        if (along < prev - 200) monotone = false;
        prev = along;
      }
      expect(monotone, isTrue,
          reason: 'le fermate non sono ordinate lungo il percorso');
    }, timeout: long, skip: available ? false : 'GTFS non estratto in data/gtfs');

    test('la linea 19 ha le 4 varianti attese', () async {
      final index = await GtfsParser(directory: dir).build(['19']);
      final shapes = index.shapesOf('19U');
      expect(shapes.map((s) => s.shapeId).toSet(),
          equals({'19UAs19AD1', '19UDi19RD2', '19UAs19AF1', '19UDi19RF2'}));
      // Python: 183 corse sulle due principali, 144 sulle altre due.
      expect(index.mainShape('19U', 1)!.tripCount, equals(183));
      expect(index.mainShape('19U', 0)!.tripCount, equals(183));
    }, timeout: long, skip: available ? false : 'GTFS non estratto in data/gtfs');

    test('una watchlist inesistente fallisce invece di restituire vuoto',
        () async {
      expect(
        () => GtfsParser(directory: dir).build(['linea-che-non-esiste']),
        throwsA(isA<GtfsParseException>()),
      );
    }, timeout: long, skip: available ? false : 'GTFS non estratto in data/gtfs');

    test('una cartella senza i file dice QUALI mancano', () async {
      expect(
        () => GtfsParser(directory: Directory('/tmp/vuota-xyz')).build(['55']),
        throwsA(isA<GtfsParseException>()),
      );
    });
  });
}

double _alongMeters(dynamic shape, double lat, double lon) {
  // Piccolo aiuto locale per non esporre Projected nei test.
  final pts = shape.meters as List;
  var best = double.infinity;
  var bestAlong = 0.0;
  var along = 0.0;
  final px = lat * 111132.0;
  final py = lon * 78618.8995;
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    final dx = b.x - a.x, dy = b.y - a.y;
    final segLen = a.distanceTo(b) as double;
    var t = 0.0;
    if (dx != 0 || dy != 0) {
      t = (((px - a.x) * dx + (py - a.y) * dy) / (dx * dx + dy * dy))
          .clamp(0.0, 1.0);
    }
    final cx = a.x + t * dx, cy = a.y + t * dy;
    final d = ((px - cx) * (px - cx) + (py - cy) * (py - cy));
    if (d < best) {
      best = d;
      bestAlong = along + segLen * t;
    }
    along += segLen;
  }
  return bestAlong;
}
