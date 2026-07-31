/// Da dove viene un avviso.
enum NoticeSource {
  /// alerts.aspx — porta il route_id gia' canonico nel 96,7% dei casi.
  gtfsRtAlert,

  /// /cms/variazioni — porta le date e la direzione in colonne separate.
  webVariazioni,
}

/// Un avviso di GTT, normalizzato, prima di qualunque interpretazione.
///
/// Non contiene geometrie ne' deduzioni: solo cio' che GTT ha detto, con
/// l'indicazione di dove l'ha detto. Serve a poter sempre mostrare
/// all'utente il testo originale accanto a qualunque cosa il sistema
/// concluda (§6.2): se sbagliamo, il dato grezzo resta a disposizione.
class RawNotice {
  const RawNotice({
    required this.id,
    required this.source,
    required this.text,
    required this.sourceUrl,
    this.headline,
    this.routeIds = const [],
    this.lineHints = const [],
    this.directionHint,
    this.reason,
    this.effect,
    this.validFrom,
    this.validUntil,
  });

  final String id;
  final NoticeSource source;

  /// Titolo, quando la fonte ne ha uno ("Linea 82 deviata in direzione...").
  final String? headline;

  /// Il testo completo, come l'ha scritto GTT.
  final String text;

  /// route_id gia' canonici, quando la fonte li fornisce.
  /// Dagli alert arrivano gratis: niente tabella alias da consultare.
  final List<String> routeIds;

  /// Nomi di linea grezzi da risolvere ("6 – 68+ - STAR 1").
  final List<String> lineHints;

  final String? directionHint;
  final String? reason;

  /// Effetto GTFS-RT: DETOUR, NO_SERVICE, MODIFIED_SERVICE...
  /// DETOUR e' un pre-filtro utile: 109 alert su 180 lo erano.
  final String? effect;

  final DateTime? validFrom;
  final DateTime? validUntil;

  final String sourceUrl;

  /// Testo su cui cercare: titolo piu' corpo.
  String get fullText =>
      headline == null || headline!.isEmpty ? text : '$headline $text';

  /// L'avviso parla di una variazione di percorso?
  /// Serve a scartare gli avvisi su ascensori, sciopero, orari estivi.
  bool get mentionsRouteChange => _routeChange.hasMatch(fullText);

  /// Codici delle fermate sospese, estratti dal TESTO.
  ///
  /// MISURATO: negli alert il campo strutturato `informed_entity.stop_id`
  /// NON contiene le fermate impattate ma tutte quelle della linea (linea
  /// 82: 31 dichiarate = 31 fermate totali). I codici veri stanno nel
  /// testo, in avvisi dedicati tipo `Fermata 3447 "Sabotino" sospesa`.
  ///
  /// GTT usa forme diverse: `Fermata 3447`, `fermata n. 15080`,
  /// `Fermata n° 3445`, `fermata n.1182`.
  List<String> get suspendedStopCodes {
    final out = <String>{};
    for (final m in _stopCode.allMatches(fullText)) {
      final code = m.group(1);
      if (code != null) out.add(code);
    }
    return out.toList();
  }

  static final _routeChange = RegExp(
    r'deviat|limitat|sospes|soppress|capolinea provvisorio|'
    r'inversione di marcia|non transita|percorso normale|prosegue per',
    caseSensitive: false,
  );

  static final _stopCode = RegExp(
    r'fermat[ae]\s*(?:n[.°]?\s*)?(\d{1,5})',
    caseSensitive: false,
  );

  @override
  String toString() => '[$id] ${headline ?? text.substring(0, 40)}';
}
