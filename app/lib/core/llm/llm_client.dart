/// Interfaccia verso un modello linguistico.
///
/// Astratta di proposito. Il compito qui e' UNO solo — trasformare prosa
/// burocratica italiana in JSON strutturato — e non richiede un modello
/// particolare: e' estrazione, non ragionamento (§5.2.1). Quindi conviene
/// poterli scambiare e **misurare** quale sbaglia meno sui 34 avvisi
/// annotati a mano, invece di sceglierne uno per sentito dire.
///
/// Chi implementa deve rispettare due cose:
/// - temperatura 0: l'estrazione non deve essere creativa;
/// - se il fornitore supporta uno schema JSON nativo, usarlo. Toglie di
///   mezzo un'intera categoria di fallimenti.
abstract class LlmClient {
  /// Nome leggibile, per i report del banco di prova.
  String get name;

  /// Manda [prompt] e restituisce il testo della risposta.
  ///
  /// [jsonSchema] e' lo schema che la risposta deve rispettare. I
  /// fornitori che lo supportano nativamente devono passarlo all'API; gli
  /// altri lo mettano nel prompt e si accontentino.
  Future<String> complete(
    String prompt, {
    Map<String, dynamic>? jsonSchema,
  });
}

class LlmException implements Exception {
  LlmException(this.provider, this.detail, {this.statusCode, this.retryAfter});

  final String provider;
  final String detail;
  final int? statusCode;

  /// Quando ha senso riprovare, se il fornitore lo dice.
  ///
  /// OpenRouter manda `X-RateLimit-Reset` dentro il corpo dell'errore. E'
  /// un'informazione che l'utente puo' usare — "riprova dopo le 02:00" —
  /// e buttarla via per poi dire genericamente "quota esaurita" sarebbe
  /// uno spreco.
  final DateTime? retryAfter;

  @override
  String toString() =>
      'LlmException($provider${statusCode != null ? " $statusCode" : ""}): '
      '$detail';
}
