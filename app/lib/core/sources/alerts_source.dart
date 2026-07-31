import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';

import '../config.dart';
import '../models/notice.dart';
import '../net/gtt_http.dart';

/// Legge gli avvisi di servizio dal feed GTFS-Realtime di GTT.
///
/// E' la fonte migliore per collegare un avviso a una linea: MISURATO, il
/// campo `informed_entity.route_id` e' popolato nel 96,7% dei 181 alert
/// attivi, gia' in forma canonica ("55U", "19U"). Per questi avvisi il
/// problema degli alias di §4.1 semplicemente non si pone.
///
/// Quello che invece NON da', nonostante le apparenze: le fermate
/// impattate. Gli `stop_id` in `informed_entity` sono tutte le fermate
/// della linea, non quelle sospese — verificato sulla linea 82, che ne
/// dichiara 31 e ne ha in tutto esattamente 31. I codici veri stanno nel
/// testo, e li estrae [RawNotice.suspendedStopCodes].
class AlertsSource {
  AlertsSource({GttHttp? http}) : _http = http ?? GttHttp();

  final GttHttp _http;

  Future<List<RawNotice>> fetch() async {
    final bytes = await _http.getBytes(GttConfig.alertsUrl);
    return parse(bytes);
  }

  /// Separato da [fetch] per poterlo provare su un payload salvato.
  List<RawNotice> parse(List<int> bytes) {
    final feed = FeedMessage.fromBuffer(bytes);
    final out = <RawNotice>[];

    for (final entity in feed.entity) {
      if (!entity.hasAlert()) continue;
      final alert = entity.alert;

      final headline = _text(alert.headerText);
      final body = _text(alert.descriptionText);
      if ((headline ?? '').isEmpty && (body ?? '').isEmpty) continue;

      final routeIds = <String>{};
      for (final sel in alert.informedEntity) {
        if (sel.routeId.isNotEmpty) routeIds.add(sel.routeId);
      }

      out.add(RawNotice(
        id: 'alert-${entity.id}',
        source: NoticeSource.gtfsRtAlert,
        headline: headline,
        text: body ?? '',
        routeIds: routeIds.toList()..sort(),
        reason: alert.hasCause() ? alert.cause.name : null,
        effect: alert.hasEffect() ? alert.effect.name : null,
        validFrom: _periodStart(alert),
        validUntil: _periodEnd(alert),
        sourceUrl: GttConfig.alertsUrl,
      ));
    }
    return out;
  }

  static String? _text(TranslatedString s) {
    if (s.translation.isEmpty) return null;
    // GTT pubblica una traduzione sola; se un giorno ne aggiungesse,
    // l'italiano resta la scelta giusta per questa app.
    for (final t in s.translation) {
      if (t.language.toLowerCase().startsWith('it')) return t.text;
    }
    return s.translation.first.text;
  }

  static DateTime? _periodStart(Alert a) {
    if (a.activePeriod.isEmpty) return null;
    final p = a.activePeriod.first;
    return p.hasStart() ? _fromEpoch(p.start.toInt()) : null;
  }

  static DateTime? _periodEnd(Alert a) {
    if (a.activePeriod.isEmpty) return null;
    final p = a.activePeriod.first;
    return p.hasEnd() ? _fromEpoch(p.end.toInt()) : null;
  }

  static DateTime? _fromEpoch(int seconds) =>
      seconds <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}
