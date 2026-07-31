import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/deviation_service.dart';
import '../core/gtfs/gtfs_downloader.dart';
import '../core/gtfs/gtfs_parser.dart';
import '../core/llm/openai_compatible_client.dart';
import '../core/models/notice.dart';
import '../core/models/transit.dart';
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

      for (final line in index.lines.values) {
        phase = 'linea ${line.shortName}';
        notifyListeners();
        try {
          _statuses[line.routeId] =
              await service.statusOf(line, allNotices: _notices);
        } on Object catch (e) {
          // Una linea che fallisce non deve bloccare le altre.
          debugPrint('linea ${line.shortName}: $e');
        }
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
