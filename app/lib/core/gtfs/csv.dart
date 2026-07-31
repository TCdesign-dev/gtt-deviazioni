/// Lettura di una riga CSV secondo RFC 4180.
///
/// Sembra banale e non lo e': i file di GTT usano campi fra virgolette
/// (`"Gruppo Torinese Trasporti S.p.A","http://..."`), e uno split su
/// virgola spezzerebbe i nomi che contengono virgole, sfasando tutte le
/// colonne successive senza dare errore. E' il tipo di bug che si scopre
/// tre giorni dopo guardando una fermata con il nome sbagliato.
class Csv {
  const Csv._();

  /// Byte order mark: i file GTFS di GTT iniziano con questo, e se non lo
  /// si toglie la prima intestazione diventa "﻿route_id" e nessuna
  /// colonna viene trovata.
  static const bom = '﻿';

  /// Divide una riga in campi, rispettando le virgolette.
  static List<String> split(String line) {
    final fields = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    var i = 0;

    while (i < line.length) {
      final c = line[i];
      if (inQuotes) {
        if (c == '"') {
          // Due virgolette di fila dentro un campo = una virgoletta.
          if (i + 1 < line.length && line[i + 1] == '"') {
            buf.write('"');
            i += 2;
            continue;
          }
          inQuotes = false;
        } else {
          buf.write(c);
        }
      } else {
        if (c == '"') {
          inQuotes = true;
        } else if (c == ',') {
          fields.add(buf.toString());
          buf.clear();
        } else {
          buf.write(c);
        }
      }
      i++;
    }
    fields.add(buf.toString());
    return fields;
  }

  /// Estrae SOLO il primo campo, senza costruire la lista completa.
  ///
  /// Serve a scartare in fretta le righe che non interessano: in
  /// `stop_times.txt` ci sono 2,3 milioni di righe e ne servono ~200.
  /// Fare lo split completo di tutte per poi buttarle costa decine di
  /// secondi; qui si fa una sottostringa e una ricerca in un Set.
  static String? firstField(String line) {
    if (line.isEmpty) return null;
    if (line.codeUnitAt(0) == 0x22) {
      final end = line.indexOf('"', 1);
      return end < 0 ? null : line.substring(1, end);
    }
    final comma = line.indexOf(',');
    return comma < 0 ? line : line.substring(0, comma);
  }

  /// Costruisce la mappa nome-colonna -> indice dall'intestazione.
  static Map<String, int> header(String line) {
    var l = line;
    if (l.startsWith(bom)) l = l.substring(bom.length);
    final cols = split(l);
    return {for (var i = 0; i < cols.length; i++) cols[i].trim(): i};
  }

  /// Legge un campo per nome. Ritorna null se la colonna non esiste o la
  /// riga e' piu' corta del previsto — invece di lanciare, perche' i feed
  /// reali hanno righe irregolari e non vale la pena farne cadere una
  /// intera per una colonna facoltativa mancante.
  static String? field(List<String> row, Map<String, int> cols, String name) {
    final i = cols[name];
    if (i == null || i >= row.length) return null;
    final v = row[i].trim();
    return v.isEmpty ? null : v;
  }
}
