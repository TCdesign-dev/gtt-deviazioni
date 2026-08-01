import 'geo/projection.dart';
import 'llm/llm_client.dart';
import 'models/notice.dart';
import 'models/transit.dart';
import 'pipeline/extractor.dart';
import 'pipeline/geocoder.dart';
import 'pipeline/line_resolver.dart';
import 'pipeline/notice_merge.dart';
import 'pipeline/rejoin_inference.dart';
import 'pipeline/route_builder.dart';
import 'pipeline/stop_impact.dart';
import 'sources/alerts_source.dart';
import 'sources/variazioni_source.dart';

/// Quanto fidarsi di quello che il sistema dice.
enum Confidence {
  /// Geometria ricostruita e superate tutte le prove.
  confermata,

  /// C'e' una geometria ma qualche verifica non torna: si mostra con
  /// riserva, accanto al testo originale.
  probabile,

  /// GTT dichiara una variazione ma non siamo riusciti a ricostruirla.
  /// Si mostra SOLO il testo di GTT: mai una mappa inventata.
  soloTesto,
}

/// Cosa succede a una linea per via di un singolo avviso.
class DeviationReport {
  const DeviationReport({
    required this.notice,
    required this.confidence,
    required this.shape,
    this.parsed,
    this.deviatedGeometry,
    this.impact,
    this.whyIncomplete,
    this.rejoin,
  });

  final RawNotice notice;

  /// Il percorso su cui e' stato calcolato: linea PIU' DIREZIONE.
  ///
  /// La specifica (§10.9) e' esplicita: mai modellare una deviazione a
  /// livello di linea, perche' quasi tutte sono asimmetriche. GTT infatti
  /// scrive "nella sola direzione Derna", e la 94 ha due avvisi distinti
  /// per le due direzioni. Calcolare le fermate saltate sempre contro
  /// l'andata darebbe fermate sbagliate per meta' degli avvisi.
  final RouteShape shape;

  final Confidence confidence;
  final ParsedDeviation? parsed;
  final List<GeoPoint>? deviatedGeometry;
  final StopImpactResult? impact;

  /// Perche' non siamo arrivati fino in fondo. Va mostrato: dire "non ho
  /// saputo ricostruirlo" e' onesto, disegnare un percorso a caso no.
  final String? whyIncomplete;

  /// Dove rientra il mezzo, e se lo ha detto GTT o l'abbiamo dedotto.
  final RejoinPoint? rejoin;

  bool get hasMap => deviatedGeometry != null && deviatedGeometry!.length > 1;
  List<StopImpact> get skippedStops => impact?.skipped ?? const [];
}

/// Stato completo di una linea.
class LineStatus {
  const LineStatus({
    required this.line,
    required this.shape,
    required this.reports,
    required this.checkedAt,
    this.shapeReturn,
    this.allShapes = const [],
  });

  final TransitLine line;

  /// La variante principale dell'andata.
  final RouteShape shape;

  /// La variante principale del ritorno, se la linea ne ha una.
  /// Una linea circolare puo' non averla.
  final RouteShape? shapeReturn;

  /// TUTTE le varianti della linea. Servono all'osservazione dei mezzi:
  /// un mezzo sulla corsa limitata non sta deviando, e confrontarlo solo
  /// con la principale lo farebbe sembrare fuori rotta.
  final List<RouteShape> allShapes;
  final List<DeviationReport> reports;
  final DateTime checkedAt;

  bool get hasDeviations => reports.isNotEmpty;

  /// I percorsi da disegnare: andata e ritorno.
  List<RouteShape> get mainShapes => [shape, ?shapeReturn];

  /// Quello che sta succedendo ADESSO.
  ///
  /// La domanda dell'utente e' al presente — "la mia fermata e' servita?"
  /// — e rispondere contando una deviazione che comincia fra tre
  /// settimane sarebbe una risposta a un'altra domanda.
  List<DeviationReport> get activeReports =>
      reports.where((r) => !r.notice.startsAfter(checkedAt)).toList();

