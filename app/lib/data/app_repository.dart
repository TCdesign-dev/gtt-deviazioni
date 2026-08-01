import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/deviation_service.dart';
import '../core/gtfs/gtfs_downloader.dart';
import '../core/gtfs/gtfs_parser.dart';
import '../core/llm/openai_compatible_client.dart';
import '../core/models/notice.dart';
import '../core/models/transit.dart';
import '../core/pipeline/vehicle_watch.dart';
import 'settings.dart';

/// A che punto e' l'avvio.
enum LoadState { idle, loading, ready, error }

/// Tiene insieme dati e servizi, e avvisa l'interfaccia quando cambia
/// qualcosa.
///
/// Deliberatamente sottile: la logica sta tutta in `core/`, che non sa
/// nulla di Flutter. Qui c'e' solo l'orchestrazione e lo stato visibile.
class AppRepository extends ChangeNotifier {
  AppRepository(this.settings);

  final Settings settings;

  LoadState state = LoadState.idle;
  String phase = '';
  double progress = 0;
  String? error;

  GtfsIndex? index;
  DeviationService? _service;

  final Map<String, LineStatus> _statuses = {};
  List<RawNotice> _notices = const [];
  DateTime? lastRefresh;

  LineStatus? statusOf(String routeId) => _statuses[routeId];
  List<LineStatus> get statuses => _statuses.values.toList(growable: false);

  /// Le linee che si stanno controllando adesso.
  ///
  /// Il controllo di una linea sola non deve coprire la schermata: le
  /// altre restano leggibili, e chi guarda vede girare solo la riga che
  /// ha chiesto.
  final Set<String> _busy = {};
  bool isChecking(String routeId) => _busy.contains(routeId);

  /// A che punto e' il controllo di quella linea.
  ///
  /// Una rotella che gira e basta, per mezzo minuto, e' indistinguibile
  /// da un'app bloccata. Dire "avviso 2 di 4: cerco «corso Lecce» sulla
  /// mappa" costa niente e cambia tutto.
  final Map<String, String> _phaseOf = {};
  String? phaseOfLine(String routeId) => _phaseOf[routeId];
  bool get isCheckingAny => _busy.isNotEmpty;

  // ---------------------------------------------------------------
  // Osservazione dei mezzi
  //
  // Vive QUI e non nella schermata perche' deve sopravvivere alla
  // navigazione: uno fa partire l'osservazione sulla 15, va a guardare
  // la 4, e quando torna la deve ritrovare in corso. Nella schermata
  // moriva al primo `Navigator.pop`.
  //
  // **Una linea alla volta.** Non e' una limitazione tecnica ma una
  // scelta: due osservazioni in parallelo raddoppiano le richieste al
  // feed di GTT, e nessuno guarda due linee insieme. Farne partire una
  // nuova ferma la precedente, e l'interfaccia lo dice.
  // ---------------------------------------------------------------

  /// La linea che si sta osservando adesso. null se nessuna.
  String? watchingRouteId;

  /// Da quando si sta guardando, e per quanto era stato chiesto.
  ///
  /// Servono a dire "ancora 3 min" invece di "5 min": la durata scelta
  /// non dice niente di utile mentre gira, l'hai scelta tu poco fa.
  DateTime? watchStartedAt;
  Duration? watchMaxDuration;

  /// L'osservazione senza fine: si mostra il tempo trascorso, non quello
  /// che manca, perche' non manca niente.
  bool get watchIsContinuous =>
      watchMaxDuration != null && watchMaxDuration! >= const Duration(hours: 1);

  /// Quanto manca. null in modalita' continua o se non si sta guardando.
  Duration? get watchRemaining {
    final da = watchStartedAt;
    final max = watchMaxDuration;
    if (da == null || max == null || watchIsContinuous) return null;
    final resta = max - DateTime.now().difference(da);
    return resta.isNegative ? Duration.zero : resta;
  }

  /// Da quanto si sta guardando.
  Duration? get watchElapsed => watchStartedAt == null
      ? null
      : DateTime.now().difference(watchStartedAt!);

