import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/deviation_service.dart';
import '../core/geo/projection.dart';
import '../core/models/notice.dart';
import '../core/models/transit.dart';
import '../core/pipeline/stop_impact.dart';

/// Gli esiti dei controlli, che sopravvivono alla chiusura dell'app.
///
/// Senza, riaprendo l'app tutte le linee tornavano «non ancora
/// controllata» e bisognava rifare tutto da capo. Con **cinquanta
/// richieste gratuite al giorno**, e una consumata per avviso, era lo
/// spreco più costoso che ci fosse: bastavano due riaperture per bruciare
/// la quota di una giornata.
///
/// ## Cosa si salva, e cosa no
///
/// Si salva solo quello che **costa**: l'esito dell'estrazione dal testo
/// (una richiesta LLM per avviso), la geometria ricostruita (geocoding
/// più routing, con le pause di cortesia verso i servizi pubblici) e le
/// fermate che ne risultano.
///
/// NON si salva quello che si ricalcola gratis dal GTFS già in memoria:
/// i percorsi, le coordinate delle fermate, i capolinea. Di quelli si
/// tiene solo l'identificatore e si ripescano all'avvio. Un percorso ha
/// centinaia di punti: metterlo nella cache significherebbe scrivere
/// megabyte per riottenere una cosa che è già lì.
///
/// ## Perché non scade
///
/// Un esito vecchio **non si butta e non si spaccia per fresco**: si
/// mostra con la sua data. L'interfaccia scrive «controllata ieri alle
/// 19:08», e chi legge decide se gli basta. Nascondere un dato vecchio
/// costringerebbe a ricontrollare per forza; mostrarlo senza data sarebbe
/// una bugia. La terza via — dirlo — è l'unica onesta.
///
/// La cache si butta invece quando **cambia il GTFS**: gli identificatori
/// dei percorsi possono cambiare da un giorno all'altro, e un esito
/// agganciato a un percorso che non esiste più non si può ricostruire.
class StatusCache {
  const StatusCache._();

  static const _key = 'esiti_controlli_v1';

  /// Oltre questa età un esito non si ripesca nemmeno: una deviazione
  /// dopo una settimana o è finita o è cambiata, e mostrarla anche solo
  /// come «vecchia» sarebbe rumore.
  static const maxAge = Duration(days: 7);