  /// Quello che comincera'. Non si nasconde: sapere in anticipo che dal
  /// 24 agosto la tua fermata salta e' utile. Si tiene solo separato.
  List<DeviationReport> get scheduledReports =>
      reports.where((r) => r.notice.startsAfter(checkedAt)).toList();

  /// Tutte le fermate non servite, da tutti gli avvisi attivi.
  /// Una linea puo' avere piu' deviazioni contemporanee (§10.14).
  List<StopImpact> get allSkippedStops =>
      activeReports.expand((r) => r.skippedStops).toList();
}

/// La facciata del sistema: da una linea al suo stato.
///
/// Tutto il calcolo avviene **per singola linea, su richiesta**. Non si
/// monitora la rete intera: il vincolo geografico del geocoding e' il
/// percorso di QUELLA linea, ed e' proprio questo a rendere il passaggio
/// testo-geometria affidabile.
class DeviationService {
  DeviationService({
    required this.index,
    required LlmClient llm,
    Geocoder? geocoder,
    RouteBuilder? router,
    AlertsSource? alerts,
    VariazioniSource? variazioni,
  })  : _extractor = NoticeExtractor(llm: llm),
        _geocoder = geocoder ?? Geocoder(),
        _router = router ?? RouteBuilder(),
        _alerts = alerts ?? AlertsSource(),
        _variazioni = variazioni ?? VariazioniSource(),
        _resolver = LineResolver(index),
        _impact = StopImpactAnalyzer(index: index);

  final GtfsIndex index;
  final NoticeExtractor _extractor;
  final Geocoder _geocoder;
  final RouteBuilder _router;
  final AlertsSource _alerts;
  final VariazioniSource _variazioni;
  final LineResolver _resolver;
  final StopImpactAnalyzer _impact;

  /// Gli avvisi di tutte le fonti, presi una volta e riusati per tutte le
  /// linee della watchlist: sono due richieste, non due per linea.
  ///
  /// Qui le due liste si concatenano e basta: i doppioni fra le fonti li
  /// toglie [noticesFor], perche' per riconoscerli serve sapere di quale
  /// linea si sta parlando. Due variazioni diverse in due quartieri
  /// diversi possono nominare le stesse vie.
  Future<List<RawNotice>> fetchAllNotices() async {
    final out = <RawNotice>[];
    try {
      out.addAll(await _alerts.fetch());
    } on Object {
      // Una fonte che cade non deve far cadere l'altra.
    }
    try {
      out.addAll(await _variazioni.fetch());
    } on Object {
      // idem
    }
    return out;
  }

  /// Gli avvisi che riguardano [line], fra quelli gia' scaricati, con i
  /// doppioni fra le due fonti gia' uniti.
  ///
  /// L'unione avviene qui e non a monte perche' e' qui che si sa di quale
  /// linea si parla, ed e' la linea a distinguere due variazioni che
  /// nominano le stesse vie. Vale anche il contrario: una riga della
  /// tabella copre spesso piu' linee, e si unisce all'alert di ognuna.
  List<RawNotice> noticesFor(TransitLine line, List<RawNotice> all) {
    final out = <RawNotice>[];
    for (final n in all) {
      if (!n.mentionsRouteChange) continue;

      // Dagli alert il route_id arriva gia' canonico: niente da risolvere.
      if (n.routeIds.contains(line.routeId)) {
        out.add(n);
        continue;
      }
      // Dalla tabella web il nome e' scritto da un umano.
      for (final hint in n.lineHints) {
        if (_resolver
            .resolve(hint)
            .resolved
            .any((l) => l.routeId == line.routeId)) {
          out.add(n);
          break;
        }
      }
    }
    return NoticeMerge.dedupe(out);
  }