  int watchSamples = 0;
  List<VehicleTrack> liveTracks = const [];
  String? watchError;

  /// Gli esiti, per linea: tornando su una linea si rivede il suo.
  final Map<String, WatchResult> _watchResults = {};
  WatchResult? watchResultOf(String routeId) => _watchResults[routeId];

  bool isWatching(String routeId) => watchingRouteId == routeId;

  /// Il nome della linea osservata, per dirlo altrove nell'app.
  String? get watchingLineName =>
      watchingRouteId == null ? null : index?.lines[watchingRouteId]?.shortName;

  bool _stopWatchRequested = false;

  /// Comincia a guardare i mezzi di [line] per [maxDuration].
  ///
  /// Se se ne stava gia' guardando un'altra, quella si ferma: [stopWatch]
  /// viene chiamato prima, e il ciclo vecchio se ne accorge al giro
  /// successivo perche' `watchingRouteId` non e' piu' il suo.
  Future<void> startWatch(TransitLine line, Duration maxDuration) async {
    if (watchingRouteId != null) stopWatch();

    watchingRouteId = line.routeId;
    watchStartedAt = DateTime.now();
    watchMaxDuration = maxDuration;
    _stopWatchRequested = false;
    watchSamples = 0;
    liveTracks = const [];
    watchError = null;
    _watchResults.remove(line.routeId);
    notifyListeners();

    final status = _statuses[line.routeId];
    if (status == null) {
      watchingRouteId = null;
      notifyListeners();
      return;
    }

    try {
      final result = await VehicleWatch(maxDuration: maxDuration).watch(
        line: status.line,
        shapes:
            status.allShapes.isNotEmpty ? status.allShapes : [status.shape],
        onProgress: (samples, tracks) {
          // Se nel frattempo si e' passati a un'altra linea, questo ciclo
          // e' un fantasma: non deve scrivere piu' niente.
          if (watchingRouteId != line.routeId) return;
          watchSamples = samples;
          liveTracks = tracks;
          notifyListeners();
        },
        shouldStop: () =>
            _stopWatchRequested || watchingRouteId != line.routeId,
      );
      if (watchingRouteId == line.routeId) {
        _watchResults[line.routeId] = result;
        liveTracks = result.tracks;
      }
    } on Object catch (e) {
      if (watchingRouteId == line.routeId) watchError = '$e';
    } finally {
      if (watchingRouteId == line.routeId) {
        watchingRouteId = null;
        watchStartedAt = null;
        watchMaxDuration = null;
      }
      notifyListeners();
    }
  }

  void stopWatch() {
    _stopWatchRequested = true;
    watchingRouteId = null;
    watchStartedAt = null;
    watchMaxDuration = null;
    notifyListeners();
  }

  /// La linea che si sta osservando, per aprirla da un punto qualsiasi.
  TransitLine? get watchingLine =>
      watchingRouteId == null ? null : index?.lines[watchingRouteId];

  /// Quando una linea e' stata controllata l'ultima volta.
  ///
  /// Con il controllo per singola linea le righe non sono piu' tutte
  /// dello stesso momento, e dire "controllate alle 14:03" sarebbe falso
  /// per quelle che non lo sono.
  final Map<String, DateTime> _checkedAt = {};
  DateTime? checkedAt(String routeId) => _checkedAt[routeId];

  /// Scarica il GTFS se serve e costruisce l'indice per le linee scelte.
  Future<void> initialise({bool forceDownload = false}) async {
    if (settings.watchlist.isEmpty) {
      state = LoadState.ready;
      notifyListeners();
      return;
    }

    state = LoadState.loading;
    error = null;
    notifyListeners();

    try {
      final dir = Directory(
          '${(await getApplicationSupportDirectory()).path}/gtfs');
      final downloader = GtfsDownloader(directory: dir);

      await downloader.ensureAvailable(
        force: forceDownload,
        onProgress: (p, f) {
          phase = p;
          progress = f * 0.6;
          notifyListeners();
        },
      );

      phase = 'preparo le tue linee';
      notifyListeners();

      index = await GtfsParser(
        directory: dir,
        onProgress: (p, f) {
          phase = p;
          progress = 0.6 + f * 0.4;
          notifyListeners();
        },
      ).build(settings.watchlist);

      _service = _buildService();
      state = LoadState.ready;
      phase = '';
      progress = 1;
    } on Object catch (e) {
      state = LoadState.error;
      error = _readable(e);
    }
    notifyListeners();
  }

