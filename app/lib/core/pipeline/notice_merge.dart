import '../config.dart';
import '../models/notice.dart';

/// Unisce gli avvisi che raccontano la **stessa** variazione.
///
/// Le due fonti si sovrappongono: MISURATO sui dati del 31/07/2026, 31
/// variazioni su 189 avvisi sono pubblicate sia nel feed protobuf sia
/// nella tabella `/cms/variazioni`. Senza unirle la stessa deviazione
/// compare due volte nella schermata, e — molto peggio — le due copie si
/// contraddicono: `active_period.start` degli alert e' l'ora di
/// PUBBLICAZIONE (161 su 161 nel passato), quindi la copia dall'alert
/// risulta "in corso" mentre quella dalla tabella dice correttamente
/// "comincia lunedi'". Vista dal vivo sulla 65 l'01/08/2026.
///
/// Costa anche quota: ogni avviso e' una richiesta LLM e ce ne sono 50
/// gratuite al giorno.
///
/// ## Il criterio
///
/// Due avvisi descrivono la stessa variazione se **nominano le stesse
/// vie**. Si confrontano quindi i nomi di via, non i testi: il resto
/// dell'avviso e' vocabolario che si ripete uguale in tutti ("deviata",
/// "percorso normale", "causa lavori stradali") e farebbe somigliare
/// qualunque coppia a qualunque altra.
///
/// I nomi di via si prendono da cio' che segue un qualificatore — "via",
/// "corso", "piazza", "strada" — e si confrontano per **parole intere**.
/// E' la stessa regola di [DeviationService.shapesConcernedBy], per la
/// stessa ragione gia' pagata una volta: il confronto per sottostringhe
/// faceva scattare "lavori **strada**li" sul capolinea "**STRADA** del
/// Drosso". Qui "lavori stradali" non produce nessun toponimo, perche'
/// dopo "stradali" non c'e' nessun qualificatore.
///
/// ## Perche' non e' simmetrico
///
/// Si usa il **contenimento** (le vie in comune sul piu' piccolo dei due
/// insiemi) e non la somiglianza di Jaccard, perche' il testo dell'alert
/// contiene quasi sempre quello della tabella piu' altra roba: entrambe
/// le direzioni, la fermata provvisoria, la causa. Sulla 65: 11 vie
/// nell'alert, 8 nella tabella, 8 in comune.
///
/// ## Cosa NON fa
///
/// - Non unisce mai due avvisi della **stessa** fonte. Il feed contiene
///   alert quasi gemelli (la S45 "marrone" e la S45 "notturna estiva"),
///   ma li' non c'e' la tabella a dire quale delle due date sia buona, e
///   unirli sarebbe un accorpamento senza guadagno.
/// - Non unisce gli avvisi che non nominano vie (2 su 189: "Linea 16CD
///   gestita con autobus" e basta). Senza toponimi non c'e' niente da
///   confrontare, e restano due: un doppione visibile e' meno grave di
///   una deviazione nascosta.
class NoticeMerge {
  const NoticeMerge._();