  /// Lo stato completo di una linea.
  ///
  /// [direction] 0 o 1. Se [allNotices] e' gia' disponibile lo si passa,
  /// per non riscaricare gli avvisi a ogni linea.
  Future<LineStatus> statusOf(
    TransitLine line, {
    List<RawNotice>? allNotices,
    void Function(String phase)? onProgress,
  }) async {
    final andata = index.mainShape(line.routeId, 0);
    final ritorno = index.mainShape(line.routeId, 1);
    final shape = andata ?? ritorno;
    if (shape == null) {
      throw StateError('nessuna geometria per ${line.shortName}');
    }

    final notices = noticesFor(line, allNotices ?? await fetchAllNotices());
    final reports = <DeviationReport>[];

    for (final notice in notices) {
      onProgress?.call('leggo l\'avviso');
      // Un avviso puo' riguardare una direzione sola, o entrambe. Va
      // analizzato contro il percorso GIUSTO, altrimenti le fermate
      // saltate sono quelle dell'altro senso di marcia.
      for (final s in shapesConcernedBy(notice, andata, ritorno)) {
        reports.add(await _analyze(notice, s));
      }
    }

    return LineStatus(
      line: line,
      shape: shape,
      shapeReturn: identical(shape, andata) ? ritorno : null,
      allShapes: index.shapesOf(line.routeId),
      reports: reports,
      checkedAt: DateTime.now(),
    );
  }

  /// Quali direzioni riguarda un avviso.
  ///
  /// GTT lo dice quasi sempre, nominando il capolinea: "nella sola
  /// direzione Derna", "in direzione piazza Statuto". Il confronto e' col
  /// nome del capolinea che sta nel GTFS. Se non si capisce, si analizzano
  /// **entrambe**: meglio due rapporti, uno dei quali superfluo, che uno
  /// solo riferito al senso di marcia sbagliato.
  static List<RouteShape> shapesConcernedBy(
    RawNotice notice,
    RouteShape? andata,
    RouteShape? ritorno,
  ) {
    final both = [?andata, ?ritorno];
    if (both.length < 2) return both;

    final words = _words('${notice.fullText} ${notice.directionHint ?? ''}');
    final matched = both.where((s) {
      // Confronto per PAROLE INTERE, non per sottostringhe: "lavori
      // stradali" conteneva "strada" e faceva scattare il capolinea
      // "STRADA DEL DROSSO", assegnando l'avviso alla direzione sbagliata.
      final head = _words(s.headsign);
      return head.isNotEmpty && head.any(words.contains);
    }).toList();

    return matched.length == 1 ? matched : both;
  }

  /// Parole significative di un testo, per il confronto coi capolinea.
  ///
  /// Si scartano i qualificatori generici: "via", "corso", "strada" e
  /// simili compaiono in ogni avviso e in meta' dei capolinea, quindi
  /// farebbero corrispondere tutto con tutto.
  static const _genericWords = {
    'via', 'viale', 'corso', 'piazza', 'piazzale', 'largo', 'strada',
    'ponte', 'lungo', 'sud', 'nord', 'est', 'ovest', 'della', 'delle',
    'dello', 'degli', 'linea', 'direzione', 'entrambe', 'capolinea',
  };

  static Set<String> _words(String s) => s
      .toLowerCase()
      .replaceAll('\u2019', "'")
      .split(RegExp(r"[^a-zà-ù0-9']+"))
      .where((w) => w.length >= 4 && !_genericWords.contains(w))
      .toSet();

