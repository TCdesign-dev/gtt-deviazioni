import '../models/transit.dart';

/// Da come GTT scrive una linea negli avvisi, al suo identificatore.
///
/// La specifica (§4.1, §10.2) indica questo come "la causa piu' frequente
/// di bug silenziosi": la stessa linea si chiama in modi diversi in ogni
/// fonte, e un'assegnazione sbagliata e' peggio di nessuna assegnazione,
/// perche' mostra all'utente la deviazione di un'altra linea.
///
/// Regola non negoziabile: **se non si risolve, si dichiara, non si
/// indovina.** Niente fuzzy matching a runtime.
///
/// I nomi veri nel GTFS del 31/07/2026, che smentiscono in parte la
/// specifica: `58/` (senza spazio, non "58 /"), `68+`, `13+`, `16 CS`,
/// `STAR 1`, `N04`, `VEX`. La tabella web pero' scrive `N8 ORO` — sia
/// senza lo zero sia con la parola di colore attaccata.
class LineResolver {
  LineResolver(this.index, {Map<String, String>? extraAliases})
      : aliases = {..._defaultAliases, ...?extraAliases};

  final GtfsIndex index;

  /// Alias -> nome breve del GTFS. Deliberatamente esplicita e piccola:
  /// le forme regolari le gestisce [_normalize].
  final Map<String, String> aliases;

  static const _defaultAliases = <String, String>{
    // Forma colloquiale della barrata.
    'BARRATA': '/',
    // Venaria Express esiste in due versioni: feriale (VEX) e festiva
    // (3990). Il nome da solo NON basta: vedi [ambiguous].
  };

  /// Parole che GTT attacca al nome nella tabella web ma che non fanno
  /// parte del nome della linea nel GTFS.
  ///
  /// Due famiglie, entrambe verificate sui dati veri:
  /// - colori delle linee suburbane e notturne: "N8 ORO", "S45 MARRONE",
  ///   "E68 VERDE";
  /// - qualificatori di servizio: "1C Festiva" e' la linea 1C (che nel
  ///   GTFS esiste come 1CU), "7 Storica" e' la 7 (7U, il cui nome esteso
  ///   e' gia' "circolare Tram Storici").
  ///
  /// Attenzione a cosa significa toglierli: si sta dicendo che il PERCORSO
  /// e' quello, non che il servizio circoli oggi. Per la mappa e' corretto;
  /// per sapere se passa un mezzo servirebbe anche il calendario.
  static const _trailingWords = {
    // colori
    'ORO', 'VERDE', 'AZZURRA', 'AZZURRO', 'GIALLA', 'GIALLO',
    'MARRONE', 'ROSSA', 'ROSSO', 'BIANCA', 'BIANCO', 'BLU', 'VIOLA',
    'ARANCIONE', 'ARGENTO',
    // qualificatori di servizio
    'FESTIVA', 'FESTIVO', 'FERIALE', 'SCOLASTICA', 'SCOLASTICO',
    'STORICA', 'STORICO', 'ESTIVA', 'ESTIVO', 'NOTTURNA', 'NOTTURNO',
  };

  /// Nomi che corrispondono a piu' linee reali: vanno segnalati, non risolti.
  static const _ambiguousNames = <String, List<String>>{
    'VENARIAEXPRESS': ['VEXU', '3990U'],
  };

  /// Separa un campo come "6 – 68+ - STAR 1 – E68 VERDE" nei singoli nomi.
  ///
  /// Si divide solo sui trattini **circondati da spazi**: "58/" e "68+"
  /// devono restare interi, e "STAR 1" contiene uno spazio.
  static List<String> tokenize(String raw) => raw
      .split(RegExp(r'\s+[-–—]\s+'))
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  /// Risolve un campo che puo' contenere piu' linee.
  LineResolution resolve(String raw) {
    final resolved = <TransitLine>[];
    final unresolved = <String>[];
    final ambiguous = <String, List<String>>{};

    for (final token in tokenize(raw)) {
      final norm = _normalize(token);
      final amb = _ambiguousNames[norm];
      if (amb != null) {
        ambiguous[token] = amb;
        continue;
      }
      final line = resolveOne(token);
      if (line != null) {
        if (!resolved.any((l) => l.routeId == line.routeId)) resolved.add(line);
      } else {
        unresolved.add(token);
      }
    }
    return LineResolution(
        resolved: resolved, unresolved: unresolved, ambiguous: ambiguous);
  }

  /// Risolve un singolo nome. null se non ce la fa: non tira a indovinare.
  TransitLine? resolveOne(String token) =>
      matchIn(index.lines.values, token, aliases: aliases);