  DeviationService? _buildService() {
    final index = this.index;
    final key = settings.apiKey;
    if (index == null || key == null) return null;
    return DeviationService(
      index: index,
      llm: OpenAiCompatibleClient.openRouter(
          apiKey: key, model: settings.model),
    );
  }

  /// Ricontrolla tutte le linee della watchlist.
  ///
  /// Gli avvisi si scaricano UNA volta e si riusano per tutte le linee:
  /// sono due richieste in tutto, non due per linea.
  Future<void> refreshAll() async {
    _service ??= _buildService();
    final service = _service;
    final index = this.index;
    if (service == null || index == null) return;

    state = LoadState.loading;
    phase = 'controllo gli avvisi di GTT';
    notifyListeners();

    try {
      _notices = await service.fetchAllNotices();

      final lines = index.lines.values.toList();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        progress = lines.length == 1 ? 0 : i / lines.length;
        phase = 'linea ${line.shortName}';
        notifyListeners();
        _busy.add(line.routeId);
        await _checkOne(service, line, _notices);
        _busy.remove(line.routeId);
        _phaseOf.remove(line.routeId);
      }
      lastRefresh = DateTime.now();
      state = LoadState.ready;
      phase = '';
    } on Object catch (e) {
      state = LoadState.error;
      error = _readable(e);
    }
    notifyListeners();
  }

  /// Ricontrolla UNA linea sola.
  ///
  /// Le richieste all'LLM sono contate — 50 gratuite al giorno, e un
  /// avviso ne consuma una — quindi ricontrollare tutta la watchlist per
  /// sapere di una linea sola e' uno spreco vero, non un dettaglio.
  ///
  /// Gli avvisi si riscaricano: sono due richieste HTTP senza chiave e
  /// senza costo, e controllare adesso su dati di mezz'ora fa vorrebbe
  /// dire rispondere alla domanda sbagliata.
  Future<void> refreshLine(TransitLine line) async {
    _service ??= _buildService();
    final service = _service;
    if (service == null || _busy.contains(line.routeId)) return;

    _busy.add(line.routeId);
    _phaseOf[line.routeId] = 'chiedo gli avvisi a GTT';
    error = null;
    notifyListeners();

    try {
      _notices = await service.fetchAllNotices();
      await _checkOne(service, line, _notices);
      lastRefresh = DateTime.now();
      if (state != LoadState.ready) state = LoadState.ready;
    } on Object catch (e) {
      // Non si passa a LoadState.error: una linea che fallisce non deve
      // cancellare dallo schermo il risultato delle altre.
      error = _readable(e);
    } finally {
      _busy.remove(line.routeId);
      _phaseOf.remove(line.routeId);
      notifyListeners();
    }
  }

  Future<void> _checkOne(
      DeviationService service, TransitLine line, List<RawNotice> notices) async {
    try {
      _statuses[line.routeId] = await service.statusOf(
        line,
        allNotices: notices,
        onProgress: (p) {
          _phaseOf[line.routeId] = p;
          notifyListeners();
        },
      );
      _checkedAt[line.routeId] = DateTime.now();
    } on Object catch (e) {
      // Una linea che fallisce non deve bloccare le altre.
      debugPrint('linea ${line.shortName}: $e');
    }
  }

  Future<void> addLine(String line) async {
    await settings.addLine(line);
    await initialise();
  }

  Future<void> removeLine(String line) async {
    await settings.removeLine(line);
    _statuses.clear();
    await initialise();
  }

  Future<void> setApiKey(String key) async {
    await settings.setApiKey(key);
    _service = _buildService();
    notifyListeners();
  }

  static String _readable(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('non raggiungibile')) {
      return 'Non riesco a raggiungere la rete. Riprova quando hai '
          'connessione.';
    }
    return s;
  }
}
