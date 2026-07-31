import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/deviation_service.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/pipeline/extractor.dart';

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
}
