import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/deviation_service.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/llm/llm_client.dart';
import 'package:gtt_deviazioni/core/pipeline/extractor.dart';
import 'package:gtt_deviazioni/core/pipeline/stop_impact.dart';

/// Un LLM che non risponde mai: quota finita, rete assente, servizio giu'.
class _LlmSpento implements LlmClient {
  @override
  String get name => 'spento';

  @override
  Future<String> complete(String prompt, {Map<String, dynamic>? jsonSchema}) =>
      Future.error(LlmException(
          'spento', 'rete non raggiungibile: SocketException'));
}

/// Quando qualcosa non funziona, chi usa l'app deve capire SE puo' fare
/// qualcosa. "Errore" non aiuta nessuno; "hai finito le richieste di oggi"
/// si', perche' dice anche che domani funzionera'.
void main() {
  String why(String? detail,
          {ExtractionStatus status = ExtractionStatus.error,
          DateTime? retryAfter}) =>
      DeviationService.explainExtractionFailure(ExtractionResult(
          status: status, detail: detail, retryAfter: retryAfter));

  test('quota esaurita: dice QUANDO riprovare, in ora locale', () {
    // Il fornitore ragiona in UTC; chi legge il messaggio all'una di notte
    // no. Dire "mezzanotte UTC" alle 01:17 sembra semplicemente sbagliato.
    final msg = why('LlmException(429): free-models-per-day exceeded',
        retryAfter: DateTime(2026, 8, 1, 2, 0));
    expect(msg, contains('richieste gratuite'));
    expect(msg, contains('02:00'));
    expect(msg, isNot(contains('UTC')));
  });

  test('senza orario dal fornitore, traduce comunque in ora italiana', () {
    final msg = why('LlmException(429): free-models-per-day exceeded');
    expect(msg, contains('richieste gratuite'));
    expect(msg, contains('2 di notte'));
  });

  test('sovraccarico momentaneo e diverso da quota finita', () {
    expect(why('LlmException(429): upstream busy'), contains('sovraccarico'));
  });

  test('chiave non valida: si corregge nelle impostazioni', () {
    expect(why('LlmException(401): no auth'), contains('chiave'));
  });

  test('rete assente: dipende dalla connessione', () {
    expect(why('rete non raggiungibile: SocketException'),
        contains('connessione'));
  });

  test('testo illeggibile: nessun gergo tecnico verso l utente', () {
    final msg = why(null, status: ExtractionStatus.parseFailed);
    expect(msg, contains('percorso'));
    for (final gergo in ['parseFailed', 'error', 'Exception', 'null']) {
      expect(msg, isNot(contains(gergo)), reason: 'trapela "\$gergo"');
    }
  });

  group('Quale direzione riguarda un avviso', () {
    // Capolinea veri della linea 4.
    final andata = RouteShape(
      shapeId: '4:0',
      routeId: '4U',
      directionId: 0,
      headsign: 'DERNA',
      points: const [GeoPoint(45.07, 7.66), GeoPoint(45.09, 7.70)],
    );
    final ritorno = RouteShape(
      shapeId: '4:1',
      routeId: '4U',
      directionId: 1,
      headsign: 'MIRAFIORI SUD, STRADA DEL DROSSO',
      points: const [GeoPoint(45.09, 7.70), GeoPoint(45.07, 7.66)],
    );

    RawNotice notice(String text, {String? direction}) => RawNotice(
        id: 'n',
        source: NoticeSource.gtfsRtAlert,
        text: text,
        directionHint: direction,
        sourceUrl: '');

    List<String> concerned(RawNotice n) =>
        DeviationService.shapesConcernedBy(n, andata, ritorno)
            .map((s) => s.headsign)
            .toList();

    test('"nella sola direzione Derna" riguarda solo l andata', () {
      // Testo reale di GTT. Calcolare le fermate contro il ritorno darebbe
      // fermate di un altro senso di marcia.
      final r = concerned(notice(
          'Linea 4 deviata nella sola direzione Derna. Da corso Turati '
          'angolo corso Sommeiller per corso Re Umberto.'));
      expect(r, equals(['DERNA']));
    });

    test('il capolinea composto si riconosce da una sua parte', () {
      final r = concerned(notice(
          'Linea 4 deviata in direzione strada del Drosso, per corso '
          'Unione Sovietica.'));
      expect(r, equals(['MIRAFIORI SUD, STRADA DEL DROSSO']));
    });

    test('la direzione puo arrivare dalla colonna della tabella', () {
      final r = concerned(
          notice('Da corso Turati deviata.', direction: 'Derna'));
      expect(r, equals(['DERNA']));
    });

    test('se non si capisce si analizzano ENTRAMBE, non si indovina', () {
      // Meglio due rapporti, uno superfluo, che uno riferito al senso di
      // marcia sbagliato.
      final r = concerned(notice('Linea 4 deviata per lavori stradali.'));
      expect(r.length, equals(2));
    });

    test('"entrambe le direzioni" le prende tutte e due', () {
      final r = concerned(
          notice('Deviata in entrambe le direzioni.', direction: 'entrambe'));
      expect(r.length, equals(2));
    });

    test('una linea con una direzione sola non si complica', () {
      final r = DeviationService.shapesConcernedBy(
          notice('qualsiasi cosa'), andata, null);
      expect(r.length, equals(1));
    });
  });

  group('Fermate sospese senza LLM', () {
    // Il caso piu' facile e' anche quello che si perdeva piu' facilmente:
    // "Fermata 3445 sospesa" non ha bisogno di nessun modello, il numero
    // sta nel testo. Perderlo proprio quando la quota e' finita sarebbe
    // il momento peggiore.
    final fermata = TransitStop(
      id: 'S3445',
      code: '3445',
      name: 'SABOTINO',
      position: const GeoPoint(45.0700, 7.6650),
    );
    final linea = RouteShape(
      shapeId: '15:0',
      routeId: '15U',
      directionId: 0,
      headsign: 'SASSI',
      points: const [GeoPoint(45.0700, 7.6600), GeoPoint(45.0700, 7.6900)],
      stops: [fermata],
    );
    final index = GtfsIndex(
      feedVersion: 'test',
      builtAt: DateTime(2026),
      lines: {'15U': const TransitLine(routeId: '15U', shortName: '15')},
      shapes: {'15U': [linea]},
      stops: {fermata.id: fermata},
    );
    final service = DeviationService(index: index, llm: _LlmSpento());

    final avviso = RawNotice(
      id: 'a1',
      source: NoticeSource.gtfsRtAlert,
      text: 'Fermata n. 3445 Sabotino temporaneamente sospesa. '
          'Causa lavori stradali.',
      routeIds: const ['15U'],
      sourceUrl: '',
    );

    test('la fermata resta segnata anche con l LLM giu', () async {
      final status = await service.statusOf(
          const TransitLine(routeId: '15U', shortName: '15'),
          allNotices: [avviso]);

      final saltate = status.allSkippedStops;
      expect(saltate.map((s) => s.stop.code), contains('3445'));
      expect(saltate.single.status, equals(StopStatus.declaredSuspended));
    });

    test('ma non si spaccia per ricostruita', () async {
      // Senza estrazione non sappiamo se l'avviso dica anche altro: la
      // fermata e' certa, il resto no, e va detto.
      final status = await service.statusOf(
          const TransitLine(routeId: '15U', shortName: '15'),
          allNotices: [avviso]);

      final r = status.reports.single;
      expect(r.confidence, equals(Confidence.probabile));
      expect(r.whyIncomplete, contains('connessione'));
      expect(r.deviatedGeometry, isNull);
    });

    test('senza codici nel testo resta solo il testo di GTT', () async {
      final status = await service.statusOf(
        const TransitLine(routeId: '15U', shortName: '15'),
        allNotices: [
          RawNotice(
            id: 'a2',
            source: NoticeSource.gtfsRtAlert,
            text: 'Linea 15 deviata per lavori stradali in via Sabotino.',
            routeIds: const ['15U'],
            sourceUrl: '',
          )
        ],
      );
      expect(status.reports.single.confidence, equals(Confidence.soloTesto));
      expect(status.allSkippedStops, isEmpty);
    });
  });
}