  static Future<void> save(
    Iterable<LineStatus> statuses, {
    required String? feedVersion,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({
          'feedVersion': feedVersion,
          'linee': [for (final s in statuses) _statusToJson(s)],
        }),
      );
    } on Object catch (e) {
      // Non riuscire a salvare non deve rompere niente: al massimo la
      // prossima volta si ricontrolla.
      debugPrint('cache non salvata: $e');
    }
  }

  /// Rilegge gli esiti, ricostruendo percorsi e fermate dall'indice.
  ///
  /// Qualunque incoerenza fa saltare quella singola linea, non tutte:
  /// meglio riottenere tre linee su quattro che perdere tutto per un
  /// percorso sparito.
  static Future<Map<String, LineStatus>> load(GtfsIndex index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return {};

      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['feedVersion'] != index.feedVersion) {
        // Orari nuovi: gli identificatori dei percorsi possono essere
        // cambiati sotto, e un esito agganciato al vecchio non regge.
        await prefs.remove(_key);
        return {};
      }

      final out = <String, LineStatus>{};
      for (final l in (data['linee'] as List).cast<Map<String, dynamic>>()) {
        final s = _statusFromJson(l, index);
        if (s != null) out[s.line.routeId] = s;
      }
      return out;
    } on Object catch (e) {
      debugPrint('cache illeggibile, la butto: $e');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
      return {};
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  // ---------------------------------------------------------------

  static Map<String, dynamic> _statusToJson(LineStatus s) => {
        'routeId': s.line.routeId,
        'checkedAt': s.checkedAt.toIso8601String(),
        'reports': [for (final r in s.reports) _reportToJson(r)],
      };

  static LineStatus? _statusFromJson(Map<String, dynamic> j, GtfsIndex index) {
    final line = index.lines[j['routeId']];
    if (line == null) return null;

    final checkedAt = DateTime.tryParse(j['checkedAt'] as String? ?? '');
    if (checkedAt == null) return null;
    if (DateTime.now().difference(checkedAt) > maxAge) return null;

    final andata = index.mainShape(line.routeId, 0);
    final ritorno = index.mainShape(line.routeId, 1);
    final shape = andata ?? ritorno;
    if (shape == null) return null;

    final reports = <DeviationReport>[];
    for (final r in (j['reports'] as List).cast<Map<String, dynamic>>()) {
      final rep = _reportFromJson(r, index, line);
      if (rep != null) reports.add(rep);
    }

    return LineStatus(
      line: line,
      shape: shape,
      shapeReturn: identical(shape, andata) ? ritorno : null,
      allShapes: index.shapesOf(line.routeId),
      reports: reports,
      checkedAt: checkedAt,
    );
  }

  static Map<String, dynamic> _reportToJson(DeviationReport r) => {
        'shapeId': r.shape.shapeId,
        'confidence': r.confidence.name,
        'whyIncomplete': r.whyIncomplete,
        'notice': _noticeToJson(r.notice),
        if (r.deviatedGeometry != null)
          'geometry': [
            for (final p in r.deviatedGeometry!) [p.lat, p.lon],
          ],
        if (r.impact != null) 'impact': _impactToJson(r.impact!),
      };

  static DeviationReport? _reportFromJson(
      Map<String, dynamic> j, GtfsIndex index, TransitLine line) {
    final shapes = index.shapesOf(line.routeId);
    final shape = shapes.where((s) => s.shapeId == j['shapeId']).firstOrNull;
    // Il percorso non c'e' piu': l'esito non e' ricostruibile, e mostrarlo
    // agganciato a un percorso diverso darebbe fermate sbagliate.
    if (shape == null) return null;

    final notice = _noticeFromJson(j['notice'] as Map<String, dynamic>);
    if (notice == null) return null;

    return DeviationReport(
      notice: notice,
      shape: shape,
      confidence: Confidence.values
              .where((c) => c.name == j['confidence'])
              .firstOrNull ??
          Confidence.soloTesto,
      whyIncomplete: j['whyIncomplete'] as String?,
      deviatedGeometry: (j['geometry'] as List?)
          ?.map((p) => GeoPoint((p as List)[0] as double, p[1] as double))
          .toList(growable: false),
      impact: j['impact'] == null
          ? null
          : _impactFromJson(j['impact'] as Map<String, dynamic>, index),
    );
  }

  static Map<String, dynamic> _noticeToJson(RawNotice n) => {
        'id': n.id,
        'source': n.source.name,
        'headline': n.headline,
        'text': n.text,
        'routeIds': n.routeIds,
        'lineHints': n.lineHints,
        'directionHint': n.directionHint,
        'reason': n.reason,
        'effect': n.effect,
        'validFrom': n.validFrom?.toIso8601String(),
        'validUntil': n.validUntil?.toIso8601String(),
        'sourceUrl': n.sourceUrl,
        // Solo un livello: gli avvisi uniti sono due, e i loro `mergedFrom`
        // sono sempre vuoti. Serve a `isMerged` e ai codici fermata, che si
        // cercano in tutti i testi.
        'mergedFrom': [
          for (final m in n.mergedFrom)
            {
              'id': m.id,
              'source': m.source.name,
              'headline': m.headline,
              'text': m.text,
              'sourceUrl': m.sourceUrl,
            },
        ],
      };

  static RawNotice? _noticeFromJson(Map<String, dynamic> j) {
    final source = NoticeSource.values
        .where((s) => s.name == j['source'])
        .firstOrNull;
    if (source == null) return null;
    return RawNotice(
      id: j['id'] as String? ?? '',
      source: source,
      headline: j['headline'] as String?,
      text: j['text'] as String? ?? '',
      routeIds: (j['routeIds'] as List?)?.cast<String>() ?? const [],
      lineHints: (j['lineHints'] as List?)?.cast<String>() ?? const [],
      directionHint: j['directionHint'] as String?,
      reason: j['reason'] as String?,
      effect: j['effect'] as String?,
      validFrom: DateTime.tryParse(j['validFrom'] as String? ?? ''),
      validUntil: DateTime.tryParse(j['validUntil'] as String? ?? ''),
      sourceUrl: j['sourceUrl'] as String? ?? '',
      mergedFrom: [
        for (final m in (j['mergedFrom'] as List? ?? const [])
            .cast<Map<String, dynamic>>())
          RawNotice(
            id: m['id'] as String? ?? '',
            source: NoticeSource.values
                    .where((s) => s.name == m['source'])
                    .firstOrNull ??
                source,
            headline: m['headline'] as String?,
            text: m['text'] as String? ?? '',
            sourceUrl: m['sourceUrl'] as String? ?? '',
          ),
      ],
    );
  }

  static Map<String, dynamic> _impactToJson(StopImpactResult i) => {
        'from': i.affectedFromMeters,
        'to': i.affectedToMeters,
        'stops': [
          for (final s in i.impacts)
            {
              'id': s.stop.id,
              'status': s.status.name,
              'meters': s.metersFromDeviatedRoute,
              'alt': [
                for (final a in s.alternatives)
                  {
                    'id': a.stop.id,
                    'm': a.straightMeters,
                    'same': a.sameLine,
                  },
              ],
            },
        ],
      };

  static StopImpactResult _impactFromJson(
      Map<String, dynamic> j, GtfsIndex index) {
    final impacts = <StopImpact>[];
    for (final s in (j['stops'] as List).cast<Map<String, dynamic>>()) {
      final stop = index.stops[s['id']];
      if (stop == null) continue;
      impacts.add(StopImpact(
        stop: stop,
        status: StopStatus.values
                .where((x) => x.name == s['status'])
                .firstOrNull ??
            StopStatus.skipped,
        metersFromDeviatedRoute: (s['meters'] as num?)?.toDouble(),
        alternatives: [
          for (final a in (s['alt'] as List? ?? const [])
              .cast<Map<String, dynamic>>())
            if (index.stops[a['id']] case final alt?)
              StopAlternative(
                stop: alt,
                straightMeters: (a['m'] as num).toDouble(),
                sameLine: a['same'] as bool? ?? false,
              ),
        ],
      ));
    }
    return StopImpactResult(
      impacts: impacts,
      affectedFromMeters: (j['from'] as num?)?.toDouble() ?? 0,
      affectedToMeters: (j['to'] as num?)?.toDouble() ?? 0,
    );
  }
}
