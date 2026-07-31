import 'package:html/parser.dart' as html;

import '../config.dart';
import '../models/notice.dart';
import '../net/gtt_http.dart';

/// Legge la tabella "Variazioni temporanee di percorso" dal sito GTT.
///
/// Complementare agli alert, non ridondante: MISURATO il 31/07/2026, solo
/// ~1 riga su 12 ha un alert molto simile. Le due fonti vanno unite.
///
/// Il vantaggio di questa: le colonne sono gia' separate, quindi date,
/// direzione e motivo si prendono senza interpretare nulla. Lo svantaggio:
/// il nome della linea e' scritto come lo scrive un umano ("6 – 68+ - STAR
/// 1 – E68 VERDE"), quindi serve LineResolver.
///
/// Colonne attese:
///   Linea | Inizio | Fine presunta | Direzione | Descrizione | Motivo
class VariazioniSource {
  VariazioniSource({GttHttp? http}) : _http = http ?? GttHttp();

  final GttHttp _http;

  Future<List<RawNotice>> fetch() async {
    return parse(await _http.getText(GttConfig.variazioniUrl));
  }

  /// Separato da [fetch] per poterlo provare su una pagina salvata.
  List<RawNotice> parse(String htmlText) {
    final doc = html.parse(htmlText);
    final tables = doc.querySelectorAll('table');
    if (tables.isEmpty) {
      throw VariazioniParseException(
          'nessuna tabella nella pagina: la struttura e cambiata');
    }

    // La pagina ha altre tabelle di contorno: si prende la piu' grande.
    final table = tables.reduce((a, b) =>
        a.querySelectorAll('tr').length >= b.querySelectorAll('tr').length
            ? a
            : b);

    final out = <RawNotice>[];
    var index = 0;
    for (final tr in table.querySelectorAll('tr')) {
      final cells = tr
          .querySelectorAll('td, th')
          .map((c) => c.text.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (cells.length < 5) continue;

      // Salta l'intestazione, riconosciuta dal contenuto e non dalla
      // posizione: la pagina a volte ha righe vuote prima.
      if (cells[0].toLowerCase() == 'linea') continue;

      final descrizione = cells[4];
      if (descrizione.isEmpty) continue;

      out.add(RawNotice(
        id: 'web-${index.toString().padLeft(3, '0')}',
        source: NoticeSource.webVariazioni,
        text: descrizione,
        lineHints: [cells[0]],
        directionHint: cells[3],
        reason: cells.length > 5 ? cells[5] : null,
        validFrom: parseGttDate(cells[1]),
        validUntil: parseGttDate(cells[2]),
        sourceUrl: GttConfig.variazioniUrl,
      ));
      index++;
    }

    if (out.isEmpty) {
      throw VariazioniParseException(
          'tabella trovata ma nessuna riga utile: struttura cambiata');
    }
    return out;
  }

  /// Date come le scrive GTT: "27/07/2026 ore 7.00", "25/05/2026", "-".
  ///
  /// Il trattino significa "senza data di fine prevista", ed e' frequente:
  /// meta' tabella ce l'ha. Va trattato come null, non come errore — e' la
  /// premessa del problema di §10.13, che la fine delle deviazioni non
  /// viene quasi mai annunciata.
  static DateTime? parseGttDate(String raw) {
    final s = raw.trim();
    if (s.isEmpty || s == '-' || s == '–') return null;

    final m = RegExp(r'(\d{1,2})/(\d{1,2})/(\d{4})').firstMatch(s);
    if (m == null) return null;
    final day = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final year = int.parse(m.group(3)!);

    // "ore 7.00" oppure "ore 15:30".
    var hour = 0;
    var minute = 0;
    final t = RegExp(r'ore\s*(\d{1,2})[.:](\d{2})', caseSensitive: false)
        .firstMatch(s);
    if (t != null) {
      hour = int.parse(t.group(1)!);
      minute = int.parse(t.group(2)!);
    }
    try {
      return DateTime(year, month, day, hour, minute);
    } on Object {
      return null;
    }
  }
}

class VariazioniParseException implements Exception {
  VariazioniParseException(this.message);

  final String message;

  @override
  String toString() => 'VariazioniParseException: $message';
}