  /// Le stesse regole, su una lista qualsiasi di linee.
  ///
  /// Esiste separata perche' serve anche a [GtfsParser], che deve
  /// scegliere quali linee caricare PRIMA che l'indice esista — e senza
  /// questo faceva un confronto suo, molto piu' povero: "10N" non
  /// trovava la N10, "N8" non trovava la N08, "58 barrata" non trovava
  /// la 58/. Due riconoscitori diversi per la stessa domanda sono un
  /// difetto strutturale, non un dettaglio.
  static TransitLine? matchIn(
    Iterable<TransitLine> lines,
    String token, {
    Map<String, String>? aliases,
  }) {
    final alias = aliases ?? _defaultAliases;
    final t = token.trim();
    if (t.isEmpty) return null;

    // 1. E' gia' un route_id ("55U").
    final upper = t.toUpperCase();
    for (final l in lines) {
      if (l.routeId.toUpperCase() == upper) return l;
    }

    // 2. Nome breve, confronto normalizzato ("16 CS" == "16CS").
    final norm = _normalize(t);
    for (final l in lines) {
      if (_normalize(l.shortName) == norm) return l;
    }

    // 3. Alias espliciti ("58 barrata" -> "58/").
    var candidate = norm;
    alias.forEach((from, to) {
      if (candidate.endsWith(from)) {
        candidate = candidate.substring(0, candidate.length - from.length) + to;
      }
    });
    if (candidate != norm) {
      for (final l in lines) {
        if (_normalize(l.shortName) == candidate) return l;
      }
    }

    // 4. Zero-padding delle notturne: la tabella web scrive "N8", il GTFS
    //    ha "N04"/"N08". Regolarita', non indovinello.
    final night = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(norm);
    if (night != null) {
      final prefix = night.group(1)!;
      final digits = night.group(2)!;
      for (final pad in [digits.padLeft(2, '0'), digits.padLeft(3, '0')]) {
        for (final l in lines) {
          if (_normalize(l.shortName) == '$prefix$pad') return l;
        }
      }
    }

    // 5. La N sta davanti o dietro? GTT usa tutte e due le forme, e chi
    //    scrive non puo' saperlo.
    //
    //    MISURATO sul GTFS: le notturne vere hanno la N DAVANTI — N04,
    //    N08, N10, tutte "notturna, piazza Vittorio Veneto - ..." — mentre
    //    1N, 4N, 19N, 35N, 36N sono un'altra famiglia, con la N DIETRO.
    //    Chi cerca la N10 scrive "10N" per analogia con la 4N, e non
    //    trovava niente.
    //
    //    E' l'ULTIMO tentativo, dopo lo zero-padding, perche' **N04 e 4N
    //    sono due linee diverse e coesistono**: scambiare per primo
    //    darebbe la linea sbagliata. Cosi' "N4" resta la notturna N04, che
    //    e' la corrispondenza piu' stretta.
    return _swappedN(lines, norm);
  }

  /// Cerca la stessa linea con la N dall'altra parte.
  ///
  /// Accetta solo se il risultato e' UNO: se lo scambio ne trovasse due
  /// non si saprebbe quale, e indovinare e' peggio che non rispondere.
  static TransitLine? _swappedN(Iterable<TransitLine> lines, String norm) {
    final forms = <String>{};
    final asPrefix = RegExp(r'^N(\d+)$').firstMatch(norm);
    final asSuffix = RegExp(r'^(\d+)N$').firstMatch(norm);

    if (asPrefix != null) {
      final d = asPrefix.group(1)!;
      forms.addAll(['${d}N', '${int.parse(d)}N']);
    } else if (asSuffix != null) {
      final d = asSuffix.group(1)!;
      forms.addAll([
        'N$d',
        'N${d.padLeft(2, '0')}',
        'N${d.padLeft(3, '0')}',
      ]);
    }
    if (forms.isEmpty) return null;

    final found = <String, TransitLine>{};
    for (final l in lines) {
      if (forms.contains(_normalize(l.shortName))) found[l.routeId] = l;
    }
    return found.length == 1 ? found.values.first : null;
  }

  /// Maiuscole, niente spazi, via le parole finali che non fanno parte del
  /// nome ("N8 ORO" -> "N8", "1C Festiva" -> "1C").
  ///
  /// Si tolgono solo in CODA e a ripetizione: una linea non si chiama
  /// "ORO 12", ma "1C Festiva Scolastica" ha due qualificatori di fila.
  static String _normalize(String s) {
    var t = s.toUpperCase().trim();
    var changed = true;
    while (changed) {
      changed = false;
      for (final w in _trailingWords) {
        if (t.endsWith(' $w')) {
          t = t.substring(0, t.length - w.length - 1).trim();
          changed = true;
          break;
        }
      }
    }
    return t.replaceAll(' ', '').replaceAll('.', '');
  }
}

/// Esito della risoluzione. Tiene separato cio' che non ha funzionato,
/// perche' vada a finire in un log invece che in un'ipotesi.
class LineResolution {
  const LineResolution({
    required this.resolved,
    required this.unresolved,
    required this.ambiguous,
  });

  final List<TransitLine> resolved;

  /// Nomi che non corrispondono a nessuna linea.
  final List<String> unresolved;

  /// Nomi che corrispondono a piu' linee: nome -> route_id possibili.
  final Map<String, List<String>> ambiguous;

  bool get isComplete => unresolved.isEmpty && ambiguous.isEmpty;
  bool get hasAny => resolved.isNotEmpty;

  @override
  String toString() => 'risolte=${resolved.map((l) => l.routeId).join(",")}'
      '${unresolved.isEmpty ? "" : " NON RISOLTE=${unresolved.join(",")}"}'
      '${ambiguous.isEmpty ? "" : " AMBIGUE=${ambiguous.keys.join(",")}"}';
}