  /// La lista senza doppioni fra le due fonti.
  ///
  /// Va chiamata sugli avvisi di UNA linea: due variazioni diverse in due
  /// quartieri diversi possono nominare le stesse vie, e la sola cosa che
  /// le distingue e' la linea. Nella tabella una riga vale spesso per piu'
  /// linee ("6 – 68+ - STAR 1"), quindi lo stesso avviso puo' finire unito
  /// ad alert diversi su linee diverse: e' corretto, sono deviazioni
  /// distinte che condividono la descrizione.
  ///
  /// L'ordine di ingresso e' conservato: l'avviso unito prende il posto
  /// del primo dei due.
  static List<RawNotice> dedupe(List<RawNotice> notices) {
    if (notices.length < 2) return notices;

    // Tutte le coppie candidate, dalla piu' simile alla meno simile. Si
    // ordina prima di scegliere perche' lo stesso avviso della tabella
    // puo' somigliare a due alert: deve unirsi al piu' simile, non al
    // primo che capita. Sulla S45 del 31/07 succede davvero (1,00 contro
    // 0,80), e prendere il primo darebbe la coppia sbagliata.
    final candidates = <_Candidate>[];
    for (var i = 0; i < notices.length; i++) {
      for (var j = i + 1; j < notices.length; j++) {
        if (notices[i].source == notices[j].source) continue;
        final score = similarity(notices[i], notices[j]);
        if (score == null) continue;
        candidates.add(_Candidate(i, j, score));
      }
    }
    if (candidates.isEmpty) return notices;
    candidates.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      // A parita' di punteggio conta l'ordine di arrivo, cosi' il
      // risultato non dipende dall'ordinamento della libreria.
      return a.i != b.i ? a.i.compareTo(b.i) : a.j.compareTo(b.j);
    });

    final partnerOf = <int, int>{};
    final used = <int>{};
    for (final c in candidates) {
      if (used.contains(c.i) || used.contains(c.j)) continue;
      used.add(c.i);
      used.add(c.j);
      partnerOf[c.i] = c.j;
    }

    final out = <RawNotice>[];
    final absorbed = partnerOf.values.toSet();
    for (var i = 0; i < notices.length; i++) {
      if (absorbed.contains(i)) continue;
      final j = partnerOf[i];
      out.add(j == null ? notices[i] : fuse(notices[i], notices[j]));
    }
    return out;
  }

  /// Quanto due avvisi descrivono la stessa variazione, oppure null se
  /// non sono abbastanza simili per unirli.
  ///
  /// Due condizioni insieme, tarate sugli 80 confronti stessa-linea del
  /// 31/07 (vedi `tool/check_merge_offline.dart`). Servono **tutte e
  /// due**: ognuna lascia passare qualcosa che l'altra ferma.
  ///
  /// - **almeno 3 vie in comune.** Due vie sole capitano: la 14 e la 63
  ///   hanno un avviso di ripristino e una riga di capolinea provvisorio
  ///   che condividono "piazza Solferino" e "corso Re Umberto" e dicono
  ///   il contrario l'uno dell'altra (contenimento 0,67).
  /// - **contenimento >= 0,6.** Tre vie in comune capitano anche loro,
  ///   se la linea passa sempre di li': la 2C e la 30 nominano entrambe
  ///   "via Conte Rossi di Montelera" in due deviazioni diverse, ma con
  ///   contenimento 0,38 e 0,27.
  ///
  /// Sui dati veri le 31 coppie giuste stanno fra 0,67 e 1,00 con 3 vie
  /// o piu'; nessuna coppia sbagliata arriva a tutte e due le soglie. Il
  /// caso piu' stretto e' la 4, vera a 0,67 con 4 vie.
  ///
  /// C'e' anche una guardia sui periodi: se uno finisce prima che l'altro
  /// cominci non sono la stessa cosa, per quanto si somiglino. Non scatta
  /// mai sui dati del 31/07 — serve al caso in cui gli stessi lavori
  /// tornino in un altro mese.
  static double? similarity(RawNotice a, RawNotice b) {
    final sa = streetsIn(a.fullText);
    final sb = streetsIn(b.fullText);
    if (sa.isEmpty || sb.isEmpty) return null;

    final shared = sa.intersection(sb).length;
    if (shared < GttConfig.mergeMinSharedStreets) return null;

    final smaller = sa.length < sb.length ? sa.length : sb.length;
    final score = shared / smaller;
    if (score < GttConfig.mergeMinStreetOverlap) return null;
    if (!_periodsOverlap(a, b)) return null;
    return score;
  }

  /// I nomi di via nominati in un testo.
  ///
  /// Si prendono le parole che seguono un qualificatore, fino al primo
  /// segno che il nome e' finito. "Da via Asinari di Bernezzo angolo
  /// corso Monte Grappa" da' {asinari, bernezzo, monte, grappa}: "di" e'
  /// troppo corta per essere un nome, "angolo" chiude.
  ///
  /// Le cifre si scartano ("corso Vittorio Emanuele II", "via 4 Marzo"):
  /// da sole non distinguono niente e i numeri di fermata li estrae gia'
  /// [RawNotice.suspendedStopCodes].
  ///
  /// Si scarta anche la via che viene dopo "direzione", perche' li' non e'
  /// una via percorsa ma il CAPOLINEA: "Direzione via Moncalieri
  /// (Grugliasco)" dice dove va il mezzo, non dove passa la deviazione.
  /// Senza questa regola due deviazioni diverse della stessa linea nello
  /// stesso senso di marcia si somigliano per forza — succede sulla 55,
  /// dove i lavori di luglio e quelli del 3-7 agosto condividono solo il
  /// capolinea e verrebbero uniti in uno solo, nascondendone uno.
  static Set<String> streetsIn(String text) {
    final t = _tokens(text);
    final out = <String>{};
    for (var i = 0; i < t.length; i++) {
      if (!streetQualifiers.contains(t[i])) continue;
      if (_afterDirection(t, i)) continue;
      var taken = 0;
      for (var j = i + 1; j < t.length && j <= i + 4 && taken < 3; j++) {
        final w = t[j];
        if (streetQualifiers.contains(w) || _notPartOfName.contains(w)) break;
        // "di", "del", "II", "XX": parti del nome che non lo identificano.
        if (w.length < 4 || _onlyDigits.hasMatch(w)) continue;
        out.add(w);
        taken++;
      }
    }
    return out;
  }

  /// L'avviso unico che sostituisce i due.
  ///
  /// Le regole, tutte con lo stesso criterio: da ogni fonte si prende
  /// quello che quella fonte sa davvero.
  ///
  /// - **Le date le porta la tabella.** MISURATO: `active_period.start`
  ///   degli alert e' l'ora di pubblicazione (161 su 161 nel passato), e
  ///   la fine e' un segnaposto lontano (la S45 dichiara il 31/12 dove la
  ///   tabella scrive "-", cioe' "senza data di fine prevista"). Se la
  ///   tabella non ha la data, l'avviso unito non ce l'ha: dire "non lo
  ///   so" e' meglio che dire una data sbagliata.
  /// - **Il testo e' il piu' completo dei due**, misurato in caratteri.
  ///   Di solito e' quello dell'alert, che aggiunge la causa e le fermate
  ///   provvisorie; ma non sempre — sulla 4 la tabella descrive tutto il
  ///   percorso delle navette sostitutive e l'alert una riga.
  /// - **I route_id li portano gli alert**, gia' canonici (96,7%).
  /// - **La direzione e il motivo li porta la tabella**, che li ha in
  ///   colonne separate invece che dentro la prosa.
  static RawNotice fuse(RawNotice x, RawNotice y) {
    final web = x.source == NoticeSource.webVariazioni ? x : y;
    final alert = identical(web, x) ? y : x;
    final fullest =
        alert.fullText.length >= web.fullText.length ? alert : web;

    return RawNotice(
      id: '${x.id}+${y.id}',
      source: fullest.source,
      headline: fullest.headline,
      text: fullest.text,
      routeIds: {...alert.routeIds, ...web.routeIds}.toList()..sort(),
      lineHints: {...alert.lineHints, ...web.lineHints}.toList(),
      directionHint: _firstNonEmpty(web.directionHint, alert.directionHint),
      reason: _firstNonEmpty(web.reason, alert.reason),
      validFrom: web.validFrom,
      validUntil: web.validUntil,
      sourceUrl: fullest.sourceUrl,
      // Gli originali restano interi: il testo di GTT si deve poter
      // sempre mostrare, e nessuno dei due va perso per strada.
      mergedFrom: [x, y],
    );
  }

  /// Le parole che introducono un toponimo.
  ///
  /// Sono le stesse che [DeviationService] scarta come generiche, e per
  /// la stessa ragione: da sole non distinguono niente, compaiono in ogni
  /// avviso. Qui pero' non si buttano — servono da segnale che la parola
  /// DOPO e' un nome di via.
  static const streetQualifiers = {
    'via', 'viale', 'corso', 'piazza', 'piazzale', 'largo', 'strada',
    'ponte', 'lungo', 'rotatoria', 'rondo', 'rondò', 'vicolo', 'borgo',
    'stradale', 'circonvallazione',
  };

  /// Parole che possono capitare subito dopo un qualificatore senza far
  /// parte del nome della via. Ricavate dai due corpus veri del
  /// 31/07/2026, non immaginate: "via Genova **dove** effettua", "in
  /// piazza Solferino **dopo** corso Re Umberto".
  ///
  /// NIENTE nomi di mese: "via XX Settembre" e "via XXIV Maggio" sono vie
  /// vere, e una data non viene mai subito dopo "via" o "corso".
  static const _notPartOfName = {
    'angolo', 'deviata', 'deviate', 'deviato', 'deviazione', 'devia',
    'percorso', 'percorsi', 'normale', 'regolare', 'attuale', 'segue',
    'prosegue', 'proseguono', 'proseguendo', 'riprende', 'causa',
    'lavori', 'fermata', 'fermate', 'sospesa', 'sospese', 'sospeso',
    'direzione', 'direzioni', 'capolinea', 'linea', 'linee', 'dalle',
    'dalla', 'dopo', 'prima', 'sino', 'fino', 'quindi', 'nella', 'nelle',
    'nello', 'sulla', 'sullo', 'presso', 'verso', 'effettua', 'effettuano',
    'istituita', 'istituite', 'gestita', 'gestite', 'comune', 'nuove',
    'comunicazioni', 'temporaneamente', 'servizio', 'carreggiata',
    'laterale', 'veicolare', 'partire', 'tutte', 'circa', 'dove', 'alla',
    'alle', 'allo', 'agli', 'sono', 'saranno', 'sarà', 'anche', 'oltre',
    'ogni', 'sita', 'site', 'sito', 'siti', 'limitata', 'limitate',
    'limitati', 'partenza', 'instrada', 'instradano', 'seguono',
    'appositamente', 'compresa', 'lato', 'della', 'delle', 'dello',
    'degli', 'dei', 'con', 'lunedi', 'lunedì', 'martedi', 'martedì',
    'mercoledi', 'mercoledì', 'giovedi', 'giovedì', 'venerdi', 'venerdì',
    'sabato', 'domenica',
  };

  static final _onlyDigits = RegExp(r'^\d+$');

  /// Il qualificatore in posizione [i] viene subito dopo "direzione"?
  /// Si guarda indietro anche oltre le parole corte, per "nella sola
  /// direzione **di** corso Cadore".
  static bool _afterDirection(List<String> t, int i) {
    for (var k = i - 1; k >= 0 && k >= i - 2; k--) {
      if (t[k] == 'direzione' || t[k] == 'direzioni') return true;
      if (t[k].length >= 4) return false;
    }
    return false;
  }

  /// L'apostrofo finale si toglie: GTT scrive "lunedi'" molto piu' spesso
  /// di "lunedì", e senza questo la lista qui sopra non lo riconosce —
  /// "da lunedi' 25 agosto" produceva il falso toponimo `lunedi'`.
  /// Nessun nome di via finisce con un apostrofo.
  static List<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll('’', "'")
      .split(RegExp(r"[^a-zà-ù0-9']+"))
      .map((w) => w.endsWith("'") ? w.substring(0, w.length - 1) : w)
      .where((w) => w.isNotEmpty)
      .toList();

  /// I due periodi si toccano? Le date mancanti valgono "aperto".
  static bool _periodsOverlap(RawNotice a, RawNotice b) =>
      !_endsBeforeStartOf(a, b) && !_endsBeforeStartOf(b, a);

  static bool _endsBeforeStartOf(RawNotice a, RawNotice b) {
    final end = a.validUntil;
    final start = b.validFrom;
    return end != null && start != null && end.isBefore(start);
  }

  static String? _firstNonEmpty(String? a, String? b) =>
      (a != null && a.trim().isNotEmpty) ? a : b;
}

class _Candidate {
  const _Candidate(this.i, this.j, this.score);

  final int i;
  final int j;
  final double score;
}