  /// Perche' la lettura del testo non e' riuscita, detto a chi usa l'app.
  ///
  /// Non basta dire "errore": alcune cause sono azionabili — la quota
  /// giornaliera si azzera, una chiave sbagliata si corregge — e altre no.
  /// Chi legge deve capire se puo' fare qualcosa o solo aspettare.
  static String _lowerFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  static String explainExtractionFailure(ExtractionResult r) {
    final detail = r.detail ?? '';
    if (detail.contains('free-models-per-day')) {
      // L'orario si dice in ORA LOCALE. Il fornitore ragiona in UTC, ma
      // chi legge il messaggio all'una di notte no: "si azzerano a
      // mezzanotte UTC" sembra sbagliato quando la mezzanotte e' passata
      // da un'ora.
      final when = _localTime(r.retryAfter);
      return 'Ho finito le richieste gratuite di oggi (sono 50). '
          '${when == null ? "Si azzerano a mezzanotte UTC, cioè alle 2 di "
              "notte in Italia." : "Riprova dopo le $when."}';
    }
    if (detail.contains('429')) {
      return 'Il servizio è momentaneamente sovraccarico. Riprova fra poco.';
    }
    if (detail.contains('401') || detail.contains('403')) {
      return 'La chiave non è valida. Controllala nelle impostazioni.';
    }
    if (detail.contains('non raggiungibile') ||
        detail.contains('TimeoutException')) {
      return 'Non sono riuscito a contattare il servizio. '
          'Controlla la connessione.';
    }
    if (r.status == ExtractionStatus.parseFailed) {
      return 'Ho letto l\'avviso ma non sono riuscito a ricavarne '
          'il percorso.';
    }
    return 'Non sono riuscito a interpretare il testo dell\'avviso.';
  }

  /// L'orario in cui riprovare, nel fuso di chi legge.
  static String? _localTime(DateTime? utcOrLocal) {
    if (utcOrLocal == null) return null;
    final t = utcOrLocal.toLocal();
    return '${t.hour.toString().padLeft(2, "0")}:'
        '${t.minute.toString().padLeft(2, "0")}';
  }

  Future<DeviationReport> _analyze(RawNotice notice, RouteShape shape) async {
    // 1. Testo -> struttura.
    final extraction = await _extractor.extract(notice);
    if (!extraction.isUsable) {
      // L'LLM non ha risposto — quota finita, rete, servizio giu'. Ma se
      // GTT ha scritto un numero di fermata, quel numero sta nel testo e
      // lo prende una regex: non serve nessun modello per leggerlo.
      // Sarebbe assurdo perdere il dato piu' certo che abbiamo proprio
      // quando tutto il resto non funziona.
      final impact = _impact.declaredOnly(
          officialRoute: shape,
          declaredCodes: notice.suspendedStopCodes.toSet());
      if (impact.hasImpact) {
        return DeviationReport(
          notice: notice,
          shape: shape,
          impact: impact,
          // Non "confermata": senza estrazione non sappiamo se l'avviso
          // dica anche altro, per esempio un cambio di percorso che non
          // abbiamo ricostruito.
          confidence: Confidence.probabile,
          whyIncomplete: 'La fermata sospesa la dichiara GTT, quella è '
              'certa. Del resto dell\'avviso non so dirti: '
              '${_lowerFirst(explainExtractionFailure(extraction))}',
        );
      }
      return DeviationReport(
        notice: notice,
        shape: shape,
        confidence: Confidence.soloTesto,
        whyIncomplete: explainExtractionFailure(extraction),
      );
    }
    final parsed = extraction.deviations.first;

    // Una sostituzione di mezzo non cambia il percorso: mostrarla come
    // deviazione sarebbe un allarme falso (§10.10).
    if (parsed.type == DeviationType.sostituzioneModale) {
      return DeviationReport(
        notice: notice,
        shape: shape,
        parsed: parsed,
        confidence: Confidence.confermata,
        whyIncomplete: 'stesso percorso, cambia solo il tipo di mezzo',
      );
    }

    // 1-bis. Fermate sospese senza cambio di percorso.
    //
    // MISURATO: 14 avvisi su 198 dicono soltanto "Fermata 3447 Sabotino
    // sospesa". Il codice sta nel testo, non in informed_entity, e si
    // estrae con una regex. Prima finivano nel ramo "non nomina abbastanza
    // vie" e l'informazione si perdeva, pur essendo la piu' certa che il
    // sistema abbia: nessuna geometria da ricostruire, solo un codice da
    // cercare nel GTFS.
    final declaredCodes = <String>{
      ...notice.suspendedStopCodes,
      ...parsed.suspendedStopCodes,
    };
    if (declaredCodes.isNotEmpty && parsed.viaSequence.isEmpty) {
      final impact = _impact.declaredOnly(
          officialRoute: shape, declaredCodes: declaredCodes);
      return DeviationReport(
        notice: notice,
        shape: shape,
        parsed: parsed,
        impact: impact,
        confidence: Confidence.confermata,
        whyIncomplete: impact.hasImpact
            ? null
            : 'GTT nomina ${declaredCodes.length == 1 ? "una fermata" : "delle fermate"} '
                '(${declaredCodes.join(", ")}) che non trovo su questa linea: '
                'potrebbe riguardarne un\'altra',
      );
    }

    // 2. Toponimi -> coordinate, vincolate al percorso di questa linea.
    final toponyms = parsed.allToponyms;
    if (toponyms.length < 2) {
      return DeviationReport(
        notice: notice,
        shape: shape,
        parsed: parsed,
        confidence: Confidence.soloTesto,
        whyIncomplete: 'l\'avviso non nomina abbastanza vie per '
            'ricostruire il percorso',
      );
    }

    final points = <GeoPoint>[];
    final unresolved = <String>[];
    for (final t in toponyms) {
      final r = await _geocoder.locate(t,
          near: shape, municipality: parsed.municipality);
      if (r.isUsable) {
        points.add(r.point!);
      } else {
        unresolved.add(t);
      }
    }
    if (points.length < 2) {
      return DeviationReport(
        notice: notice,
        shape: shape,
        parsed: parsed,
        confidence: Confidence.soloTesto,
        whyIncomplete: 'non ho trovato sulla mappa: ${unresolved.join(", ")}',
      );
    }

    // 2-bis. Dove rientra.
    //
    // MISURATO: 24 avvisi su 28 non nominano la via di rientro, dicono solo
    // "percorso normale". Senza dedurlo il percorso deviato si ferma
    // all'ultima via nominata, il tratto di linea interessato resta
    // troncato, e le fermate fra li' e il rientro vero non vengono valutate.
    final RejoinPoint rejoin;
    if (parsed.rejoinStreet != null) {
      // GTT l'ha detto: il punto e' gia' fra quelli geocodificati.
      rejoin = RejoinPoint(
        source: RejoinSource.dichiarato,
        point: points.last,
      );
    } else {
      rejoin = RejoinInference.infer(
        officialRoute: shape,
        detachPoint: points.first,
        lastVia: points.last,
      );
    }

    // Il punto dedotto diventa l'ultimo waypoint: cosi' il percorso
    // calcolato arriva fino al rientro invece di fermarsi prima.
    final waypoints = [
      ...points,
      if (rejoin.source == RejoinSource.dedotto) rejoin.point!,
    ];

    // 3. Punti -> percorso vero, con le cinque prove.
    final route = await _router.build(
      waypoints: waypoints,
      officialRoute: shape,
      // Le vie da attraversare restano quelle NOMINATE: il rientro dedotto
      // e' una nostra inferenza, non una promessa di GTT, e pretendere che
      // il percorso ci passi vicino sarebbe verificare noi stessi.
      requiredVias: points.sublist(1),
    );
    if (route.geometry == null) {
      return DeviationReport(
        notice: notice,
        shape: shape,
        parsed: parsed,
        rejoin: rejoin,
        confidence: Confidence.soloTesto,
        whyIncomplete: 'non sono riuscito a tracciare il percorso deviato',
      );
    }

    // 4. Quali fermate saltano.
    final impact = _impact.analyze(
      officialRoute: shape,
      deviatedRoute: route.geometry!,
      declaredSuspendedCodes: {
        ...notice.suspendedStopCodes,
        ...parsed.suspendedStopCodes,
      },
    );

    return DeviationReport(
      notice: notice,
      shape: shape,
      parsed: parsed,
      rejoin: rejoin,
      deviatedGeometry: route.geometry,
      impact: impact,
      confidence: route.isUsable && unresolved.isEmpty
          ? Confidence.confermata
          : Confidence.probabile,
      whyIncomplete: route.isUsable && unresolved.isEmpty
          ? null
          : [
              if (unresolved.isNotEmpty)
                'non ho trovato: ${unresolved.join(", ")}',
              if (!rejoin.isUsable && rejoin.whyNot != null) rejoin.whyNot!,
              ...route.failures.map((f) => f.message),
            ].join('; '),
    );
  }
}
