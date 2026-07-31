import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/deviation_service.dart';
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
}
