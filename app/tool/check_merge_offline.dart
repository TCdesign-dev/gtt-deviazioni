// Misura l'unione degli avvisi sui dati veri, offline.
//
// Serve a tarare le due soglie di GttConfig (mergeMinStreetOverlap,
// mergeMinSharedStreets) e a rimisurarle quando cambia qualcosa: stampa
// TUTTE le coppie stessa-linea con il loro punteggio, cosi' si vede dove
// passa il confine fra le coppie vere e le false invece di crederci.
//
//   cd app && dart run tool/check_merge_offline.dart
//
// Usa le fixture del 31/07/2026 in test/fixtures/ e il GTFS estratto in
// data/gtfs/ (serve per risolvere i nomi di linea della tabella).
import 'dart:io';

import 'package:gtt_deviazioni/core/config.dart';
import 'package:gtt_deviazioni/core/gtfs/csv.dart';
import 'package:gtt_deviazioni/core/gtfs/gtfs_parser.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/pipeline/line_resolver.dart';
import 'package:gtt_deviazioni/core/pipeline/notice_merge.dart';
import 'package:gtt_deviazioni/core/sources/alerts_source.dart';
import 'package:gtt_deviazioni/core/sources/variazioni_source.dart';

Future<void> main() async {
  final dir = Directory('../data/gtfs');
  if (!File('${dir.path}/routes.txt').existsSync()) {
    stdout.writeln('manca il GTFS: cd data && unzip -o gtt_gtfs-*.zip -d gtfs');
    exit(1);
  }

  final index = await GtfsParser(directory: dir)
      .build(_allShortNames(dir), withStops: false);
  final resolver = LineResolver(index);

  final alerts = AlertsSource()
      .parse(File('test/fixtures/alerts.pb').readAsBytesSync())
      .where((n) => n.mentionsRouteChange)
      .toList();
  final web = VariazioniSource()
      .parse(File('test/fixtures/variazioni.html').readAsStringSync())
      .where((n) => n.mentionsRouteChange)
      .toList();
  final all = [...alerts, ...web];
  stdout.writeln('avvisi di variazione: ${alerts.length} dal feed, '
      '${web.length} dalla tabella');
  stdout.writeln('soglie: contenimento >= ${GttConfig.mergeMinStreetOverlap}, '
      'vie in comune >= ${GttConfig.mergeMinSharedStreets}\n');

  var prima = 0;
  var dopo = 0;
  var unite = 0;
  var conDataCambiata = 0;
  final righe = <List<String>>[];

  for (final line in index.lines.values) {
    final mie = all
        .where((n) =>
            n.routeIds.contains(line.routeId) ||
            n.lineHints.any((h) => resolver
                .resolve(h)
                .resolved
                .any((l) => l.routeId == line.routeId)))
        .toList();
    if (mie.isEmpty) continue;

    final merged = NoticeMerge.dedupe(mie);
    prima += mie.length;
    dopo += merged.length;

    for (final n in merged.where((n) => n.isMerged)) {
      unite++;
      final alert =
          n.mergedFrom.firstWhere((m) => m.source == NoticeSource.gtfsRtAlert);
      final tabella =
          n.mergedFrom.firstWhere((m) => m.source == NoticeSource.webVariazioni);
      // Il caso che conta: la data d'inizio cambia perche' quella
      // dell'alert era l'ora di pubblicazione.
      final cambia = alert.validFrom != null &&
          tabella.validFrom != null &&
          alert.validFrom!.difference(tabella.validFrom!).inHours.abs() > 24;
      if (cambia) conDataCambiata++;
      righe.add([
        line.shortName,
        NoticeMerge.similarity(alert, tabella)!.toStringAsFixed(2),
        '${NoticeMerge.streetsIn(alert.fullText).intersection(NoticeMerge.streetsIn(tabella.fullText)).length}',
        cambia ? 'DATA CAMBIA' : '',
        '${_d(alert.validFrom)} → ${_d(tabella.validFrom)}',
        n.text.length > 70 ? '${n.text.substring(0, 70)}…' : n.text,
      ]);
    }

    // Le coppie NON unite servono a vedere il confine da sotto.
    for (var i = 0; i < mie.length; i++) {
      for (var j = i + 1; j < mie.length; j++) {
        if (mie[i].source == mie[j].source) continue;
        if (NoticeMerge.similarity(mie[i], mie[j]) != null) continue;
        final sa = NoticeMerge.streetsIn(mie[i].fullText);
        final sb = NoticeMerge.streetsIn(mie[j].fullText);
        final shared = sa.intersection(sb).length;
        final smaller = sa.length < sb.length ? sa.length : sb.length;
        if (shared < 2) continue; // troppo lontane per essere interessanti
        stderr.writeln('scartata  ${line.shortName}\t'
            '${smaller == 0 ? "0.00" : (shared / smaller).toStringAsFixed(2)}'
            '\t∩=$shared\t${sa.intersection(sb).join(" ")}');
      }
    }
  }

  righe.sort((a, b) => b[1].compareTo(a[1]));
  stdout.writeln('linea\tcont\t∩\tdata\tinizio alert → inizio tabella\ttesto');
  for (final r in righe) {
    stdout.writeln(r.join('\t'));
  }

  stdout.writeln('\ncoppie unite: $unite');
  stdout.writeln('di cui con la data d\'inizio corretta di piu\' di un '
      'giorno: $conDataCambiata');
  stdout.writeln('avvisi da analizzare: $prima → $dopo '
      '(${prima - dopo} richieste LLM risparmiate, su 50 al giorno)');
  stdout.writeln('\nle coppie scartate stanno su stderr, col loro punteggio');
}

List<String> _allShortNames(Directory dir) {
  final lines = File('${dir.path}/routes.txt').readAsLinesSync();
  final header = Csv.split(lines.first.replaceAll('﻿', ''));
  final i = header.indexOf('route_short_name');
  return [
    for (final l in lines.skip(1))
      if (l.trim().isNotEmpty && Csv.split(l).length > i) Csv.split(l)[i],
  ];
}

String _d(DateTime? t) => t == null
    ? '—'
    : '${t.day.toString().padLeft(2, "0")}/'
        '${t.month.toString().padLeft(2, "0")}';
