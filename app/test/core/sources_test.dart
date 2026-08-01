import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/gtfs/gtfs_parser.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/pipeline/line_resolver.dart';
import 'package:gtt_deviazioni/core/sources/alerts_source.dart';
import 'package:gtt_deviazioni/core/sources/variazioni_source.dart';

/// Le fixture sono la pagina e il feed VERI di GTT, salvati il 31/07/2026.
/// I test girano offline ma su dati che nessuno ha addolcito.
void main() {
  const long = Timeout(Duration(minutes: 3));
  final variazioniHtml = File('test/fixtures/variazioni.html');
  final alertsPb = File('test/fixtures/alerts.pb');

  group('VariazioniSource', () {
    late List<RawNotice> notices;

    setUpAll(() {
      notices = VariazioniSource().parse(variazioniHtml.readAsStringSync());
    });

    test('estrae le variazioni dalla tabella', () {
      // Analisi Python del 31/07: 50 righe utili.
      expect(notices.length, equals(50));
      expect(notices.every((n) => n.text.isNotEmpty), isTrue);
      expect(notices.every((n) => n.lineHints.isNotEmpty), isTrue);
    });

    test('non scambia l intestazione per una variazione', () {
      expect(notices.any((n) => n.lineHints.first.toLowerCase() == 'linea'),
          isFalse);
    });

    test('legge le date, e il trattino significa "senza fine prevista"', () {
      final withStart = notices.where((n) => n.validFrom != null).length;
      expect(withStart, greaterThan(40));

      // Meta' tabella non ha data di fine: e' la premessa del problema
      // §10.13, non un errore di lettura.
      final openEnded = notices.where((n) => n.validUntil == null).length;
      expect(openEnded, greaterThan(10));
    });

    test('parseGttDate sulle forme reali', () {
      expect(VariazioniSource.parseGttDate('27/07/2026 ore 7.00'),
          equals(DateTime(2026, 7, 27, 7, 0)));
      expect(VariazioniSource.parseGttDate('25/05/2026'),
          equals(DateTime(2026, 5, 25)));
      expect(VariazioniSource.parseGttDate('19/03/2026 ore 8.00'),
          equals(DateTime(2026, 3, 19, 8, 0)));
      expect(VariazioniSource.parseGttDate('-'), isNull);
      expect(VariazioniSource.parseGttDate(''), isNull);
      expect(VariazioniSource.parseGttDate('prossimamente'), isNull);
    });

    test('una pagina senza tabella fallisce invece di restituire vuoto', () {
      expect(() => VariazioniSource().parse('<html><body>ops</body></html>'),
          throwsA(isA<VariazioniParseException>()));
    });
  });

  group('AlertsSource', () {
    late List<RawNotice> alerts;

    setUpAll(() {
      alerts = AlertsSource().parse(alertsPb.readAsBytesSync());
    });

    test('decodifica il protobuf', () {
      expect(alerts.length, greaterThan(150));
    });

    test('il route_id arriva gia canonico: niente alias da risolvere', () {
      // MISURATO: 96,7% degli alert ha almeno un route_id.
      final withRoute = alerts.where((a) => a.routeIds.isNotEmpty).length;
      expect(withRoute / alerts.length, greaterThan(0.9));
      // Forma attesa: "55U", "19U", "16CDU".
      final sample = alerts.firstWhere((a) => a.routeIds.isNotEmpty);
      expect(sample.routeIds.first, matches(RegExp(r'^[A-Z0-9]+U?$')));
    });

    test('riconosce gli avvisi che parlano di percorso', () {
      final routeChanges = alerts.where((a) => a.mentionsRouteChange).length;
      // Misurato: 139 su 180 parlano di deviazione/limitazione/sospensione.
      expect(routeChanges, greaterThan(100));
    });

    test('estrae i codici fermata dal TESTO, non da informed_entity', () {
      // E' la correzione che conta: gli stop_id strutturati sono tutte le
      // fermate della linea, non quelle sospese.
      final withCodes =
          alerts.where((a) => a.suspendedStopCodes.isNotEmpty).toList();
      expect(withCodes, isNotEmpty);
    });
  });

  group('RawNotice.suspendedStopCodes — forme reali di GTT', () {
    RawNotice make(String t) => RawNotice(
        id: 't', source: NoticeSource.gtfsRtAlert, text: t, sourceUrl: '');

    test('tutte le varianti di scrittura', () {
      expect(make('Fermata 3447 "Sabotino" sospesa.').suspendedStopCodes,
          equals(['3447']));
      expect(make('Fermata n. 15080 temporaneamente sospesa').suspendedStopCodes,
          equals(['15080']));
      expect(make('Fermata n° 3445 Sabotino sospesa').suspendedStopCodes,
          equals(['3445']));
      expect(make('presso la fermata n.1182 - "Maroncelli Cap"')
          .suspendedStopCodes, equals(['1182']));
    });

    test('non inventa codici dove non ce ne sono', () {
      expect(make('Gestione per autobus.').suspendedStopCodes, isEmpty);
      expect(
          make('Da via Pininfarina deviata in via Ferrero, percorso normale.')
              .suspendedStopCodes,
          isEmpty);
    });
  });

  group('LineResolver sui nomi VERI della tabella GTT', () {
    final dir = Directory('../data/gtfs');
    final available =
        dir.existsSync() && File('${dir.path}/routes.txt').existsSync();

    test('la N davanti o dietro: GTT usa tutte e due le forme', () async {
      // MISURATO sul GTFS: le notturne vere hanno la N DAVANTI (N04, N08,
      // N10, tutte "notturna, piazza Vittorio Veneto - ..."), mentre 1N,
      // 4N, 19N, 35N, 36N sono un'altra famiglia con la N DIETRO. Chi
      // cerca la N10 scrive "10N" per analogia con la 4N.
      final index = await GtfsParser(directory: dir)
          .build(['N10', 'N08', 'N04', '4N', '19N']);
      final r = LineResolver(index);

      expect(r.resolveOne('10N')?.routeId, equals('N10U'),
          reason: 'e il caso che non funzionava');
      expect(r.resolveOne('N10')?.routeId, equals('N10U'));
      expect(r.resolveOne('8N')?.routeId, equals('N08U'),
          reason: 'scambio piu zero-padding insieme');

      // La trappola: N04 e 4N sono due linee DIVERSE e coesistono.
      // Scambiare prima di provare lo zero-padding darebbe quella
      // sbagliata.
      expect(r.resolveOne('4N')?.routeId, equals('4NU'));
      expect(r.resolveOne('N4')?.routeId, equals('N04U'),
          reason: 'lo zero-padding e piu stretto dello scambio');
      expect(r.resolveOne('N04')?.routeId, equals('N04U'));

      // Il suffisso resta il suffisso quando esiste gia'.
      expect(r.resolveOne('19N')?.routeId, equals('19NU'));
      expect(r.resolveOne('N19')?.routeId, equals('19NU'),
          reason: 'N19 non esiste, 19N si: lo scambio e sicuro');
    }, skip: available ? false : 'GTFS non estratto');

    test('risolve i casi difficili che la specifica segnala', () async {
      // Watchlist larga: servono le linee citate dai casi difficili.
      final index = await GtfsParser(directory: dir)
          .build(['58/', '68+', '16 CS', 'STAR 1', 'N08', '13+', '55']);
      final r = LineResolver(index);

      // Il GTFS scrive "58/" senza spazio; GTT negli avvisi usa anche
      // "58 /" e "58 barrata".
      expect(r.resolveOne('58/')?.routeId, equals('58BU'));
      expect(r.resolveOne('58 /')?.routeId, equals('58BU'));
      expect(r.resolveOne('58 barrata')?.routeId, equals('58BU'));
      expect(r.resolveOne('68+')?.routeId, equals('68BU'));
      expect(r.resolveOne('13+')?.routeId, equals('13BU'));
      expect(r.resolveOne('16 CS')?.routeId, equals('16CSU'));
      expect(r.resolveOne('16CS')?.routeId, equals('16CSU'));
      expect(r.resolveOne('STAR 1')?.routeId, equals('ST1U'));
      expect(r.resolveOne('star1')?.routeId, equals('ST1U'));

      // La tabella web scrive "N8 ORO": manca lo zero e c'e' il colore.
      expect(r.resolveOne('N8 ORO')?.routeId, equals('N08U'));

      // Un route_id gia' canonico deve passare da solo.
      expect(r.resolveOne('55U')?.routeId, equals('55U'));
    }, timeout: long, skip: available ? false : 'GTFS non estratto');

    test('non indovina: cio che non conosce lo dichiara', () async {
      final index = await GtfsParser(directory: dir).build(['55']);
      final r = LineResolver(index);
      expect(r.resolveOne('linea inventata'), isNull);
      final res = r.resolve('55 - linea inventata');
      expect(res.resolved.single.routeId, equals('55U'));
      expect(res.unresolved, equals(['linea inventata']));
      expect(res.isComplete, isFalse);
    }, timeout: long, skip: available ? false : 'GTFS non estratto');

    test('separa piu linee senza spezzare "58/" ne "STAR 1"', () {
      expect(LineResolver.tokenize('6 – 68+ - STAR 1 – E68 VERDE'),
          equals(['6', '68+', 'STAR 1', 'E68 VERDE']));
      expect(LineResolver.tokenize('24 - 93/'), equals(['24', '93/']));
      expect(LineResolver.tokenize('2 - 22'), equals(['2', '22']));
      expect(LineResolver.tokenize('14 - 63'), equals(['14', '63']));
      // Un nome con trattino interno non va spezzato.
      expect(LineResolver.tokenize('1C Festiva'), equals(['1C Festiva']));
    });

    test('COPERTURA sui 50 nomi veri della tabella variazioni', () async {
      // La verifica onesta di quanto sia grave il problema degli alias di
      // §4.1, che la specifica indica come rischio numero due.
      final parser = GtfsParser(directory: dir);
      final index =
          await parser.build(await parser.allShortNames(), withStops: false);
      final resolver = LineResolver(index);
      final notices =
          VariazioniSource().parse(variazioniHtml.readAsStringSync());

      var tokens = 0, ok = 0, ambiguous = 0;
      final failures = <String>[];
      for (final n in notices) {
        final res = resolver.resolve(n.lineHints.first);
        tokens += LineResolver.tokenize(n.lineHints.first).length;
        ok += res.resolved.length;
        // Un nome ambiguo NON e' un fallimento: e' stato riconosciuto e
        // dichiarato tale, che e' il comportamento voluto.
        ambiguous += res.ambiguous.length;
        failures.addAll(res.unresolved);
      }
      ok += ambiguous;
      // ignore: avoid_print
      print('  copertura alias: $ok/$tokens '
          '(${(100 * ok / tokens).toStringAsFixed(1)}%)');
      if (failures.isNotEmpty) {
        // ignore: avoid_print
        print('  non risolti: ${failures.toSet().join(", ")}');
      }
      expect(ok / tokens, greaterThan(0.95));
    }, timeout: long, skip: available ? false : 'GTFS non estratto');

    test('"Venaria Express" e ambiguo e viene dichiarato tale', () async {
      // Sono due linee diverse: VEXU nei feriali, 3990U nei festivi.
      // Sceglierne una a caso mostrerebbe il percorso sbagliato.
      final index = await GtfsParser(directory: dir).build(['VEX', '3990']);
      final res = LineResolver(index).resolve('Venaria Express');
      expect(res.ambiguous.keys, contains('Venaria Express'));
      expect(res.isComplete, isFalse);
    }, timeout: long, skip: available ? false : 'GTFS non estratto');
  });
}
